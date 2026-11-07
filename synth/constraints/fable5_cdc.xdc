# PROVENANCE: copied from fable5_llm (the user's own project), commit 35d95a5,
#   path synth/constraints/fable5_cdc.xdc (the build_007 pure-shell constraint set). Content unchanged
#   below this header. See synth/constraints/PROVENANCE.md.
# CDC declarations for csr_block.
# calib_in[3:0] are quasi-static DDR4 init_calib_complete bits crossing from
# the four MIG ui_clk domains (300 MHz) into xdma_0_axi_aclk (250 MHz)
# through a 2FF synchronizer (ASYNC_REG=TRUE in rtl/csr_block.sv).
# Declare the crossing so the router does not try to time 4 unrelated
# clock pairs (and does not tear csr placement across SLRs doing so).
set_false_path -to [get_pins -hierarchical -filter {NAME =~ */u_csr/calib_meta_reg[*]/D}]
