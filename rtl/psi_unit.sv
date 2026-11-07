// psi: y-form RNS residues -> 64-bit torus, for the sample-extracted LWE of each slot
// (docs/ARCHITECTURE.md §4.4; bit-exact target Rns::psi with F = 28):
//   out = ((sum_i y_i K'_i + 2^(F-1)) >> F) mod 2^64,  K'_i = round(2^(64+F) / p_i)
// Only the low 64 + F bits of the sum matter, so each product is kept mod 2^(64+F).
// Input: the EXTRACT stream of br_core (FR beats of 3 residues x P lanes, block layout, body[0]
// with the first beat). Each slot's frame is buffered, then emitted serially, one word per cycle:
// index 0..N-1 = the mask (position j = lane q * FR + beat tau), index N = body. A slot's output
// starts once its frame is complete; outputs keep slot order.
module psi_unit #(
  parameter int PLOG  = 5,
  parameter int BSLOG = 3
) (
  input  logic                         clk,
  input  logic                         rst,
  input  logic                         ex_valid,
  input  logic                         ex_sof,
  input  logic [BSLOG-1:0]             ex_slot,
  input  logic [3*(1<<PLOG)*18-1:0]    ex_d,
  input  logic [3*18-1:0]              ex_body,
  output logic                         o_valid,
  output logic [BSLOG-1:0]             o_slot,
  output logic [11:0]                  o_idx,
  output logic [63:0]                  o_data
);
  localparam int PP = 1 << PLOG;
  localparam int FB = ntt_pkg::LOG_N - PLOG;
  localparam int FR = 1 << FB;
  localparam int BS = 1 << BSLOG;
  localparam int F  = 28;
  localparam int SW = 64 + F;                    // kept sum width
  localparam longint PR [3] = '{249857, 188417, 163841};

  // K'_i = round(2^(64+F) / p_i), a 75-bit constant (computed in 128-bit halves)
  function automatic logic [SW-1:0] kout(input logic [1:0] i);
    logic [127:0] num, den;
    den = 128'(PR[i]);
    num = (128'(1) << (64 + F)) + (den >> 1);
    return SW'(num / den);
  endfunction
  localparam logic [SW-1:0] K0 = kout(0), K1 = kout(1), K2 = kout(2);

  // ---- frame buffer: {slot, beat} -> 3 residues x P lanes; bodies per slot
  logic [3*PP*18-1:0] fbuf [BS * FR];
  logic [3*18-1:0]    body [BS];
  logic [FB-1:0]      in_beat;
  logic [BSLOG-1:0]   in_slot;
  logic [BS-1:0]      ready;                  // frame of slot complete, not yet emitted
  // the write is registered once (address, data, enables) so the BRAM address fanout starts here
  logic                     w_v, w_b;
  (* max_fanout = 16 *) logic [BSLOG+FB-1:0] w_a;
  logic [BSLOG-1:0]         w_bs;
  logic [3*PP*18-1:0]       w_d;
  logic [3*18-1:0]          w_body;
  always_ff @(posedge clk) begin
    w_v    <= ex_valid && !rst;
    w_b    <= ex_valid && ex_sof && !rst;
    w_a    <= {ex_sof ? ex_slot : in_slot, ex_sof ? '0 : in_beat};
    w_bs   <= ex_slot;
    w_d    <= ex_d;
    w_body <= ex_body;
    if (w_v) fbuf[w_a] <= w_d;
    if (w_b) body[w_bs] <= w_body;
  end

  // ---- serial emitter
  logic             run;
  logic [BSLOG-1:0] e_slot;
  logic [11:0]      e_idx;                    // 0..N
  logic [3*PP*18-1:0] rd_q;
  logic [3*18-1:0]  bd_q;
  logic [PLOG-1:0]  lane_d;
  logic             v1, isbody1;
  logic [BSLOG-1:0] s1;
  logic [11:0]      i1;
  wire  [FB-1:0]    e_beat = e_idx[FB-1:0];
  wire  [PLOG-1:0]  e_lane = e_idx[FB +: PLOG];
  always_ff @(posedge clk) begin
    rd_q <= fbuf[{e_slot, e_beat}];
    bd_q <= body[e_slot];
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      in_beat <= '0;
      ready <= '0;
      run <= 1'b0;
      e_slot <= '0;
      e_idx <= '0;
      v1 <= 1'b0;
    end else begin
      // input side
      if (ex_valid) begin
        if (ex_sof) begin
          in_slot <= ex_slot;
          in_beat <= FB'(1);
        end else begin
          in_beat <= in_beat + 1'b1;
          if (in_beat == FB'(FR - 1)) ready[in_slot] <= 1'b1;
        end
      end
      // emit side: slots in order 0..BS-1, each once its frame is ready
      v1 <= 1'b0;
      if (!run) begin
        if (ready[e_slot]) begin
          run <= 1'b1;
          e_idx <= '0;
        end
      end else begin
        v1 <= 1'b1;
        s1 <= e_slot;
        i1 <= e_idx;
        lane_d <= e_lane;
        isbody1 <= (e_idx == 12'(ntt_pkg::N));
        if (e_idx == 12'(ntt_pkg::N)) begin
          run <= 1'b0;
          ready[e_slot] <= 1'b0;
          e_slot <= e_slot + 1'b1;
        end else begin
          e_idx <= e_idx + 1'b1;
        end
      end
    end
  end

  // ---- psi arithmetic: select (two stages: lane[2:0] of each group of 8, then the group),
  // multiply, sum, round (pipelined)
  localparam int NG = (PP + 7) / 8;
  logic [17:0]    ya [3][NG];
  logic [17:0]    y [3];
  logic [17:0]    bd_a [3];
  logic           va, isbody_a;
  logic [BSLOG-1:0] sa;
  logic [11:0]    ia;
  logic [PLOG-1:0] lane_a;
  // lane g * 8 + l of residue r, constant indices (an index computed from lane_d was mapped to a DSP)
  logic [17:0]    grp [3][NG][8];
  always_comb
    for (int r = 0; r < 3; r++)
      for (int g = 0; g < NG; g++)
        for (int l = 0; l < 8; l++)
          grp[r][g][l] = rd_q[(r*PP + (g * 8 + l) % PP)*18 +: 18];
  logic           v2, v3, v4;
  logic [BSLOG-1:0] s2, s3, s4;
  logic [11:0]    i2, i3, i4;
  logic [SW-1:0]  pr [3];
  logic [SW-1:0]  sum;
  always_ff @(posedge clk) begin
    for (int r = 0; r < 3; r++) begin
      for (int g = 0; g < NG; g++)
        ya[r][g] <= grp[r][g][lane_d[(PLOG >= 3 ? 2 : PLOG - 1):0]];
      bd_a[r] <= bd_q[r*18 +: 18];
    end
    va <= v1 && !rst; sa <= s1; ia <= i1; isbody_a <= isbody1; lane_a <= lane_d;
    for (int r = 0; r < 3; r++)
      y[r] <= isbody_a ? bd_a[r] : ya[r][int'(lane_a) >> 3];
    v2 <= va && !rst; s2 <= sa; i2 <= ia;
    pr[0] <= SW'(K0 * SW'(y[0]));
    pr[1] <= SW'(K1 * SW'(y[1]));
    pr[2] <= SW'(K2 * SW'(y[2]));
    v3 <= v2; s3 <= s2; i3 <= i2;
    sum <= pr[0] + pr[1] + pr[2];
    v4 <= v3; s4 <= s3; i4 <= i3;
    o_valid <= v4;
    o_slot  <= s4;
    o_idx   <= i4;
    o_data  <= 64'((sum + SW'(1 << (F - 1))) >> F);
  end
endmodule
