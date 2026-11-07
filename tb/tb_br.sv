// br_core against the model (dump_engine br): a whole blind rotation of 2^BSLOG slots x NC CMuxes
// on random data. The TB serves BSK requests from the engine-form operand files, and checks every
// beat of every EXTRACT frame (3 residues) plus body[0].
// Compile: -GPLOG=5 -GBSLOG=3 -GNC=8 -GROMDIR='"<pipe ROM dir>"'   Run: +vec=<dir>
`timescale 1ns/1ps
module tb_br #(parameter int PLOG = 5, parameter int BSLOG = 3, parameter int NC = 8, parameter string ROMDIR = "",
              parameter int RED_F = 0, parameter int RED_M = 0, parameter int RED_I = 0,
              parameter string ROMDIR_F = ROMDIR, parameter string ROMDIR_I = ROMDIR,
              parameter logic [31:0] CYC_RST = '0);
  localparam int PP = 1 << PLOG;
  localparam int FR = 2048 / PP;
  localparam int BS = 1 << BSLOG;
  localparam string PS [3] = '{"249857", "188417", "163841"};
  logic clk = 0, rst = 1;
  always #1 clk = ~clk;

  logic lut_we = 0, ms_we = 0, start = 0, op_we = 0, op_buf = 0, bsk_done = 0;
  logic [1:0] lut_res;
  logic [10-PLOG:0] lut_addr, op_addr;
  logic [PP*18-1:0] lut_wdata;
  logic [BSLOG-1:0] ms_slot, ex_slot;
  logic [9:0] ms_idx;
  logic [10:0] bsk_req_idx;
  logic [11:0] ms_val;
  logic [3*4*PP*18-1:0] op_wdata;
  logic busy, done, bsk_req, bsk_req_buf, ex_valid, ex_sof;
  logic [3*PP*18-1:0] ex_d;
  logic [3*18-1:0] ex_body;
  logic o_valid;
  logic [BSLOG-1:0] o_slot;
  logic [11:0] o_idx;
  logic [63:0] o_data;
  psi_unit #(.PLOG(PLOG), .BSLOG(BSLOG)) u_psi (
    .clk(clk), .rst(rst), .ex_valid(ex_valid), .ex_sof(ex_sof), .ex_slot(ex_slot), .ex_d(ex_d), .ex_body(ex_body),
    .o_valid(o_valid), .o_slot(o_slot), .o_idx(o_idx), .o_data(o_data));
  logic [63:0] outv [BS * 2049];
  int outs_seen = 0, fdo = 0;
  string outfile;
  initial if ($value$plusargs("outfile=%s", outfile)) fdo = $fopen(outfile, "w");
  always @(negedge clk) if (o_valid) begin
    if (fdo != 0) $fdisplay(fdo, "%016h", o_data);
    if (o_data !== outv[o_slot * 2049 + o_idx]) begin
      if (errors < 6) $display("ERROR psi slot %0d idx %0d: got %h want %h", o_slot, o_idx, o_data, outv[o_slot * 2049 + o_idx]);
      errors++;
    end
    outs_seen++;
  end

  br_core #(.PLOG(PLOG), .BSLOG(BSLOG), .NC(NC), .RED_F(RED_F), .RED_M(RED_M), .RED_I(RED_I),
            .ROMDIR_F(ROMDIR_F), .ROMDIR_I(ROMDIR_I), .CYC_RST(CYC_RST)) dut (
    .clk(clk), .rst(rst), .lut_we(lut_we), .lut_res(lut_res), .lut_addr(lut_addr), .lut_wdata(lut_wdata),
    .ms_we(ms_we), .ms_bank(1'b0), .ms_slot(ms_slot), .ms_idx(ms_idx), .ms_val(ms_val), .start(start), .start_bank(1'b0), .busy(busy), .done(done),
    .bsk_req(bsk_req), .bsk_req_idx(bsk_req_idx), .bsk_req_buf(bsk_req_buf), .op_we(op_we), .op_buf(op_buf),
    .op_addr(op_addr), .op_wdata(op_wdata), .bsk_done(bsk_done), .ex_valid(ex_valid), .ex_sof(ex_sof),
    .ex_slot(ex_slot), .ex_d(ex_d), .ex_body(ex_body));

  logic [PP*18-1:0]   lut [3][FR];
  logic [4*PP*18-1:0] ops [3][1024 * FR];
  logic [PP*18-1:0]   ext [3][BS * (FR + 1)];
  int ms [BS][1025];
  string vec;
  int errors = 0, frames_seen = 0, beat = 0, cur_slot = 0, reqs = 0;
  longint cyc = 0, t_start, t_done;
  longint maxcyc = 200_000_000;     // +maxcyc=<n>: batch timeout (the cyc-wrap test uses a short one)
  int predelay = 0;
  initial begin
    void'($value$plusargs("maxcyc=%d", maxcyc));
    void'($value$plusargs("predelay=%d", predelay));
  end

  always @(negedge clk) cyc++;

  // EXTRACT checker
  always @(negedge clk) if (ex_valid) begin
    if (ex_sof) begin
      beat = 0;
      cur_slot = ex_slot;
      for (int i = 0; i < 3; i++)
        if (ex_body[i*18 +: 18] !== ext[i][cur_slot * (FR + 1) + FR][17:0]) begin
          if (errors < 6) $display("ERROR slot %0d p=%s body[0]: got %h want %h", cur_slot, PS[i], ex_body[i*18 +: 18], ext[i][cur_slot * (FR + 1) + FR][17:0]);
          errors++;
        end
    end
    for (int i = 0; i < 3; i++)
      if (ex_d[i*PP*18 +: PP*18] !== ext[i][cur_slot * (FR + 1) + beat]) begin
        if (errors < 6) $display("ERROR slot %0d p=%s tau %0d", cur_slot, PS[i], beat);
        errors++;
      end
    beat++;
    if (beat == FR) frames_seen++;
  end

  // BSK server: answer each request by writing that CMux's operands into the named buffer
  initial begin
    forever begin
      @(negedge clk);
      if (bsk_req) begin
        int idx, b;
        idx = bsk_req_idx;
        b = bsk_req_buf;
        reqs++;
        for (int w = 0; w < FR; w++) begin
          @(negedge clk);
          op_we <= 1;
          op_buf <= 1'(b);
          op_addr <= (11 - PLOG)'(w);
          for (int i = 0; i < 3; i++) op_wdata[i*4*PP*18 +: 4*PP*18] <= ops[i][idx * FR + w];
        end
        @(negedge clk);
        op_we <= 0;
        bsk_done <= 1;
        @(negedge clk);
        bsk_done <= 0;
      end
    end
  end

  initial begin
    int fd;
    if (!$value$plusargs("vec=%s", vec)) $fatal(1, "+vec=<dir> required");
    for (int i = 0; i < 3; i++) begin
      $readmemh({vec, "/lut_p", PS[i], ".hex"}, lut[i]);
      $readmemh({vec, "/op_p", PS[i], ".hex"}, ops[i], 0, NC * FR - 1);
      $readmemh({vec, "/ext_p", PS[i], ".hex"}, ext[i]);
    end
    $readmemh({vec, "/out.hex"}, outv);
    fd = $fopen({vec, "/ms.txt"}, "r");
    for (int c = 0; c < BS; c++) for (int k = 0; k <= NC; k++) void'($fscanf(fd, "%d", ms[c][k]));
    $fclose(fd);
    repeat (4) @(negedge clk);
    rst = 0;
    for (int i = 0; i < 3; i++) for (int t = 0; t < FR; t++) begin
      @(negedge clk);
      lut_we <= 1; lut_res <= 2'(i); lut_addr <= (11 - PLOG)'(t); lut_wdata <= lut[i][t];
    end
    for (int c = 0; c < BS; c++) for (int k = 0; k <= NC; k++) begin
      @(negedge clk);
      lut_we <= 0;
      ms_we <= 1; ms_slot <= BSLOG'(c); ms_idx <= 10'(k); ms_val <= 12'(ms[c][k]);
    end
    @(negedge clk);
    ms_we <= 0;
    repeat (predelay) @(negedge clk);   // +predelay=<n>: shifts the batch against the cyc wrap
    start <= 1;
    t_start = cyc;
    @(negedge clk);
    start <= 0;
    while (!done) begin
      @(negedge clk);
      if (cyc - t_start > maxcyc) $fatal(1, "tb_br timeout");
    end
    t_done = cyc;
    while (outs_seen < BS * 2049) begin
      @(negedge clk);
      if (cyc - t_done > 64'd100_000) $fatal(1, "tb_br: psi outputs missing (%0d)", outs_seen);
    end
    $display("br_core: %0d slots x %0d CMux in %0d cycles (%0d frames of %0d cycles = %0d), BSK requests %0d",
             BS, NC, t_done - t_start, BS * (NC + 2), FR, BS * (NC + 2) * FR, reqs);
    if (fdo != 0) $fclose(fdo);
    if (errors != 0 || frames_seen != BS) $fatal(1, "tb_br FAILED: %0d errors, %0d EXTRACT frames", errors, frames_seen);
    $display("PASS tb_br P=%0d slots=%0d NC=%0d (EXTRACT y-form + %0d psi outputs u64 bit-exact)", PP, BS, NC, outs_seen);
    $finish;
  end
endmodule
