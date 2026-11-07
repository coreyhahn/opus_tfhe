// Streaming external product over the RNS Q = 249857 * 188417 * 163841: signed gadget digits in
// (P lanes x 24-bit two's complement, block-per-path layout), the three residues of O_0, O_1 out.
// Digit -> residue as in extprod3.sv (64-entry table of h * 2^18 mod p, two subtractions), 3 cycles:
// a per-residue copy of the digits (registered in the residue's SLR), the table add, the subtractions.
module xpipe3 #(
  parameter int    RED    = ntt_pkg::RED_MONT,
  parameter int    RED_F  = RED,
  parameter int    RED_M  = RED,
  parameter int    RED_I  = RED,
  parameter int    PLOG   = 4,
  parameter string ROMDIR = "",           // pf_p<p>_s<i>.hex, pi_p<p>_s<i>.hex
  parameter string ROMDIR_F = ROMDIR,     // forward ROMs (stored form of RED_F)
  parameter string ROMDIR_I = ROMDIR      // inverse ROMs (stored form of RED_I)
) (
  input  logic                           clk,
  input  logic                           op_we,
  input  logic                           op_buf,
  input  logic [ntt_pkg::LOG_N-PLOG-1:0] op_addr,
  input  logic [3*4*(1<<PLOG)*18-1:0]    op_wdata,     // residue i at [i*4*P*18 +: 4*P*18]
  input  logic                           in_valid,
  input  logic                           in_sof,
  input  logic                           in_tag,
  input  logic [(1<<PLOG)*24-1:0]        in_d0,
  input  logic [(1<<PLOG)*24-1:0]        in_d1,
  output logic                           mac_done,
  output logic                           mac_done_tag,
  output logic                           out_valid,
  output logic                           out_sof,
  output logic [3*(1<<PLOG)*18-1:0]      out_o0,       // residue i at [i*P*18 +: P*18]
  output logic [3*(1<<PLOG)*18-1:0]      out_o1
);
  localparam int    PP = 1 << PLOG;
  localparam int    PR [3] = '{249857, 188417, 163841};
  localparam string PS [3] = '{"249857", "188417", "163841"};

  typedef logic [63:0][17:0] tab_t;
  function automatic tab_t hi_tab(input int p);
    tab_t t;
    for (int c = 0; c < 64; c++) begin
      longint h;
      h = (c >= 32) ? longint'(c) - 64 : longint'(c);
      t[c] = 18'(((h << 18) % longint'(p) + longint'(p)) % longint'(p));
    end
    return t;
  endfunction

  logic v0, v1, v2, s0q, s1, s2, t0, t1, t2;
  always_ff @(posedge clk) begin
    v0  <= in_valid;
    v1  <= v0;
    v2  <= v1;
    s0q <= in_sof;
    s1  <= s0q;
    s2  <= s1;
    t0  <= in_tag;
    t1  <= t0;
    t2  <= t1;
  end

  logic [2:0] ov, os, md, mt;
  for (genvar i = 0; i < 3; i++) begin : g_res
    localparam tab_t HT = hi_tab(PR[i]);
    localparam logic [19:0] P20 = 20'(PR[i]);
    localparam logic [19:0] P2X = 20'(2 * PR[i]);
    logic [PP*18-1:0] r0, r1;
    logic [PP*24-1:0] di0, di1;
    always_ff @(posedge clk) begin
      di0 <= in_d0;
      di1 <= in_d1;
    end
    for (genvar m = 0; m < PP; m++) begin : g_d2r
      logic [19:0] s0, s1v;
      always_ff @(posedge clk) begin
        s0  <= 20'(di0[m*24 +: 18]) + 20'(HT[di0[m*24+18 +: 6]]);
        s1v <= 20'(di1[m*24 +: 18]) + 20'(HT[di1[m*24+18 +: 6]]);
        r0[m*18 +: 18] <= 18'((s0 >= P2X) ? s0 - P2X : (s0 >= P20) ? s0 - P20 : s0);
        r1[m*18 +: 18] <= 18'((s1v >= P2X) ? s1v - P2X : (s1v >= P20) ? s1v - P20 : s1v);
      end
    end
    xpipe1 #(.P(PR[i]), .RED_F(RED_F), .RED_M(RED_M), .RED_I(RED_I), .PLOG(PLOG),
             .ROM_FWD({ROMDIR_F, "/pf_p", PS[i]}), .ROM_INV({ROMDIR_I, "/pi_p", PS[i]})) u_xp (
      .clk(clk), .op_we(op_we), .op_buf(op_buf), .op_addr(op_addr), .op_wdata(op_wdata[i*4*PP*18 +: 4*PP*18]),
      .in_valid(v2), .in_sof(s2), .in_tag(t2), .in_d0(r0), .in_d1(r1), .mac_done(md[i]), .mac_done_tag(mt[i]),
      .out_valid(ov[i]), .out_sof(os[i]), .out_o0(out_o0[i*PP*18 +: PP*18]), .out_o1(out_o1[i*PP*18 +: PP*18]));
  end
  assign out_valid = ov[0];
  assign out_sof   = os[0];
  assign mac_done  = md[0];
  assign mac_done_tag = mt[0];
  wire unused_lockstep = ^{ov[2:1], os[2:1], md[2:1], mt[2:1]};
endmodule
