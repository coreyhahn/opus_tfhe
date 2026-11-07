// Key switch (KS32) + centred modulus switch, one ciphertext at a time (docs/ARCHITECTURE.md §4.5).
// Bit-exact target: tfhe.rs keyswitch + modulus_switch_centered = tfhe-rs's own KS32 -> MS
// (ref_ks_out.u32 / ref_ms.u32 of the oracle).
//
//   out[0..n-1] = 0, out[n] = round(body to its top 32 bits); for every input mask element i
//   (k*N = 2048) and decomposition level j = 1..4 (digit d_ij of a_i, base 2^4, balanced, tfhe-rs
//   tie rules): out -= d_ij * KSK[i][stored level 4-j][0..n] (mod 2^32).
//   Then the centred modulus switch to 2N = 4096: masks round(a / 2^20); the body gets
//   sum_i (round(a_i) - a_i)/2 (tfhe-rs's exact halving rule) - 2^19 before rounding.
//
// KSK memory: row r = i*4 + stored_level, W = ceil((n+1)/L) words of L x 32 bits per row
// (lanes past n are zero). The accumulator vector (W x L x 32 bits) is updated one word per cycle.
// Load a ciphertext with ct_* (2049 u64: masks then body), pulse start: after ~8192*W cycles the
// 919 KS outputs come out on ks_*, and the 919 MS values on ms_* (masks then body, idx 0..n).
// ct_* must write address 0 at least 6 cycles before start (its digits are decomposed on the
// write); pbs_engine and tb_ks write 0..2048 in order, then start.
module ks32 #(
  parameter int NIN  = 2048,           // k * N
  parameter int NOUT = 918,            // n (small LWE dimension)
  parameter int L    = 16,             // lanes
  parameter int G    = 3               // lane groups (one per SLR; ks_lanes)
) (
  input  logic                    clk,
  input  logic                    rst,
  input  logic                    ksk_we,
  input  logic [$clog2(NIN*4*((NOUT+L)/L))-1:0] ksk_addr,
  input  logic [L*32-1:0]         ksk_wdata,
  input  logic                    ct_we,
  input  logic [11:0]             ct_addr,
  input  logic [63:0]             ct_wdata,
  input  logic                    start,
  output logic                    busy,
  output logic                    ks_valid,
  output logic [9:0]              ks_idx,
  output logic [31:0]             ks_val,
  output logic                    ms_valid,
  output logic [9:0]              ms_idx,
  output logic [11:0]             ms_val
);
  localparam int W  = (NOUT + L) / L;              // words per row (NOUT+1 outputs)
  localparam int RW = NIN * 4;                     // rows
  localparam int KA = $clog2(RW * W);
  localparam int WB = (W > 1) ? $clog2(W) : 1;

  // ---- tfhe-rs balanced signed decomposition of a u64, base 2^4, 4 levels (tfhe.rs decompose).
  // Only a[63:47] matters (non_rep = 48: 16 bits + the rounding bit), so it is done on 18-bit
  // signed values, in three registered stages: round, then two digits per stage.
  typedef logic signed [4:0] dig_t;
  typedef logic signed [17:0] dst_t;
  function automatic dst_t dec_round(input logic [16:0] top);
    logic [16:0] res;
    logic need;
    res = 17'((18'(top) + 18'd1) >> 1) & 17'hffff;
    need = (res > 17'h8000) || (res == 17'h8000 && top[0]);
    return need ? dst_t'(res) - dst_t'(18'h10000) : dst_t'(res);
  endfunction
  // one level: the low digit of state, and state' = (state >>> 4) + carry
  // carry = (((r - 1) | (x >>> 4)) & r) >> 3 with r = x[3:0]; (r - 1)[3] & r[3] = r[3] & (r[2:0] != 0)
  function automatic logic dec_carry(input logic [3:0] r, input logic s3);
    return r[3] & ((r[2:0] != 3'd0) | s3);
  endfunction
  function automatic dig_t dec_digit(input logic [3:0] r, input logic s3);
    return dec_carry(r, s3) ? dig_t'({1'b0, r}) - 5'sd16 : dig_t'({1'b0, r});
  endfunction
  function automatic dst_t dec_next(input dst_t x);
    return (x >>> 4) + dst_t'(dec_carry(x[3:0], x[7]));
  endfunction

  // ---- memories
  // 30.1 MB of KSK in UltraRAM (ksk_ram.sv: its own kept hierarchy, read latency KRL = 4 in ks_lanes.sv)
  // masks: only bits 63:47 reach the decomposition; the body is captured on its write
  localparam int CB = $clog2(NIN);
  logic [16:0]     ctm [NIN];
  logic [63:0]     body_q;
  logic [16:0]     a0_top;             // a[0], captured on its write (its digits are needed first)
  always_ff @(posedge clk) begin
    if (ct_we && ct_addr < 12'(NIN)) ctm[CB'(ct_addr)] <= ct_wdata[63:47];
    if (ct_we && ct_addr == 12'(NIN)) body_q <= ct_wdata;
    if (ct_we && ct_addr == 12'd0) a0_top <= ct_wdata[63:47];
  end

  // ---- row sequencer: for input element ci: read a_ci, decompose, then the 4 rows
  // (stored level s = 0..3 holds decomposition level j = 4 - s, digit digs[3 - s]) x W words
  typedef enum logic [2:0] {K_IDLE, K_INIT, K_READ, K_DEC, K_ROWS, K_DRAIN, K_OUT, K_END} kst_e;
  kst_e st;
  logic [11:0]   ci;
  logic [1:0]    sl;
  logic [WB-1:0] kw;
  dig_t          digs [4];
  logic [3:0]    drain;
  // digit pipeline, off the issue path: while the rows of ci issue, a[ci+1] is read (2 registers)
  // and decomposed (3 stages); digs_nx latches the result as ci advances (4W+2 >= 6 cycles later).
  // In K_IDLE the pipeline decomposes a[0] instead.
  logic [11:0]   nci;
  logic [16:0]   pf_q1, pf_q2;
  dst_t          d_s1, d_s2;
  dig_t          d_hi [2], digs_pf [4], digs_nx [4];
  dst_t n1;
  /* verilator lint_off UNUSEDSIGNAL */
  dst_t n2;                            // only its low digit is used
  /* verilator lint_on UNUSEDSIGNAL */
  assign n1 = dec_next(d_s1);
  assign n2 = dec_next(d_s2);
  always_ff @(posedge clk) begin
    pf_q1 <= ctm[CB'(nci)];
    pf_q2 <= pf_q1;
    d_s1  <= dec_round((st == K_IDLE) ? a0_top : pf_q2);
    d_hi[1] <= dec_digit(d_s1[3:0], d_s1[7]);        // level 4: digit 3
    d_hi[0] <= dec_digit(n1[3:0], n1[7]);            // level 3: digit 2
    d_s2  <= dec_next(n1);
    digs_pf[3] <= d_hi[1];
    digs_pf[2] <= d_hi[0];
    digs_pf[1] <= dec_digit(d_s2[3:0], d_s2[7]);     // level 2: digit 1
    digs_pf[0] <= dec_digit(n2[3:0], n2[7]);         // level 1: digit 0
  end
  // issue (row, kw) -> the lane groups (ks_lanes: one control register stage, ksk_ram 2, MAC).
  // Rows are issued strictly in address order ((ci*4 + sl)*W + kw), so the KSK address is a
  // counter (no multiply by W: with W = 5 it was mapped to a DSP and broke URAM inference).
  logic          p_v;
  logic [WB-1:0] p_k;
  dig_t          p_d;
  logic [KA-1:0] ka;
  localparam int LB = $clog2(L);
  logic [LB-1:0] ol;
  logic          o_sh, o_adv;              // output: shift word 0 / advance the words
  assign o_sh  = (st == K_OUT) && (ol != LB'(L - 1));
  assign o_adv = (st == K_OUT) && (ol == LB'(L - 1));
  logic [31:0]   g_lane0 [G + 1];
  assign g_lane0[G] = '0;
  // lane group g holds lanes [goff(g), goff(g) + glen(g)); L = G * (L / G) + L % G
  function automatic int glen(input int g);
    return L / G + ((g < L % G) ? 1 : 0);
  endfunction
  function automatic int goff(input int g);
    int o;
    o = 0;
    for (int h = 0; h < g; h++) o += glen(h);
    return o;
  endfunction
  for (genvar g = 0; g < G; g++) begin : g_grp
    localparam int OFF = goff(g);
    localparam int LG  = glen(g);
    localparam int BL  = NOUT % L;                  // out[n] = word NOUT / L, lane NOUT % L
    ks_lanes #(.LG(LG), .W(W), .DEPTH(RW * W),
               .INIT_LANE((BL >= OFF && BL < OFF + LG) ? BL - OFF : -1), .INIT_WORD(NOUT / L)) u_l (
      .clk, .rst, .ksk_we, .ksk_addr, .ksk_wdata(ksk_wdata[OFF*32 +: LG*32]),
      .i_init(st == K_INIT), .i_body(32'((body_q + 64'h80000000) >> 32)),
      .i_v(p_v), .i_k(p_k), .i_d(p_d), .i_ka(ka), .i_sh(o_sh), .i_adv(o_adv),
      .sh_in(g_lane0[g + 1]), .lane0(g_lane0[g]));
  end

  // output: K_OUT asks the groups for one lane per cycle (o_sh / o_adv); the lane is read from
  // group 0 two cycles later, as the groups act on their twice-registered copy of the request.
  logic [9:0] oidx, o_idx, o_idx1;
  logic       o_v, o_v1;
  always_ff @(posedge clk) begin
    o_v1     <= o_v && !rst;
    o_idx1   <= o_idx;
    ks_valid <= o_v1 && !rst;
    ks_idx   <= o_idx1;
    ks_val   <= g_lane0[0];
  end
  always_ff @(posedge clk) begin
    if (rst) begin
      st <= K_IDLE; busy <= 1'b0; p_v <= 1'b0; o_v <= 1'b0;
    end else begin
      p_v <= 1'b0;
      o_v <= 1'b0;
      case (st)
        K_IDLE: if (start) begin st <= K_INIT; busy <= 1'b1; end
        K_INIT: begin st <= K_READ; ci <= '0; nci <= 12'd1; ka <= '0; digs_nx <= digs_pf; end
        K_READ: st <= K_DEC;
        K_DEC:  begin digs <= digs_nx; st <= K_ROWS; sl <= '0; kw <= '0; end
        K_ROWS: begin
          ka  <= ka + 1'b1;
          p_v <= 1'b1;
          p_k <= kw;
          p_d <= digs[3 - sl];
          if (kw == WB'(W - 1)) begin
            kw <= '0;
            if (sl == 2'd3) begin
              if (ci == 12'(NIN - 1)) begin st <= K_DRAIN; drain <= 4'd7; end
              else begin ci <= ci + 1'b1; nci <= nci + 1'b1; st <= K_READ; digs_nx <= digs_pf; end
            end else sl <= sl + 1'b1;
          end else kw <= kw + 1'b1;
        end
        K_DRAIN: if (drain == 0) begin st <= K_OUT; oidx <= '0; ol <= '0; end else drain <= drain - 1'b1;
        K_OUT: begin
          o_v   <= 1'b1;
          o_idx <= oidx;
          ol    <= (ol == LB'(L - 1)) ? '0 : ol + 1'b1;
          if (oidx == 10'(NOUT)) begin st <= K_END; drain <= 4'd1; end
          else oidx <= oidx + 1'b1;
        end
        K_END: if (drain == 0) begin st <= K_IDLE; busy <= 1'b0; end      // busy falls with the last ks_valid
               else drain <= drain - 1'b1;
      endcase
    end
  end

  // ---- centred modulus switch on the KS output stream (w = 32, 2N = 4096: shift 20)
  logic [31:0] sum_half;
  logic signed [15:0] sum_hd;
  function automatic logic [11:0] msw(input logic [31:0] a);
    return 12'((a + 32'h80000) >> 20);
  endfunction
  always_ff @(posedge clk) begin
    ms_valid <= 1'b0;
    if (st == K_DRAIN) begin
      sum_half <= '0;
      sum_hd <= '0;
    end
    if (ks_valid) begin
      if (ks_idx != 10'(NOUT)) begin
        logic [31:0] rounded, e;
        logic signed [31:0] es, half;
        rounded = {msw(ks_val), 20'b0};
        e = rounded - ks_val;
        es = $signed(e);
        half = es / 2;                                  // truncation toward zero
        sum_half <= sum_half + 32'(half);
        sum_hd   <= sum_hd + 16'(2 * half - es);
        ms_valid <= 1'b1;
        ms_idx   <= ks_idx;
        ms_val   <= msw(ks_val);
      end else begin
        logic [31:0] corr, sh;
        sh = sum_half - 32'(32'($signed(sum_hd)) / 2);
        corr = sh - 32'h80000;
        ms_valid <= 1'b1;
        ms_idx   <= ks_idx;
        ms_val   <= msw(ks_val + corr);
      end
    end
  end
endmodule
