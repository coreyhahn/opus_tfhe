// opus_top: the PBS engine with its board-side plumbing (docs/ARCHITECTURE.md §5), everything the
// shell block design connects to: the CSR (AXI4-Lite), the io window (AXI4 slave) and four
// read-only AXI4 masters, one per DDR4 channel (ui_clk each). Engine clock = aclk.
//   ch0 / ch1 / ch3: BSK residue 0 / 1 / 2 (bsk_asm)     ch2: KSK load (ksk_asm)
module opus_top #(
  parameter logic [31:0] VERSION = 32'h0,
  parameter int RED_F = 0, parameter int RED_M = 1, parameter int RED_I = 1,
  parameter int PLOG  = 5,
  parameter int BSLOG = 3,
  parameter int NC    = 918,
  parameter int KSL   = 184,
  parameter int IDW   = 4,
  parameter string ROMDIR_F = "",
  parameter string ROMDIR_I = ""
) (
  input  logic          aclk,
  input  logic          aresetn,
  input  logic [3:0]    calib_in,
  // CSR, AXI4-Lite
  input  logic [11:0]   s_axil_awaddr,
  input  logic          s_axil_awvalid,
  output logic          s_axil_awready,
  input  logic [31:0]   s_axil_wdata,
  input  logic [3:0]    s_axil_wstrb,
  input  logic          s_axil_wvalid,
  output logic          s_axil_wready,
  output logic [1:0]    s_axil_bresp,
  output logic          s_axil_bvalid,
  input  logic          s_axil_bready,
  input  logic [11:0]   s_axil_araddr,
  input  logic          s_axil_arvalid,
  output logic          s_axil_arready,
  output logic [31:0]   s_axil_rdata,
  output logic [1:0]    s_axil_rresp,
  output logic          s_axil_rvalid,
  input  logic          s_axil_rready,
  // io window, AXI4 slave 256-bit
  input  logic [IDW-1:0] s_io_awid,
  input  logic [21:0]   s_io_awaddr,
  input  logic [7:0]    s_io_awlen,
  input  logic          s_io_awvalid,
  output logic          s_io_awready,
  input  logic [255:0]  s_io_wdata,
  input  logic [31:0]   s_io_wstrb,
  input  logic          s_io_wlast,
  input  logic          s_io_wvalid,
  output logic          s_io_wready,
  output logic [IDW-1:0] s_io_bid,
  output logic [1:0]    s_io_bresp,
  output logic          s_io_bvalid,
  input  logic          s_io_bready,
  input  logic [IDW-1:0] s_io_arid,
  input  logic [21:0]   s_io_araddr,
  input  logic [7:0]    s_io_arlen,
  input  logic          s_io_arvalid,
  output logic          s_io_arready,
  output logic [IDW-1:0] s_io_rid,
  output logic [255:0]  s_io_rdata,
  output logic [1:0]    s_io_rresp,
  output logic          s_io_rlast,
  output logic          s_io_rvalid,
  input  logic          s_io_rready,
  // DDR4 channels, AXI4 read-only masters on each channel's ui_clk
  // scalar clock ports: Verilator 5.020 did not clock an xpm_cdc destination from a clock that
  // arrives as an array element (the request never crossed; evidence/stage3/verilator_arrclk), and the IPI
  // wrapper needs scalars anyway
  input  logic          ui_clk0, ui_clk1, ui_clk2, ui_clk3,
  input  logic          ui_rstn0, ui_rstn1, ui_rstn2, ui_rstn3,
  output logic [33:0]   m_araddr  [4],
  output logic [7:0]    m_arlen   [4],
  output logic [2:0]    m_arsize  [4],
  output logic [1:0]    m_arburst [4],
  output logic          m_arvalid [4],
  input  logic          m_arready [4],
  input  logic [511:0]  m_rdata   [4],
  input  logic [1:0]    m_rresp   [4],
  input  logic          m_rlast   [4],
  input  logic          m_rvalid  [4],
  output logic          m_rready  [4]
);
  localparam int FB = ntt_pkg::LOG_N - PLOG;

  // ---- control/status
  logic        eng_start, eng_start_bank, ksk_load, soft_rst, rst;
  logic [31:0] bsk_base_r [3], ksk_base_r;
  logic [1:0]  bank_free;
  logic        busy, done, done_bank, ksk_busy, bsk_busy;
  logic [3:0]  rd_err;
  always_ff @(posedge aclk) rst <= !aresetn || soft_rst;

  opus_csr #(.VERSION(VERSION)) u_csr (
    .aclk(aclk), .aresetn(aresetn), .calib_in(calib_in),
    .s_axil_awaddr(s_axil_awaddr), .s_axil_awvalid(s_axil_awvalid), .s_axil_awready(s_axil_awready),
    .s_axil_wdata(s_axil_wdata), .s_axil_wstrb(s_axil_wstrb), .s_axil_wvalid(s_axil_wvalid),
    .s_axil_wready(s_axil_wready), .s_axil_bresp(s_axil_bresp), .s_axil_bvalid(s_axil_bvalid),
    .s_axil_bready(s_axil_bready), .s_axil_araddr(s_axil_araddr), .s_axil_arvalid(s_axil_arvalid),
    .s_axil_arready(s_axil_arready), .s_axil_rdata(s_axil_rdata), .s_axil_rresp(s_axil_rresp),
    .s_axil_rvalid(s_axil_rvalid), .s_axil_rready(s_axil_rready),
    .eng_start(eng_start), .eng_start_bank(eng_start_bank), .ksk_load(ksk_load), .soft_rst(soft_rst),
    .bsk_base(bsk_base_r), .ksk_base(ksk_base_r),
    .bank_free(bank_free), .busy(busy), .ksk_busy(ksk_busy), .done(done), .done_bank(done_bank),
    .bsk_busy(bsk_busy), .rd_err(rd_err));

  // ---- the four channel readers
  logic          ui_clk [4], ui_rstn [4];
  assign ui_clk  = '{ui_clk0, ui_clk1, ui_clk2, ui_clk3};
  assign ui_rstn = '{ui_rstn0, ui_rstn1, ui_rstn2, ui_rstn3};
  logic          rq [4];
  logic [33:0]   rbase [4];
  logic [31:0]   rbeats [4];
  logic          rv [4], rr [4];
  logic [511:0]  rd [4];
  for (genvar c = 0; c < 4; c++) begin : g_ch
    ddr_chan_rd #(.ADDR_W(34)) u_rd (
      .clk(aclk), .rst(rst), .req(rq[c]), .req_base(rbase[c]), .req_beats(rbeats[c]),
      .o_valid(rv[c]), .o_ready(rr[c]), .o_data(rd[c]), .err(rd_err[c]),
      .ui_clk(ui_clk[c]), .ui_rstn(ui_rstn[c]),
      .m_araddr(m_araddr[c]), .m_arlen(m_arlen[c]), .m_arsize(m_arsize[c]), .m_arburst(m_arburst[c]),
      .m_arvalid(m_arvalid[c]), .m_arready(m_arready[c]), .m_rdata(m_rdata[c]), .m_rresp(m_rresp[c]),
      .m_rlast(m_rlast[c]), .m_rvalid(m_rvalid[c]), .m_rready(m_rready[c]));
  end

  // ---- BSK: residues 0/1/2 on channels 0/1/3
  logic                    bsk_req, bsk_req_buf, op_we, op_buf, bsk_done;
  logic                    b_rq [3];
  logic [2:0]              b_rr;
  logic [10:0]             bsk_req_idx;
  logic [FB-1:0]           op_addr;
  logic [3*4*(1<<PLOG)*18-1:0] op_wdata;
  logic [33:0]             b_base [3], b_rbase [3];
  logic [31:0]             b_beats;
  logic [511:0]            b_rd [3];
  for (genvar i = 0; i < 3; i++) begin : g_bb
    assign b_base[i] = 34'(bsk_base_r[i]);
  end
  assign b_rd[0] = rd[0];
  assign b_rd[1] = rd[1];
  assign b_rd[2] = rd[3];
  bsk_asm #(.PLOG(PLOG), .ADDR_W(34)) u_bsk (
    .clk(aclk), .rst(rst), .base(b_base), .bsk_req(bsk_req), .bsk_req_idx(bsk_req_idx),
    .bsk_req_buf(bsk_req_buf), .op_we(op_we), .op_buf(op_buf), .op_addr(op_addr), .op_wdata(op_wdata),
    .bsk_done(bsk_done), .rd_req(b_rq), .rd_base(b_rbase), .rd_beats(b_beats),
    .rd_valid({rv[3], rv[1], rv[0]}), .rd_ready(b_rr), .rd_data(b_rd), .busy(bsk_busy));

  // ---- KSK load on channel 2
  logic                    k_rq, k_rr, ksk_we;
  logic [33:0]             k_rbase;
  logic [31:0]             k_beats;
  logic [$clog2(2048*4*((NC+KSL)/KSL))-1:0] ksk_addr;
  logic [KSL*32-1:0]       ksk_wdata;
  ksk_asm #(.KSL(KSL), .NOUT(NC), .ADDR_W(34)) u_kska (
    .clk(aclk), .rst(rst), .start(ksk_load), .base(34'(ksk_base_r)), .busy(ksk_busy),
    .ksk_we(ksk_we), .ksk_addr(ksk_addr), .ksk_wdata(ksk_wdata), .rd_req(k_rq), .rd_base(k_rbase),
    .rd_beats(k_beats), .rd_valid(rv[2]), .rd_ready(k_rr), .rd_data(rd[2]));

  always_comb begin
    rq[0] = b_rq[0]; rbase[0] = b_rbase[0]; rbeats[0] = b_beats; rr[0] = b_rr[0];
    rq[1] = b_rq[1]; rbase[1] = b_rbase[1]; rbeats[1] = b_beats; rr[1] = b_rr[1];
    rq[3] = b_rq[2]; rbase[3] = b_rbase[2]; rbeats[3] = b_beats; rr[3] = b_rr[2];
    rq[2] = k_rq; rbase[2] = k_rbase;    rbeats[2] = k_beats; rr[2] = k_rr;
  end

  // ---- io window
  logic                    in_we, in_bank, lut_we, o_valid, o_bank;
  logic [BSLOG-1:0]        in_slot, o_slot;
  logic [11:0]             in_addr, o_idx;
  logic [63:0]             in_wdata, o_data;
  logic [1:0]              lut_res;
  logic [FB-1:0]           lut_addr;
  logic [(1<<PLOG)*18-1:0] lut_wdata;
  io_win #(.PLOG(PLOG), .BSLOG(BSLOG), .IDW(IDW), .AW(22)) u_io (
    .clk(aclk), .rst(rst),
    .s_awid(s_io_awid), .s_awaddr(s_io_awaddr), .s_awlen(s_io_awlen), .s_awvalid(s_io_awvalid),
    .s_awready(s_io_awready), .s_wdata(s_io_wdata), .s_wstrb(s_io_wstrb), .s_wlast(s_io_wlast),
    .s_wvalid(s_io_wvalid), .s_wready(s_io_wready), .s_bid(s_io_bid), .s_bresp(s_io_bresp),
    .s_bvalid(s_io_bvalid), .s_bready(s_io_bready), .s_arid(s_io_arid), .s_araddr(s_io_araddr),
    .s_arlen(s_io_arlen), .s_arvalid(s_io_arvalid), .s_arready(s_io_arready), .s_rid(s_io_rid),
    .s_rdata(s_io_rdata), .s_rresp(s_io_rresp), .s_rlast(s_io_rlast), .s_rvalid(s_io_rvalid),
    .s_rready(s_io_rready),
    .in_we(in_we), .in_bank(in_bank), .in_slot(in_slot), .in_addr(in_addr), .in_wdata(in_wdata),
    .lut_we(lut_we), .lut_res(lut_res), .lut_addr(lut_addr), .lut_wdata(lut_wdata),
    .o_valid(o_valid), .o_bank(o_bank), .o_slot(o_slot), .o_idx(o_idx), .o_data(o_data));

  // ---- the engine
  pbs_engine #(.RED_F(RED_F), .RED_M(RED_M), .RED_I(RED_I), .PLOG(PLOG), .BSLOG(BSLOG), .NC(NC),
               .KSL(KSL), .ROMDIR_F(ROMDIR_F), .ROMDIR_I(ROMDIR_I)) u_eng (
    .clk(aclk), .rst(rst), .ksk_we(ksk_we), .ksk_addr(ksk_addr), .ksk_wdata(ksk_wdata),
    .lut_we(lut_we), .lut_res(lut_res), .lut_addr(lut_addr), .lut_wdata(lut_wdata),
    .in_we(in_we), .in_bank(in_bank), .in_slot(in_slot), .in_addr(in_addr), .in_wdata(in_wdata),
    .start(eng_start), .start_bank(eng_start_bank), .bank_free(bank_free), .busy(busy), .done(done),
    .done_bank(done_bank), .bsk_req(bsk_req), .bsk_req_idx(bsk_req_idx), .bsk_req_buf(bsk_req_buf),
    .op_we(op_we), .op_buf(op_buf), .op_addr(op_addr), .op_wdata(op_wdata), .bsk_done(bsk_done),
    .o_valid(o_valid), .o_bank(o_bank), .o_slot(o_slot), .o_idx(o_idx), .o_data(o_data));
endmodule
