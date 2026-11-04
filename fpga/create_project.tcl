set here [file normalize [file dirname [info script]]]
set front $here
set rtl_dir [file join $here verilog-ethernet rtl]
set project_dir [file join $here out]
if {[file exists $project_dir]} { error "Refusing to overwrite $project_dir" }
create_project cam0_raw10g_trigger_v2_2025_2 $project_dir -part xczu7ev-ffvc1156-2-i
set_property include_dirs [list $front $here] [get_filesets sources_1]
add_files -norecurse [file join $here cam0_frontend_raw10g.v]
add_files -norecurse [file join $front cam0_csi_probe_top.sv]
set_property file_type {Verilog Header} [get_files [file join $front cam0_csi_probe_top.sv]]
add_files -norecurse [glob [file join $rtl_dir *.v]]
add_files -norecurse [file join $here camera_l2_live_packetizer.v]
add_files -norecurse [file join $here sc130gs_trigger_pulse.v]
add_files -norecurse [file join $here bz10_cam0_raw10g_trigger.v]
add_files -fileset constrs_1 -norecurse [file join $front cam0_csi_probe.xdc]
add_files -fileset constrs_1 -norecurse [file join $here bz10_cam0_raw10g.xdc]

create_ip -name clk_wiz -vendor xilinx.com -library ip -module_name dphy_ref_clock
set_property -dict [list CONFIG.PRIM_SOURCE {No_buffer} CONFIG.PRIM_IN_FREQ {100.000} \
 CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {200.000} CONFIG.USE_RESET {true} \
 CONFIG.RESET_TYPE {ACTIVE_HIGH}] [get_ips dphy_ref_clock]
create_ip -name mipi_csi2_rx_subsystem -vendor xilinx.com -library ip -version 6.0 -module_name cam0_csi
set_property -dict [list CONFIG.CMN_NUM_LANES {4} CONFIG.C_DPHY_LANES {4} CONFIG.CMN_NUM_PIXELS {4} \
 CONFIG.CMN_PXL_FORMAT {RAW10} CONFIG.C_HS_LINE_RATE {1000} CONFIG.DPY_LINE_RATE {1000} \
 CONFIG.C_DPHY_MODE {SLAVE} \
 CONFIG.CLK_LANE_IO_LOC {AD15} CONFIG.DATA_LANE0_IO_LOC {AA14} CONFIG.DATA_LANE1_IO_LOC {AB16} \
 CONFIG.DATA_LANE2_IO_LOC {AA16} CONFIG.DATA_LANE3_IO_LOC {AC17}] [get_ips cam0_csi]
create_ip -name gtwizard_ultrascale -vendor xilinx.com -library ip -module_name eth_gt_sfp4
set gt [get_ips eth_gt_sfp4]
set_property CONFIG.preset {GTH-10GBASE-R} $gt
set_property -dict [list \
    CONFIG.CHANNEL_ENABLE {X0Y4} \
    CONFIG.RX_REFCLK_SOURCE {X0Y4 clk1} CONFIG.TX_REFCLK_SOURCE {X0Y4 clk1} \
    CONFIG.RX_LINE_RATE 10.3125 CONFIG.TX_LINE_RATE 10.3125 \
    CONFIG.RX_REFCLK_FREQUENCY 156.25 CONFIG.TX_REFCLK_FREQUENCY 156.25 \
    CONFIG.RX_USER_DATA_WIDTH 64 CONFIG.TX_USER_DATA_WIDTH 64 \
    CONFIG.RX_INT_DATA_WIDTH 32 CONFIG.TX_INT_DATA_WIDTH 32 \
    CONFIG.FREERUN_FREQUENCY 100 CONFIG.LOCATE_COMMON CORE \
    CONFIG.LOCATE_RESET_CONTROLLER CORE CONFIG.LOCATE_TX_USER_CLOCKING CORE \
    CONFIG.LOCATE_RX_USER_CLOCKING CORE CONFIG.LOCATE_USER_DATA_WIDTH_SIZING CORE \
    CONFIG.DISABLE_LOC_XDC 1] $gt
create_ip -name axis_dwidth_converter -vendor xilinx.com -library ip -module_name width40to64
set_property -dict [list CONFIG.S_TDATA_NUM_BYTES {5} CONFIG.M_TDATA_NUM_BYTES {8} \
 CONFIG.HAS_TKEEP {1} CONFIG.HAS_TLAST {1} CONFIG.TUSER_BITS_PER_BYTE {1}] [get_ips width40to64]
create_ip -name axis_data_fifo -vendor xilinx.com -library ip -module_name csi_async_fifo
set_property -dict [list CONFIG.FIFO_DEPTH {4096} CONFIG.IS_ACLK_ASYNC {1} \
 CONFIG.TDATA_NUM_BYTES {8} CONFIG.HAS_TKEEP {1} CONFIG.HAS_TLAST {1} \
 CONFIG.TUSER_WIDTH {8}] [get_ips csi_async_fifo]

create_bd_design ps_clocks
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:3.5 ps]
set_property -dict [list CONFIG.PSU__FPGA_PL0_ENABLE {1} \
 CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {100} \
 CONFIG.PSU__GPIO_EMIO__PERIPHERAL__ENABLE {1} CONFIG.PSU__GPIO_EMIO_WIDTH {95} \
 CONFIG.PSU__USE__M_AXI_GP0 {0} CONFIG.PSU__USE__M_AXI_GP1 {0} \
 CONFIG.PSU__USE__M_AXI_GP2 {1} CONFIG.PSU__USE__S_AXI_GP2 {0}] $ps
make_bd_pins_external -name pl_clk [get_bd_pins ps/pl_clk0]
make_bd_pins_external -name pl_resetn [get_bd_pins ps/pl_resetn0]
make_bd_pins_external -name emio_gpio_i [get_bd_pins ps/emio_gpio_i]

set control [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 trigger_control_gpio]
set_property -dict [list CONFIG.C_GPIO_WIDTH {32} CONFIG.C_ALL_OUTPUTS {1} \
 CONFIG.C_DOUT_DEFAULT {0x00000000}] $control
set status [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 trigger_status_gpio]
set_property -dict [list CONFIG.C_GPIO_WIDTH {32} CONFIG.C_ALL_INPUTS {1}] $status
set ctl [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 trigger_axi]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {2}] $ctl
connect_bd_intf_net [get_bd_intf_pins ps/M_AXI_HPM0_LPD] [get_bd_intf_pins trigger_axi/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins trigger_axi/M00_AXI] [get_bd_intf_pins trigger_control_gpio/S_AXI]
connect_bd_intf_net [get_bd_intf_pins trigger_axi/M01_AXI] [get_bd_intf_pins trigger_status_gpio/S_AXI]
foreach pin {trigger_control_gpio/s_axi_aclk trigger_status_gpio/s_axi_aclk trigger_axi/aclk ps/maxihpm0_lpd_aclk} {
    connect_bd_net [get_bd_pins ps/pl_clk0] [get_bd_pins $pin]
}
foreach pin {trigger_control_gpio/s_axi_aresetn trigger_status_gpio/s_axi_aresetn trigger_axi/aresetn} {
    connect_bd_net [get_bd_pins ps/pl_resetn0] [get_bd_pins $pin]
}
set control_port [create_bd_port -dir O -from 31 -to 0 trigger_control]
set status_port [create_bd_port -dir I -from 31 -to 0 trigger_status]
connect_bd_net [get_bd_pins trigger_control_gpio/gpio_io_o] $control_port
connect_bd_net [get_bd_pins trigger_status_gpio/gpio_io_i] $status_port
assign_bd_address
set_property offset 0x80040000 [get_bd_addr_segs ps/Data/SEG_trigger_control_gpio_Reg]
set_property offset 0x80050000 [get_bd_addr_segs ps/Data/SEG_trigger_status_gpio_Reg]
validate_bd_design
save_bd_design
set wrapper [make_wrapper -files [get_files ps_clocks.bd] -top]
add_files -norecurse $wrapper
generate_target all [get_files ps_clocks.bd]
set_property top bz10_cam0_raw10g_trigger [get_filesets sources_1]
update_compile_order -fileset sources_1
puts "PROJECT_READY=$project_dir"
close_project
exit
