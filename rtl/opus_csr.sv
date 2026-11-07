// PROVENANCE: the AXI4-Lite slave, MAGIC/VERSION/SCRATCH/CALIB/UPTIME registers and the CALIB
// synchroniser are adapted from fable5_llm/rtl/csr_block.sv (the user's own project, commit
// ca9e0e2). Changed: MAGIC value, SV port style, and the engine registers from 0x40.
//
// opus_csr: AXI4-Lite status/control register file (docs/ARCHITECTURE.md §5).
// Safety property kept from csr_block: every transaction completes in bounded time with no
// dependency on anything outside this module, so a host MMIO read can never stall a PCIe completion.
//   0x00 MAGIC RO 0x0F7FE001   0x04 VERSION RO   0x08 SCRATCH RW   0x0C CALIB RO (2FF sync)
//   0x10/0x14 UPTIME RO
//   0x40 CTRL      W1P  b0 start, b1 start_bank, b4 ksk_load, b8 engine soft reset
//   0x44 STATUS    RO   b1:0 bank_free, b2 busy, b3 ksk_busy, b4 last done_bank, b11:8 rresp err
//   0x48 DONE_CNT  RO   batches completed
//   0x50/54/58 BSK_BASE0..2 RW (byte address in that residue's channel)   0x5C KSK_BASE RW
//   0x60/64 BATCH_CYC RO  start -> done of the last completed batch (its own bank's start)
//   0x68/6C BUSY_CYC  RO  cycles with the engine busy
//   0x70/74 BSK_WAIT  RO  cycles with a BSK request outstanding
//   others RO 0xDEADC0DE
// start is dropped unless the bank is free and all four CALIB bits are set.
module opus_csr #(
  parameter logic [31:0] VERSION = 32'h0
) (
  input  logic        aclk,
  input  logic        aresetn,
  input  logic [3:0]  calib_in,         // async, one per DDR4 channel
  // AXI4-Lite slave
  input  logic [11:0] s_axil_awaddr,
  input  logic        s_axil_awvalid,
  output logic        s_axil_awready,
  input  logic [31:0] s_axil_wdata,
  input  logic [3:0]  s_axil_wstrb,
  input  logic        s_axil_wvalid,
  output logic        s_axil_wready,
  output logic [1:0]  s_axil_bresp,
  output logic        s_axil_bvalid,
  input  logic        s_axil_bready,
  input  logic [11:0] s_axil_araddr,
  input  logic        s_axil_arvalid,
  output logic        s_axil_arready,
  output logic [31:0] s_axil_rdata,
  output logic [1:0]  s_axil_rresp,
  output logic        s_axil_rvalid,
  input  logic        s_axil_rready,
  // engine control
  output logic        eng_start,
  output logic        eng_start_bank,
  output logic        ksk_load,
  output logic        soft_rst,
  output logic [31:0] bsk_base [3],
  output logic [31:0] ksk_base,
  // engine status
  input  logic [1:0]  bank_free,
  input  logic        busy,
  input  logic        ksk_busy,
  input  logic        done,
  input  logic        done_bank,
  input  logic        bsk_busy,
  input  logic [3:0]  rd_err
);
  localparam logic [31:0] MAGIC   = 32'h0F7F_E001;
  localparam logic [31:0] BADADDR = 32'hDEAD_C0DE;

  (* ASYNC_REG = "TRUE" *) logic [3:0] calib_meta, calib_sync;
  always_ff @(posedge aclk) begin
    calib_meta <= calib_in;
    calib_sync <= calib_meta;
  end

  logic [63:0] uptime, busy_cyc, wait_cyc, batch_cyc;
  logic [63:0] t_start [2];
  logic [31:0] scratch, done_cnt;
  logic        last_bank;

  // ---- write channel: latch AW and W independently, respond when both seen
  logic        aw_got, w_got;
  logic [9:0]  awaddr_q;
  logic [31:0] wdata_q;
  logic [3:0]  wstrb_q;
  /* verilator lint_off UNUSEDSIGNAL */
  wire [1:0] unused_addr_lsbs = s_axil_awaddr[1:0] | s_axil_araddr[1:0];
  /* verilator lint_on UNUSEDSIGNAL */
  assign s_axil_awready = !aw_got && !s_axil_bvalid;
  assign s_axil_wready  = !w_got  && !s_axil_bvalid;

  always_ff @(posedge aclk) begin
    eng_start <= 1'b0;
    ksk_load  <= 1'b0;
    soft_rst  <= 1'b0;
    if (!aresetn) begin
      aw_got <= 1'b0; w_got <= 1'b0; s_axil_bvalid <= 1'b0; s_axil_bresp <= 2'b00;
      scratch <= '0; uptime <= '0; busy_cyc <= '0; wait_cyc <= '0; batch_cyc <= '0;
      done_cnt <= '0; last_bank <= 1'b0; eng_start_bank <= 1'b0;
      bsk_base[0] <= '0; bsk_base[1] <= '0; bsk_base[2] <= '0; ksk_base <= '0;
    end else begin
      uptime <= uptime + 64'd1;
      if (busy) busy_cyc <= busy_cyc + 64'd1;
      if (bsk_busy) wait_cyc <= wait_cyc + 64'd1;
      if (done) begin
        done_cnt <= done_cnt + 1'b1;
        last_bank <= done_bank;
        batch_cyc <= uptime - t_start[done_bank];
      end

      if (s_axil_awvalid && s_axil_awready) begin aw_got <= 1'b1; awaddr_q <= s_axil_awaddr[11:2]; end
      if (s_axil_wvalid && s_axil_wready) begin w_got <= 1'b1; wdata_q <= s_axil_wdata; wstrb_q <= s_axil_wstrb; end

      if (aw_got && w_got && !s_axil_bvalid) begin
        case (awaddr_q)
          10'h002: for (int b = 0; b < 4; b++) if (wstrb_q[b]) scratch[b*8 +: 8] <= wdata_q[b*8 +: 8];
          10'h010: begin                                       // 0x40 CTRL
            if (wdata_q[0] && bank_free[wdata_q[1]] && calib_sync == 4'hF) begin
              eng_start <= 1'b1;
              eng_start_bank <= wdata_q[1];
              t_start[wdata_q[1]] <= uptime;
            end
            if (wdata_q[4] && calib_sync == 4'hF) ksk_load <= 1'b1;
            if (wdata_q[8]) soft_rst <= 1'b1;
          end
          10'h014: bsk_base[0] <= wdata_q;                      // 0x50
          10'h015: bsk_base[1] <= wdata_q;                      // 0x54
          10'h016: bsk_base[2] <= wdata_q;                      // 0x58
          10'h017: ksk_base    <= wdata_q;                      // 0x5C
          default: ;
        endcase
        s_axil_bvalid <= 1'b1;
        s_axil_bresp  <= 2'b00;          // OKAY even for RO addresses (writes ignored)
        aw_got <= 1'b0;
        w_got  <= 1'b0;
      end
      if (s_axil_bvalid && s_axil_bready) s_axil_bvalid <= 1'b0;
    end
  end

  // ---- read channel: single outstanding, data the cycle after AR accept
  assign s_axil_arready = !s_axil_rvalid;
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      s_axil_rvalid <= 1'b0; s_axil_rresp <= 2'b00; s_axil_rdata <= '0;
    end else begin
      if (s_axil_arvalid && s_axil_arready) begin
        s_axil_rvalid <= 1'b1;
        s_axil_rresp  <= 2'b00;
        case (s_axil_araddr[11:2])
          10'h000: s_axil_rdata <= MAGIC;
          10'h001: s_axil_rdata <= VERSION;
          10'h002: s_axil_rdata <= scratch;
          10'h003: s_axil_rdata <= {28'd0, calib_sync};
          10'h004: s_axil_rdata <= uptime[31:0];
          10'h005: s_axil_rdata <= uptime[63:32];
          10'h011: s_axil_rdata <= {20'd0, rd_err, 3'd0, last_bank, ksk_busy, busy, bank_free};
          10'h012: s_axil_rdata <= done_cnt;
          10'h014: s_axil_rdata <= bsk_base[0];
          10'h015: s_axil_rdata <= bsk_base[1];
          10'h016: s_axil_rdata <= bsk_base[2];
          10'h017: s_axil_rdata <= ksk_base;
          10'h018: s_axil_rdata <= batch_cyc[31:0];
          10'h019: s_axil_rdata <= batch_cyc[63:32];
          10'h01A: s_axil_rdata <= busy_cyc[31:0];
          10'h01B: s_axil_rdata <= busy_cyc[63:32];
          10'h01C: s_axil_rdata <= wait_cyc[31:0];
          10'h01D: s_axil_rdata <= wait_cyc[63:32];
          default: s_axil_rdata <= BADADDR;
        endcase
      end else if (s_axil_rvalid && s_axil_rready) begin
        s_axil_rvalid <= 1'b0;
      end
    end
  end
endmodule
