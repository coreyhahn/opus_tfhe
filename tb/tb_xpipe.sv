// xpipe3 against the model (dump_pipe px_* files): shared signed digits, 3 residues, operand
// groups of 3 jobs (one BSK_i per batch). The operand buffer is rewritten only when every frame
// sent has come out. Frames are contiguous, with random gaps between jobs.
// Compile: -GPLOG=4 -GRED=0 -GROMDIR='"<dir>"'   Run: +vec=<dir> +jobs=6 +seed=S +gap=G
`timescale 1ns/1ps
module tb_xpipe #(parameter int PLOG = 4, parameter int RED = 0, parameter string ROMDIR = "");
  localparam int PP = 1 << PLOG;
  localparam int FR = 2048 / PP;
  localparam int G  = 3;
  localparam string PS [3] = '{"249857", "188417", "163841"};

  logic clk = 0;
  always #1 clk = ~clk;
  logic op_we = 0;
  logic [10-PLOG:0] op_addr;
  logic [3*4*PP*18-1:0] op_wdata;
  logic in_valid = 0, in_sof = 0, out_valid, out_sof;
  logic [PP*24-1:0] in_d0, in_d1;
  logic [3*PP*18-1:0] out_o0, out_o1;

  xpipe3 #(.RED(RED), .PLOG(PLOG), .ROMDIR(ROMDIR)) dut (
    .clk(clk), .op_we(op_we), .op_buf(1'b0), .op_addr(op_addr), .op_wdata(op_wdata), .in_valid(in_valid), .in_sof(in_sof), .in_tag(1'b0),
    .in_d0(in_d0), .in_d1(in_d1), .mac_done(), .mac_done_tag(), .out_valid(out_valid), .out_sof(out_sof), .out_o0(out_o0), .out_o1(out_o1));

  logic [PP*24-1:0]   dsig [16*2*FR];
  logic [4*PP*18-1:0] ops  [3][(16/G+1)*FR];
  logic [PP*18-1:0]   outv [3][16*2*FR];
  string vecdir;
  int jobs, seed, gap, errors = 0;
  longint cyc = 0, t_in [16], t_out [16];
  int oj = 0, ol = 0;

  always @(negedge clk) begin
    cyc++;
    if (out_valid) begin
      for (int i = 0; i < 3; i++) begin
        if (out_o0[i*PP*18 +: PP*18] !== outv[i][(2*oj)*FR + ol] || out_o1[i*PP*18 +: PP*18] !== outv[i][(2*oj+1)*FR + ol]) begin
          if (errors < 6) $display("ERROR job %0d p=%s tau %0d", oj, PS[i], ol);
          errors++;
        end
      end
      if (out_sof !== (ol == 0)) errors++;
      if (ol == FR - 1) begin
        ol = 0;
        t_out[oj] = cyc;
        oj++;
      end else ol++;
    end
  end

  task automatic send_job(input int j);
    for (int t = 0; t < FR; t++) begin
      @(negedge clk);
      in_valid <= 1;
      in_sof <= (t == 0);
      in_d0 <= dsig[(2*j)*FR + t];
      in_d1 <= dsig[(2*j+1)*FR + t];
      if (t == 0) t_in[j] = cyc;
    end
    @(negedge clk);
    in_valid <= 0;
    in_sof <= 0;
    repeat ($urandom % (gap + 1)) @(negedge clk);
  endtask

  initial begin
    if (!$value$plusargs("vec=%s", vecdir)) $fatal(1, "+vec=<dir> required");
    if (!$value$plusargs("jobs=%d", jobs)) jobs = 6;
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    if (!$value$plusargs("gap=%d", gap)) gap = 3;
    if (jobs % G != 0 || jobs > 15) $fatal(1, "jobs must be a multiple of 3, <= 15");
    void'($urandom(seed));
    $readmemh({vecdir, "/px_dsigned.hex"}, dsig, 0, jobs * 2 * FR - 1);
    for (int i = 0; i < 3; i++) begin
      $readmemh({vecdir, "/px_p", PS[i], "_op.hex"}, ops[i], 0, (jobs / G) * FR - 1);
      $readmemh({vecdir, "/px_p", PS[i], "_out.hex"}, outv[i], 0, jobs * 2 * FR - 1);
    end
    repeat (4) @(negedge clk);
    for (int g = 0; g < jobs / G; g++) begin
      while (oj < g * G) @(negedge clk);      // every frame sent has come out
      for (int w = 0; w < FR; w++) begin
        @(negedge clk);
        op_we <= 1;
        op_addr <= w[10-PLOG:0];
        for (int i = 0; i < 3; i++) op_wdata[i*4*PP*18 +: 4*PP*18] <= ops[i][g*FR + w];
      end
      @(negedge clk);
      op_we <= 0;
      for (int j = g * G; j < (g + 1) * G; j++) send_job(j);
    end
    while (oj < jobs) begin
      @(negedge clk);
      if (cyc > 64'd5_000_000) $fatal(1, "tb_xpipe timeout");
    end
    $display("job latency %0d cyc (first job), job interval %0d cyc (frame %0d cyc) PLOG=%0d RED=%0d",
             t_out[0] - t_in[0], (t_out[G-1] - t_out[0]) / (G - 1), FR, PLOG, RED);
    if (errors != 0) $fatal(1, "tb_xpipe FAILED: %0d mismatches", errors);
    $display("PASS tb_xpipe PLOG=%0d RED=%0d seed=%0d jobs=%0d (3 residues x 2 outputs x 2048 coefficients)", PLOG, RED, seed, jobs);
    $finish;
  end
endmodule
