// The io window (docs/ARCHITECTURE.md §5): an AXI4 slave (256-bit, INCR bursts) on the engine
// clock that the host DMAs batches through. Byte offsets inside the window:
//   0x000000  input  : ((bank*8 + slot)*4096 + i) * 8, u64 ciphertext words -> pbs_engine in_*
//                      (one u64 per cycle: WREADY drops while a beat is serialised)
//   0x100000  LUT    : ((res*64 + t) * 128), one engine LUT word (P*18 bits, LSB first) per
//                      128 bytes; lut_we fires on the beat at +64 (beats at +0, +32, +64 carry it)
//   0x200000  output : ((bank*8 + slot)*4096 + i) * 8, read only, from out_ram
// Writes to the output region and reads of the input/LUT regions are accepted and ignored / read 0.
// Every transaction completes; nothing here waits on the engine.
module io_win #(
  parameter int PLOG  = 5,
  parameter int BSLOG = 3,
  parameter int IDW   = 4,
  parameter int AW    = 22
) (
  input  logic                 clk,
  input  logic                 rst,
  // AXI4 slave
  input  logic [IDW-1:0]       s_awid,
  input  logic [AW-1:0]        s_awaddr,
  input  logic [7:0]           s_awlen,
  input  logic                 s_awvalid,
  output logic                 s_awready,
  input  logic [255:0]         s_wdata,
  input  logic [31:0]          s_wstrb,
  input  logic                 s_wlast,
  input  logic                 s_wvalid,
  output logic                 s_wready,
  output logic [IDW-1:0]       s_bid,
  output logic [1:0]           s_bresp,
  output logic                 s_bvalid,
  input  logic                 s_bready,
  input  logic [IDW-1:0]       s_arid,
  input  logic [AW-1:0]        s_araddr,
  input  logic [7:0]           s_arlen,
  input  logic                 s_arvalid,
  output logic                 s_arready,
  output logic [IDW-1:0]       s_rid,
  output logic [255:0]         s_rdata,
  output logic [1:0]           s_rresp,
  output logic                 s_rlast,
  output logic                 s_rvalid,
  input  logic                 s_rready,
  // to pbs_engine
  output logic                 in_we,
  output logic                 in_bank,
  output logic [BSLOG-1:0]     in_slot,
  output logic [11:0]          in_addr,
  output logic [63:0]          in_wdata,
  output logic                 lut_we,
  output logic [1:0]           lut_res,
  output logic [ntt_pkg::LOG_N-PLOG-1:0] lut_addr,
  output logic [(1<<PLOG)*18-1:0] lut_wdata,
  // from pbs_engine (psi outputs)
  input  logic                 o_valid,
  input  logic                 o_bank,
  input  logic [BSLOG-1:0]     o_slot,
  input  logic [11:0]          o_idx,
  input  logic [63:0]          o_data
);
  localparam int LW  = (1 << PLOG) * 18;
  localparam int FB  = ntt_pkg::LOG_N - PLOG;
  localparam int OAW = 1 + BSLOG + 10;               // out_ram words (4 u64 each)
  /* verilator lint_off UNUSEDSIGNAL */
  wire unused = ^{s_wstrb, s_wlast};
  /* verilator lint_on UNUSEDSIGNAL */

  // ---------------- write channel
  typedef enum logic [1:0] {W_ADDR, W_DATA, W_SER, W_RESP} wst_e;
  wst_e          ws;
  logic [AW-1:0] wa;                // byte address of the current beat
  logic [IDW-1:0] wid;
  logic [7:0]    wleft;
  logic [255:0]  wbuf;
  logic [1:0]    wk;                // u64 lane being serialised
  logic [511:0]  lstage;            // the first two beats of a LUT word
  assign s_awready = (ws == W_ADDR);
  assign s_wready  = (ws == W_DATA);
  assign s_bvalid  = (ws == W_RESP);
  assign s_bid     = wid;
  assign s_bresp   = 2'b00;
  wire [1:0] wreg = wa[21:20];
  wire [15:0] widx = wa[18:3];       // u64 index inside the input region

  always_ff @(posedge clk) begin
    in_we <= 1'b0;
    lut_we <= 1'b0;
    if (rst) begin
      ws <= W_ADDR;
    end else begin
      case (ws)
        W_ADDR: if (s_awvalid) begin wa <= s_awaddr; wid <= s_awid; wleft <= s_awlen; ws <= W_DATA; end
        W_DATA: if (s_wvalid) begin
          wbuf <= s_wdata;
          wk <= '0;
          if (wreg == 2'd0) ws <= W_SER;
          else begin
            if (wreg == 2'd1) begin
              // LUT word: beats at +0/+32/+64 of the 128-byte slot
              case (wa[6:5])
                2'd0: lstage[255:0] <= s_wdata;
                2'd1: lstage[511:256] <= s_wdata;
                2'd2: begin
                  lut_we <= 1'b1;
                  lut_res <= wa[14:13];
                  lut_addr <= wa[7 +: FB];
                  lut_wdata <= {s_wdata[LW-513:0], lstage[511:0]};
                end
                default: ;
              endcase
            end
            wa <= wa + AW'(32);
            if (wleft == 0) ws <= W_RESP; else wleft <= wleft - 1'b1;
          end
        end
        W_SER: begin
          // one u64 per cycle into the input bank
          in_we <= 1'b1;
          in_bank <= widx[15];
          in_slot <= widx[12 +: BSLOG];
          in_addr <= widx[11:0] + 12'(wk);
          in_wdata <= wbuf[wk*64 +: 64];
          wk <= wk + 1'b1;
          if (wk == 2'd3) begin
            wa <= wa + AW'(32);
            if (wleft == 0) ws <= W_RESP; else begin wleft <= wleft - 1'b1; ws <= W_DATA; end
          end
        end
        W_RESP: if (s_bready) ws <= W_ADDR;
        default: ws <= W_ADDR;
      endcase
    end
  end

  // ---------------- output RAM: psi writes, the read channel reads
  logic [OAW-1:0] ra;
  logic [255:0]   rq;
  logic [AW-1:0]  rda;
  out_ram #(.AW(OAW)) u_out (
    .clk(clk), .we(o_valid), .wa({o_bank, o_slot, o_idx[11:2]}), .wl(o_idx[1:0]), .wd(o_data),
    .ra(ra), .q(rq));

  // ---------------- read channel: one beat per 4 cycles (2 RAM cycles, capture, present)
  typedef enum logic [2:0] {R_ADDR, R_RD0, R_RD1, R_RD2, R_DATA} rst_e;
  rst_e          rs;
  logic [7:0]    rleft;
  assign ra = rda[5 +: OAW];
  assign s_arready = (rs == R_ADDR);
  assign s_rvalid  = (rs == R_DATA);
  assign s_rresp   = 2'b00;
  assign s_rlast   = (rleft == 0);
  always_ff @(posedge clk) begin
    if (rst) begin
      rs <= R_ADDR;
    end else begin
      case (rs)
        R_ADDR: if (s_arvalid) begin rda <= s_araddr; s_rid <= s_arid; rleft <= s_arlen; rs <= R_RD0; end
        R_RD0: rs <= R_RD1;
        R_RD1: rs <= R_RD2;
        R_RD2: begin s_rdata <= (rda[21:20] == 2'd2) ? rq : '0; rs <= R_DATA; end
        R_DATA: if (s_rready) begin
          rda <= rda + AW'(32);
          if (rleft == 0) rs <= R_ADDR; else begin rleft <= rleft - 1'b1; rs <= R_RD0; end
        end
        default: rs <= R_ADDR;
      endcase
    end
  end
endmodule
