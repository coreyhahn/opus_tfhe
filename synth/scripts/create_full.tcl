# create_full.tcl — opus_tfhe Stage 3 FULL-DESIGN project + block design (docs/ARCHITECTURE.md §5):
#   synth/scripts/create_shell.tcl (the shell that built a bitstream) + the engine (rtl/opus_top.sv).
#
# PROVENANCE: copied from synth/scripts/create_shell.tcl (itself adapted from fable5_llm commit 35d95a5,
#   synth/scripts/create_project.tcl, the build_007 pure-shell BD). Changes vs create_shell.tcl, and
#   nothing else (the XDMA / DDR4 / reset / refclk / port-naming section is untouched):
#   - project name opus_full (was opus_shell)
#   - csr_0 (opus_shell_csr_ipi, engine tied off) replaced by the module-reference cell opus_0 of
#     rtl/opus_top_ipi.v (opus_top_flat -> opus_top: CSR + io window + DDR readers + pbs_engine) on
#     xdma_0/axi_aclk (250 MHz, docs/ARCHITECTURE.md); CONFIG.VERSION set and asserted as for csr_0
#   - adds the engine RTL (tb/Makefile TOP_RTL + the files synth/scripts/ooc.tcl reads)
#   - axi_smc NUM_MI 5: M04_AXI -> opus_0/s_io (io window) at 0x10_0000_0000, 4 MiB
#   - per DDR4 channel i a SmartConnect ddr_smc_i (2 SI, 1 MI, one clock = ddr4_i ui_clk):
#     S00 <- axi_smc/M0i_AXI (host DMA), S01 <- opus_0/m<i> (engine reader), M00 -> ddr4_i S_AXI
#   - opus_0 ui_clk<i>/ui_rstn<i> from ddr4_i c0_ddr4_ui_clk / ddr4_c<i>_reset peripheral_aresetn
#   - engine floorplan synth/constraints/engine_slr_full.xdc, IMPLEMENTATION-ONLY
#   - synthesis options for the engine: -keep_equivalent_registers -resource_sharing off on synth_1
#     AND on the module reference's own out-of-context run bd_opus_0_0_synth_1 (the BD is synthesised
#     out-of-context per IP, as in the shell build: build_001 has a bd_csr_0_0_synth_1 run for the
#     shell's module reference, so opus_0 is synthesised in its OWN OOC run, not in synth_1). Without
#     -keep_equivalent_registers synth_design never left Cross Boundary Optimization (CLAUDE.md).
#
# Usage: vivado -mode batch -source create_full.tcl -tclargs <out_dir> <version_hex8>
#
# Address map (CLAUDE.md "Address map (Stage 3)"):
#   XDMA M_AXI (DMA): ddr4_0 0x0_0000_0000, ddr4_1 0x1_0000_0000, ddr4_2 0x2_0000_0000,
#                     ddr4_3 0x3_0000_0000, 4 GiB each
#   XDMA M_AXI (DMA): opus_0 io window 0x10_0000_0000, 4 MiB (input +0, LUT +1M, output +2M)
#   XDMA M_AXI_LITE BAR (/dev/xdma0_user): opus_0 CSR at 0x0 (+4K)
#     0x00 MAGIC 0x0F7FE001, 0x04 VERSION, 0x08 SCRATCH, 0x0C CALIB[3:0], 0x10/0x14 UPTIME,
#     0x40.. engine registers (docs/ARCHITECTURE.md §5)
#   opus_0/m<i> (engine reader i): ddr4_i at 0x0, 4 GiB (one channel per master)

if {[llength $argv] < 2} { puts "FATAL: need <out_dir> <version_hex8>"; exit 1 }
set OutDir   [lindex $argv 0]
set BuildVer [lindex $argv 1]
if {![regexp {^[0-9a-f]{8}$} $BuildVer]} { puts "FATAL: version '$BuildVer' is not 8 hex digits"; exit 1 }

set ScriptDir [file dirname [file normalize [info script]]]
set RepoRoot  [file normalize "$ScriptDir/../.."]
set ConstrDir "$RepoRoot/synth/constraints"
set RtlDir    "$RepoRoot/rtl"

if {[string compare [version -short] "2024.2"] != 0} {
    puts "FATAL: this script expects Vivado 2024.2, got [version -short]"; exit 1
}

proc must {script} {
    if {[catch {uplevel 1 $script} err]} {
        puts "FATAL: $err"
        exit 1
    }
}

set_param general.maxThreads 8

must {create_project opus_full $OutDir/proj -part xcvu9p-fsgd2104-2L-e}

# Sources: custom DDR4 part CSV, board XDCs, CSR RTL
must {import_files -norecurse $ConstrDir/BLS4G4D240FSB.csv}
foreach x {BCU1525_DIMM0.xdc BCU1525_DIMM1.xdc BCU1525_DIMM2.xdc BCU1525_DIMM3.xdc fable5_pcie_clk.xdc fable5_cdc.xdc} {
    must {import_files -fileset constrs_1 -norecurse $ConstrDir/$x}
}
# implementation-only: XDMA reset-synchroniser exception (fable5 85d05d6)
must {import_files -fileset constrs_1 -norecurse $ConstrDir/fable5_xdma_rst_exception.xdc}
must {set_property USED_IN_SYNTHESIS false [get_files fable5_xdma_rst_exception.xdc]}
must {set_property USED_IN_IMPLEMENTATION true [get_files fable5_xdma_rst_exception.xdc]}

# implementation-only: engine floorplan (pblocks on engine cells only)
must {import_files -fileset constrs_1 -norecurse $ConstrDir/engine_slr_full.xdc}
must {set_property USED_IN_SYNTHESIS false [get_files engine_slr_full.xdc]}
must {set_property USED_IN_IMPLEMENTATION true [get_files engine_slr_full.xdc]}

# Engine RTL: tb/Makefile TOP_RTL (opus_top and everything it instantiates) plus the rest of what
# synth/scripts/ooc.tcl reads (the rejected iterative core: sfifo, ntt_cg, extprod1/3; unused here).
set EngSv {ntt_pkg.sv modmul.sv bfly.sv sfifo.sv ntt_cg.sv ntt_pipe_stage.sv ntt_pipe.sv extprod1.sv
           extprod3.sv xpipe1.sv xpipe3.sv digit_unit.sv acc_slice.sv br_core.sv psi_unit.sv ksk_ram.sv
           ks_lanes.sv ks32.sv pbs_engine.sv ddr_rd_streamer.sv ddr_chan_rd.sv bsk_lane.sv bsk_asm.sv ksk_slice.sv ksk_asm.sv
           out_ram.sv io_win.sv opus_csr.sv opus_top.sv opus_top_flat.sv}
foreach f $EngSv {
    must {add_files -norecurse $RtlDir/$f}
    must {set_property file_type SystemVerilog [get_files $RtlDir/$f]}
}
must {add_files -norecurse $RtlDir/opus_top_ipi.v}
# twiddle ROM dirs read by $readmemh at synthesis (opus_top_ipi defaults; git-ignored, regenerable)
foreach d {P5_mont P5_table} {
    if {[llength [glob -nocomplain $RepoRoot/synth/roms/$d/*.hex]] == 0} {
        puts "FATAL: no ROM files in $RepoRoot/synth/roms/$d"; exit 1
    }
}
must {update_compile_order -fileset sources_1}

# synth_1 options (engine rule, CLAUDE.md "Vivado discipline"); bd_opus_0_0_synth_1 gets the same below
must {set_property STEPS.SYNTH_DESIGN.ARGS.KEEP_EQUIVALENT_REGISTERS true [get_runs synth_1]}
must {set_property STEPS.SYNTH_DESIGN.ARGS.RESOURCE_SHARING off [get_runs synth_1]}

must {create_bd_design "bd"}

# ---------------- PCIe refclk buffer + XDMA ----------------
must {create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf:2.2 refclk_buf}
must {set_property -dict [list CONFIG.C_BUF_TYPE {IBUFDSGTE}] [get_bd_cells refclk_buf]}
must {make_bd_intf_pins_external [get_bd_intf_pins refclk_buf/CLK_IN_D]}
must {set_property name pcie_refclk [get_bd_intf_ports CLK_IN_D_0]}
must {set_property CONFIG.FREQ_HZ 100000000 [get_bd_intf_ports /pcie_refclk]}

must {create_bd_cell -type ip -vlnv xilinx.com:ip:xdma:4.1 xdma_0}
# NB: set_property on BD cells only WARNS for unknown CONFIG params, so every
# config below is re-read and asserted afterwards.
must {set_property -dict [list CONFIG.mode_selection {Advanced}] [get_bd_cells xdma_0]}
must {set_property -dict [list \
    CONFIG.pl_link_cap_max_link_width {X8} \
    CONFIG.pl_link_cap_max_link_speed {8.0_GT/s} \
] [get_bd_cells xdma_0]}
must {set_property -dict [list \
    CONFIG.axi_data_width {256_bit} \
    CONFIG.axisten_freq {250} \
    CONFIG.en_gt_selection {true} \
    CONFIG.select_quad {GTY_Quad_227} \
    CONFIG.axilite_master_en {true} \
    CONFIG.xdma_pcie_64bit_en {true} \
] [get_bd_cells xdma_0]}
foreach {param want} {
    CONFIG.mode_selection Advanced
    CONFIG.pl_link_cap_max_link_width X8
    CONFIG.pl_link_cap_max_link_speed 8.0_GT/s
    CONFIG.axi_data_width 256_bit
    CONFIG.axisten_freq 250
    CONFIG.en_gt_selection true
    CONFIG.select_quad GTY_Quad_227
    CONFIG.axilite_master_en true
} {
    set got [get_property $param [get_bd_cells xdma_0]]
    if {[string compare $got $want] != 0} {
        puts "FATAL: xdma $param = '$got', wanted '$want'"; exit 1
    }
}
if {[llength [get_bd_intf_pins -quiet xdma_0/M_AXI_LITE]] != 1} {
    puts "FATAL: xdma_0/M_AXI_LITE pin missing"; exit 1
}

must {make_bd_intf_pins_external [get_bd_intf_pins xdma_0/pcie_mgt]}
must {set_property name pcie_mgt [get_bd_intf_ports pcie_mgt_0]}
must {make_bd_pins_external [get_bd_pins xdma_0/sys_rst_n]}
must {set_property name pcie_perstn [get_bd_ports sys_rst_n_0]}

must {connect_bd_net [get_bd_pins refclk_buf/IBUF_DS_ODIV2] [get_bd_pins xdma_0/sys_clk]}
must {connect_bd_net [get_bd_pins refclk_buf/IBUF_OUT] [get_bd_pins xdma_0/sys_clk_gt]}

# ---------------- 4x DDR4 ----------------
# PERST# (active low) inverted to drive DDR4 sys_rst (active high)
must {create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic:2.0 perst_inv}
must {set_property -dict [list CONFIG.C_SIZE {1} CONFIG.C_OPERATION {not}] [get_bd_cells perst_inv]}
must {connect_bd_net [get_bd_ports pcie_perstn] [get_bd_pins perst_inv/Op1]}

set csv_file [lindex [get_files */BLS4G4D240FSB.csv] 0]
for {set i 0} {$i < 4} {incr i} {
    must {create_bd_cell -type ip -vlnv xilinx.com:ip:ddr4:2.2 ddr4_$i}
    must {set_property -dict [list \
        CONFIG.C0.DDR4_TimePeriod {833} \
        CONFIG.C0.DDR4_InputClockPeriod {3332} \
        CONFIG.C0.DDR4_CLKOUT0_DIVIDE {5} \
        CONFIG.C0.DDR4_CustomParts $csv_file \
        CONFIG.C0.DDR4_isCustom {true} \
        CONFIG.C0.DDR4_MemoryType {UDIMMs} \
        CONFIG.C0.DDR4_MemoryPart {BLS4G4D240FSB-2400} \
        CONFIG.C0.DDR4_DataWidth {64} \
        CONFIG.C0.DDR4_AxiSelection {true} \
    ] [get_bd_cells ddr4_$i]}

    must {make_bd_intf_pins_external [get_bd_intf_pins ddr4_$i/C0_DDR4]}
    must {make_bd_intf_pins_external [get_bd_intf_pins ddr4_$i/C0_SYS_CLK]}
    must {connect_bd_net [get_bd_pins perst_inv/Res] [get_bd_pins ddr4_$i/sys_rst]}

    # per-channel UI-clock reset
    must {create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 ddr4_c${i}_reset}
    must {set_property -dict [list CONFIG.C_AUX_RESET_HIGH {0}] [get_bd_cells ddr4_c${i}_reset]}
    must {connect_bd_net [get_bd_pins ddr4_$i/c0_ddr4_ui_clk] [get_bd_pins ddr4_c${i}_reset/slowest_sync_clk]}
    must {connect_bd_net [get_bd_pins ddr4_$i/c0_ddr4_ui_clk_sync_rst] [get_bd_pins ddr4_c${i}_reset/ext_reset_in]}
    must {connect_bd_net [get_bd_pins ddr4_c${i}_reset/peripheral_aresetn] [get_bd_pins ddr4_$i/c0_ddr4_aresetn]}
}

# external port names expected by the XDCs.
# NB: renaming a BD port to its CURRENT name is NOT a no-op — Vivado
# uniquifies against the existing name and silently renames it (e.g.
# C0_DDR4_0 -> C0_DDR4_4), which orphans every XDC constraint. Only rename
# when the name actually changes (C0_DDR4_0 already has the right name).
must {set_property name C1_DDR4_0 [get_bd_intf_ports C0_DDR4_1]}
must {set_property name C2_DDR4_0 [get_bd_intf_ports C0_DDR4_2]}
must {set_property name C3_DDR4_0 [get_bd_intf_ports C0_DDR4_3]}
must {set_property name dimm0_refclk [get_bd_intf_ports C0_SYS_CLK_0]}
must {set_property name dimm1_refclk [get_bd_intf_ports C0_SYS_CLK_1]}
must {set_property name dimm2_refclk [get_bd_intf_ports C0_SYS_CLK_2]}
must {set_property name dimm3_refclk [get_bd_intf_ports C0_SYS_CLK_3]}
# assert the exact top-level port set the XDCs constrain
foreach want {C0_DDR4_0 C1_DDR4_0 C2_DDR4_0 C3_DDR4_0 \
              dimm0_refclk dimm1_refclk dimm2_refclk dimm3_refclk \
              pcie_refclk pcie_mgt} {
    if {[llength [get_bd_intf_ports -quiet $want]] != 1} {
        puts "FATAL: expected intf port '$want' missing"; exit 1
    }
}
if {[llength [get_bd_ports -quiet pcie_perstn]] != 1} {
    puts "FATAL: expected port 'pcie_perstn' missing"; exit 1
}
foreach n {dimm0_refclk dimm1_refclk dimm2_refclk dimm3_refclk} {
    must {set_property CONFIG.FREQ_HZ 300000000 [get_bd_intf_ports /$n]}
}

# ---------------- SmartConnect: XDMA M_AXI -> 4x DDR4 ----------------
must {create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 axi_smc}
must {set_property -dict [list CONFIG.NUM_MI {5} CONFIG.NUM_SI {1} CONFIG.NUM_CLKS {5}] [get_bd_cells axi_smc]}
must {connect_bd_intf_net [get_bd_intf_pins xdma_0/M_AXI] [get_bd_intf_pins axi_smc/S00_AXI]}
must {connect_bd_net [get_bd_pins xdma_0/axi_aclk] [get_bd_pins axi_smc/aclk]}
must {connect_bd_net [get_bd_pins xdma_0/axi_aresetn] [get_bd_pins axi_smc/aresetn]}
for {set i 0} {$i < 4} {incr i} {
    must {connect_bd_net [get_bd_pins ddr4_$i/c0_ddr4_ui_clk] [get_bd_pins axi_smc/aclk[expr {$i+1}]]}
}
# M04 (aclk domain): the engine's io window, connected below once opus_0 exists

# ---------------- per-channel SmartConnect: host DMA + engine reader -> DDR4 i ----------------
for {set i 0} {$i < 4} {incr i} {
    must {create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 ddr_smc_$i}
    must {set_property -dict [list CONFIG.NUM_MI {1} CONFIG.NUM_SI {2} CONFIG.NUM_CLKS {1}] [get_bd_cells ddr_smc_$i]}
    must {connect_bd_net [get_bd_pins ddr4_$i/c0_ddr4_ui_clk] [get_bd_pins ddr_smc_$i/aclk]}
    must {connect_bd_net [get_bd_pins ddr4_c${i}_reset/peripheral_aresetn] [get_bd_pins ddr_smc_$i/aresetn]}
    must {connect_bd_intf_net [get_bd_intf_pins axi_smc/M0${i}_AXI] [get_bd_intf_pins ddr_smc_$i/S00_AXI]}
    must {connect_bd_intf_net [get_bd_intf_pins ddr_smc_$i/M00_AXI] [get_bd_intf_pins ddr4_$i/C0_DDR4_S_AXI]}
}

# ---------------- engine (opus_top: CSR + io window + DDR readers + pbs_engine) ----------------
must {create_bd_cell -type module -reference opus_top_ipi opus_0}
must {set_property CONFIG.VERSION 0x$BuildVer [get_bd_cells opus_0]}
must {set_property CONFIG.ROMDIR_F $RepoRoot/synth/roms/P5_mont [get_bd_cells opus_0]}
must {set_property CONFIG.ROMDIR_I $RepoRoot/synth/roms/P5_table [get_bd_cells opus_0]}
set gotver [get_property CONFIG.VERSION [get_bd_cells opus_0]]
if {![regexp -nocase {([0-9a-f]{8})$} $gotver -> gothex] || [string tolower $gothex] ne $BuildVer} {
    puts "FATAL: opus_0 CONFIG.VERSION = '$gotver', wanted 0x$BuildVer"; exit 1
}
puts "CSR_VERSION: $gotver"
puts "ROMDIR_F: [get_property CONFIG.ROMDIR_F [get_bd_cells opus_0]]"
puts "ROMDIR_I: [get_property CONFIG.ROMDIR_I [get_bd_cells opus_0]]"
foreach want {s_axil s_io m0 m1 m2 m3} {
    if {[llength [get_bd_intf_pins -quiet opus_0/$want]] != 1} {
        puts "FATAL: opus_0 interface '$want' was not inferred (X_INTERFACE attributes)"; exit 1
    }
}
must {connect_bd_intf_net [get_bd_intf_pins xdma_0/M_AXI_LITE] [get_bd_intf_pins opus_0/s_axil]}
must {connect_bd_intf_net [get_bd_intf_pins axi_smc/M04_AXI] [get_bd_intf_pins opus_0/s_io]}
must {connect_bd_net [get_bd_pins xdma_0/axi_aclk] [get_bd_pins opus_0/aclk]}
must {connect_bd_net [get_bd_pins xdma_0/axi_aresetn] [get_bd_pins opus_0/aresetn]}
for {set i 0} {$i < 4} {incr i} {
    must {connect_bd_net [get_bd_pins ddr4_$i/c0_ddr4_ui_clk] [get_bd_pins opus_0/ui_clk$i]}
    must {connect_bd_net [get_bd_pins ddr4_c${i}_reset/peripheral_aresetn] [get_bd_pins opus_0/ui_rstn$i]}
    must {connect_bd_intf_net [get_bd_intf_pins opus_0/m$i] [get_bd_intf_pins ddr_smc_$i/S01_AXI]}
}

must {create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 calib_concat}
must {set_property -dict [list CONFIG.NUM_PORTS {4}] [get_bd_cells calib_concat]}
for {set i 0} {$i < 4} {incr i} {
    must {connect_bd_net [get_bd_pins ddr4_$i/c0_init_calib_complete] [get_bd_pins calib_concat/In$i]}
}
must {connect_bd_net [get_bd_pins calib_concat/dout] [get_bd_pins opus_0/calib_in]}

# ---------------- address map ----------------
must {assign_bd_address}
# io window in XDMA's DMA space (first: assign_bd_address may have put it inside ddr4_0's 4 GiB)
set seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces xdma_0/M_AXI] -filter "NAME =~ *opus_0*"]
if {[llength $seg] != 1} { puts "FATAL: io window seg lookup got: $seg"; exit 1 }
must {set_property range 4M $seg}
must {set_property offset 0x1000000000 $seg}
# Park the four DDR4 segments at 0x20_0000_0000 + i*4G first: with the engine's extra address spaces
# assign_bd_address no longer leaves the shell's targets free (it put ddr4_3 at 0x8000_0000 [2G]).
for {set i 0} {$i < 4} {incr i} {
    set seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces xdma_0/M_AXI] -filter "NAME =~ *ddr4_$i*"]
    if {[llength $seg] != 1} { puts "FATAL: ddr4_$i seg lookup got: $seg"; exit 1 }
    must {set_property offset [expr {0x2000000000 + $i * 0x100000000}] $seg}
    must {set_property range 4G $seg}
}
# Pin DDR4 segments at 4GB strides in XDMA's DMA address space
for {set i 0} {$i < 4} {incr i} {
    set seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces xdma_0/M_AXI] -filter "NAME =~ *ddr4_$i*"]
    if {[llength $seg] != 1} { puts "FATAL: ddr4_$i seg lookup got: $seg"; exit 1 }
    must {set_property range 4G $seg}
    must {set_property offset [expr {$i * 0x100000000}] $seg}
}
set seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces xdma_0/M_AXI_LITE] -filter "NAME =~ *opus_0*"]
if {[llength $seg] != 1} { puts "FATAL: csr seg lookup got: $seg"; exit 1 }
must {set_property offset 0x0 $seg}
# engine reader i sees only DDR4 channel i, at 0, 4 GiB
for {set i 0} {$i < 4} {incr i} {
    set segs [get_bd_addr_segs -of_objects [get_bd_addr_spaces opus_0/m$i]]
    foreach s $segs {
        if {![string match "*ddr4_$i/*" $s] && ![string match "*ddr4_${i}_*" $s]} {
            puts "excluding $s from opus_0/m$i"
            must {exclude_bd_addr_seg $s}
        }
    }
    set seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces opus_0/m$i] -filter "NAME =~ *ddr4_$i*"]
    if {[llength $seg] != 1} { puts "FATAL: opus_0/m$i ddr4_$i seg lookup got: '$seg' (all: [get_bd_addr_segs -of_objects [get_bd_addr_spaces opus_0/m$i]])"; exit 1 }
    must {set_property offset 0x0 $seg}
    must {set_property range 4G $seg}
}
puts "ADDRESS MAP:"
foreach s [get_bd_addr_segs -of_objects [get_bd_addr_spaces {xdma_0/* opus_0/m*}]] {
    puts [format "  %-60s off=%s range=%s" $s [get_property OFFSET $s] [get_property RANGE $s]]
}
foreach s [get_bd_addr_segs -excluded -quiet -of_objects [get_bd_addr_spaces {xdma_0/* opus_0/m*}]] {
    puts [format "  %-60s EXCLUDED" $s]
}

must {validate_bd_design}
must {save_bd_design}

set bdfile [get_files bd.bd]
must {make_wrapper -files $bdfile -top}
must {add_files -norecurse $OutDir/proj/opus_full.gen/sources_1/bd/bd/hdl/bd_wrapper.v}
must {set_property top bd_wrapper [current_fileset]}

# The BD is synthesised out-of-context per IP (project default, as the shell build): create the IP
# runs now and give the module reference's run the engine options, then assert them.
must {set_property synth_checkpoint_mode Hierarchical $bdfile}
must {generate_target all $bdfile}
must {create_ip_run $bdfile}
set erun [get_runs -quiet bd_opus_0_0_synth_1]
if {[llength $erun] != 1} { puts "FATAL: no OOC run bd_opus_0_0_synth_1 (runs: [get_runs])"; exit 1 }
foreach r [list [get_runs synth_1] $erun] {
    must {set_property STEPS.SYNTH_DESIGN.ARGS.KEEP_EQUIVALENT_REGISTERS true $r}
    must {set_property STEPS.SYNTH_DESIGN.ARGS.RESOURCE_SHARING off $r}
    set ker [get_property STEPS.SYNTH_DESIGN.ARGS.KEEP_EQUIVALENT_REGISTERS $r]
    set rs  [get_property STEPS.SYNTH_DESIGN.ARGS.RESOURCE_SHARING $r]
    if {!$ker || $rs ne "off"} { puts "FATAL: $r keep_equivalent_registers=$ker resource_sharing=$rs"; exit 1 }
    puts "SYNTH_OPTS: $r keep_equivalent_registers=$ker resource_sharing=$rs flatten=[get_property STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY $r]"
}
puts "RUNS: [lsort [get_runs]]"

puts "CREATE_PROJECT_OK"
