// extprod3 against the model (NttQ::ext_product per prime, shared signed digits and operands).
// Operand groups (one per 3 jobs, like one BSK_i per batch) are written while the core is idle.
// Compile: -GT=8 -GM=1 -GRED=0 -GROMDIR='"<dir with twf_p*.hex>"'
// Run    : +vec=<dir> +jobs=J (multiple of 3) +seed=S +gap=<percent>
`timescale 1ns/1ps
module tb_extprod #(parameter int T = 8, parameter int M = 1, parameter int RED = 0, parameter string ROMDIR = "");
  localparam int N = 2048;
  localparam int BEATS = N / M;
  localparam int G = 3;
  localparam string PS [3] = '{"249857", "188417", "163841"};

  logic clk = 0, rst = 1;
  always #1 clk = ~clk;

  logic op_we = 0;
  logic [$clog2(N/M)-1:0] op_addr;
  logic [3*4*M*18-1:0] op_wdata;
  logic in_job_ready, in_job_start = 0, in_valid = 0, out_job_ready = 0, out_job_start, out_valid, busy;
  logic [M*24-1:0] in_d0, in_d1;
  logic [3*M*18-1:0] out_data0, out_data1;

  extprod3 #(.RED(RED), .T(T), .M(M), .ROMDIR(ROMDIR)) dut (
    .clk(clk), .rst(rst), .op_we(op_we), .op_addr(op_addr), .op_wdata(op_wdata),
    .in_job_ready(in_job_ready), .in_job_start(in_job_start), .in_valid(in_valid), .in_d0(in_d0), .in_d1(in_d1),
    .out_job_ready(out_job_ready), .out_job_start(out_job_start), .out_valid(out_valid),
    .out_data0(out_data0), .out_data1(out_data1), .busy(busy));

  logic [23:0] dsig [16*2*N];
  logic [17:0] ops  [3][(16/G+1)*4*N];
  logic [17:0] outv [3][16*2*N];
  string vecdir;
  int jobs, seed, gap, errors = 0;
  longint cyc = 0, t_start [16], t_done [16];
  int oj = 0, ob = 0;

  int n_fwd_out = 0, n_inv_in = 0, n_inv_start = 0, n_out = 0;
  always @(negedge clk) begin
    if (dut.g_res[0].u_xp.f_out_valid) n_fwd_out++;
    if (dut.g_res[0].u_xp.vpipe[dut.g_res[0].u_xp.MACL-1]) n_inv_in++;
    if (dut.g_res[0].u_xp.f_out_job_start) n_inv_start++;
    if (out_valid) n_out++;
  end
  always @(negedge clk) begin
    cyc++;
    if (cyc == 64'd200_000) begin
      $display("WATCHDOG cyc=%0d oj=%0d busy=%0b in_job_ready=%0b out_valid=%0b ijr=%b bz=%b", cyc, oj, busy, in_job_ready, out_valid, dut.ijr, dut.bz);
      $display("  lane0 fwd: ld_busy=%0b c_busy=%0b ul_busy=%0b lq_n=%0d dq_n=%0d free_any=%0b bst=%0d%0d%0d%0d c_pass=%0d drain=%0d/%0d",
               dut.g_res[0].u_xp.u_fwd.ld_busy, dut.g_res[0].u_xp.u_fwd.c_busy, dut.g_res[0].u_xp.u_fwd.ul_busy,
               dut.g_res[0].u_xp.u_fwd.lq_n, dut.g_res[0].u_xp.u_fwd.dq_n, dut.g_res[0].u_xp.u_fwd.free_any,
               dut.g_res[0].u_xp.u_fwd.bst[0], dut.g_res[0].u_xp.u_fwd.bst[1], dut.g_res[0].u_xp.u_fwd.bst[2], dut.g_res[0].u_xp.u_fwd.bst[3],
               dut.g_res[0].u_xp.u_fwd.c_pass, dut.g_res[0].u_xp.u_fwd.drain[0], dut.g_res[0].u_xp.u_fwd.drain[1]);
      $display("  lane0 inv: ld_busy=%0b c_busy=%0b ul_busy=%0b lq_n=%0d dq_n=%0d free_any=%0b ld_beat=%0d",
               dut.g_res[0].u_xp.u_inv.ld_busy, dut.g_res[0].u_xp.u_inv.c_busy, dut.g_res[0].u_xp.u_inv.ul_busy,
               dut.g_res[0].u_xp.u_inv.lq_n, dut.g_res[0].u_xp.u_inv.dq_n, dut.g_res[0].u_xp.u_inv.free_any, dut.g_res[0].u_xp.u_inv.ld_beat);
      $display("  beats: fwd_out=%0d inv_in=%0d inv_job_starts=%0d out=%0d", n_fwd_out, n_inv_in, n_inv_start, n_out);
      $fatal(1, "tb_extprod WATCHDOG: no progress");
    end
    out_job_ready <= (($urandom % 100) >= gap);
    if (out_valid) begin
      for (int i = 0; i < 3; i++)
        for (int m = 0; m < M; m++)
          for (int c = 0; c < 2; c++) begin
            logic [17:0] got, want;
            got  = c ? out_data1[(i*M+m)*18 +: 18] : out_data0[(i*M+m)*18 +: 18];
            want = outv[i][(2*oj+c)*N + ob*M + m];
            if (got !== want) begin
              if (errors < 8) $display("ERROR job %0d p=%s O%0d pos %0d: got %h want %h", oj, PS[i], c, ob*M+m, got, want);
              errors++;
            end
          end
      if (ob == BEATS - 1) begin
        ob = 0;
        t_done[oj] = cyc;
        oj++;
      end else ob++;
    end
  end

  task automatic send_job(input int j);
    int b;
    b = 0;
    while (b < BEATS) begin
      @(negedge clk);
      in_job_start <= 0;
      in_valid <= 0;
      if (b == 0) begin
        if (!in_job_ready) continue;
        in_job_start <= 1;
        t_start[j] = cyc;
        $display("cyc %0d: job %0d start", cyc, j);
      end else if (($urandom % 100) < gap) continue;
      for (int m = 0; m < M; m++) begin
        in_d0[m*24 +: 24] <= dsig[(2*j)*N + b*M + m];
        in_d1[m*24 +: 24] <= dsig[(2*j+1)*N + b*M + m];
      end
      in_valid <= 1;
      b++;
    end
    @(negedge clk);
    in_valid <= 0;
    in_job_start <= 0;
  endtask

  initial begin
    if (!$value$plusargs("vec=%s", vecdir)) $fatal(1, "+vec=<dir> required");
    if (!$value$plusargs("jobs=%d", jobs)) jobs = 6;
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    if (!$value$plusargs("gap=%d", gap)) gap = 10;
    if (jobs % G != 0 || jobs > 15) $fatal(1, "jobs must be a multiple of 3, <= 15");
    void'($urandom(seed));
    $readmemh({vecdir, "/vec_xp_dsigned.hex"}, dsig, 0, jobs * 2 * N - 1);
    for (int i = 0; i < 3; i++) begin
      $readmemh({vecdir, "/vec_p", PS[i], "_xp_op.hex"}, ops[i], 0, (jobs / G) * 4 * N - 1);
      $readmemh({vecdir, "/vec_p", PS[i], "_xp_out.hex"}, outv[i], 0, jobs * 2 * N - 1);
    end
    repeat (4) @(negedge clk);
    rst = 0;
    for (int g = 0; g < jobs / G; g++) begin
      // the operand buffer may only change while the core is idle
      while (busy || oj < g * G) @(negedge clk);
      for (int w = 0; w < BEATS; w++) begin
        @(negedge clk);
        op_we <= 1;
        op_addr <= w[$clog2(N/M)-1:0];
        for (int i = 0; i < 3; i++)
          for (int k = 0; k < 4; k++)
            for (int m = 0; m < M; m++)
              op_wdata[((i*4 + k)*M + m)*18 +: 18] <= ops[i][(g*4 + k)*N + w*M + m];
      end
      @(negedge clk);
      op_we <= 0;
      for (int j = g * G; j < (g + 1) * G; j++) send_job(j);
    end
    while (oj < jobs) begin
      @(negedge clk);
      if (cyc > 64'd50_000_000) $fatal(1, "timeout");
    end
    for (int g = 0; g < jobs / G; g++)
      $display("group %0d: job latency %0d cyc (first job), interval %0d cyc/job (T=%0d M=%0d RED=%0d; one fwd/inv NTT job = %0d cyc)",
               g, t_done[g*G] - t_start[g*G], (t_done[g*G+G-1] - t_done[g*G]) / (G - 1), T, M, RED, 11 * 2048 / T);
    if (errors != 0) $fatal(1, "tb_extprod FAILED: %0d mismatches", errors);
    $display("PASS tb_extprod T=%0d M=%0d RED=%0d seed=%0d jobs=%0d (all 3 residues x 2 outputs x %0d coefficients)", T, M, RED, seed, jobs, N);
    $finish;
  end
endmodule
