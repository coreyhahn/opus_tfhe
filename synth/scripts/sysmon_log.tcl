# Read-only SYSMON sampler over JTAG (never programs; the running bitstream is untouched).
#   vivado -mode batch -nojournal -source sysmon_log.tcl -tclargs <secs> <period_s> <out.csv>
# Run under the board lock (board_lock.py --exec).
set secs [lindex $argv 0]; set per [lindex $argv 1]; set out [lindex $argv 2]
open_hw_manager
connect_hw_server -url localhost:3121
open_hw_target localhost:3121/xilinx_tcf/Xilinx/21440289J04FA
set dev [lindex [get_hw_devices xcvu9p*] 0]
current_hw_device $dev
set sms [get_hw_sysmons -of_objects $dev]
set f [open $out w]
puts $f "t_s,sysmon,temp_c,vccint_v,vccaux_v,vccbram_v"
set t0 [clock milliseconds]
while {[expr {([clock milliseconds] - $t0) / 1000.0}] < $secs} {
    foreach sm $sms {
        refresh_hw_sysmon $sm
        puts $f [format "%.1f,%s,%s,%s,%s,%s" [expr {([clock milliseconds] - $t0) / 1000.0}] [get_property NAME $sm] \
            [get_property TEMPERATURE $sm] [get_property VCCINT $sm] [get_property VCCAUX $sm] [get_property VCCBRAM $sm]]
    }
    flush $f
    after [expr {int($per * 1000)}]
}
close $f
close_hw_target
puts SYSMON_OK
