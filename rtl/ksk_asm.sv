// KSK load from DDR4 (docs/ARCHITECTURE.md §5): on start, one read of ROWS rows x BPR beats
// (row = KSL x 32 bits of the ks32 layout, padded to BPR x 512) from the KSK channel, written
// into ksk_ram one row per BPR beats at consecutive addresses.
//
// SLR layout (build 006 failed routing on SLL demand): the row is assembled per KS lane group in
// that group's SLR (g_sl[g].u_s), so only the registered 512-bit beat crosses an SLR boundary, not
// the group's ~2000-bit slice of the row. Lane group g holds lanes [goff(g), goff(g) + glen(g)), as
// in ks32. Timing: beat accepted (c) -> bv1/bd1 (c+1) -> slice (c+2) -> ksk_wdata (c+3) ; ksk_we (c+3).
module ksk_asm #(
  parameter int KSL    = 184,
  parameter int NIN    = 2048,
  parameter int NOUT   = 918,
  parameter int ADDR_W = 34,
  parameter int G      = 3
) (
  input  logic                    clk,
  input  logic                    rst,
  input  logic                    start,
  input  logic [ADDR_W-1:0]       base,
  output logic                    busy,
  output logic                    ksk_we,
  output logic [$clog2(NIN*4*((NOUT+KSL)/KSL))-1:0] ksk_addr,
  output logic [KSL*32-1:0]       ksk_wdata,
  output logic                    rd_req,
  output logic [ADDR_W-1:0]       rd_base,
  output logic [31:0]             rd_beats,
  input  logic                    rd_valid,
  output logic                    rd_ready,
  input  logic [511:0]            rd_data
);
  localparam int ROWS = NIN * 4 * ((NOUT + KSL) / KSL);
  localparam int RB   = KSL * 32;
  localparam int BPR  = (RB + 511) / 512;
  localparam int AW   = $clog2(ROWS);
  localparam int BW   = $clog2(BPR + 1);

  logic [BW-1:0] bc, bc1;
  logic [AW:0]   rc;
  logic          bv1, we1, we2;
  logic [511:0]  bd1;
  logic [AW-1:0] ad1, ad2;
  assign rd_beats = 32'(ROWS * BPR);
  assign rd_ready = busy;

  always_ff @(posedge clk) begin
    rd_req <= 1'b0;
    we1    <= 1'b0;
    bv1    <= busy && rd_valid && !rst;
    bc1    <= bc;
    bd1    <= rd_data;
    we2    <= we1 && !rst;  ad2 <= ad1;
    ksk_we <= we2 && !rst;  ksk_addr <= ad2;
    if (rst) begin
      busy <= 1'b0;
    end else begin
      if (start && !busy) begin
        busy <= 1'b1; bc <= '0; rc <= '0; rd_base <= base; rd_req <= 1'b1;
      end
      if (busy && rd_valid) begin
        if (bc == BW'(BPR - 1)) begin
          bc <= '0;
          we1 <= 1'b1;
          ad1 <= rc[AW-1:0];
          rc <= rc + 1'b1;
          if (rc == (AW+1)'(ROWS - 1)) busy <= 1'b0;
        end else bc <= bc + 1'b1;
      end
    end
  end

  function automatic int glen(input int g);
    return KSL / G + ((g < KSL % G) ? 1 : 0);
  endfunction
  function automatic int goff(input int g);
    int o;
    o = 0;
    for (int h = 0; h < g; h++) o += glen(h);
    return o;
  endfunction
  for (genvar g = 0; g < G; g++) begin : g_sl
    localparam int OFF = goff(g);
    localparam int LG  = glen(g);
    (* keep_hierarchy = "yes" *)
    ksk_slice #(.BPR(BPR), .LO(OFF * 32), .W(LG * 32)) u_s (
      .clk(clk), .rst(rst), .bv(bv1), .bc(bc1), .bd(bd1), .wdata(ksk_wdata[OFF*32 +: LG*32]));
  end
endmodule

