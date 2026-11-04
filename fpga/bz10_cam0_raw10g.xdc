set_property PACKAGE_PIN AA10 [get_ports gt_refclk_p]
set_property PACKAGE_PIN AA9 [get_ports gt_refclk_n]
create_clock -name gt_refclk -period 6.400 [get_ports gt_refclk_p]
set_property LOC GTHE4_CHANNEL_X0Y4 [get_cells -hierarchical -filter {REF_NAME == GTHE4_CHANNEL}]
set_property LOC GTHE4_COMMON_X0Y1 [get_cells -hierarchical -filter {REF_NAME == GTHE4_COMMON}]

# The only TX->video CDC is the input of a two-flop status synchronizer.
# Keep all synchronous logic after its first stage fully timed.
set gt_done_video_meta_cell [get_cells -hierarchical -filter {NAME =~ *gt_done_video_meta_reg}]
set_false_path -to [get_pins -of_objects $gt_done_video_meta_cell -filter {REF_PIN_NAME == D}]

# The PL trigger scheduler's accepted-start toggle crosses into the 10G TX
# clock through the packetizer's first synchronizer flop.
set run_start_meta_cell [get_cells -hierarchical -filter {NAME =~ *u_packetizer/start_meta_reg}]
set_false_path -to [get_pins -of_objects $run_start_meta_cell -filter {REF_PIN_NAME == D}]
