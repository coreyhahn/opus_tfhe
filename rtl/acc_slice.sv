// Accumulator slice for one RNS residue (docs/ARCHITECTURE.md §3, §4.2): y-form ACC of 2^BSLOG
// ciphertext slots x 2 polynomials, block layout (lane q at frame time tau = position q*FR + tau).
//
// Read side, one frame of FR cycles per command (cmd_start = first cycle):
//   CMUX    (0): d0/d1 = rot(ACC_slot, cmd_rot) - ACC_slot, per polynomial (mod p)
//   INIT    (1): d0/d1 = 0 (the accumulate side writes rot(LUT, rot) for this frame)
//   EXTRACT (2): d0 = sample-extracted mask (out[0] = A[0], out[j] = -A[N-j]), d1 = body polynomial
// Accumulate side, one frame per a_sof: ACC_slot <- base + O, base = ACC_slot (CMUX) or
//   (0, rot(LUT, a_rot)) (INIT). Written to all three copies.
// Copies: R serves rotated reads, U unrotated reads, A the accumulate read; each is a simple
// dual-port RAM written by the accumulate side. The sequencer guarantees that a slot is never read
// while its previous frame is still accumulating.
// Rotation by X^r, r = A*FR + alpha: source time (tau - alpha) mod FR is the same for every lane;
// lane q takes source lane v mod P, v = (q - A - [tau < alpha]) mod 2P, negated if v >= P.
// Read latency 7 (input register, address, RAM, RAM output register, 3-stage permute, subtract ->
// registered out); accumulate latency 7 (input register, address, RAM, RAM output register,
// 3-stage permute, base, add/write).
module acc_slice #(
  parameter int P     = 249857,
  parameter int PLOG  = 5,
  parameter int BSLOG = 2
) (
  input  logic                         clk,
  input  logic                         rst,
  input  logic                         lut_we,
  input  logic [ntt_pkg::LOG_N-PLOG-1:0] lut_addr,
  input  logic [(1<<PLOG)*18-1:0]      lut_wdata,
  input  logic                         cmd_start,
  input  logic [1:0]                   cmd_type,
  input  logic [BSLOG-1:0]             cmd_slot,
  input  logic [ntt_pkg::LOG_N:0]      cmd_rot,
  output logic                         d_valid,
  output logic                         d_sof,
  output logic [1:0]                   d_type,
  output logic [BSLOG-1:0]             d_slot,
  output logic [ntt_pkg::LOG_N:0]      d_rot,
  output logic [(1<<PLOG)*18-1:0]      d0,
  output logic [(1<<PLOG)*18-1:0]      d1,
  input  logic                         a_valid,
  input  logic                         a_sof,
  input  logic [1:0]                   a_type,
  input  logic [BSLOG-1:0]             a_slot,
  input  logic [ntt_pkg::LOG_N:0]      a_rot,
  input  logic [(1<<PLOG)*18-1:0]      o0,
  input  logic [(1<<PLOG)*18-1:0]      o1
);
  localparam int PP = 1 << PLOG;
  localparam int FB = ntt_pkg::LOG_N - PLOG;    // frame-local time bits
  localparam int FR = 1 << FB;
  localparam int AW = BSLOG + FB;
  localparam int W  = PP * 18;
  localparam int RB = ntt_pkg::LOG_N + 1;       // rotation amount bits, [0, 2N)
  localparam logic [17:0] P18 = 18'(P);
  localparam logic [18:0] P19 = 19'(P);

  typedef logic [W-1:0] word_t;

  // ------------------------------------------------------------------ input registers
  // The sequencer (cmd_*) and the accumulate metadata (a_*) come from br_core, outside the
  // residue's SLR: one register stage here takes the crossing (read and accumulate latency +1).
  logic            c_start, q_valid, q_sof;
  logic [1:0]      c_type, q_type;
  logic [BSLOG-1:0] c_slot, q_slot;
  logic [ntt_pkg::LOG_N:0] c_rot, q_rot;
  logic [(1<<PLOG)*18-1:0] q_o0, q_o1;
  always_ff @(posedge clk) begin
    c_start <= cmd_start && !rst;
    c_type  <= cmd_type;
    c_slot  <= cmd_slot;
    c_rot   <= cmd_rot;
    q_valid <= a_valid && !rst;
    q_sof   <= a_sof && !rst;
    q_type  <= a_type;
    q_slot  <= a_slot;
    q_rot   <= a_rot;
    q_o0    <= o0;
    q_o1    <= o1;
  end

  function automatic logic [17:0] negm(input logic [17:0] x);
    return (x == 0) ? 18'd0 : 18'(P18 - x);
  endfunction

  // ------------------------------------------------------------------ memories
  logic          w_en;
  (* max_fanout = 32 *) logic [AW-1:0] w_addr;
  word_t         w_d [2];
  logic [AW-1:0] r_addr_r, r_addr_u, r_addr_a;
  word_t         r_r [2], r_u [2], r_a [2];      // registered RAM outputs
  word_t         r_r2 [2], r_u2 [2], r_a2 [2];   // RAM output registers
  for (genvar k = 0; k < 2; k++) begin : g_poly
    (* ram_style = "block" *) word_t cr [1 << AW];
    (* ram_style = "block" *) word_t cu [1 << AW];
    (* ram_style = "block" *) word_t ca [1 << AW];
    always_ff @(posedge clk) begin
      if (w_en) begin
        cr[w_addr] <= w_d[k];
        cu[w_addr] <= w_d[k];
        ca[w_addr] <= w_d[k];
      end
      r_r[k]  <= cr[r_addr_r];
      r_u[k]  <= cu[r_addr_u];
      r_a[k]  <= ca[r_addr_a];
      r_r2[k] <= r_r[k];
      r_u2[k] <= r_u[k];
      r_a2[k] <= r_a[k];
    end
  end
  (* ram_style = "block" *) word_t lut [FR];
  logic [FB-1:0] l_addr;
  word_t         l_q, l_q2;
  // LUT writes come from the io window in SLR1: registered here, on the residue's side
  logic          lw_we;
  logic [FB-1:0] lw_a;
  word_t         lw_d;
  always_ff @(posedge clk) begin
    lw_we <= lut_we && !rst;
    lw_a  <= lut_addr;
    lw_d  <= lut_wdata;
    if (lw_we) lut[lw_a] <= lw_d;
    l_q  <= lut[l_addr];
    l_q2 <= l_q;
  end

  // ------------------------------------------------------------------ read side
  logic            rd_on;
  logic [FB-1:0]   rd_tau;
  logic [1:0]      rd_type;
  logic [BSLOG-1:0] rd_slot;
  logic [RB-1:0]   rd_rot;
  wire             f_on   = c_start || rd_on;
  wire  [FB-1:0]   f_tau  = c_start ? '0 : rd_tau;
  wire  [1:0]      f_type = c_start ? c_type : rd_type;
  wire  [BSLOG-1:0] f_slot = c_start ? c_slot : rd_slot;
  wire  [RB-1:0]   f_rot  = c_start ? c_rot : rd_rot;

  // rotation decomposition for this cycle
  wire  [FB-1:0]   f_alpha  = f_rot[FB-1:0];
  wire  [PLOG:0]   f_A      = f_rot[RB-1:FB];
  wire             f_borrow = (f_tau < f_alpha);
  wire  [FB-1:0]   f_tsrc   = f_tau - f_alpha;            // mod FR
  wire  [PLOG:0]   f_rr     = f_A + (PLOG+1)'(f_borrow);  // mod 2P
  wire             f_ext    = (f_type == 2'd2);
  always_comb begin
    r_addr_u = {f_slot, f_tau};
    r_addr_r = f_ext ? {f_slot, FB'(-f_tau)} : {f_slot, f_tsrc};
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      rd_on <= 1'b0;
      rd_tau <= '0;
    end else begin
      if (c_start) begin
        rd_type <= c_type;
        rd_slot <= c_slot;
        rd_rot  <= c_rot;
      end
      rd_on  <= f_on && (f_tau != FB'(FR - 1));
      rd_tau <= f_tau + 1'b1;
    end
  end

  // metadata pipeline, stage 0 = address cycle
  localparam int RL = 5;
  logic            m_v   [RL];
  logic            m_sof [RL];
  logic [1:0]      m_ty  [RL];
  logic [BSLOG-1:0] m_sl [RL];
  logic [RB-1:0]   m_rot [RL];
  (* max_fanout = 32 *) logic [PLOG:0]   m_rr  [RL];
  logic            m_t0  [RL];
  always_ff @(posedge clk) begin
    m_v[0]   <= f_on && !rst;
    m_sof[0] <= f_on && (f_tau == 0);
    m_ty[0]  <= f_type;
    m_sl[0]  <= f_slot;
    m_rot[0] <= f_rot;
    m_rr[0]  <= f_ext ? (PLOG+1)'(f_tau == 0) : f_rr;
    m_t0[0]  <= (f_tau == 0);
    for (int i = 1; i < RL; i++) begin
      m_v[i] <= m_v[i-1]; m_sof[i] <= m_sof[i-1]; m_ty[i] <= m_ty[i-1]; m_sl[i] <= m_sl[i-1];
      m_rot[i] <= m_rot[i-1]; m_rr[i] <= m_rr[i-1]; m_t0[i] <= m_t0[i-1];
    end
  end

  // stages 2..4 (RAM output registers valid at 2): permute; stage 5: subtract -> outputs
  word_t pr0, pr1, pu0, pu1, pu0_d [2], pu1_d [2];
  lane_perm #(.P(P), .PLOG(PLOG)) u_pr0 (.clk(clk), .x(r_r2[0]), .rr(m_rr[0]), .rev(m_ty[0] == 2'd2), .ext_t0(m_t0[0]), .y(pr0));
  lane_perm #(.P(P), .PLOG(PLOG)) u_pr1 (.clk(clk), .x(r_r2[1]), .rr(m_rr[0]), .rev(1'b0), .ext_t0(1'b0), .y(pr1));
  always_ff @(posedge clk) begin
    pu0_d[0] <= r_u2[0]; pu0_d[1] <= pu0_d[0]; pu0 <= pu0_d[1];
    pu1_d[0] <= r_u2[1]; pu1_d[1] <= pu1_d[0]; pu1 <= pu1_d[1];
    for (int q = 0; q < PP; q++) begin
      case (m_ty[4])
        2'd0: begin
          d0[q*18 +: 18] <= 18'(ntt_pkg::mod_sub(pr0[q*18 +: 18], pu0[q*18 +: 18], P19));
          d1[q*18 +: 18] <= 18'(ntt_pkg::mod_sub(pr1[q*18 +: 18], pu1[q*18 +: 18], P19));
        end
        2'd2: begin
          d0[q*18 +: 18] <= pr0[q*18 +: 18];
          d1[q*18 +: 18] <= pu1[q*18 +: 18];
        end
        default: begin
          d0[q*18 +: 18] <= '0;
          d1[q*18 +: 18] <= '0;
        end
      endcase
    end
    d_valid <= m_v[4];
    d_sof   <= m_sof[4];
    d_type  <= m_ty[4];
    d_slot  <= m_sl[4];
    d_rot   <= m_rot[4];
  end

  // ------------------------------------------------------------------ accumulate side
  logic [FB-1:0]   a_tau_r;
  logic [1:0]      a_type_r;
  logic [BSLOG-1:0] a_slot_r;
  logic [RB-1:0]   a_rot_r;
  wire  [FB-1:0]   g_tau  = q_sof ? '0 : a_tau_r;
  wire  [1:0]      g_type = q_sof ? q_type : a_type_r;
  wire  [BSLOG-1:0] g_slot = q_sof ? q_slot : a_slot_r;
  wire  [RB-1:0]   g_rot  = q_sof ? q_rot : a_rot_r;
  wire  [FB-1:0]   g_alpha = g_rot[FB-1:0];
  wire             g_borrow = (g_tau < g_alpha);
  // r_addr_a / l_addr are next cycle's {g_slot, g_tau} and g_tau - g_alpha, computed from this
  // cycle's inputs (q_* <= a_*, a_*_r as below) and registered: the BRAM addresses leave flops,
  // not the q_sof mux (build 010: q_sof -> ca ADDR, 3.6 ns route at 250 MHz). Same values, same cycle.
  wire  [FB-1:0]    x_tau  = a_sof ? '0 : (q_valid ? g_tau + 1'b1 : a_tau_r);
  wire  [BSLOG-1:0] x_slot = a_sof ? a_slot : (q_valid ? g_slot : a_slot_r);
  wire  [FB-1:0]    x_alpha = a_sof ? a_rot[FB-1:0] : (q_valid ? g_alpha : a_rot_r[FB-1:0]);
  (* max_fanout = 16 *) logic [AW-1:0] ra_q;
  (* max_fanout = 16 *) logic [FB-1:0] la_q;
  always_ff @(posedge clk) begin
    ra_q <= {x_slot, x_tau};
    la_q <= x_tau - x_alpha;
  end
  always_comb begin
    r_addr_a = ra_q;
    l_addr   = la_q;
  end
  always_ff @(posedge clk) begin
    if (q_valid) begin
      a_tau_r  <= g_tau + 1'b1;
      a_type_r <= g_type;
      a_slot_r <= g_slot;
      a_rot_r  <= g_rot;
    end
  end
  localparam int AL = 6;                 // address cycle -> write (RAM, RAM reg, 3-stage permute, base)
  logic            n_v  [AL];
  (* max_fanout = 32 *) logic            n_in [AL];            // INIT frame
  logic [AW-1:0]   n_ad [AL];
  (* max_fanout = 32 *) logic [PLOG:0]   n_rr [AL];
  word_t           n_o0 [AL], n_o1 [AL];
  always_ff @(posedge clk) begin
    n_v[0]  <= q_valid && !rst;
    n_in[0] <= (g_type == 2'd1);
    n_ad[0] <= {g_slot, g_tau};
    n_rr[0] <= g_rot[RB-1:FB] + (PLOG+1)'(g_borrow);
    n_o0[0] <= q_o0;
    n_o1[0] <= q_o1;
    for (int i = 1; i < AL; i++) begin
      n_v[i] <= n_v[i-1]; n_in[i] <= n_in[i-1]; n_ad[i] <= n_ad[i-1]; n_rr[i] <= n_rr[i-1];
      n_o0[i] <= n_o0[i-1]; n_o1[i] <= n_o1[i-1];
    end
  end
  // stage 2: RAM output registers valid (r_a2 / l_q2); stages 2..4: LUT permute (INIT frames)
  word_t base0, base1, lp, ra0_d [3], ra1_d [3];
  lane_perm #(.P(P), .PLOG(PLOG)) u_pl (.clk(clk), .x(l_q2), .rr(n_rr[0]), .rev(1'b0), .ext_t0(1'b0), .y(lp));
  always_ff @(posedge clk) begin
    ra0_d[0] <= r_a2[0]; ra0_d[1] <= ra0_d[0]; ra0_d[2] <= ra0_d[1];
    ra1_d[0] <= r_a2[1]; ra1_d[1] <= ra1_d[0]; ra1_d[2] <= ra1_d[1];
    // stage 5: base
    base0 <= n_in[4] ? '0 : ra0_d[2];
    base1 <= n_in[4] ? lp : ra1_d[2];
    // stage 6: add and write
    w_en   <= n_v[5];
    w_addr <= n_ad[5];
    for (int q = 0; q < PP; q++) begin
      w_d[0][q*18 +: 18] <= 18'(ntt_pkg::mod_add(base0[q*18 +: 18], n_o0[5][q*18 +: 18], P19));
      w_d[1][q*18 +: 18] <= 18'(ntt_pkg::mod_add(base1[q*18 +: 18], n_o1[5][q*18 +: 18], P19));
    end
  end
endmodule

// Lane permutation of one P-lane word, 3 registered stages (latency 3). The selects (rr, rev,
// ext_t0) are presented ONE CYCLE BEFORE x and registered per lane, so no single register drives
// the select of all 32 x 18 output bits (a -3.6 ns route-bound path in the routed engine).
//   y[q] = +/- x'[(q - rr) mod P], x' = reversed x if rev else x; the sign: rev -> negate every lane
//   but lane 0 when ext_t0; else negate where (q - rr) mod 2P >= P (rr in [0, 2P)).
// Stage 1: reversal + rotation by rr[1:0]; stage 2: rotation by rr[PLOG-1:2]; stage 3: negation.
/* verilator lint_off DECLFILENAME */
module lane_perm #(
  parameter int P    = 249857,
  parameter int PLOG = 5
) (
  input  logic                    clk,
  input  logic [(1<<PLOG)*18-1:0] x,
  input  logic [PLOG:0]           rr,
  input  logic                    rev,
  input  logic                    ext_t0,
  output logic [(1<<PLOG)*18-1:0] y
);
  localparam int PP = 1 << PLOG;
  localparam logic [17:0] P18 = 18'(P);
  logic [PP*18-1:0] ya, yb;
  logic [PLOG:0]    rr_l [PP];
  logic             rev_l [PP], ext_l [PP];
  logic [PLOG-1:2]  rhi [PP];
  logic [PP-1:0]    nma, nmb;
  always_ff @(posedge clk) begin
    for (int q = 0; q < PP; q++) begin
      rr_l[q]  <= rr;
      rev_l[q] <= rev;
      ext_l[q] <= ext_t0;
    end
    for (int q = 0; q < PP; q++) begin
      int s, v;
      s = (q - int'(rr_l[q][1:0])) & (PP - 1);
      ya[q*18 +: 18] <= rev_l[q] ? x[(PP - 1 - s)*18 +: 18] : x[s*18 +: 18];
      v = (q - int'(rr_l[q])) & (2 * PP - 1);
      nma[q] <= rev_l[q] ? !(ext_l[q] && q == 0) : (v >= PP);
      rhi[q] <= rr_l[q][PLOG-1:2];
    end
    for (int q = 0; q < PP; q++) yb[q*18 +: 18] <= ya[((q - 4 * int'(rhi[q])) & (PP - 1))*18 +: 18];
    nmb <= nma;
    for (int q = 0; q < PP; q++)
      y[q*18 +: 18] <= (nmb[q] && yb[q*18 +: 18] != 0) ? 18'(P18 - yb[q*18 +: 18]) : yb[q*18 +: 18];
  end
endmodule
/* verilator lint_on DECLFILENAME */
