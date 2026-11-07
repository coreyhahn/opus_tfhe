# Vivado power estimate [model] for a routed full-design checkpoint (PLAN D8 fallback, user option (c)).
#   vivado -mode batch -nojournal -source power_est.tcl -tclargs <routed.dcp> <outdir>
# t12p5: vectorless default (12.5% on undriven inputs; it does not reach the engine's internal nets).
# eng50: the TFHE engine's register/SRL/LUTRAM/DSP outputs forced to 50% toggle, P(1)=0.5 -- the
#        right activity for uniformly random ciphertext/key data (user, 2026-11-06); vectorless
#        propagation from those through the LUTs.
set dcp [lindex $argv 0]
set out [lindex $argv 1]
file mkdir $out
open_checkpoint $dcp
set_switching_activity -deassert_resets
report_power -hierarchical_depth 4 -file $out/power_t12p5.rpt
set eng [get_cells bd_i/opus_0]
foreach ty {register shift_register lut_ram dsp} {
    set_switching_activity -type $ty -hier -toggle_rate 50 -static_probability 0.5 $eng
}
report_power -hierarchical_depth 4 -file $out/power_eng50.rpt
puts POWER_EST_OK
