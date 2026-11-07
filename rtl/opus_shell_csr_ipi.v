// opus_shell_csr_ipi: plain-Verilog IPI wrapper that puts rtl/opus_csr.sv on the XDMA AXI-Lite BAR
// of the SHELL-ONLY bitstream (Stage 3 step 2, docs/ARCHITECTURE.md §5 "Verification order" 2).
//
// PROVENANCE: the port list and X_INTERFACE attributes are adapted from fable5_llm (the user's own
// project), commit 35d95a5, rtl/csr_block_ipi.v. Changed: wraps opus_csr instead of csr_block, and
// ties off opus_csr's engine ports because no engine is present in this bitstream.
//
// Why a .v wrapper: Vivado IPI module references do not accept a SystemVerilog top file
// (filemgmt 56-195). The instance is named u_csr so synth/constraints/fable5_cdc.xdc
// (false path to */u_csr/calib_meta_reg[*]/D) applies unchanged.
//
// Engine tie-offs (what the host sees in the shell): STATUS (0x44) reads bank_free = 2'b11, busy = 0,
// ksk_busy = 0, rd_err = 0; DONE_CNT/BATCH_CYC/BUSY_CYC/BSK_WAIT stay 0. CTRL writes produce
// eng_start/ksk_load/soft_rst pulses that go nowhere. BSK_BASE*/KSK_BASE read back what was written.


module opus_shell_csr_ipi #(
    parameter [31:0] VERSION = 32'h0
) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axil, ASSOCIATED_RESET aresetn" *)
    input  wire        aclk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire        aresetn,

    input  wire [3:0]  calib_in,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axil AWADDR" *)
    (* X_INTERFACE_PARAMETER = "PROTOCOL AXI4LITE, DATA_WIDTH 32, ADDR_WIDTH 12" *)
    input  wire [11:0] s_axil_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axil AWVALID" *)
    input  wire        s_axil_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axil AWREADY" *)
    output wire        s_axil_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axil WDATA" *)
    input  wire [31:0] s_axil_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axil WSTRB" *)
    input  wire [3:0]  s_axil_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axil WVALID" *)
    input  wire        s_axil_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axil WREADY" *)
    output wire        s_axil_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axil BRESP" *)
    output wire [1:0]  s_axil_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axil BVALID" *)
    output wire        s_axil_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axil BREADY" *)
    input  wire        s_axil_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axil ARADDR" *)
    input  wire [11:0] s_axil_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axil ARVALID" *)
    input  wire        s_axil_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axil ARREADY" *)
    output wire        s_axil_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axil RDATA" *)
    output wire [31:0] s_axil_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axil RRESP" *)
    output wire [1:0]  s_axil_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axil RVALID" *)
    output wire        s_axil_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axil RREADY" *)
    input  wire        s_axil_rready
);

    /* verilator lint_off PINCONNECTEMPTY */
    opus_csr #(.VERSION(VERSION)) u_csr (
        .aclk(aclk), .aresetn(aresetn), .calib_in(calib_in),
        .s_axil_awaddr(s_axil_awaddr), .s_axil_awvalid(s_axil_awvalid), .s_axil_awready(s_axil_awready),
        .s_axil_wdata(s_axil_wdata), .s_axil_wstrb(s_axil_wstrb), .s_axil_wvalid(s_axil_wvalid),
        .s_axil_wready(s_axil_wready), .s_axil_bresp(s_axil_bresp), .s_axil_bvalid(s_axil_bvalid),
        .s_axil_bready(s_axil_bready), .s_axil_araddr(s_axil_araddr), .s_axil_arvalid(s_axil_arvalid),
        .s_axil_arready(s_axil_arready), .s_axil_rdata(s_axil_rdata), .s_axil_rresp(s_axil_rresp),
        .s_axil_rvalid(s_axil_rvalid), .s_axil_rready(s_axil_rready),
        // engine control: no engine in the shell-only bitstream
        .eng_start(), .eng_start_bank(), .ksk_load(), .soft_rst(), .bsk_base(), .ksk_base(),
        // engine status: idle, both banks free, no read errors
        .bank_free(2'b11), .busy(1'b0), .ksk_busy(1'b0), .done(1'b0), .done_bank(1'b0),
        .bsk_busy(1'b0), .rd_err(4'b0000)
    );
    /* verilator lint_on PINCONNECTEMPTY */

endmodule
