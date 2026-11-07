// Modular multiplier r = x * w mod P for one 18-bit NTT prime, fully pipelined, one result per
// clock, fixed latency ntt_pkg::mul_lat(RED).
//
//   x : unsigned, canonical in [0, P)            (data; goes to the DSP48E2 27-bit A port)
//   wc: signed, centred in (-P/2, P/2)            (constant/key; the 18-bit B port)
//       wc = centre(w * C mod P), C = 2^18 for RED_MONT, C = 1 for RED_TABLE
//   r : canonical in [0, P)
//
// Both styles first form z = x*wc + P*2^17 in one DSP (0 < z < P*2^18 < 2^36), then reduce:
//   RED_MONT : Montgomery, two more DSP products; m = z*(-P^-1) mod 2^18,
//              r = (z + m P)/2^18 = z_h + m - floor(m (2^18 - P) / 2^18), one conditional subtract.
//   RED_TABLE: z = z0 + sum_i c_i 2^(18+6i) folded through three 64-entry ROMs of c*2^(18+6i) mod P,
//              then a 16-entry ROM of c*2^17 mod P on the sum's top bits, one conditional subtract.
module modmul #(
  parameter int P   = 249857,
  parameter int RED = ntt_pkg::RED_MONT
) (
  input  logic               clk,
  input  logic        [17:0] x,
  input  logic signed [17:0] wc,
  output logic        [17:0] r
);
  localparam logic [35:0] K = 36'(P) << 17;

  // constant functions live at module scope (IEEE 1800-2017 13.4.3)
  function automatic logic [17:0] neg_inv();
    logic [17:0] inv;
    inv = 18'(1);
    for (int i = 0; i < 6; i++) inv = 18'(inv * (18'(2) - 18'(P) * inv));
    return 18'(-inv);
  endfunction
  typedef logic [63:0][17:0] tab64_t;
  typedef logic [15:0][17:0] tab16_t;
  function automatic tab64_t make_tab(input int shift);
    tab64_t t;
    longint unsigned base;
    base = (64'(1) << shift) % 64'(P);
    for (int c = 0; c < 64; c++) t[c] = 18'((64'(c) * base) % 64'(P));
    return t;
  endfunction
  function automatic tab16_t make_tab16();
    tab16_t t;
    for (int c = 0; c < 16; c++) t[c] = 18'((64'(c) << 17) % 64'(P));
    return t;
  endfunction

  // ---- z = x * wc + P*2^17 (DSP48E2: AREG/BREG, MREG, PREG with the constant on C)
  logic        [17:0] xa;
  logic signed [17:0] wb;
  logic signed [36:0] prod;
  logic        [35:0] z;
  always_ff @(posedge clk) begin
    xa   <= x;
    wb   <= wc;
    prod <= $signed({19'b0, xa}) * $signed(wb);
    z    <= 36'(prod + $signed({1'b0, K}));
  end

  if (RED == ntt_pkg::RED_MONT) begin : g_mont
    // PINV = -P^{-1} mod 2^18 and CP = 2^18 - P: the DSP B-port constants of the two reductions.
    localparam logic [17:0] PINV = neg_inv();
    localparam logic [17:0] CP   = 18'((1 << 18) - P);

    // t = (z + m P)/2^18 with m = z_l (-P^{-1}) mod 2^18. Since z_l = (m CP) mod 2^18,
    // t = z_h + m - floor(m CP / 2^18): only the 18-bit z_h is carried, no 36-bit subtract.
    logic [17:0] zl, mq, m6, m7, m8;
    logic [17:0] zh4, zh5, zh6, zh7, zh8;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [34:0] mc7;                // only floor(m CP / 2^18) is needed
    /* verilator lint_on UNUSEDSIGNAL */
    logic [16:0] q8;
    logic [19:0] t9;
    always_ff @(posedge clk) begin
      zl  <= z[17:0];
      zh4 <= z[35:18];
      mq  <= 18'(zl * PINV);           // DSP2: A = z_l, B = PINV, low 18 bits kept
      zh5 <= zh4;
      m6  <= mq;
      zh6 <= zh5;
      mc7 <= 35'(m6) * 35'(CP);        // DSP3: A = m, B = 2^18 - P
      m7  <= m6;
      zh7 <= zh6;
      q8  <= mc7[34:18];
      m8  <= m7;
      zh8 <= zh7;
      t9  <= 20'(zh8) + 20'(m8) - 20'(q8);
      r   <= (t9 >= 20'(P)) ? 18'(t9 - 20'(P)) : t9[17:0];
    end
  end else begin : g_table
    localparam tab64_t T0 = make_tab(18);
    localparam tab64_t T1 = make_tab(24);
    localparam tab64_t T2 = make_tab(30);
    localparam tab16_t T3 = make_tab16();

    logic [19:0] s4a, s4b;
    logic [20:0] s5;
    logic [18:0] s6;
    // small LUT ROMs: keep them out of block RAM (one BRAM per multiplier would not scale)
    (* rom_style = "distributed" *) logic [17:0] t0v, t1v, t2v, t3v;
    assign t0v = T0[z[23:18]];
    assign t1v = T1[z[29:24]];
    assign t2v = T2[z[35:30]];
    assign t3v = T3[s5[20:17]];
    always_ff @(posedge clk) begin
      s4a <= 20'(z[17:0]) + 20'(t0v);
      s4b <= 20'(t1v) + 20'(t2v);
      s5  <= 21'(s4a) + 21'(s4b);
      s6  <= 19'(s5[16:0]) + 19'(t3v);
      r   <= (s6 >= 19'(P)) ? 18'(s6 - 19'(P)) : s6[17:0];
    end
  end
endmodule
