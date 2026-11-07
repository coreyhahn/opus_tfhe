// pbs_engine end to end on two batches (banks 0 and 1): tfhe-rs ciphertexts in (oracle lwe_in,
// cts 0..7 and 8..15), bootstrapped ciphertexts out. The KS of batch 1 overlaps the blind rotation
// of batch 0. KSK (ks32 layout) preloaded by hierarchical $readmemh; LUT and BSK (engine form) from
// dump_engine real; BSK requests served by the TB. Outputs checked against the model and written
// to +outA / +outB for tfhe-rs decryption.
// Compile: -GPLOG=5 -GBSLOG=3 -GKSL=256 -GROMDIR='"<dir>"'
// Run    : +vecA=<real dir cts 0..7> +vecB=<real dir cts 8..15> +ks=<ks dir, 16 cts> +outA= +outB=
`timescale 1ns/1ps
`include "ksk_preload.svh"
module tb_pbs #(parameter int PLOG = 5, parameter int BSLOG = 3, parameter int KSL = 256, parameter string ROMDIR = "");
  localparam int PP = 1 << PLOG;
  localparam int FR = 2048 / PP;
  localparam int BS = 1 << BSLOG;
  localparam int NC = 918;
  localparam string PS [3] = '{"249857", "188417", "163841"};
  logic clk = 0, rst = 1;
  always #1 clk = ~clk;
  logic lut_we = 0, in_we = 0, in_bank = 0, start = 0, start_bank = 0, op_we = 0, op_buf = 0, bsk_done = 0;
  logic [1:0] lut_res, bank_free;
  logic [10-PLOG:0] lut_addr, op_addr;
  logic [PP*18-1:0] lut_wdata;
  logic [BSLOG-1:0] in_slot, o_slot;
  logic [11:0] in_addr, o_idx;
  logic [63:0] in_wdata, o_data;
  logic [3*4*PP*18-1:0] op_wdata;
  logic busy, done, done_bank, bsk_req, bsk_req_buf, o_valid, o_bank;
  logic [10:0] bsk_req_idx;

  pbs_engine #(.PLOG(PLOG), .BSLOG(BSLOG), .NC(NC), .KSL(KSL), .ROMDIR(ROMDIR)) dut (
    .clk(clk), .rst(rst), .ksk_we(1'b0), .ksk_addr('0), .ksk_wdata('0),
    .lut_we(lut_we), .lut_res(lut_res), .lut_addr(lut_addr), .lut_wdata(lut_wdata),
    .in_we(in_we), .in_bank(in_bank), .in_slot(in_slot), .in_addr(in_addr), .in_wdata(in_wdata),
    .start(start), .start_bank(start_bank), .bank_free(bank_free), .busy(busy), .done(done), .done_bank(done_bank),
    .bsk_req(bsk_req), .bsk_req_idx(bsk_req_idx), .bsk_req_buf(bsk_req_buf), .op_we(op_we), .op_buf(op_buf),
    .op_addr(op_addr), .op_wdata(op_wdata), .bsk_done(bsk_done),
    .o_valid(o_valid), .o_bank(o_bank), .o_slot(o_slot), .o_idx(o_idx), .o_data(o_data));

  logic [PP*18-1:0]   lut [3][FR];
  logic [4*PP*18-1:0] ops [3][NC * FR];
  logic [63:0] cts [2 * BS * 2049], outv0 [BS * 2049], outv1 [BS * 2049];
  string vecA, vecB, ksd, outA, outB;
  int errors = 0, outs [2], fdo [2], ndone = 0;
  longint cyc = 0, t_start, t_done [2];
  logic [63:0] want;
  always @(negedge clk) cyc++;
  always @(negedge clk) begin
    if (o_valid) begin
      if (fdo[o_bank] != 0) $fdisplay(fdo[o_bank], "%016h", o_data);
      want = o_bank ? outv1[o_slot * 2049 + o_idx] : outv0[o_slot * 2049 + o_idx];
      if (o_data !== want) begin
        if (errors < 6) $display("ERROR bank %0d slot %0d idx %0d: got %h want %h", o_bank, o_slot, o_idx, o_data, want);
        errors++;
      end
      outs[o_bank]++;
    end
    if (done) begin t_done[done_bank] = cyc; ndone++; end
  end
  initial forever begin
    @(negedge clk);
    if (bsk_req) begin
      int idx, b;
      idx = bsk_req_idx; b = bsk_req_buf;
      for (int w = 0; w < FR; w++) begin
        @(negedge clk);
        op_we <= 1; op_buf <= 1'(b); op_addr <= (11 - PLOG)'(w);
        for (int i = 0; i < 3; i++) op_wdata[i*4*PP*18 +: 4*PP*18] <= ops[i][idx * FR + w];
      end
      @(negedge clk);
      op_we <= 0; bsk_done <= 1;
      @(negedge clk);
      bsk_done <= 0;
    end
  end
  task automatic load_bank(input int b);
    for (int c = 0; c < BS; c++) for (int w = 0; w < 2049; w++) begin
      @(negedge clk);
      in_we <= 1; in_bank <= 1'(b); in_slot <= BSLOG'(c); in_addr <= 12'(w); in_wdata <= cts[(b * BS + c) * 2049 + w];
    end
    @(negedge clk);
    in_we <= 0;
    while (!bank_free[b]) @(negedge clk);
    start <= 1; start_bank <= 1'(b);
    @(negedge clk);
    start <= 0;
  endtask
  `KSK_PRELOAD(dut.u_ks, KSL)
  initial begin
    if (!$value$plusargs("vecA=%s", vecA) || !$value$plusargs("vecB=%s", vecB) || !$value$plusargs("ks=%s", ksd))
      $fatal(1, "+vecA= +vecB= +ks= required");
    fdo[0] = 0; fdo[1] = 0; outs[0] = 0; outs[1] = 0;
    if ($value$plusargs("outA=%s", outA)) fdo[0] = $fopen(outA, "w");
    if ($value$plusargs("outB=%s", outB)) fdo[1] = $fopen(outB, "w");
    $readmemh({ksd, "/ksk.hex"}, ksk_img);
    ksk_img_ready = 1;
    $readmemh({ksd, "/ct.hex"}, cts, 0, 2 * BS * 2049 - 1);
    $readmemh({vecA, "/out.hex"}, outv0);
    $readmemh({vecB, "/out.hex"}, outv1);
    for (int i = 0; i < 3; i++) begin
      $readmemh({vecA, "/lut_p", PS[i], ".hex"}, lut[i]);
      $readmemh({vecA, "/op_p", PS[i], ".hex"}, ops[i]);
    end
    repeat (4) @(negedge clk);
    rst = 0;
    for (int i = 0; i < 3; i++) for (int t = 0; t < FR; t++) begin
      @(negedge clk);
      lut_we <= 1; lut_res <= 2'(i); lut_addr <= (11 - PLOG)'(t); lut_wdata <= lut[i][t];
    end
    @(negedge clk);
    lut_we <= 0;
    t_start = cyc;
    load_bank(0);
    load_bank(1);
    while (ndone < 2) begin
      @(negedge clk);
      if (cyc - t_start > 64'd400_000_000) $fatal(1, "tb_pbs timeout");
    end
    for (int b = 0; b < 2; b++) if (fdo[b] != 0) $fclose(fdo[b]);
    $display("pbs_engine: 2 batches of %0d: batch 0 done at %0d cycles, batch 1 at %0d (+%0d per batch in steady state)",
             BS, t_done[0] - t_start, t_done[1] - t_start, t_done[1] - t_done[0]);
    if (errors != 0 || outs[0] != BS * 2049 || outs[1] != BS * 2049) $fatal(1, "tb_pbs FAILED: %0d errors, outputs %0d/%0d", errors, outs[0], outs[1]);
    $display("PASS tb_pbs P=%0d slots=%0d KSL=%0d: 2 x %0d output words bit-exact with the model", PP, BS, KSL, BS * 2049);
    $finish;
  end
endmodule
