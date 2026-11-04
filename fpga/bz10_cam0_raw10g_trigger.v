// CAM0 official CSI RX -> 40/64 AXIS -> async FIFO -> raw 10G SFP4.
// No VDMA, DDR, IP stack, host acknowledgment, or PC-driven pacing.
module bz10_cam0_raw10g_trigger (
    input wire gt_refclk_p, gt_refclk_n, gt_rxp, gt_rxn,
    output wire gt_txp, gt_txn,
    input wire cam0_clk_p, cam0_clk_n,
    input wire [3:0] cam0_data_p, cam0_data_n,
    output wire cam0_mclk, cam0_pwdn, cam0_tri0, cam0_tri1,
    output wire cam0_frame_odd,
    inout wire cam0_sda, cam0_scl
);
    wire pl_clk, pl_resetn;
    wire [94:0] camera_status;
    wire [31:0] trigger_control;
    wire [31:0] trigger_status;
    ps_clocks_wrapper u_ps (
        .emio_gpio_i(camera_status), .pl_clk(pl_clk), .pl_resetn(pl_resetn),
        .trigger_control(trigger_control), .trigger_status(trigger_status)
    );

    wire trigger0, run_start_toggle;
    sc130gs_trigger_pulse #(.CLK_PER_US(100), .PULSE_US(100))
    u_trigger (
        .clk(pl_clk), .resetn(pl_resetn),
        .arm_async(trigger_control[30]),
        .start_toggle_async(trigger_control[31]),
        .period_us_async(trigger_control[15:0]),
        .frame_count_async(trigger_control[29:16]),
        .trigger0(trigger0), .frame_odd(cam0_frame_odd),
        .run_start_toggle(run_start_toggle),
        .debug_status(trigger_status)
    );

    wire video_clk, video_resetn;
    wire [39:0] camera_data;
    wire [4:0] camera_user;
    wire camera_valid, camera_ready, camera_last;
    cam0_csi_probe_top u_camera (
        .pl_clk(pl_clk), .pl_resetn0(pl_resetn),
        .capture_enable(1'b1),
        .trigger0(trigger0),
        .emio_gpio_i(camera_status),
        .video_clk200(video_clk), .video_resetn(video_resetn),
        .video_tdata(camera_data), .video_tvalid(camera_valid),
        .video_tready(camera_ready), .video_tlast(camera_last),
        .video_tuser(camera_user),
        .cam0_mclk(cam0_mclk), .cam0_pwdn(cam0_pwdn),
        .cam0_tri0(cam0_tri0), .cam0_tri1(cam0_tri1),
        .cam0_sda(cam0_sda), .cam0_scl(cam0_scl),
        .cam0_clk_p(cam0_clk_p), .cam0_clk_n(cam0_clk_n),
        .cam0_data_p(cam0_data_p), .cam0_data_n(cam0_data_n)
    );

    wire [63:0] wide_data;
    wire [7:0] wide_keep, wide_user;
    wire wide_valid, wide_ready, wide_last;
    width40to64 u_width (
        .aclk(video_clk), .aresetn(video_resetn),
        .s_axis_tdata(camera_data), .s_axis_tkeep(5'h1f),
        .s_axis_tvalid(camera_valid), .s_axis_tready(camera_ready),
        .s_axis_tlast(camera_last), .s_axis_tuser(camera_user),
        .m_axis_tdata(wide_data), .m_axis_tkeep(wide_keep),
        .m_axis_tvalid(wide_valid), .m_axis_tready(wide_ready),
        .m_axis_tlast(wide_last), .m_axis_tuser(wide_user)
    );

    // Same verified FH1223 Quad-224 156.25-MHz reference/reset as link test.
    wire gt_refclk, refclk_fabric, refclk_buf;
    wire ctrl_clk, ctrl_clk_unbuf, ctrl_locked, clkfb, clkfb_buf;
    reg [15:0] ctrl_reset_pipe = 16'hffff;
    IBUFDS_GTE4 u_refbuf (
        .I(gt_refclk_p), .IB(gt_refclk_n), .CEB(1'b0),
        .O(gt_refclk), .ODIV2(refclk_fabric)
    );
    BUFG_GT u_refbuf_fabric (
        .I(refclk_fabric), .CE(1'b1), .CEMASK(1'b1),
        .CLR(1'b0), .CLRMASK(1'b1), .DIV(3'b000), .O(refclk_buf)
    );
    MMCME4_BASE #(
        .BANDWIDTH("OPTIMIZED"), .CLKIN1_PERIOD(6.400),
        .DIVCLK_DIVIDE(1), .CLKFBOUT_MULT_F(8.000),
        .CLKOUT0_DIVIDE_F(12.500)
    ) u_ctrl_mmcm (
        .CLKIN1(refclk_buf), .CLKFBIN(clkfb_buf), .CLKFBOUT(clkfb),
        .CLKOUT0(ctrl_clk_unbuf), .LOCKED(ctrl_locked),
        .PWRDWN(1'b0), .RST(1'b0)
    );
    BUFG u_clkfb_bufg (.I(clkfb), .O(clkfb_buf));
    BUFG u_ctrl_bufg (.I(ctrl_clk_unbuf), .O(ctrl_clk));
    always @(posedge ctrl_clk or negedge ctrl_locked) begin
        if (!ctrl_locked) ctrl_reset_pipe <= 16'hffff;
        else ctrl_reset_pipe <= {ctrl_reset_pipe[14:0], 1'b0};
    end

    wire tx_clk, rx_clk, gt_tx_done, gt_rx_done;
    wire rx_reset_req, rx_bitslip;
    wire [63:0] serdes_tx_data, serdes_rx_data;
    wire [5:0] serdes_tx_hdr, serdes_rx_hdr;
    reg [3:0] tx_reset_pipe = 4'hf, rx_reset_pipe = 4'hf;
    eth_gt_sfp4 u_gt (
        .gtwiz_userclk_tx_reset_in(1'b0),
        .gtwiz_userclk_tx_usrclk2_out(tx_clk),
        .gtwiz_userclk_rx_reset_in(1'b0),
        .gtwiz_userclk_rx_usrclk2_out(rx_clk),
        .gtwiz_reset_clk_freerun_in(ctrl_clk),
        .gtwiz_reset_all_in(ctrl_reset_pipe[15]),
        .gtwiz_reset_tx_pll_and_datapath_in(1'b0),
        .gtwiz_reset_tx_datapath_in(1'b0),
        .gtwiz_reset_rx_pll_and_datapath_in(1'b0),
        .gtwiz_reset_rx_datapath_in(rx_reset_req),
        .gtwiz_reset_tx_done_out(gt_tx_done),
        .gtwiz_reset_rx_done_out(gt_rx_done),
        .gtwiz_userdata_tx_in(serdes_tx_data),
        .gtwiz_userdata_rx_out(serdes_rx_data),
        .gtrefclk00_in(gt_refclk),
        .gthrxn_in(gt_rxn), .gthrxp_in(gt_rxp),
        .rxgearboxslip_in(rx_bitslip),
        .txheader_in(serdes_tx_hdr), .txsequence_in(7'b0),
        .gthtxn_out(gt_txn), .gthtxp_out(gt_txp),
        .rxheader_out(serdes_rx_hdr)
    );
    always @(posedge tx_clk or negedge gt_tx_done) begin
        if (!gt_tx_done) tx_reset_pipe <= 4'hf;
        else tx_reset_pipe <= {tx_reset_pipe[2:0], 1'b0};
    end
    always @(posedge rx_clk or negedge gt_rx_done) begin
        if (!gt_rx_done) rx_reset_pipe <= 4'hf;
        else rx_reset_pipe <= {rx_reset_pipe[2:0], 1'b0};
    end
    wire tx_rst = tx_reset_pipe[3], rx_rst = rx_reset_pipe[3];

    // GT reset-done is generated in the TX clock domain.  Only the first
    // synchronizer stage receives it directly; a scoped CDC exception for
    // that first stage is in bz10_cam0_raw10g.xdc.
    (* ASYNC_REG = "TRUE", DONT_TOUCH = "TRUE" *) reg gt_done_video_meta = 1'b0;
    (* ASYNC_REG = "TRUE", DONT_TOUCH = "TRUE" *) reg gt_done_video_sync = 1'b0;
    always @(posedge video_clk) begin
        gt_done_video_meta <= gt_tx_done;
        gt_done_video_sync <= gt_done_video_meta;
    end
    reg [3:0] fifo_reset_pipe = 4'b0000;
    always @(posedge video_clk) begin
        if (!video_resetn || !gt_done_video_sync) fifo_reset_pipe <= 4'b0000;
        else fifo_reset_pipe <= {fifo_reset_pipe[2:0], 1'b1};
    end
    wire [63:0] fifo_data;
    wire [7:0] fifo_keep, fifo_user;
    wire fifo_valid, fifo_ready, fifo_last;
    csi_async_fifo u_fifo (
        .s_axis_aresetn(fifo_reset_pipe[3]),
        .s_axis_aclk(video_clk), .m_axis_aclk(tx_clk),
        .s_axis_tdata(wide_data), .s_axis_tkeep(wide_keep),
        .s_axis_tvalid(wide_valid), .s_axis_tready(wide_ready),
        .s_axis_tlast(wide_last), .s_axis_tuser(wide_user),
        .m_axis_tdata(fifo_data), .m_axis_tkeep(fifo_keep),
        .m_axis_tvalid(fifo_valid), .m_axis_tready(fifo_ready),
        .m_axis_tlast(fifo_last), .m_axis_tuser(fifo_user)
    );

    wire [63:0] tx_data;
    wire [7:0] tx_keep;
    wire tx_valid, tx_ready, tx_last;
    (* mark_debug = "true" *) wire [31:0] frames_sent;
    (* mark_debug = "true" *) wire [31:0] input_error_count;
    camera_l2_live_packetizer u_packetizer (
        .clk(tx_clk), .rst(tx_rst),
        .run_start_toggle_async(run_start_toggle),
        .s_axis_tdata(fifo_data), .s_axis_tkeep(fifo_keep),
        .s_axis_tvalid(fifo_valid), .s_axis_tready(fifo_ready),
        .s_axis_tlast(fifo_last), .s_axis_tuser(fifo_user[0]),
        .m_axis_tdata(tx_data), .m_axis_tkeep(tx_keep),
        .m_axis_tvalid(tx_valid), .m_axis_tready(tx_ready),
        .m_axis_tlast(tx_last), .input_error_count(input_error_count),
        .frames_sent(frames_sent)
    );

    (* mark_debug = "true" *) wire tx_underflow, rx_block_lock, rx_status;
    eth_mac_phy_10g #(
        .DATA_WIDTH(64), .HDR_WIDTH(2), .BIT_REVERSE(1)
    ) u_mac_phy (
        .rx_clk(rx_clk), .rx_rst(rx_rst),
        .tx_clk(tx_clk), .tx_rst(tx_rst),
        .tx_axis_tdata(tx_data), .tx_axis_tkeep(tx_keep),
        .tx_axis_tvalid(tx_valid), .tx_axis_tready(tx_ready),
        .tx_axis_tlast(tx_last), .tx_axis_tuser(1'b0),
        .rx_axis_tdata(), .rx_axis_tkeep(),
        .rx_axis_tvalid(), .rx_axis_tlast(), .rx_axis_tuser(),
        .serdes_tx_data(serdes_tx_data), .serdes_tx_hdr(serdes_tx_hdr),
        .serdes_rx_data(serdes_rx_data), .serdes_rx_hdr(serdes_rx_hdr),
        .serdes_rx_bitslip(rx_bitslip), .serdes_rx_reset_req(rx_reset_req),
        .tx_ptp_ts(96'b0), .rx_ptp_ts(96'b0),
        .tx_axis_ptp_ts(), .tx_axis_ptp_ts_tag(),
        .tx_axis_ptp_ts_valid(), .tx_start_packet(),
        .tx_error_underflow(tx_underflow),
        .rx_start_packet(), .rx_error_count(),
        .rx_error_bad_frame(), .rx_error_bad_fcs(),
        .rx_bad_block(), .rx_block_lock(rx_block_lock),
        .rx_high_ber(), .rx_status(rx_status),
        .cfg_ifg(8'd12), .cfg_tx_enable(1'b1), .cfg_rx_enable(1'b1),
        .cfg_tx_prbs31_enable(1'b0), .cfg_rx_prbs31_enable(1'b0)
    );
endmodule
