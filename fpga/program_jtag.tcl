# Temporary PL-only test; Linux/SD boot files are unchanged.
set here [file normalize [file dirname [info script]]]
set bit [file join $here bz10_cam0_raw10g_trigger.bit]
if {![file exists $bit]} { error "Missing bitstream: $bit" }
open_hw_manager
connect_hw_server
set targets [get_hw_targets]
if {[llength $targets] != 1} { error "Expected one JTAG target, got: $targets" }
open_hw_target [lindex $targets 0]
set devices [get_hw_devices xczu7_0]
if {[llength $devices] != 1} { error "Expected xczu7_0, got: $devices" }
set device [lindex $devices 0]
set_property PROGRAM.FILE $bit $device
program_hw_devices -mpsoc_reset no $device
refresh_hw_device $device
puts "PROGRAMMED=$bit"
close_hw_target
disconnect_hw_server
exit
