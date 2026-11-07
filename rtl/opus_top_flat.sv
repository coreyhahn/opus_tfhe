// opus_top_flat: opus_top with its unpacked-array DDR4 master ports (m_*[4]) flattened to one set of
// scalar ports per channel (m0_* .. m3_*). Nothing else: same parameters, same scalar ports, no logic.
// It exists so the plain-Verilog IPI wrapper rtl/opus_top_ipi.v (Vivado module references reject an
// SV top file, filemgmt 56-195) can connect the four AXI4 read masters without SV array ports.
// The opus_top instance is named u_top, so the hierarchy keeps .../u_top/u_csr/... (the
// synth/constraints/fable5_cdc.xdc false path */u_csr/calib_meta_reg[*]/D) and .../u_top/u_eng/...
// (synth/constraints/engine_slr_full.xdc).
module opus_top_flat #(
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
  input  logic          ui_clk0, ui_clk1, ui_clk2, ui_clk3,
  input  logic          ui_rstn0, ui_rstn1, ui_rstn2, ui_rstn3,
  output logic [33:0]   m0_araddr,  m1_araddr,  m2_araddr,  m3_araddr,
  output logic [7:0]    m0_arlen,   m1_arlen,   m2_arlen,   m3_arlen,
  output logic [2:0]    m0_arsize,  m1_arsize,  m2_arsize,  m3_arsize,
  output logic [1:0]    m0_arburst, m1_arburst, m2_arburst, m3_arburst,
  output logic          m0_arvalid, m1_arvalid, m2_arvalid, m3_arvalid,
  input  logic          m0_arready, m1_arready, m2_arready, m3_arready,
  input  logic [511:0]  m0_rdata,   m1_rdata,   m2_rdata,   m3_rdata,
  input  logic [1:0]    m0_rresp,   m1_rresp,   m2_rresp,   m3_rresp,
  input  logic          m0_rlast,   m1_rlast,   m2_rlast,   m3_rlast,
  input  logic          m0_rvalid,  m1_rvalid,  m2_rvalid,  m3_rvalid,
  output logic          m0_rready,  m1_rready,  m2_rready,  m3_rready
);
  logic [33:0]  m_araddr  [4];
  logic [7:0]   m_arlen   [4];
  logic [2:0]   m_arsize  [4];
  logic [1:0]   m_arburst [4];
  logic         m_arvalid [4];
  logic         m_arready [4];
  logic [511:0] m_rdata   [4];
  logic [1:0]   m_rresp   [4];
  logic         m_rlast   [4];
  logic         m_rvalid  [4];
  logic         m_rready  [4];

  assign {m0_araddr,  m1_araddr,  m2_araddr,  m3_araddr}  = {m_araddr[0],  m_araddr[1],  m_araddr[2],  m_araddr[3]};
  assign {m0_arlen,   m1_arlen,   m2_arlen,   m3_arlen}   = {m_arlen[0],   m_arlen[1],   m_arlen[2],   m_arlen[3]};
  assign {m0_arsize,  m1_arsize,  m2_arsize,  m3_arsize}  = {m_arsize[0],  m_arsize[1],  m_arsize[2],  m_arsize[3]};
  assign {m0_arburst, m1_arburst, m2_arburst, m3_arburst} = {m_arburst[0], m_arburst[1], m_arburst[2], m_arburst[3]};
  assign {m0_arvalid, m1_arvalid, m2_arvalid, m3_arvalid} = {m_arvalid[0], m_arvalid[1], m_arvalid[2], m_arvalid[3]};
  assign {m0_rready,  m1_rready,  m2_rready,  m3_rready}  = {m_rready[0],  m_rready[1],  m_rready[2],  m_rready[3]};
  assign m_arready = '{m0_arready, m1_arready, m2_arready, m3_arready};
  assign m_rdata   = '{m0_rdata,   m1_rdata,   m2_rdata,   m3_rdata};
  assign m_rresp   = '{m0_rresp,   m1_rresp,   m2_rresp,   m3_rresp};
  assign m_rlast   = '{m0_rlast,   m1_rlast,   m2_rlast,   m3_rlast};
  assign m_rvalid  = '{m0_rvalid,  m1_rvalid,  m2_rvalid,  m3_rvalid};

  opus_top #(.VERSION(VERSION), .RED_F(RED_F), .RED_M(RED_M), .RED_I(RED_I), .PLOG(PLOG),
             .BSLOG(BSLOG), .NC(NC), .KSL(KSL), .IDW(IDW), .ROMDIR_F(ROMDIR_F), .ROMDIR_I(ROMDIR_I)) u_top (
    .aclk(aclk), .aresetn(aresetn), .calib_in(calib_in),
    .s_axil_awaddr(s_axil_awaddr), .s_axil_awvalid(s_axil_awvalid), .s_axil_awready(s_axil_awready),
    .s_axil_wdata(s_axil_wdata), .s_axil_wstrb(s_axil_wstrb), .s_axil_wvalid(s_axil_wvalid),
    .s_axil_wready(s_axil_wready), .s_axil_bresp(s_axil_bresp), .s_axil_bvalid(s_axil_bvalid),
    .s_axil_bready(s_axil_bready), .s_axil_araddr(s_axil_araddr), .s_axil_arvalid(s_axil_arvalid),
    .s_axil_arready(s_axil_arready), .s_axil_rdata(s_axil_rdata), .s_axil_rresp(s_axil_rresp),
    .s_axil_rvalid(s_axil_rvalid), .s_axil_rready(s_axil_rready),
    .s_io_awid(s_io_awid), .s_io_awaddr(s_io_awaddr), .s_io_awlen(s_io_awlen), .s_io_awvalid(s_io_awvalid),
    .s_io_awready(s_io_awready), .s_io_wdata(s_io_wdata), .s_io_wstrb(s_io_wstrb), .s_io_wlast(s_io_wlast),
    .s_io_wvalid(s_io_wvalid), .s_io_wready(s_io_wready), .s_io_bid(s_io_bid), .s_io_bresp(s_io_bresp),
    .s_io_bvalid(s_io_bvalid), .s_io_bready(s_io_bready), .s_io_arid(s_io_arid), .s_io_araddr(s_io_araddr),
    .s_io_arlen(s_io_arlen), .s_io_arvalid(s_io_arvalid), .s_io_arready(s_io_arready), .s_io_rid(s_io_rid),
    .s_io_rdata(s_io_rdata), .s_io_rresp(s_io_rresp), .s_io_rlast(s_io_rlast), .s_io_rvalid(s_io_rvalid),
    .s_io_rready(s_io_rready),
    .ui_clk0(ui_clk0), .ui_clk1(ui_clk1), .ui_clk2(ui_clk2), .ui_clk3(ui_clk3),
    .ui_rstn0(ui_rstn0), .ui_rstn1(ui_rstn1), .ui_rstn2(ui_rstn2), .ui_rstn3(ui_rstn3),
    .m_araddr(m_araddr), .m_arlen(m_arlen), .m_arsize(m_arsize), .m_arburst(m_arburst),
    .m_arvalid(m_arvalid), .m_arready(m_arready), .m_rdata(m_rdata), .m_rresp(m_rresp),
    .m_rlast(m_rlast), .m_rvalid(m_rvalid), .m_rready(m_rready));
endmodule
