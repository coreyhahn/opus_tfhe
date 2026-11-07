// Output ciphertext RAM (docs/ARCHITECTURE.md §5): 2 banks x 8 slots x 4096 u64 as 16384 x 256 bits
// in UltraRAM, written one u64 lane at a time by psi_unit, read 256 bits at a time by the io window.
// Read latency 2. Own kept hierarchy so the URAM is inferred before cross-boundary optimisation
// (the ksk_ram lesson).
(* keep_hierarchy = "yes" *)
module out_ram #(
  parameter int AW = 14
) (
  input  logic          clk,
  input  logic          we,
  input  logic [AW-1:0] wa,
  input  logic [1:0]    wl,          // u64 lane within the 256-bit word
  input  logic [63:0]   wd,
  input  logic [AW-1:0] ra,
  output logic [255:0]  q
);
  (* ram_style = "ultra" *) logic [255:0] mem [1 << AW];
  logic [255:0] r;
  always_ff @(posedge clk) begin
    for (int l = 0; l < 4; l++)
      if (we && wl == 2'(l)) mem[wa][l*64 +: 64] <= wd;
    r <= mem[ra];
    q <= r;
  end
endmodule
