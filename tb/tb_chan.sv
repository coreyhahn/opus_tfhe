// ddr_chan_rd alone: aclk 250 MHz engine side, ui_clk 300 MHz channel side, one axi_ddr_model.
// Two requests (the second after the first's beats are all consumed), with random o_ready gaps;
// every beat is checked against the model image. Run: +seed=<n>
`timescale 1ps/1ps
module tb_chan;
  localparam int DEPTH = 4096;
  localparam longint BASE = 64'h0040_0000;
  logic aclk = 0, ui_clk = 0, rst = 1, ui_rstn = 0;
  always #2000 aclk = ~aclk;
  initial begin #700; forever #1667 ui_clk = ~ui_clk; end

  logic req = 0, o_valid, o_ready = 0, err;
  logic [33:0] req_base = 0;
  logic [31:0] req_beats = 0;
  logic [511:0] o_data;
  logic [33:0] araddr; logic [7:0] arlen; logic [2:0] arsize; logic [1:0] arburst;
  logic arvalid, arready, rlast, rvalid, rready;
  logic [511:0] rdata; logic [1:0] rresp;
  ddr_chan_rd #(.ADDR_W(34)) dut (
    .clk(aclk), .rst(rst), .req(req), .req_base(req_base), .req_beats(req_beats),
    .o_valid(o_valid), .o_ready(o_ready), .o_data(o_data), .err(err),
    .ui_clk(ui_clk), .ui_rstn(ui_rstn), .m_araddr(araddr), .m_arlen(arlen), .m_arsize(arsize),
    .m_arburst(arburst), .m_arvalid(arvalid), .m_arready(arready), .m_rdata(rdata), .m_rresp(rresp),
    .m_rlast(rlast), .m_rvalid(rvalid), .m_rready(rready));
  axi_ddr_model #(.DEPTH(DEPTH), .BASE(BASE)) ddr (.clk(ui_clk), .araddr(araddr), .arlen(arlen),
    .arsize(arsize), .arburst(arburst), .arvalid(arvalid), .arready(arready), .rdata(rdata),
    .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready));

  longint cyc = 0;
  always @(negedge aclk) begin
    cyc++;
    if (cyc % 20000 == 0) begin
      $display("[%0d] pend %0d send %0d ack %0d | ui req %0d start %0d busy %0d arv %0d | ddr beats %0d",
               cyc, dut.pend, dut.h_send, dut.h_ack, dut.h_rcv, dut.ui_start, dut.u_rd.busy, arvalid, ddr.beats);
      $fflush;
    end
    if (cyc > 200000) $fatal(1, "tb_chan: timeout");
  end

  task automatic run(input int first, input int n);
    int got = 0;
    @(negedge aclk);
    req_base = 34'(BASE + 64 * first); req_beats = 32'(n); req = 1;
    @(negedge aclk); req = 0;
    while (got < n) begin
      logic take;
      o_ready = ($urandom_range(99, 0) < 70);
      take = o_valid && o_ready;
      if (take && o_data !== ddr.mem[first + got]) $fatal(1, "tb_chan: beat %0d of %0d wrong", got, n);
      @(negedge aclk);
      if (take) got++;
    end
    o_ready = 0;
    $display("request of %0d beats from beat %0d: all bit-exact, done at aclk %0d", n, first, cyc);
  endtask

  initial begin
    int seed;
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    void'($urandom(seed));
    for (int i = 0; i < DEPTH; i++) for (int j = 0; j < 16; j++) ddr.mem[i][j*32 +: 32] = $urandom;
    repeat (8) @(negedge aclk);
    rst = 0; ui_rstn = 1;
    repeat (40) @(negedge aclk);
    run(0, 1000);
    run(1024, 3000);
    if (err) $fatal(1, "tb_chan: err set");
    $display("PASS tb_chan seed %0d", seed);
    $finish;
  end
endmodule
