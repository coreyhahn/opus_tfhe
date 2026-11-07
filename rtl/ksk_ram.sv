// KSK memory for ks32: UltraRAM with an RL-register read (read latency RL >= 2; registers past the
// first two let Vivado pipeline the URAM cascade, which is ~10 deep per lane group).
// Kept as its own hierarchy so synthesis infers the URAM before any cross-boundary
// optimisation: inside ks32 the MAC's DSP48E2s absorbed the read registers as their
// input registers, the read became asynchronous and Vivado fell back to LUTRAM
// (Synth 8-6849), even with a second register in between (synth/probe/uram_probe4/5).
(* keep_hierarchy = "yes" *)
module ksk_ram #(
  parameter int DW    = 32,
  parameter int DEPTH = 1024,
  parameter int RL    = 2
) (
  input  logic                     clk,
  input  logic                     we,
  input  logic [$clog2(DEPTH)-1:0] wa,
  input  logic [DW-1:0]            wd,
  input  logic [$clog2(DEPTH)-1:0] ra,
  output logic [DW-1:0]            q
);
  (* ram_style = "ultra" *) logic [DW-1:0] mem [DEPTH];
  logic [DW-1:0] r [RL - 1];
  always_ff @(posedge clk) begin
    if (we) mem[wa] <= wd;
    r[0] <= mem[ra];
    for (int k = 1; k < RL - 1; k++) r[k] <= r[k-1];
    q <= r[RL-2];
  end
endmodule
