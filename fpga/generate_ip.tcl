set here [file normalize [file dirname [info script]]]
open_project [file join $here out cam0_raw10g_trigger_v2_2025_2.xpr]
generate_target all [get_ips {width40to64 csi_async_fifo eth_gt_sfp4 dphy_ref_clock cam0_csi}]
close_project
exit
