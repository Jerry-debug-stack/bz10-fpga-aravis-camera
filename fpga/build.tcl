set here [file normalize [file dirname [info script]]]
open_project [file join $here out cam0_raw10g_trigger_v2_2025_2.xpr]
update_compile_order -fileset sources_1
if {[get_property STATUS [get_runs synth_1]] ne "Not started"} {
    reset_run synth_1
}
launch_runs synth_1 -jobs 1
wait_on_run synth_1
set status [get_property STATUS [get_runs synth_1]]
puts "SYNTH_STATUS=$status"
if {$status ne "synth_design Complete!"} { error "Synthesis failed" }
if {[get_property STATUS [get_runs impl_1]] ne "Not started"} {
    reset_run impl_1
}
launch_runs impl_1 -to_step write_bitstream -jobs 1
wait_on_run impl_1
set status [get_property STATUS [get_runs impl_1]]
puts "IMPL_STATUS=$status"
if {$status ne "write_bitstream Complete!"} { error "Implementation failed" }
open_run impl_1
report_route_status -file [file join $here route_status.rpt]
report_drc -file [file join $here drc.rpt]
report_timing_summary -file [file join $here timing_summary.rpt]
puts "BITSTREAM=[file join $here out cam0_raw10g_trigger_v2_2025_2.runs impl_1 bz10_cam0_raw10g_trigger.bit]"
close_project
exit
