// One residue's lane: registers the controller's request and pops on its own side of the SLR
// boundary, assembles BPW beats per word into a distributed-RAM FIFO, reports each word (av) and
// presents the popped word on op_wdata one cycle after the pop arrives.
module bsk_lane #(
  parameter int RW     = 2304,
  parameter int BPW    = 5,
  parameter int FD     = 16,
  parameter int ADDR_W = 34
) (
  input  logic              clk,
  input  logic              rst,
  input  logic              rq_c,
  input  logic [ADDR_W-1:0] base_c,
  input  logic              pop_c,
  output logic              av,
  output logic [RW-1:0]     op_wdata,
  output logic              rd_req,
  output logic [ADDR_W-1:0] rd_base,
  input  logic              rd_valid,
  output logic              rd_ready,
  input  logic [511:0]      rd_data
);
  localparam int FA = $clog2(FD);
  localparam int CW = $clog2(FD + 1);
  logic              rq_l, pop_l;
  logic [ADDR_W-1:0] base_l;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [BPW*512-1:0] sh;          // the oldest beat leaves through w
  /* verilator lint_on UNUSEDSIGNAL */
  logic [$clog2(BPW+1)-1:0] bc;
  (* ram_style = "distributed" *) logic [RW-1:0] fifo [FD];
  logic [FA-1:0]     wp, rp;
  logic [CW-1:0]     n;
  logic              wr;
  assign rd_ready = (n < CW'(FD - 1));
  assign wr = rd_valid && rd_ready && (bc == ($clog2(BPW+1))'(BPW - 1));

  always_ff @(posedge clk) begin
    rq_l    <= rq_c && !rst;
    base_l  <= base_c;
    pop_l   <= pop_c && !rst;
    rd_req  <= rq_l && !rst;
    if (rq_l) rd_base <= base_l;
    av      <= wr && !rst;
    if (rd_valid && rd_ready) sh <= {rd_data, sh[BPW*512-1:512]};
    /* verilator lint_off UNUSEDSIGNAL */
    if (wr) begin
      logic [BPW*512-1:0] w;
      w = {rd_data, sh[BPW*512-1:512]};
      fifo[wp] <= w[RW-1:0];
    end
    /* verilator lint_on UNUSEDSIGNAL */
    if (pop_l) op_wdata <= fifo[rp];
    if (rst) begin
      bc <= '0; wp <= '0; rp <= '0; n <= '0;
    end else begin
      if (rd_valid && rd_ready) bc <= wr ? '0 : bc + 1'b1;
      if (wr) wp <= wp + 1'b1;
      if (pop_l) rp <= rp + 1'b1;
      n <= n + CW'(wr) - CW'(pop_l);
    end
  end
endmodule
