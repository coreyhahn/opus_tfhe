# build_full.tcl — synth + impl + bitstream for a project made by create_full.tcl (shell + engine).
#
# PROVENANCE: copied from synth/scripts/build_shell.tcl (adapted from fable5_llm commit 35d95a5,
#   synth/scripts/build.tcl). Changes vs build_shell.tcl: project opus_full.xpr and opus_full.* artifact
#   names; before launching, re-asserts -keep_equivalent_registers / -resource_sharing off on synth_1
#   and on the engine's OOC run bd_opus_0_0_synth_1 and afterwards checks that run's log for them;
#   checks the engine floorplan (engine_slr_full.xdc) is in the implementation and every pblock got
#   cells; adds per-SLR and per-pblock utilisation reports. Same report set and bitstream otherwise
#   (no .bin / .mmi: there is no processor and the shell build writes none).
#
# Usage: vivado -mode batch -source build_full.tcl -tclargs <out_dir> <version_hex8> <git_desc> \
#            [<place_directive>]
#   With <place_directive> (re-roll mode, used by launch_reroll.sh on an rsync copy of a finished
#   build): synthesis is NOT rerun; impl_1 is reset and re-run with place -directive D plus
#   post-place AND post-route phys_opt (AggressiveExplore) — fable5_llm's "full recipe"
#   (fable5 synth/scripts/full_impl.tcl).

if {[llength $argv] < 3} { puts "FATAL: need <out_dir> <version_hex8> <git_desc> \[<place_directive>\]"; exit 1 }
set OutDir   [lindex $argv 0]
set BuildVer [lindex $argv 1]
set GitDesc  [lindex $argv 2]
set PlaceDir [lindex $argv 3]

proc must {script} {
    if {[catch {uplevel 1 $script} err]} {
        puts "FATAL: $err"
        exit 1
    }
}

set_param general.maxThreads 8

must {open_project $OutDir/proj/opus_full.xpr}
file mkdir $OutDir/reports

set recipe "default impl_1 strategy"
# engine synthesis options (CLAUDE.md "Vivado discipline"): never launch without them
set erun [get_runs -quiet bd_opus_0_0_synth_1]
if {[llength $erun] != 1} { puts "FATAL: engine OOC run bd_opus_0_0_synth_1 missing"; exit 1 }
foreach r [list [get_runs synth_1] $erun] {
    set ker [get_property STEPS.SYNTH_DESIGN.ARGS.KEEP_EQUIVALENT_REGISTERS $r]
    set rs  [get_property STEPS.SYNTH_DESIGN.ARGS.RESOURCE_SHARING $r]
    if {!$ker || $rs ne "off"} { puts "FATAL: $r keep_equivalent_registers=$ker resource_sharing=$rs"; exit 1 }
    puts "SYNTH_OPTS: $r keep_equivalent_registers=$ker resource_sharing=$rs"
}
set xf [get_files -quiet -of_objects [get_filesets constrs_1] *engine_slr_full.xdc]
if {[llength $xf] != 1 || [get_property USED_IN_SYNTHESIS $xf] || ![get_property USED_IN_IMPLEMENTATION $xf]} {
    puts "FATAL: engine_slr_full.xdc must be in constrs_1, implementation-only"; exit 1
}

if {$PlaceDir eq ""} {
    # fresh build: optional placement directive from the environment (OPUS_PLACE_DIRECTIVE), with the
    # re-roll recipe's post-place and post-route phys_opt
    if {[info exists ::env(OPUS_PLACE_DIRECTIVE)] && $::env(OPUS_PLACE_DIRECTIVE) ne ""} {
        set r [get_runs impl_1]
        must {set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE               $::env(OPUS_PLACE_DIRECTIVE) $r}
        must {set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED                true              $r}
        must {set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE            AggressiveExplore $r}
        must {set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED     true              $r}
        must {set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore $r}
        set recipe "place -directive $::env(OPUS_PLACE_DIRECTIVE), post-place + post-route phys_opt AggressiveExplore"
        puts "IMPL_CFG: $recipe"
    }
    # optional route directive (OPUS_ROUTE_DIRECTIVE; AggressiveExplore closed build 028)
    if {[info exists ::env(OPUS_ROUTE_DIRECTIVE)] && $::env(OPUS_ROUTE_DIRECTIVE) ne ""} {
        must {set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE $::env(OPUS_ROUTE_DIRECTIVE) [get_runs impl_1]}
        append recipe ", route -directive $::env(OPUS_ROUTE_DIRECTIVE)"
        puts "IMPL_CFG: route -directive $::env(OPUS_ROUTE_DIRECTIVE)"
    }
    # optional incremental implementation (OPUS_INCR_DCP: a routed checkpoint of a near-identical
    # netlist, e.g. build 028's): placement and routing of matching cells are reused
    if {[info exists ::env(OPUS_INCR_DCP)] && $::env(OPUS_INCR_DCP) ne ""} {
        set dcp [file normalize $::env(OPUS_INCR_DCP)]
        if {![file exists $dcp]} { puts "FATAL: OPUS_INCR_DCP $dcp not found"; exit 1 }
        must {set_property AUTO_INCREMENTAL_CHECKPOINT 0 [get_runs impl_1]}
        must {set_property INCREMENTAL_CHECKPOINT $dcp [get_runs impl_1]}
        must {set_property INCREMENTAL_CHECKPOINT.DIRECTIVE TimingClosure [get_runs impl_1]}
        append recipe ", incremental from $dcp (TimingClosure)"
        puts "IMPL_CFG: incremental from $dcp (TimingClosure)"
    }
    must {launch_runs synth_1 -jobs 8}
    must {wait_on_run synth_1}
    if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
        puts "FATAL: synthesis failed"; exit 1
    }
    # the engine's OOC synth log must show the options on its synth_design line
    set elog [get_property DIRECTORY $erun]/runme.log
    set fh [open $elog r]; set el [read $fh]; close $fh
    if {![regexp {synth_design [^\n]*-keep_equivalent_registers} $el] || ![regexp {synth_design [^\n]*-resource_sharing off} $el]} {
        puts "FATAL: $elog: synth_design line lacks -keep_equivalent_registers / -resource_sharing off"; exit 1
    }
    puts "ENGINE_SYNTH_OPTS_OK: $elog"
} else {
    if {[get_property PROGRESS [get_runs synth_1]] != "100%" || [get_property NEEDS_REFRESH [get_runs synth_1]]} {
        puts "FATAL: re-roll needs a complete, up-to-date synth_1 in the copied project"; exit 1
    }
    set r [get_runs impl_1]
    must {set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE               $PlaceDir         $r}
    must {set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED                true              $r}
    must {set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE            AggressiveExplore $r}
    must {set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED     true              $r}
    must {set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore $r}
    must {reset_run impl_1}
    set recipe "re-roll: place -directive $PlaceDir, post-place + post-route phys_opt AggressiveExplore"
    # optional placement over-constraint (OPUS_PLACE_UNCERTAINTY, ns): extra setup uncertainty on the
    # 250 MHz aclk and the four DDR4 ui clocks for place_design and post-place phys_opt (one process,
    # so it carries over), set back to 0 before route_design
    if {[info exists ::env(OPUS_PLACE_UNCERTAINTY)] && $::env(OPUS_PLACE_UNCERTAINTY) ne ""} {
        set u $::env(OPUS_PLACE_UNCERTAINTY)
        if {![string is double -strict $u] || $u <= 0 || $u > 0.5} { puts "FATAL: bad OPUS_PLACE_UNCERTAINTY '$u'"; exit 1 }
        set clks {xdma_0_axi_aclk mmcm_clkout0 mmcm_clkout0_1 mmcm_clkout0_2 mmcm_clkout0_3}
        foreach {f v} [list place_unc_pre.tcl $u route_unc_pre.tcl 0] {
            set fh [open [file normalize $OutDir/$f] w]
            puts $fh "set_clock_uncertainty -setup $v \[get_clocks {$clks}\]"
            puts $fh "puts \"OPUS_UNCERTAINTY: setup $v on {$clks}\""
            close $fh
        }
        must {set_property STEPS.PLACE_DESIGN.TCL.PRE [file normalize $OutDir/place_unc_pre.tcl] $r}
        must {set_property STEPS.ROUTE_DESIGN.TCL.PRE [file normalize $OutDir/route_unc_pre.tcl] $r}
        append recipe ", +$u ns setup uncertainty during place/phys_opt (removed before route)"
    }
    puts "REROLL_CFG: $recipe"
}

must {launch_runs impl_1 -to_step write_bitstream -jobs 8}
must {wait_on_run impl_1}
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    puts "FATAL: implementation failed"; exit 1
}

must {open_run impl_1}

# Clock-sanity gate (fable5: added after the unconstrained-pcie_refclk incident):
# the XDMA axi_aclk domain (250 MHz / 4 ns) MUST exist as a timed clock.
set clk4 [get_clocks -quiet -filter {PERIOD < 4.05 && PERIOD > 3.95}]
if {[llength $clk4] == 0} {
    puts "FATAL: no 4ns (250MHz) clock found — XDMA clock tree unconstrained"
    exit 1
}
puts "CLOCK_GATE_OK: 250MHz clocks: $clk4"
check_timing -override_defaults no_clock -file $OutDir/reports/check_timing_noclock.rpt
set fh [open $OutDir/reports/check_timing_noclock.rpt r]
set ct [read $fh]; close $fh
set noclk 0
if {[regexp {There are (\d+) register/latch pins with no clock} $ct -> noclk] && $noclk > 0} {
    puts "WARNING: $noclk register/latch pins with no clock (see check_timing_noclock.rpt)"
}

must {report_timing_summary -max_paths 20 -file $OutDir/reports/timing_summary.rpt}
must {report_utilization -file $OutDir/reports/utilization.rpt}
must {report_utilization -hierarchical -file $OutDir/reports/utilization_hier.rpt}
must {report_utilization -slr -file $OutDir/reports/utilization_slr.rpt}
foreach pb [get_pblocks] { must {report_utilization -pblocks $pb -file $OutDir/reports/utilization_$pb.rpt} }
# engine floorplan applied: each pblock must hold cells, and only engine cells
foreach pb {pb_slr0 pb_slr1 pb_slr2} {
    set pcells [get_cells -quiet -of_objects [get_pblocks -quiet $pb]]
    set foreign 0
    foreach c $pcells {
        set ok 0
        # [list] keeps the backslashes: a braced list would substitute them and turn [*] into a class
        foreach pat [list {u_eng/*} {u_bsk/*} {u_kska/*} {g_ch\[*\].u_rd} {g_ch\[*\].u_rd/*}] { if {[string match "bd_i/opus_0/inst/u_flat/u_top/$pat" $c]} { set ok 1 } }
        if {!$ok} { incr foreign }
    }
    puts "PBLOCK: $pb cells=[llength $pcells] non_engine=$foreign"
    if {[llength $pcells] == 0 || $foreign > 0} { puts "FATAL: pblock $pb is empty or holds cells outside the engine and its BSK/KSK/reader glue"; exit 1 }
}
must {report_clock_utilization -file $OutDir/reports/clock_util.rpt}
must {report_drc -file $OutDir/reports/drc.rpt}
must {report_exceptions -ignored -file $OutDir/reports/exceptions_ignored.rpt}

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
set tsr [report_timing_summary -no_detailed_paths -return_string]
set tns NA; set ths NA
# Design Timing Summary row: WNS TNS fail total WHS THS ...
if {[regexp {\n\s*(-?[0-9.]+)\s+(-?[0-9.]+)\s+\d+\s+\d+\s+(-?[0-9.]+)\s+(-?[0-9.]+)\s+\d+\s+\d+} $tsr -> w0 tns h0 ths]} {}
puts "TIMING: WNS=$wns TNS=$tns WHS=$whs THS=$ths"

# utilisation headline
set ur [report_utilization -return_string]
proc ucount {ur pat} {
    if {[regexp "\\|\\s*${pat}\\s*\\|\\s*(\[0-9.\]+)" $ur -> n]} { return $n }
    return NA
}
set u_lut  [ucount $ur {CLB LUTs\*?}]
set u_ff   [ucount $ur {CLB Registers}]
set u_bram [ucount $ur {Block RAM Tile}]
set u_uram [ucount $ur {URAM}]
set u_dsp  [ucount $ur {DSPs}]
puts "UTIL: LUT=$u_lut FF=$u_ff BRAM36=$u_bram URAM=$u_uram DSP=$u_dsp"

# PCIe block + GT placement sanity (must be quad 226/227 per board wiring)
foreach c [get_cells -hier -filter {REF_NAME =~ PCIE4*}] { puts "PCIE_LOC: $c -> [get_property LOC $c]" }
foreach c [get_cells -hier -filter {REF_NAME =~ GTYE4_CHANNEL*}] { puts "GT_LOC: [get_property LOC $c]" }

# XDMA reset-synchroniser exception scope (must match >0 pins, all inside xdma_0, all /CLR)
set exc [get_pins -quiet -hierarchical -filter {NAME =~ */udma_wrapper/dma_top/user_rst_*_reg*/CLR}]
set exc_out 0
foreach p $exc { if {![string match "*xdma_0*" $p]} { incr exc_out } }
puts "EXC_MATCHED_PIN_COUNT: [llength $exc] (outside xdma_0: $exc_out)"

# artifacts into the out dir
set rundir $OutDir/proj/opus_full.runs/impl_1
set bit [glob -nocomplain $rundir/*.bit]
if {[llength $bit] != 1} { puts "FATAL: expected one .bit in $rundir, got: $bit"; exit 1 }
file copy -force [lindex $bit 0] $OutDir/opus_full.bit
set dcp [glob -nocomplain $rundir/*_routed.dcp]
if {[llength $dcp] == 1} { file copy -force [lindex $dcp 0] $OutDir/opus_full_routed.dcp } else {
    must {write_checkpoint -force $OutDir/opus_full_routed.dcp}
}
set ltx [glob -nocomplain $rundir/*.ltx]
set ltxnote "none (no debug cores)"
if {[llength $ltx] > 0} { file copy -force [lindex $ltx 0] $OutDir/opus_full.ltx; set ltxnote $OutDir/opus_full.ltx }

set now [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S %Z}]
set bitmt [clock format [file mtime [lindex $bit 0]] -format {%Y-%m-%d %H:%M:%S %Z}]
set fh [open $OutDir/summary.txt w]
puts $fh "opus_tfhe FULL bitstream: shell + engine on axi_aclk (Stage 3 step 3)"
puts $fh "out_dir        : $OutDir"
puts $fh "git            : $GitDesc"
puts $fh "CSR VERSION    : 0x$BuildVer   (CSR MAGIC 0x0F7FE001)"
puts $fh "vivado         : [version -short]   part [get_property PART [current_project]]"
puts $fh "finished       : $now"
puts $fh "impl recipe    : $recipe"
puts $fh "WNS / TNS      : $wns / $tns ns"
puts $fh "WHS / THS      : $whs / $ths ns"
puts $fh "timing met     : [expr {($wns >= 0 && $whs >= 0) ? "YES" : "NO"}]"
puts $fh "no-clock pins  : $noclk"
puts $fh "LUT / FF       : $u_lut / $u_ff"
puts $fh "BRAM36 / URAM  : $u_bram / $u_uram"
puts $fh "DSP            : $u_dsp"
puts $fh "engine synth   : bd_opus_0_0_synth_1 (OOC per IP), -keep_equivalent_registers -resource_sharing off"
puts $fh "floorplan      : engine_slr_full.xdc (pb_slr0/1/2; reports/utilization_pblocks.rpt, utilization_slr.rpt)"
puts $fh "xdma rst exc   : [llength $exc] pins matched, $exc_out outside xdma_0"
puts $fh "bit (run dir)  : [lindex $bit 0]  mtime $bitmt"
puts $fh "bit (copy)     : $OutDir/opus_full.bit"
puts $fh "routed dcp     : $OutDir/opus_full_routed.dcp"
puts $fh "ltx            : $ltxnote"
close $fh
puts "SUMMARY: $OutDir/summary.txt"
puts "BITSTREAM: $OutDir/opus_full.bit"
puts "BUILD_OK"
