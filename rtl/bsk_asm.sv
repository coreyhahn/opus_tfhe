// BSK streaming for br_core (docs/ARCHITECTURE.md §5): on bsk_req (idx, buf) post one read of
// FR words x 5 beats to each residue's DDR4 channel (residue i word = 4*P*18 bits padded to
// 5 x 512), write one op word (all three residues) per issue, and pulse bsk_done after the FR-th.
// busy is high while a request is outstanding.
//
// SLR layout (build 006 failed routing on SLL demand): residue i's lane (g_ln[i].u_ln) sits in
// residue i's SLR beside its channel reader and the engine's residue-i operand RAM, so the 2304-bit
// words never cross an SLR. Each lane pops its own channel into a word FIFO; this controller (SLR1)
// counts the words each lane reports (credit) and issues a pop to all three lanes at once when every
// lane holds a word. Only registered single-bit pulses and the request cross SLRs:
//   issue (c) -> pop_c (c+1) -> lane pop_l (c+2) -> lane op_wdata (c+3) ; op_we/op_addr/op_buf (c+3)
module bsk_asm #(
  parameter int PLOG   = 5,
  parameter int ADDR_W = 34
) (
  input  logic                         clk,
  input  logic                         rst,
  input  logic [ADDR_W-1:0]            base [3],     // per-residue BSK image base, 4 KiB-aligned (bursts are never realigned)
  input  logic                         bsk_req,
  input  logic [10:0]                  bsk_req_idx,
  input  logic                         bsk_req_buf,
  output logic                         op_we,
  output logic                         op_buf,
  output logic [ntt_pkg::LOG_N-PLOG-1:0] op_addr,
  output logic [3*4*(1<<PLOG)*18-1:0]  op_wdata,
  output logic                         bsk_done,
  // to the three channel readers (lane i drives reader i)
  output logic                         rd_req [3],
  output logic [ADDR_W-1:0]            rd_base [3],
  output logic [31:0]                  rd_beats,
  input  logic [2:0]                   rd_valid,
  output logic [2:0]                   rd_ready,
  input  logic [511:0]                 rd_data [3],
  output logic                         busy
);
  localparam int FR   = 1 << (ntt_pkg::LOG_N - PLOG);
  localparam int RW   = 4 * (1 << PLOG) * 18;          // bits per residue word
  localparam int BPW  = (RW + 511) / 512;              // beats per residue word
  localparam int STR  = FR * BPW * 64;                 // bytes per CMux index per channel
  localparam int FB   = ntt_pkg::LOG_N - PLOG;
  localparam int FD   = 16;                            // lane word FIFO depth
  localparam int CW   = $clog2(FD + 1);

  assign rd_beats = 32'(FR * BPW);

  logic              rq_c, pop_c;
  logic [ADDR_W-1:0] base_c [3];
  logic [2:0]        av, av_c;
  logic [CW-1:0]     cnt [3];
  logic [FB:0]       ic;
  logic              ib;
  logic              we1, we2, bf1, bf2;
  logic [FB-1:0]     ad1, ad2;
  wire issue = busy && (cnt[0] != '0) && (cnt[1] != '0) && (cnt[2] != '0);

  always_ff @(posedge clk) begin
    rq_c     <= 1'b0;
    pop_c    <= issue && !rst;
    av_c     <= rst ? '0 : av;
    we1      <= issue && !rst;  ad1 <= ic[FB-1:0]; bf1 <= ib;
    we2      <= we1 && !rst;    ad2 <= ad1;        bf2 <= bf1;
    op_we    <= we2 && !rst;    op_addr <= ad2;    op_buf <= bf2;
    bsk_done <= op_we && op_addr == FB'(FR - 1) && !rst;
    if (rst) begin
      busy <= 1'b0;
      for (int i = 0; i < 3; i++) cnt[i] <= '0;
    end else begin
      if (bsk_req) begin
        busy <= 1'b1; ic <= '0; ib <= bsk_req_buf; rq_c <= 1'b1;
        for (int i = 0; i < 3; i++) base_c[i] <= base[i] + ADDR_W'(bsk_req_idx) * ADDR_W'(STR);
      end
      for (int i = 0; i < 3; i++) cnt[i] <= cnt[i] + CW'(av_c[i]) - CW'(issue);
      if (issue) begin
        ic <= ic + 1'b1;
        if (ic == (FB+1)'(FR - 1)) busy <= 1'b0;
      end
    end
  end

  for (genvar i = 0; i < 3; i++) begin : g_ln
    (* keep_hierarchy = "yes" *)
    bsk_lane #(.RW(RW), .BPW(BPW), .FD(FD), .ADDR_W(ADDR_W)) u_ln (
      .clk(clk), .rst(rst), .rq_c(rq_c), .base_c(base_c[i]), .pop_c(pop_c), .av(av[i]),
      .op_wdata(op_wdata[i*RW +: RW]), .rd_req(rd_req[i]), .rd_base(rd_base[i]),
      .rd_valid(rd_valid[i]), .rd_ready(rd_ready[i]), .rd_data(rd_data[i]));
  end
endmodule

