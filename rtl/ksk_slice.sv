// One lane group's slice of a KSK row: registers the beat on its side of the SLR boundary, keeps
// only the beats that overlap bits [LO, LO + W) (synthesis drops the other slots), and presents
// the slice when the row's last beat arrives.
module ksk_slice #(
  parameter int BPR = 12,
  parameter int LO  = 0,
  parameter int W   = 1984
) (
  input  logic                     clk,
  input  logic                     rst,
  input  logic                     bv,
  input  logic [$clog2(BPR+1)-1:0] bc,
  input  logic [511:0]             bd,
  output logic [W-1:0]             wdata
);
  localparam int BW = $clog2(BPR + 1);
  logic          v_l;
  logic [BW-1:0] bc_l;
  logic [511:0]  bd_l;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [511:0]  slot [BPR - 1];
  logic [BPR*512-1:0] w;
  /* verilator lint_on UNUSEDSIGNAL */
  always_comb begin
    w[BPR*512-1 -: 512] = bd_l;
    for (int k = 0; k < BPR - 1; k++) w[k*512 +: 512] = slot[k];
  end
  always_ff @(posedge clk) begin
    v_l  <= bv && !rst;
    bc_l <= bc;
    bd_l <= bd;
    if (v_l) begin
      for (int k = 0; k < BPR - 1; k++) if (bc_l == BW'(k)) slot[k] <= bd_l;
      if (bc_l == BW'(BPR - 1)) wdata <= w[LO +: W];
    end
  end
endmodule
