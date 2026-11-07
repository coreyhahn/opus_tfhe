// ntt_cg against the model's vectors: 3 primes x {forward, inverse}, JOBS jobs of 2 polynomials.
// Random gaps on the input stream and random out_job_ready exercise the buffer rotation.
// Compile: -GT=8 -GM=1 -GRED=0 -GROMDIR='"<abs dir with twf_p*.hex>"'
// Run    : +vec=<dir with vec_p*.hex> +jobs=J +seed=S +gap=<percent>
`timescale 1ns/1ps
module tb_ntt_one #(
  parameter int    P = 249857, parameter string PSTR = "249857",
  parameter int    RED = 0, parameter int T = 8, parameter int M = 1, parameter int DIR = 0,
  parameter string ROMDIR = ""
) (
  input logic clk, input logic rst, input logic go, input string vecdir, input int jobs, input int gap,
  output logic finished, output int errors, output longint first_in, output longint last_out,
  output longint lat_sum, output longint job_done_at [64]
);
  localparam int N = 2048;
  localparam int BEATS = N / M;
  localparam string ROM = {ROMDIR, (DIR == 0) ? "/twf_p" : "/twi_p", PSTR, ".hex"};

  logic in_job_ready, in_job_start, in_valid, out_job_ready, out_job_start, out_valid, busy;
  logic [M*18-1:0] in_data0, in_data1, out_data0, out_data1;

  ntt_cg #(.P(P), .RED(RED), .DIR(DIR), .T(T), .M(M), .ROM_FILE(ROM)) dut (
    .clk(clk), .rst(rst), .in_job_ready(in_job_ready), .in_job_start(in_job_start), .in_valid(in_valid), .in_data0(in_data0),
    .in_data1(in_data1), .out_job_ready(out_job_ready), .out_job_start(out_job_start), .out_valid(out_valid), .out_data0(out_data0),
    .out_data1(out_data1), .busy(busy));

  logic [17:0] vin  [64*2*N];
  logic [17:0] vout [64*2*N];
  longint cyc = 0;
  longint job_start_at [64];
  int ij = 0, ib = 0, oj = 0, ob = 0;
  logic in_job_active = 0;

  initial begin
    string d;
    errors = 0;
    finished = 0;
    first_in = -1;
    last_out = 0;
    lat_sum = 0;
    in_valid = 0;
    in_job_start = 0;
    out_job_ready = 0;
    wait (go);
    d = (DIR == 0) ? "fwd" : "inv";
    $readmemh({vecdir, "/vec_p", PSTR, "_", d, "_in.hex"}, vin, 0, jobs * 2 * N - 1);
    $readmemh({vecdir, "/vec_p", PSTR, "_", d, "_out.hex"}, vout, 0, jobs * 2 * N - 1);
  end

  always @(negedge clk) if (!rst && go) begin
    cyc++;
    // ---- producer
    in_valid <= 0;
    in_job_start <= 0;
    if (ij < jobs) begin
      logic send;
      // a job may only start in a cycle where in_job_ready is high; its beats may then have gaps
      if (!in_job_active) begin
        send = in_job_ready && (($urandom % 100) >= gap);
        if (send) begin
          in_job_start <= 1;
          in_job_active <= 1;
          job_start_at[ij] = cyc;
          if (first_in < 0) first_in = cyc;
        end
      end else begin
        send = (($urandom % 100) >= gap);
      end
      if (send) begin
        for (int m = 0; m < M; m++) begin
          in_data0[18*m +: 18] <= vin[(2*ij)*N + ib*M + m];
          in_data1[18*m +: 18] <= vin[(2*ij+1)*N + ib*M + m];
        end
        in_valid <= 1;
        if (ib == BEATS - 1) begin
          ib = 0;
          ij++;
          in_job_active <= 0;
        end else ib++;
      end
    end
    // ---- consumer
    out_job_ready <= (($urandom % 100) >= gap);
    if (out_valid) begin
      for (int m = 0; m < M; m++) begin
        logic [17:0] g0, g1, e0, e1;
        g0 = out_data0[18*m +: 18];
        g1 = out_data1[18*m +: 18];
        e0 = vout[(2*oj)*N + ob*M + m];
        e1 = vout[(2*oj+1)*N + ob*M + m];
        if (g0 !== e0 || g1 !== e1) begin
          if (errors < 8) $display("ERROR P=%0d DIR=%0d job %0d pos %0d: got %h/%h want %h/%h", P, DIR, oj, ob*M+m, g0, g1, e0, e1);
          errors++;
        end
      end
      if (ob == BEATS - 1) begin
        ob = 0;
        job_done_at[oj] = cyc;
        lat_sum += cyc - job_start_at[oj];
        oj++;
        last_out = cyc;
        if (oj == jobs) finished = 1;
      end else ob++;
    end
  end
endmodule

module tb_ntt #(parameter int T = 8, parameter int M = 1, parameter int RED = 0, parameter string ROMDIR = "");
  logic clk = 0, rst = 1, go = 0;
  always #1 clk = ~clk;
  string vecdir;
  int jobs, seed, gap;
  logic fin [6];
  int err [6];
  longint fi [6], lo [6], ls [6];
  longint jd [6][64];
  localparam int    PR [3] = '{249857, 188417, 163841};
  localparam string PS [3] = '{"249857", "188417", "163841"};

  for (genvar i = 0; i < 3; i++) begin : g_p
    for (genvar d = 0; d < 2; d++) begin : g_d
      tb_ntt_one #(.P(PR[i]), .PSTR(PS[i]), .RED(RED), .T(T), .M(M), .DIR(d), .ROMDIR(ROMDIR)) u (
        .clk(clk), .rst(rst), .go(go), .vecdir(vecdir), .jobs(jobs), .gap(gap), .finished(fin[2*i+d]),
        .errors(err[2*i+d]), .first_in(fi[2*i+d]), .last_out(lo[2*i+d]), .lat_sum(ls[2*i+d]), .job_done_at(jd[2*i+d]));
    end
  end

  initial begin
    longint limit;
    if (!$value$plusargs("vec=%s", vecdir)) $fatal(1, "+vec=<dir> required");
    if (!$value$plusargs("jobs=%d", jobs)) jobs = 4;
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    if (!$value$plusargs("gap=%d", gap)) gap = 10;
    void'($urandom(seed));
    repeat (4) @(negedge clk);
    rst = 0;
    go = 1;
    limit = longint'(jobs + 4) * 40 * 2048;
    for (longint c = 0; c < limit; c++) begin
      @(negedge clk);
      if (fin[0] && fin[1] && fin[2] && fin[3] && fin[4] && fin[5]) break;
    end
    for (int k = 0; k < 6; k++) begin
      longint thr;
      thr = (jobs > 1) ? (jd[k][jobs-1] - jd[k][0]) / (jobs - 1) : 0;
      $display("P=%0d %s T=%0d M=%0d RED=%0d jobs=%0d errors=%0d finished=%0d mean_job_latency=%0d cyc steady_job_interval=%0d cyc (ideal compute %0d)",
               PR[k/2], (k % 2) ? "INV" : "FWD", T, M, RED, jobs, err[k], fin[k], (jobs > 0) ? ls[k] / jobs : 0, thr,
               11 * 2048 / T);
      if (err[k] != 0 || !fin[k]) $fatal(1, "tb_ntt FAILED");
    end
    $display("PASS tb_ntt T=%0d M=%0d RED=%0d seed=%0d gap=%0d", T, M, RED, seed, gap);
    $finish;
  end
endmodule
