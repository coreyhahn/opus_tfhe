// External product for one RNS residue, k = 1, l = 1 (docs/PARAMS.md):
//   O_c = INTT( NTT(D_0) * B'_0c + NTT(D_1) * B'_1c ),  c = 0, 1,   B' = N^{-1} NTT(B) (host-prepared)
// Bit-exact target: NttQ::ext_product in ref/tfhe_model/src/ntt_q.rs.
//
// Job = the two digit polynomials D_0, D_1 of one ciphertext (one CMux). The operand buffer holds
// B'_rc for the current CMux index and is shared by every job until it is rewritten (batch
// semantics); it may only be rewritten while busy = 0.
//   op RAM word w (0 <= w < N/M) = operands at positions wM .. wM+M-1, order {B'_11, B'_10, B'_01,
//   B'_00} from the top, each M lanes x 18 bits in stored form (see modmul).
// Streams and job handshakes as ntt_cg.
module extprod1 #(
  parameter int    P        = 249857,
  parameter int    RED      = ntt_pkg::RED_MONT,
  parameter int    T        = 8,
  parameter int    M        = 1,
  parameter string ROM_FWD  = "",
  parameter string ROM_INV  = ""
) (
  input  logic                       clk,
  input  logic                       rst,
  input  logic                       op_we,
  input  logic [$clog2(2048/M)-1:0]  op_addr,
  input  logic [4*M*18-1:0]          op_wdata,
  output logic                       in_job_ready,
  input  logic                       in_job_start,
  input  logic                       in_valid,
  input  logic [M*18-1:0]            in_data0,
  input  logic [M*18-1:0]            in_data1,
  input  logic                       out_job_ready,
  output logic                       out_job_start,
  output logic                       out_valid,
  output logic [M*18-1:0]            out_data0,
  output logic [M*18-1:0]            out_data1,
  output logic                       busy
);
  localparam int N  = ntt_pkg::N;
  localparam int AB = $clog2(N / M);
  localparam int ML = ntt_pkg::mul_lat(RED);
  localparam int MACL = 1 + ML + 1;          // op RAM read, multiply, add
  localparam logic [18:0] P19 = 19'(P);

  logic            f_out_job_ready, f_out_job_start, f_out_valid, f_busy, i_in_job_ready, i_busy;
  logic [M*18-1:0] f_out0, f_out1;

  ntt_cg #(.P(P), .RED(RED), .DIR(0), .T(T), .M(M), .ROM_FILE(ROM_FWD)) u_fwd (
    .clk(clk), .rst(rst), .in_job_ready(in_job_ready), .in_job_start(in_job_start), .in_valid(in_valid),
    .in_data0(in_data0), .in_data1(in_data1), .out_job_ready(f_out_job_ready), .out_job_start(f_out_job_start),
    .out_valid(f_out_valid), .out_data0(f_out0), .out_data1(f_out1), .busy(f_busy));

  // ---- operand buffer and MAC
  logic [4*M*18-1:0] opram [N / M];
  logic [4*M*18-1:0] op_q;
  logic [AB-1:0]     mac_beat;
  logic [M*18-1:0]   d0_q, d1_q;
  logic [MACL-1:0]   vpipe;
  always_ff @(posedge clk) begin
    if (op_we) opram[op_addr] <= op_wdata;
    op_q <= opram[mac_beat];
    d0_q <= f_out0;
    d1_q <= f_out1;
    if (rst) begin
      mac_beat <= '0;
      vpipe    <= '0;
    end else begin
      if (f_out_valid) mac_beat <= mac_beat + 1'b1;   // wraps at N/M: jobs are whole
      vpipe <= {vpipe[MACL-2:0], f_out_valid};
    end
  end

  logic [M*18-1:0] o0, o1;
  for (genvar m = 0; m < M; m++) begin : g_mac
    logic [17:0] p00, p10, p01, p11;
    wire signed [17:0] b00 = op_q[(0*M+m)*18 +: 18];
    wire signed [17:0] b01 = op_q[(1*M+m)*18 +: 18];
    wire signed [17:0] b10 = op_q[(2*M+m)*18 +: 18];
    wire signed [17:0] b11 = op_q[(3*M+m)*18 +: 18];
    modmul #(.P(P), .RED(RED)) u00 (.clk(clk), .x(d0_q[m*18 +: 18]), .wc(b00), .r(p00));
    modmul #(.P(P), .RED(RED)) u10 (.clk(clk), .x(d1_q[m*18 +: 18]), .wc(b10), .r(p10));
    modmul #(.P(P), .RED(RED)) u01 (.clk(clk), .x(d0_q[m*18 +: 18]), .wc(b01), .r(p01));
    modmul #(.P(P), .RED(RED)) u11 (.clk(clk), .x(d1_q[m*18 +: 18]), .wc(b11), .r(p11));
    always_ff @(posedge clk) begin
      o0[m*18 +: 18] <= 18'(ntt_pkg::mod_add(p00, p10, P19));
      o1[m*18 +: 18] <= 18'(ntt_pkg::mod_add(p01, p11, P19));
    end
  end

  // the inverse core's buffer is reserved when the forward core starts unloading
  assign f_out_job_ready = i_in_job_ready;

  ntt_cg #(.P(P), .RED(RED), .DIR(1), .T(T), .M(M), .ROM_FILE(ROM_INV)) u_inv (
    .clk(clk), .rst(rst), .in_job_ready(i_in_job_ready), .in_job_start(f_out_job_start),
    .in_valid(vpipe[MACL-1]), .in_data0(o0), .in_data1(o1), .out_job_ready(out_job_ready),
    .out_job_start(out_job_start), .out_valid(out_valid), .out_data0(out_data0), .out_data1(out_data1),
    .busy(i_busy));

  assign busy = f_busy || i_busy || (vpipe != '0) || f_out_valid;
endmodule
