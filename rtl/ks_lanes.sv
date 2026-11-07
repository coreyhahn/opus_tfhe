// One lane group of ks32: its slice of the KSK (ksk_ram), its MACs and its slice of the
// accumulator. The KSK needs 820 of the VU9P's 960 URAMs, so it spans all three SLRs; every
// control input is registered here first (one copy per group, placed with the group's URAMs)
// so that only these few bits cross SLRs. Every control gets two stages (one on each side of the
// SLR crossing); the second copy of the accumulator controls is replicated (max_fanout), as each
// drives the clock enables of W x LG x 32 registers. ks32 sees lane0 move two cycles after i_sh/i_adv.
//
// Accumulator: W words of LG lanes x 32 bits.
//   i_init: words <- 0, except the body word i_body at (INIT_WORD, INIT_LANE) if INIT_LANE >= 0
//   i_v:    acc[i_k] -= i_d * KSK[i_ka] per lane (mod 2^32), written 6 + KRL - 2 cycles after i_v (the
//           last write lands before the first i_sh of ks32's output: K_DRAIN covers it)
//   i_sh:   word 0 shifts down one lane, sh_in enters at the top lane
//   i_adv:  words move down one (acc[k] <= acc[k+1]), the last word is cleared
// lane0 is word 0's lane 0 (registered state, valid the cycle after the control that set it).
module ks_lanes #(
  parameter int LG        = 16,
  parameter int W         = 5,
  parameter int DEPTH     = 1024,
  parameter int INIT_LANE = -1,
  parameter int INIT_WORD = 0
) (
  input  logic                     clk,
  input  logic                     rst,
  input  logic                     ksk_we,
  input  logic [$clog2(DEPTH)-1:0] ksk_addr,
  input  logic [LG*32-1:0]         ksk_wdata,
  input  logic                     i_init,
  input  logic [31:0]              i_body,
  input  logic                     i_v,
  input  logic [((W > 1) ? $clog2(W) : 1)-1:0] i_k,
  input  logic signed [4:0]        i_d,
  input  logic [$clog2(DEPTH)-1:0] i_ka,
  input  logic                     i_sh,
  input  logic                     i_adv,
  input  logic [31:0]              sh_in,
  output logic [31:0]              lane0
);
  localparam int AW = $clog2(DEPTH);
  localparam int WB = (W > 1) ? $clog2(W) : 1;
  localparam int IL = (INIT_LANE >= 0) ? INIT_LANE : 0;
  if (LG < 2) begin : g_bad_lg $error("ks_lanes: LG must be >= 2"); end

  // ---- the group's copy of every control
  logic          x_we, x_init, x_v, x_sh, x_adv;
  logic [AW-1:0] x_wa, x_ka;
  logic [LG*32-1:0] x_wd;
  logic [31:0]   x_body;
  logic [WB-1:0] x_k;
  logic signed [4:0] x_d;
  always_ff @(posedge clk) begin
    x_we   <= ksk_we && !rst;
    x_wa   <= ksk_addr;
    x_wd   <= ksk_wdata;
    x_init <= i_init && !rst;
    x_body <= i_body;
    x_v    <= i_v && !rst;
    x_k    <= i_k;
    x_d    <= i_d;
    x_ka   <= i_ka;
    x_sh   <= i_sh && !rst;
    x_adv  <= i_adv && !rst;
  end
  logic          r_we, r_v;
  (* max_fanout = 256 *) logic r_init, r_sh, r_adv;
  logic [AW-1:0] r_wa;
  (* max_fanout = 16 *) logic [AW-1:0] r_ka;
  logic [LG*32-1:0] r_wd;
  logic [31:0]   r_body;
  logic [WB-1:0] r_k, q_k;
  logic signed [4:0] r_d;
  (* max_fanout = 16 *) logic signed [4:0] q_d;
  logic          q_v;
  localparam int KRL = 5;               // ksk_ram read latency (pipelined URAM cascade), >= 3; 5 since
                                        // build 010 (URAM -> MAC input -0.24 ns with 0.4 ns skew)
  localparam int ED  = KRL - 2;         // extra metadata stages beyond the latency-2 alignment
  logic          e_v [ED];
  logic [WB-1:0] e_k [ED];
  (* max_fanout = 16 *) logic signed [4:0] e_d [ED];
  always_ff @(posedge clk) begin
    r_we   <= x_we && !rst;
    r_wa   <= x_wa;
    r_wd   <= x_wd;
    r_init <= x_init && !rst;
    r_body <= x_body;
    r_v    <= x_v && !rst;
    r_k    <= x_k;
    r_d    <= x_d;
    r_ka   <= x_ka;
    r_sh   <= x_sh && !rst;
    r_adv  <= x_adv && !rst;
    // aligned with kq2: ksk_ram read latency KRL from r_ka
    e_v[0] <= r_v && !rst;
    e_k[0] <= r_k;
    e_d[0] <= r_d;
    for (int k = 1; k < ED; k++) begin
      e_v[k] <= e_v[k-1] && !rst;
      e_k[k] <= e_k[k-1];
      e_d[k] <= e_d[k-1];
    end
    q_v    <= e_v[ED-1] && !rst;
    q_k    <= e_k[ED-1];
    q_d    <= e_d[ED-1];
  end

  logic [LG*32-1:0] kq2;
  ksk_ram #(.DW(LG*32), .DEPTH(DEPTH), .RL(KRL)) u_ksk (
    .clk, .we(r_we), .wa(r_wa), .wd(r_wd), .ra(r_ka), .q(kq2));

  // MAC, 3 registered stages: (1) the KSK word, digit and word index; (2) the two partial products
  // acc - d*w = acc - d*w_lo - (d*w_hi)*2^17 (mod 2^32), w_lo = w[16:0], w_hi = w[31:17], each a
  // DSP48E2 multiply with its output register; (3) acc[k] -= both. A word is rewritten every W
  // cycles at most, and the read-modify-write is all in stage 3, so the pipeline needs no bypass.
  logic [LG*32-1:0] acc [W];
  logic [LG*32-1:0] w1;
  logic signed [4:0] d1;
  logic [WB-1:0] k1;
  (* max_fanout = 64 *) logic [WB-1:0] k2;
  logic          v1;
  (* max_fanout = 64 *) logic v2;
  (* use_dsp = "yes" *) logic [LG*23-1:0] plo;
  (* use_dsp = "yes" *) logic [LG*15-1:0] phi;   // (d*w_hi) mod 2^15: only those bits survive the *2^17
  always_ff @(posedge clk) begin
    w1 <= kq2;
    d1 <= q_d;
    k1 <= q_k;
    v1 <= q_v && !rst;
    k2 <= k1;
    v2 <= v1 && !rst;
    for (int l = 0; l < LG; l++) begin
      plo[l*23 +: 23] <= 23'($signed(d1) * $signed({1'b0, w1[l*32 +: 17]}));
      phi[l*15 +: 15] <= 15'($signed(d1) * $signed({1'b0, w1[l*32 + 17 +: 15]}));
    end
  end
  logic [LG*32-1:0] mac_w;
  always_comb begin
    for (int l = 0; l < LG; l++)
      mac_w[l*32 +: 32] = acc[k2][l*32 +: 32] - 32'($signed(plo[l*23 +: 23])) - {phi[l*15 +: 15], 17'b0};
  end
  always_ff @(posedge clk) begin
    if (r_init) begin
      for (int k = 0; k < W; k++) begin
        acc[k] <= '0;
        if (INIT_LANE >= 0 && k == INIT_WORD) acc[k][IL*32 +: 32] <= r_body;
      end
    end else if (v2) begin
      acc[k2] <= mac_w;
    end else if (r_adv) begin
      for (int k = 0; k < W - 1; k++) acc[k] <= acc[k + 1];
      acc[W - 1] <= '0;
    end else if (r_sh) begin
      acc[0] <= {sh_in, acc[0][LG*32-1:32]};
    end
  end
  assign lane0 = acc[0][31:0];
endmodule
