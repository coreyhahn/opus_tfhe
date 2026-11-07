// ks32 against tfhe-rs's own KS32 -> centred MS (oracle ref_ks_out / ref_ms via dump_engine ks).
// The KSK is preloaded into the DUT's memory by hierarchical $readmemh (sim only). Each ciphertext
// is loaded, keyswitched, and every KS and MS output word checked.
// Compile: -GL=16   Run: +vec=<dir> +count=C
`timescale 1ns/1ps
`include "ksk_preload.svh"
module tb_ks #(parameter int L = 16);
  logic clk = 0, rst = 1;
  always #1 clk = ~clk;
  logic ct_we = 0, start = 0, busy, ks_valid, ms_valid;
  logic [11:0] ct_addr;
  logic [63:0] ct_wdata;
  logic [9:0] ks_idx, ms_idx;
  logic [31:0] ks_val;
  logic [11:0] ms_val;
  ks32 #(.L(L)) dut (.clk(clk), .rst(rst), .ksk_we(1'b0), .ksk_addr('0), .ksk_wdata('0), .ct_we(ct_we),
    .ct_addr(ct_addr), .ct_wdata(ct_wdata), .start(start), .busy(busy), .ks_valid(ks_valid), .ks_idx(ks_idx),
    .ks_val(ks_val), .ms_valid(ms_valid), .ms_idx(ms_idx), .ms_val(ms_val));
  logic [63:0] cts [64 * 2049];
  logic [31:0] ksx [64 * 919];
  logic [11:0] msx [64 * 919];
  string vec;
  int count, errors = 0, cur = 0, nks = 0, nms = 0;
  longint cyc = 0, t0, per_ct;
  always @(negedge clk) begin
    cyc++;
    if (ks_valid) begin
      if (ks_val !== ksx[cur * 919 + ks_idx]) begin
        if (errors < 6) $display("ERROR ct %0d KS[%0d]: got %h want %h", cur, ks_idx, ks_val, ksx[cur * 919 + ks_idx]);
        errors++;
      end
      nks++;
    end
    if (ms_valid) begin
      if (ms_val !== msx[cur * 919 + ms_idx]) begin
        if (errors < 6) $display("ERROR ct %0d MS[%0d]: got %h want %h", cur, ms_idx, ms_val, msx[cur * 919 + ms_idx]);
        errors++;
      end
      nms++;
    end
  end
  `KSK_PRELOAD(dut, L)
  initial begin
    if (!$value$plusargs("vec=%s", vec)) $fatal(1, "+vec=<dir> required");
    if (!$value$plusargs("count=%d", count)) count = 4;
    $readmemh({vec, "/ksk.hex"}, ksk_img);
    ksk_img_ready = 1;
    $readmemh({vec, "/ct.hex"}, cts, 0, count * 2049 - 1);
    $readmemh({vec, "/ks.hex"}, ksx, 0, count * 919 - 1);
    $readmemh({vec, "/ms.hex"}, msx, 0, count * 919 - 1);
    repeat (3) @(negedge clk);
    rst = 0;
    for (cur = 0; cur < count; cur++) begin
      for (int w = 0; w < 2049; w++) begin
        @(negedge clk);
        ct_we <= 1; ct_addr <= 12'(w); ct_wdata <= cts[cur * 2049 + w];
      end
      @(negedge clk);
      ct_we <= 0;
      start <= 1;
      t0 = cyc;
      @(negedge clk);
      start <= 0;
      @(negedge clk);
      while (busy || nms < (cur + 1) * 919) @(negedge clk);
      per_ct = cyc - t0;
    end
    if (errors != 0 || nks != count * 919 || nms != count * 919) $fatal(1, "tb_ks FAILED: %0d errors, %0d KS, %0d MS", errors, nks, nms);
    $display("PASS tb_ks L=%0d: %0d ciphertexts, KS and MS bit-exact with tfhe-rs; %0d cycles per ciphertext", L, count, per_ct);
    $finish;
  end
endmodule
