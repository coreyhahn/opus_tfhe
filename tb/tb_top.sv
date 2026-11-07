// opus_top end to end, the way the host will drive the board (docs/ARCHITECTURE.md §5): the keys
// sit in four DDR4 channel models in the board layout (sw/pack_ddr.py), everything else goes through
// the CSR (AXI4-Lite) and the io window (AXI4): KSK load from DDR4, LUT, two batches of BS tfhe-rs
// ciphertexts into banks 0 and 1, start both, poll DONE_CNT, read both output banks back. Outputs
// are checked against the model and written to +outA / +outB for tfhe-rs decryption.
// aclk 250 MHz, the four ui_clk 300 MHz (unrelated phases), as on the board.
// Compile: -GPLOG=5 -GBSLOG=3 -GKSL=184 -GRED_F=0 -GRED_M=1 -GRED_I=1 -GROMDIR_F='"<mont>"' -GROMDIR_I='"<table>"'
// Run    : +vecA=<real dir cts 0..7> +vecB=<cts 8..15> +ks=<ks dir, 16 cts> +ddr=<dir with ch0..3.hex>
//          +outA= +outB=
`timescale 1ps/1ps
module tb_top #(
  parameter int PLOG = 5, parameter int BSLOG = 3, parameter int KSL = 184,
  parameter int RED_F = 0, parameter int RED_M = 1, parameter int RED_I = 1,
  parameter string ROMDIR_F = "", parameter string ROMDIR_I = ""
);
  localparam int PP = 1 << PLOG;
  localparam int FR = 2048 / PP;
  localparam int BS = 1 << BSLOG;
  localparam int NC = 918;
  localparam int LW = PP * 18;
  localparam int BSK_BEATS = NC * FR * ((4 * LW + 511) / 512);
  localparam int KSK_BEATS = 2048 * 4 * ((NC + KSL) / KSL) * ((KSL * 32 + 511) / 512);
  localparam longint BB0 = 64'h0010_0000, BB1 = 64'h0020_0000, BB2 = 64'h0030_0000, KB = 64'h0040_0000;
  localparam string PS [3] = '{"249857", "188417", "163841"};

  logic aclk = 0, aresetn = 0;
  logic uc0 = 0, uc1 = 0, uc2 = 0, uc3 = 0, ui_rstn_all = 0;
  logic ui_clk [4];
  assign ui_clk = '{uc0, uc1, uc2, uc3};
  logic [3:0] calib = 4'h0;
  always #2000 aclk = ~aclk;
  initial fork
    forever #1666 uc0 = ~uc0;
    begin #300;  forever #1666 uc1 = ~uc1; end
    begin #700;  forever #1667 uc2 = ~uc2; end
    begin #1100; forever #1666 uc3 = ~uc3; end
  join_none

  // ---- AXI-Lite (CSR)
  logic [11:0] l_awaddr = 0, l_araddr = 0;
  logic l_awvalid = 0, l_wvalid = 0, l_bready = 0, l_arvalid = 0, l_rready = 0;
  logic l_awready, l_wready, l_bvalid, l_arready, l_rvalid;
  logic [31:0] l_wdata = 0, l_rdata;
  logic [1:0] l_bresp, l_rresp;
  // ---- AXI4 (io window)
  logic [3:0] w_awid = 0, w_arid = 0, w_bid, w_rid;
  logic [21:0] w_awaddr = 0, w_araddr = 0;
  logic [7:0] w_awlen = 0, w_arlen = 0;
  logic w_awvalid = 0, w_wvalid = 0, w_wlast = 0, w_bready = 0, w_arvalid = 0, w_rready = 0;
  logic w_awready, w_wready, w_bvalid, w_arready, w_rvalid, w_rlast;
  logic [255:0] w_wdata = 0, w_rdata;
  logic [1:0] w_bresp, w_rresp;
  // ---- DDR4 channels
  logic [33:0]  m_araddr  [4];
  logic [7:0]   m_arlen   [4];
  logic [2:0]   m_arsize  [4];
  logic [1:0]   m_arburst [4];
  logic         m_arvalid [4], m_arready [4], m_rlast [4], m_rvalid [4], m_rready [4];
  logic [511:0] m_rdata   [4];
  logic [1:0]   m_rresp   [4];

  opus_top #(.VERSION(32'h1234_5678), .RED_F(RED_F), .RED_M(RED_M), .RED_I(RED_I), .PLOG(PLOG),
             .BSLOG(BSLOG), .NC(NC), .KSL(KSL), .ROMDIR_F(ROMDIR_F), .ROMDIR_I(ROMDIR_I)) dut (
    .aclk(aclk), .aresetn(aresetn), .calib_in(calib),
    .s_axil_awaddr(l_awaddr), .s_axil_awvalid(l_awvalid), .s_axil_awready(l_awready),
    .s_axil_wdata(l_wdata), .s_axil_wstrb(4'hF), .s_axil_wvalid(l_wvalid), .s_axil_wready(l_wready),
    .s_axil_bresp(l_bresp), .s_axil_bvalid(l_bvalid), .s_axil_bready(l_bready),
    .s_axil_araddr(l_araddr), .s_axil_arvalid(l_arvalid), .s_axil_arready(l_arready),
    .s_axil_rdata(l_rdata), .s_axil_rresp(l_rresp), .s_axil_rvalid(l_rvalid), .s_axil_rready(l_rready),
    .s_io_awid(w_awid), .s_io_awaddr(w_awaddr), .s_io_awlen(w_awlen), .s_io_awvalid(w_awvalid),
    .s_io_awready(w_awready), .s_io_wdata(w_wdata), .s_io_wstrb('1), .s_io_wlast(w_wlast),
    .s_io_wvalid(w_wvalid), .s_io_wready(w_wready), .s_io_bid(w_bid), .s_io_bresp(w_bresp),
    .s_io_bvalid(w_bvalid), .s_io_bready(w_bready), .s_io_arid(w_arid), .s_io_araddr(w_araddr),
    .s_io_arlen(w_arlen), .s_io_arvalid(w_arvalid), .s_io_arready(w_arready), .s_io_rid(w_rid),
    .s_io_rdata(w_rdata), .s_io_rresp(w_rresp), .s_io_rlast(w_rlast), .s_io_rvalid(w_rvalid),
    .s_io_rready(w_rready),
    .ui_clk0(uc0), .ui_clk1(uc1), .ui_clk2(uc2), .ui_clk3(uc3),
    .ui_rstn0(ui_rstn_all), .ui_rstn1(ui_rstn_all), .ui_rstn2(ui_rstn_all), .ui_rstn3(ui_rstn_all), .m_araddr(m_araddr), .m_arlen(m_arlen), .m_arsize(m_arsize),
    .m_arburst(m_arburst), .m_arvalid(m_arvalid), .m_arready(m_arready), .m_rdata(m_rdata),
    .m_rresp(m_rresp), .m_rlast(m_rlast), .m_rvalid(m_rvalid), .m_rready(m_rready));

  axi_ddr_model #(.DEPTH(BSK_BEATS), .BASE(BB0)) ddr0 (.clk(uc0), .araddr(m_araddr[0]), .arlen(m_arlen[0]),
    .arsize(m_arsize[0]), .arburst(m_arburst[0]), .arvalid(m_arvalid[0]), .arready(m_arready[0]), .rdata(m_rdata[0]),
    .rresp(m_rresp[0]), .rlast(m_rlast[0]), .rvalid(m_rvalid[0]), .rready(m_rready[0]));
  axi_ddr_model #(.DEPTH(BSK_BEATS), .BASE(BB1)) ddr1 (.clk(uc1), .araddr(m_araddr[1]), .arlen(m_arlen[1]),
    .arsize(m_arsize[1]), .arburst(m_arburst[1]), .arvalid(m_arvalid[1]), .arready(m_arready[1]), .rdata(m_rdata[1]),
    .rresp(m_rresp[1]), .rlast(m_rlast[1]), .rvalid(m_rvalid[1]), .rready(m_rready[1]));
  axi_ddr_model #(.DEPTH(KSK_BEATS), .BASE(KB)) ddr2 (.clk(uc2), .araddr(m_araddr[2]), .arlen(m_arlen[2]),
    .arsize(m_arsize[2]), .arburst(m_arburst[2]), .arvalid(m_arvalid[2]), .arready(m_arready[2]), .rdata(m_rdata[2]),
    .rresp(m_rresp[2]), .rlast(m_rlast[2]), .rvalid(m_rvalid[2]), .rready(m_rready[2]));
  axi_ddr_model #(.DEPTH(BSK_BEATS), .BASE(BB2)) ddr3 (.clk(uc3), .araddr(m_araddr[3]), .arlen(m_arlen[3]),
    .arsize(m_arsize[3]), .arburst(m_arburst[3]), .arvalid(m_arvalid[3]), .arready(m_arready[3]), .rdata(m_rdata[3]),
    .rresp(m_rresp[3]), .rlast(m_rlast[3]), .rvalid(m_rvalid[3]), .rready(m_rready[3]));

  // ---- bus tasks: drive at negedge. The readies do not depend on the valids combinationally, so a
  // ready seen at a negedge while valid is high means the handshake happens at the next posedge.
  task automatic csr_wr(input logic [11:0] a, input logic [31:0] d);
    logic ra, rw;
    @(negedge aclk);
    l_awaddr <= a; l_awvalid <= 1; l_wdata <= d; l_wvalid <= 1;
    fork
      begin do begin ra = l_awready; @(negedge aclk); end while (!ra); l_awvalid <= 0; end
      begin do begin rw = l_wready;  @(negedge aclk); end while (!rw); l_wvalid <= 0; end
    join
    l_bready <= 1;
    do begin ra = l_bvalid; @(negedge aclk); end while (!ra);
    l_bready <= 0;
  endtask
  task automatic csr_rd(input logic [11:0] a, output logic [31:0] d);
    logic rd;
    @(negedge aclk);
    l_araddr <= a; l_arvalid <= 1;
    do begin rd = l_arready; @(negedge aclk); end while (!rd);
    l_arvalid <= 0; l_rready <= 1;
    do begin rd = l_rvalid; d = l_rdata; @(negedge aclk); end while (!rd);
    l_rready <= 0;
  endtask
  task automatic csr_rd64(input logic [11:0] a, output longint v);
    logic [31:0] lo, hi;
    csr_rd(a, lo); csr_rd(a + 12'd4, hi);
    v = {hi, lo};
  endtask
  task automatic io_wr(input logic [21:0] a, input logic [255:0] beats [$]);
    logic rd;
    @(negedge aclk);
    w_awaddr <= a; w_awlen <= 8'(beats.size() - 1); w_awvalid <= 1;
    do begin rd = w_awready; @(negedge aclk); end while (!rd);
    w_awvalid <= 0;
    for (int i = 0; i < beats.size(); i++) begin
      w_wdata <= beats[i]; w_wlast <= (i == beats.size() - 1); w_wvalid <= 1;
      do begin rd = w_wready; @(negedge aclk); end while (!rd);
    end
    w_wvalid <= 0;
    w_bready <= 1;
    do begin rd = w_bvalid; @(negedge aclk); end while (!rd);
    w_bready <= 0;
  endtask
  task automatic io_rd(input logic [21:0] a, input int n, output logic [255:0] beats [$]);
    logic rd;
    beats = {};
    @(negedge aclk);
    w_araddr <= a; w_arlen <= 8'(n - 1); w_arvalid <= 1;
    do begin rd = w_arready; @(negedge aclk); end while (!rd);
    w_arvalid <= 0; w_rready <= 1;
    while (beats.size() < n) begin
      if (w_rvalid) begin
        beats.push_back(w_rdata);
        if ((beats.size() == n) != w_rlast) $fatal(1, "io_rd: RLAST wrong at beat %0d", beats.size());
      end
      @(negedge aclk);
    end
    w_rready <= 0;
  endtask

  // ---- data
  logic [LW-1:0] lut [3][FR];
  logic [63:0]   cts [2 * BS * 2049], outv0 [BS * 2049], outv1 [BS * 2049];
  string vecA, vecB, ksd, ddrd, outf [2];
  longint cyc = 0, t_start, t_done [2];
  int ndone = 0;
  always @(negedge aclk) cyc++;
  int k_rq_seen = 0, ui_start_seen = 0, ui2_edges = 0;
  always @(posedge aclk) if (dut.k_rq) k_rq_seen++;
  always @(posedge uc2) begin ui2_edges++; if (dut.g_ch[2].u_rd.ui_start) ui_start_seen++; end
  // progress watchdog: a line every 250k aclk cycles (flushed, so a hang shows where), hard limit 8M
  always @(negedge aclk) if (cyc % 250000 == 0 && cyc != 0) begin
    $display("[%0d] ksk_busy %0d rows %0d | ddr beats %0d %0d %0d %0d | arv %0d%0d%0d%0d rv %0d%0d%0d%0d rr %0d%0d%0d%0d | done %0d",
             cyc, dut.ksk_busy, dut.u_kska.rc, ddr0.beats, ddr1.beats, ddr2.beats, ddr3.beats,
             m_arvalid[0], m_arvalid[1], m_arvalid[2], m_arvalid[3], m_rvalid[0], m_rvalid[1], m_rvalid[2], m_rvalid[3],
             m_rready[0], m_rready[1], m_rready[2], m_rready[3], ndone);
    $display("    ch2: k_rq seen %0d pend %0d send %0d ack %0d | ui req %0d start seen %0d busy %0d btr %0d | ui_clk2 edges %0d",
             k_rq_seen, dut.g_ch[2].u_rd.pend, dut.g_ch[2].u_rd.h_send, dut.g_ch[2].u_rd.h_ack,
             dut.g_ch[2].u_rd.h_rcv, ui_start_seen, dut.g_ch[2].u_rd.u_rd.busy, dut.g_ch[2].u_rd.u_rd.beats_to_req, ui2_edges);
    $fflush;
    if (cyc >= 8_000_000) $fatal(1, "tb_top: no finish after %0d aclk cycles", cyc);
  end
  always @(negedge aclk) if (dut.done) begin t_done[dut.done_bank] = cyc; ndone++; end

  initial begin
    logic [31:0] r;
    logic [255:0] bq [$];
    longint bc, busy_c, wait_c, b_cyc [2];
    int errors = 0;
    if (!$value$plusargs("vecA=%s", vecA) || !$value$plusargs("vecB=%s", vecB) || !$value$plusargs("ks=%s", ksd)
        || !$value$plusargs("ddr=%s", ddrd))
      $fatal(1, "+vecA= +vecB= +ks= +ddr= required");
    if (!$value$plusargs("outA=%s", outf[0])) outf[0] = "";
    if (!$value$plusargs("outB=%s", outf[1])) outf[1] = "";
    ddr0.load({ddrd, "/ch0.hex"}); ddr1.load({ddrd, "/ch1.hex"});
    ddr2.load({ddrd, "/ch2.hex"}); ddr3.load({ddrd, "/ch3.hex"});
    $readmemh({ksd, "/ct.hex"}, cts, 0, 2 * BS * 2049 - 1);
    $readmemh({vecA, "/out.hex"}, outv0);
    $readmemh({vecB, "/out.hex"}, outv1);
    for (int i = 0; i < 3; i++) $readmemh({vecA, "/lut_p", PS[i], ".hex"}, lut[i]);
    repeat (8) @(negedge aclk);
    aresetn = 1;
    ui_rstn_all = 1;
    repeat (16) @(negedge aclk);

    csr_rd(12'h000, r); if (r !== 32'h0F7F_E001) $fatal(1, "MAGIC %h", r);
    csr_rd(12'h004, r); if (r !== 32'h1234_5678) $fatal(1, "VERSION %h", r);
    csr_wr(12'h008, 32'hA5A5_0F0F); csr_rd(12'h008, r); if (r !== 32'hA5A5_0F0F) $fatal(1, "SCRATCH %h", r);
    // start before calibration must be ignored
    csr_wr(12'h040, 32'h1);
    repeat (8) @(negedge aclk);
    csr_rd(12'h044, r); if (r[2] !== 1'b0) $fatal(1, "engine started before CALIB");
    calib = 4'hF;
    do csr_rd(12'h00C, r); while (r[3:0] != 4'hF);
    csr_wr(12'h050, 32'(BB0)); csr_wr(12'h054, 32'(BB1)); csr_wr(12'h058, 32'(BB2)); csr_wr(12'h05C, 32'(KB));

    // KSK from DDR4
    bc = cyc;
    csr_wr(12'h040, 32'h10);
    do begin repeat (2000) @(negedge aclk); csr_rd(12'h044, r); end while (r[3]);
    $display("KSK load: %0d aclk cycles (%0d beats from ch2)", cyc - bc, KSK_BEATS);
    // LUT: three beats per word at a 128-byte stride
    for (int i = 0; i < 3; i++) for (int t = 0; t < FR; t++) begin
      logic [767:0] w;
      w = 768'(lut[i][t]);
      bq = {w[255:0], w[511:256], w[767:512]};
      io_wr(22'h100000 + 22'((i * FR + t) * 128), bq);
    end
    // two batches, 16-beat bursts (4 u64 per beat)
    t_start = cyc;
    for (int b = 0; b < 2; b++) begin
      for (int c = 0; c < BS; c++) for (int w0 = 0; w0 < 2049; w0 += 64) begin
        bq = {};
        for (int k = 0; k < 16 && w0 + 4 * k < 2049; k++) begin
          logic [255:0] x;
          for (int j = 0; j < 4; j++) x[j*64 +: 64] = (w0 + 4 * k + j < 2049) ? cts[(b * BS + c) * 2049 + w0 + 4 * k + j] : 64'h0;
          bq.push_back(x);
        end
        io_wr(22'(((b * BS + c) * 4096 + w0) * 8), bq);
      end
      do csr_rd(12'h044, r); while (!r[b]);
      csr_wr(12'h040, 32'h1 | (32'(b) << 1));
    end
    // wait for both, by DONE_CNT; BATCH_CYC after each
    for (int n = 1; n <= 2; n++) begin
      do begin
        repeat (1000) @(negedge aclk);
        csr_rd(12'h048, r);
        if (cyc - t_start > 64'd20_000_000) $fatal(1, "tb_top timeout");
      end while (r < 32'(n));
      csr_rd64(12'h060, b_cyc[n - 1]);
    end
    csr_rd64(12'h068, busy_c);
    csr_rd64(12'h070, wait_c);
    csr_rd(12'h044, r);
    if (r[11:8] != 0) $fatal(1, "DDR read response error %b", r[11:8]);
    if (ddr0.bad + ddr1.bad + ddr2.bad + ddr3.bad != 0) $fatal(1, "DDR model flagged bad reads");
    // read both output banks back through the io window
    for (int b = 0; b < 2; b++) begin
      int fd;
      fd = 0;
      if (outf[b] != "") fd = $fopen(outf[b], "w");
      for (int c = 0; c < BS; c++) for (int w0 = 0; w0 < 2049; w0 += 64) begin
        int nb;
        nb = (2049 - w0 + 3) / 4; if (nb > 16) nb = 16;
        io_rd(22'h200000 + 22'(((b * BS + c) * 4096 + w0) * 8), nb, bq);
        for (int k = 0; k < nb; k++) for (int j = 0; j < 4; j++) begin
          int i;
          i = w0 + 4 * k + j;
          if (i < 2049) begin
            if (fd != 0) $fdisplay(fd, "%016h", bq[k][j*64 +: 64]);
            if (bq[k][j*64 +: 64] !== (b ? outv1[c * 2049 + i] : outv0[c * 2049 + i])) begin
              if (errors < 6) $display("ERROR bank %0d slot %0d idx %0d: got %h want %h", b, c, i, bq[k][j*64 +: 64], (b ? outv1[c * 2049 + i] : outv0[c * 2049 + i]));
              errors++;
            end
          end
        end
      end
      if (fd != 0) $fclose(fd);
    end
    $display("opus_top: 2 batches of %0d: batch 0 done at %0d cycles, batch 1 at %0d (+%0d per batch in steady state)",
             BS, t_done[0] - t_start, t_done[1] - t_start, t_done[1] - t_done[0]);
    $display("opus_top CSR: BATCH_CYC %0d / %0d, BUSY_CYC %0d, BSK_WAIT %0d (BSK request outstanding)",
             b_cyc[0], b_cyc[1], busy_c, wait_c);
    if (errors != 0) $fatal(1, "tb_top FAILED: %0d output words differ", errors);
    $display("PASS tb_top P=%0d slots=%0d KSL=%0d: keys from DDR4 models, 2 x %0d output words read back bit-exact",
             PP, BS, KSL, BS * 2049);
    $finish;
  end
endmodule
