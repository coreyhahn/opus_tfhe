// Streaming external product for one RNS residue, k = 1, l = 1 (docs/PARAMS.md):
//   O_c = INTT( NTT(D_0) * B'_0c + NTT(D_1) * B'_1c ),  c = 0, 1,   B' = N^{-1} NTT(B)
// Two forward pipelines (D_0, D_1 in lockstep), the MAC, two inverse pipelines. One CMux of one
// ciphertext per frame of N/P cycles. Bit-exact target: NttQ::ext_product; layout: ntt_pipe.rs.
// Operand buffers: two (double buffering across CMux indices), selected per frame by in_tag, which
// travels with the frame through the forward pipelines. Word tau of a buffer = the operands at
// frame time tau of the forward-output layout, {B'_11, B'_10, B'_01, B'_00} x P lanes from the
// top, stored form (see modmul). mac_done pulses on the last MAC beat of a frame (with its tag): a
// buffer may be rewritten once every frame that uses it has produced its mac_done.
// Kept hierarchy: each residue is floorplanned into its own SLR (synth/constraints/engine_slr.xdc).
// Without it, cross-boundary optimisation hoisted ~19k cells and ~98k boundary pins per residue
// into xpipe3, outside the pblocks, and placement needed 96,628 SLLs between SLR0 and SLR1 (10427a1).
(* keep_hierarchy = "yes" *)
module xpipe1 #(
  parameter int    P       = 249857,
  parameter int    RED     = ntt_pkg::RED_MONT,   // default for all three roles
  parameter int    RED_F   = RED,                 // forward pipelines
  parameter int    RED_M   = RED,                 // MAC (operands stored in this representation)
  parameter int    RED_I   = RED,                 // inverse pipelines
  parameter int    PLOG    = 4,
  parameter string ROM_FWD = "",          // ROM prefix of the forward pipeline (.../pf_p<p>)
  parameter string ROM_INV = ""           // ROM prefix of the inverse pipeline (.../pi_p<p>)
) (
  input  logic                         clk,
  input  logic                         op_we,
  input  logic                         op_buf,
  input  logic [ntt_pkg::LOG_N-PLOG-1:0] op_addr,
  input  logic [4*(1<<PLOG)*18-1:0]    op_wdata,
  input  logic                         in_valid,
  input  logic                         in_sof,
  input  logic                         in_tag,
  input  logic [(1<<PLOG)*18-1:0]      in_d0,
  input  logic [(1<<PLOG)*18-1:0]      in_d1,
  output logic                         mac_done,
  output logic                         mac_done_tag,
  output logic                         out_valid,
  output logic                         out_sof,
  output logic [(1<<PLOG)*18-1:0]      out_o0,
  output logic [(1<<PLOG)*18-1:0]      out_o1
);
  localparam int PP   = 1 << PLOG;
  localparam int FB   = ntt_pkg::LOG_N - PLOG;
  localparam int ML   = ntt_pkg::mul_lat(RED_M);
  localparam int MACL = 1 + 1 + ML + 1;        // operand address, operand read, multiply, add
  localparam logic [18:0] P19 = 19'(P);

  logic fv, fs, ft, fv1, fs1, ft1;
  logic [PP*18-1:0] f0, f1;
  ntt_pipe #(.P(P), .RED(RED_F), .DIR(0), .PLOG(PLOG), .ROM_PFX(ROM_FWD)) u_f0 (
    .clk(clk), .in_valid(in_valid), .in_sof(in_sof), .in_tag(in_tag), .in_data(in_d0), .out_valid(fv), .out_sof(fs), .out_tag(ft), .out_data(f0));
  ntt_pipe #(.P(P), .RED(RED_F), .DIR(0), .PLOG(PLOG), .ROM_PFX(ROM_FWD)) u_f1 (
    .clk(clk), .in_valid(in_valid), .in_sof(in_sof), .in_tag(in_tag), .in_data(in_d1), .out_valid(fv1), .out_sof(fs1), .out_tag(ft1), .out_data(f1));
  wire unused_lockstep = fv1 ^ fs1 ^ ft1;   // identical twin of u_f0's control

  // ---- MAC
  logic [4*PP*18-1:0] opram [2 << FB];       // {buffer, tau}
  logic [4*PP*18-1:0] op_q;
  logic [FB-1:0]      tau_r;
  wire  [FB-1:0]      tau = fs ? '0 : tau_r;
  // the operand address {buffer, tau} is registered: the RAM is 2304 bits wide (~64 BRAMs)
  logic [FB:0]        oa;
  logic               md1, mt1;
  logic [PP*18-1:0]   d0_p, d1_p, d0_q, d1_q;
  logic               mv [MACL], ms [MACL];
  // operand writes are registered here, inside the residue's SLR: op_we/op_buf/op_addr come from the
  // BSK controller in SLR1 (opus_top); br_core delays bsk_done by the same cycle
  logic               opw_we, opw_buf;
  logic [FB-1:0]      opw_addr;
  logic [4*PP*18-1:0] opw_d;
  always_ff @(posedge clk) begin
    opw_we <= op_we; opw_buf <= op_buf; opw_addr <= op_addr; opw_d <= op_wdata;
  end
  always_ff @(posedge clk) begin
    if (opw_we) opram[{opw_buf, opw_addr}] <= opw_d;
    oa    <= {ft, tau};
    op_q  <= opram[oa];
    md1   <= fv && (tau == FB'((1 << FB) - 1));   // the last read of the buffer is a cycle later
    mt1   <= ft;
    mac_done     <= md1;
    mac_done_tag <= mt1;
    tau_r <= tau + 1'b1;
    d0_p  <= f0;
    d1_p  <= f1;
    d0_q  <= d0_p;
    d1_q  <= d1_p;
    mv[0] <= fv;
    ms[0] <= fs;
    for (int k = 1; k < MACL; k++) begin
      mv[k] <= mv[k-1];
      ms[k] <= ms[k-1];
    end
  end

  logic [PP*18-1:0] o0, o1;
  for (genvar m = 0; m < PP; m++) begin : g_mac
    logic [17:0] p00, p10, p01, p11;
    modmul #(.P(P), .RED(RED_M)) u00 (.clk(clk), .x(d0_q[m*18 +: 18]), .wc(op_q[(0*PP+m)*18 +: 18]), .r(p00));
    modmul #(.P(P), .RED(RED_M)) u10 (.clk(clk), .x(d1_q[m*18 +: 18]), .wc(op_q[(2*PP+m)*18 +: 18]), .r(p10));
    modmul #(.P(P), .RED(RED_M)) u01 (.clk(clk), .x(d0_q[m*18 +: 18]), .wc(op_q[(1*PP+m)*18 +: 18]), .r(p01));
    modmul #(.P(P), .RED(RED_M)) u11 (.clk(clk), .x(d1_q[m*18 +: 18]), .wc(op_q[(3*PP+m)*18 +: 18]), .r(p11));
    always_ff @(posedge clk) begin
      o0[m*18 +: 18] <= 18'(ntt_pkg::mod_add(p00, p10, P19));
      o1[m*18 +: 18] <= 18'(ntt_pkg::mod_add(p01, p11, P19));
    end
  end

  logic iv1, is1, it0, it1;
  ntt_pipe #(.P(P), .RED(RED_I), .DIR(1), .PLOG(PLOG), .ROM_PFX(ROM_INV)) u_i0 (
    .clk(clk), .in_valid(mv[MACL-1]), .in_sof(ms[MACL-1]), .in_tag(1'b0), .in_data(o0), .out_valid(out_valid), .out_sof(out_sof), .out_tag(it0), .out_data(out_o0));
  ntt_pipe #(.P(P), .RED(RED_I), .DIR(1), .PLOG(PLOG), .ROM_PFX(ROM_INV)) u_i1 (
    .clk(clk), .in_valid(mv[MACL-1]), .in_sof(ms[MACL-1]), .in_tag(1'b0), .in_data(o1), .out_valid(iv1), .out_sof(is1), .out_tag(it1), .out_data(out_o1));
  wire unused_lockstep2 = iv1 ^ is1 ^ it0 ^ it1;
endmodule
