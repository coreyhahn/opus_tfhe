// ntt_pipe against the model (dump_pipe): 3 primes x {forward, inverse}, J frames each, random
// gaps between frames (frames themselves are contiguous). Every output line is checked in order.
// Compile: -GPLOG=4 -GRED=0 -GROMDIR='"<dir with pf_/pi_ ROMs>"'
// Run    : +vec=<dir> +jobs=J +seed=S +gap=<max idle cycles between frames>
`timescale 1ns/1ps
module tb_pipe_one #(
  parameter int P = 249857, parameter string PSTR = "249857", parameter int RED = 0,
  parameter int PLOG = 4, parameter int DIR = 0, parameter string ROMDIR = ""
) (
  input logic clk, input logic go, input string vecdir, input int jobs, input int gap,
  output logic finished, output int errors, output longint latency
);
  localparam int PP = 1 << PLOG;
  localparam int FR = 2048 / PP;
  logic in_valid = 0, in_sof = 0, out_valid, out_sof;
  logic [PP*18-1:0] in_data, out_data;
  ntt_pipe #(.P(P), .RED(RED), .DIR(DIR), .PLOG(PLOG),
             .ROM_PFX({ROMDIR, (DIR == 0) ? "/pf_p" : "/pi_p", PSTR})) dut (
    .clk(clk), .in_valid(in_valid), .in_sof(in_sof), .in_tag(1'b0), .in_data(in_data),
    .out_valid(out_valid), .out_sof(out_sof), .out_tag(), .out_data(out_data));

  logic [PP*18-1:0] vin [64*FR], vout [64*FR];
  longint cyc = 0, first_in = -1;
  int il = 0, ol = 0, idle = 0;
  initial begin
    errors = 0;
    finished = 0;
    latency = -1;
    wait (go);
    $readmemh({vecdir, "/pv_p", PSTR, (DIR == 0) ? "_fwd_in.hex" : "_inv_in.hex"}, vin, 0, jobs * FR - 1);
    $readmemh({vecdir, "/pv_p", PSTR, (DIR == 0) ? "_fwd_out.hex" : "_inv_out.hex"}, vout, 0, jobs * FR - 1);
  end
  always @(negedge clk) if (go) begin
    cyc++;
    in_valid <= 0;
    in_sof <= 0;
    if (il < jobs * FR) begin
      if (il % FR != 0 || idle == 0) begin
        in_valid <= 1;
        in_sof <= (il % FR == 0);
        in_data <= vin[il];
        if (first_in < 0) first_in = cyc;
        il++;
        if (il % FR == 0) idle = (gap > 0) ? int'($urandom % (gap + 1)) : 0;
      end else idle--;
    end
    if (out_valid) begin
      if (out_sof !== (ol % FR == 0)) begin
        if (errors < 4) $display("ERROR P=%0d DIR=%0d line %0d: sof=%0b", P, DIR, ol, out_sof);
        errors++;
      end
      if (out_data !== vout[ol]) begin
        if (errors < 4) $display("ERROR P=%0d DIR=%0d frame %0d tau %0d: got %h want %h", P, DIR, ol / FR, ol % FR, out_data, vout[ol]);
        errors++;
      end
      if (latency < 0) latency = cyc - first_in;
      ol++;
      if (ol == jobs * FR) finished = 1;
    end
  end
endmodule

module tb_pipe #(parameter int PLOG = 4, parameter int RED = 0, parameter string ROMDIR = "");
  logic clk = 0, go = 0;
  always #1 clk = ~clk;
  string vecdir;
  int jobs, seed, gap;
  logic fin [6];
  int err [6];
  longint lat [6];
  localparam int    PR [3] = '{249857, 188417, 163841};
  localparam string PS [3] = '{"249857", "188417", "163841"};
  for (genvar i = 0; i < 3; i++) begin : g_p
    for (genvar dd = 0; dd < 2; dd++) begin : g_d
      tb_pipe_one #(.P(PR[i]), .PSTR(PS[i]), .RED(RED), .PLOG(PLOG), .DIR(dd), .ROMDIR(ROMDIR)) u (
        .clk(clk), .go(go), .vecdir(vecdir), .jobs(jobs), .gap(gap), .finished(fin[2*i+dd]),
        .errors(err[2*i+dd]), .latency(lat[2*i+dd]));
    end
  end
  initial begin
    if (!$value$plusargs("vec=%s", vecdir)) $fatal(1, "+vec=<dir> required");
    if (!$value$plusargs("jobs=%d", jobs)) jobs = 6;
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    if (!$value$plusargs("gap=%d", gap)) gap = 3;
    void'($urandom(seed));
    repeat (2) @(negedge clk);
    go = 1;
    for (int c = 0; c < (jobs + 8) * 2048; c++) begin
      @(negedge clk);
      if (fin[0] && fin[1] && fin[2] && fin[3] && fin[4] && fin[5]) break;
    end
    for (int k = 0; k < 6; k++) begin
      $display("P=%0d %s PLOG=%0d RED=%0d frames=%0d errors=%0d finished=%0d latency=%0d cyc (frame %0d cyc)",
               PR[k/2], (k % 2) ? "INV" : "FWD", PLOG, RED, jobs, err[k], fin[k], lat[k], 2048 >> PLOG);
      if (err[k] != 0 || !fin[k]) $fatal(1, "tb_pipe FAILED");
    end
    $display("PASS tb_pipe PLOG=%0d RED=%0d seed=%0d gap=%0d", PLOG, RED, seed, gap);
    $finish;
  end
endmodule
