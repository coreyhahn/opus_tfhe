// One DDR4 channel's read path for the engine (docs/ARCHITECTURE.md §5): a request (byte base,
// 64-byte beat count) posted on the engine clock crosses to the channel's ui_clk
// (xpm_cdc_handshake), ddr_rd_streamer fetches it, and the beats cross back through an async FIFO
// (first-word fall-through) to a valid/ready stream on the engine clock.
// One request at a time: the next req is posted only after the previous one's beats were all
// consumed (the streamer has then received them all and is idle). err is sticky on the engine side.
module ddr_chan_rd #(
  parameter int ADDR_W = 34
) (
  // engine side
  input  logic              clk,
  input  logic              rst,
  input  logic              req,            // pulse; base/beats held until the beats are consumed
  input  logic [ADDR_W-1:0] req_base,
  input  logic [31:0]       req_beats,
  output logic              o_valid,
  input  logic              o_ready,
  output logic [511:0]      o_data,
  output logic              err,
  // DDR4 channel side (ui_clk)
  input  logic              ui_clk,
  input  logic              ui_rstn,
  output logic [ADDR_W-1:0] m_araddr,
  output logic [7:0]        m_arlen,
  output logic [2:0]        m_arsize,
  output logic [1:0]        m_arburst,
  output logic              m_arvalid,
  input  logic              m_arready,
  input  logic [511:0]      m_rdata,
  input  logic [1:0]        m_rresp,
  input  logic              m_rlast,
  input  logic              m_rvalid,
  output logic              m_rready
);
  // ---- request: engine clock -> ui_clk
  logic                     h_send, h_rcv, h_ack;
  logic [ADDR_W+31:0]       h_dest;
  logic                     pend;
  always_ff @(posedge clk) begin
    if (rst) begin h_send <= 1'b0; pend <= 1'b0; end
    else begin
      if (req) pend <= 1'b1;
      if (pend && !h_send && !h_ack) begin h_send <= 1'b1; pend <= 1'b0; end
      else if (h_send && h_ack) h_send <= 1'b0;
    end
  end
  xpm_cdc_handshake #(.DEST_EXT_HSK(0), .DEST_SYNC_FF(3), .SRC_SYNC_FF(3), .WIDTH(ADDR_W + 32)) u_req (
    .src_clk(clk), .src_in({req_base, req_beats}), .src_send(h_send), .src_rcv(h_ack),
    .dest_clk(ui_clk), .dest_req(h_rcv), .dest_ack(1'b0), .dest_out(h_dest));
  logic h_rcv_q;
  always_ff @(posedge ui_clk) h_rcv_q <= h_rcv;
  wire ui_start = h_rcv && !h_rcv_q;

  // ---- the read master (ui_clk)
  logic         s_valid, s_ready, ui_err, unused_busy, unused_done;
  logic [511:0] s_data;
  logic [47:0]  unused_pc;
  logic [31:0]  unused_pb;
  ddr_rd_streamer #(.ADDR_W(ADDR_W)) u_rd (
    .clk(ui_clk), .rstn(ui_rstn), .cfg_base(h_dest[ADDR_W+31:32]), .cfg_beats(h_dest[31:0]),
    .start(ui_start), .busy(unused_busy), .done(unused_done), .perf_cycles(unused_pc), .perf_beats(unused_pb),
    .m_araddr(m_araddr), .m_arlen(m_arlen), .m_arsize(m_arsize), .m_arburst(m_arburst),
    .m_arvalid(m_arvalid), .m_arready(m_arready), .m_rdata(m_rdata), .m_rresp(m_rresp),
    .m_rlast(m_rlast), .m_rvalid(m_rvalid), .m_rready(m_rready), .err_rresp(ui_err),
    .s_valid(s_valid), .s_ready(s_ready), .s_data(s_data));
  wire unused_st = ^{unused_busy, unused_done, unused_pc, unused_pb};

  // ---- beats: ui_clk -> engine clock
  logic f_full, f_empty, f_wbusy, f_rbusy;
  assign s_ready = !f_full && !f_wbusy;
  /* verilator lint_off PINCONNECTEMPTY */
  xpm_fifo_async #(.FIFO_MEMORY_TYPE("block"), .FIFO_WRITE_DEPTH(64), .WRITE_DATA_WIDTH(512),
                   .READ_DATA_WIDTH(512), .READ_MODE("fwft"), .FIFO_READ_LATENCY(0),
                   .USE_ADV_FEATURES("0000"), .CDC_SYNC_STAGES(3)) u_fifo (
    .sleep(1'b0), .rst(!ui_rstn), .wr_clk(ui_clk), .wr_en(s_valid && s_ready), .din(s_data),
    .full(f_full), .prog_full(), .wr_data_count(), .overflow(), .wr_rst_busy(f_wbusy), .almost_full(),
    .wr_ack(), .rd_clk(clk), .rd_en(o_valid && o_ready), .dout(o_data), .empty(f_empty), .prog_empty(),
    .rd_data_count(), .underflow(), .rd_rst_busy(f_rbusy), .almost_empty(), .data_valid(),
    .injectsbiterr(1'b0), .injectdbiterr(1'b0), .sbiterr(), .dbiterr());
  /* verilator lint_on PINCONNECTEMPTY */
  assign o_valid = !f_empty && !f_rbusy;

  // ---- sticky read-response error on the engine clock
  logic err_s;
  xpm_cdc_single #(.DEST_SYNC_FF(3), .SRC_INPUT_REG(1)) u_err (
    .src_clk(ui_clk), .src_in(ui_err), .dest_clk(clk), .dest_out(err_s));
  always_ff @(posedge clk) begin
    if (rst) err <= 1'b0;
    else if (err_s) err <= 1'b1;
  end
endmodule
