// CAM0 CSI bring-up: report both MMCM and external PHY PLL lock before
// interpreting CSI stream counters.  No DDR writer is instantiated yet.
module cam0_csi_probe_top (
`ifdef CAM0_FRONTEND
    input  wire       pl_clk,
    input  wire       pl_resetn0,
    input  wire       capture_enable,
    input  wire       trigger0,
`ifdef CAM0_STREAM
    output wire [31:0] stream_sof_count,
`endif
    output wire [94:0] emio_gpio_i,
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 VIDEO_CLK CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME VIDEO_CLK, FREQ_HZ 200000000, ASSOCIATED_BUSIF VIDEO, ASSOCIATED_RESET video_resetn" *)
    output wire        video_clk200,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 VIDEO_RESETN RST" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME VIDEO_RESETN, POLARITY ACTIVE_LOW" *)
    output wire        video_resetn,
`ifdef CAM0_DIRECT40
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 VIDEO TDATA" *)
`ifdef CAM0_USER5
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME VIDEO, FREQ_HZ 200000000, TDATA_NUM_BYTES 5, HAS_TKEEP 0, HAS_TLAST 1, HAS_TREADY 1, HAS_TUSER 1, TUSER_WIDTH 5" *)
`else
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME VIDEO, FREQ_HZ 200000000, TDATA_NUM_BYTES 5, HAS_TKEEP 0, HAS_TLAST 1, HAS_TREADY 1, HAS_TUSER 1, TUSER_WIDTH 1" *)
`endif
    output wire [39:0] video_tdata,
`else
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 VIDEO TDATA" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME VIDEO, FREQ_HZ 200000000, TDATA_NUM_BYTES 3, HAS_TKEEP 1, HAS_TLAST 1, HAS_TREADY 1, HAS_TUSER 1, TUSER_WIDTH 3" *)
    output wire [23:0] video_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 VIDEO TKEEP" *)
    output wire [2:0]  video_tkeep,
`endif
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 VIDEO TLAST" *)
    output wire        video_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 VIDEO TVALID" *)
    output wire        video_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 VIDEO TUSER" *)
`ifdef CAM0_DIRECT40
`ifdef CAM0_USER5
    output wire [4:0]  video_tuser,
`else
    output wire [0:0]  video_tuser,
`endif
`else
    output wire [2:0]  video_tuser,
`endif
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 VIDEO TREADY" *)
    input  wire        video_tready,
`endif
    output wire       cam0_mclk,
    output wire       cam0_pwdn,
    output wire       cam0_tri0,
    output wire       cam0_tri1,
    inout  wire       cam0_sda,
    inout  wire       cam0_scl,
    input  wire       cam0_clk_p,
    input  wire       cam0_clk_n,
    input  wire [3:0] cam0_data_p,
    input  wire [3:0] cam0_data_n
);
    localparam integer I2C_HALF_DIV = 485;
    localparam integer START_DELAY  = 2_000_000;
    localparam integer WAKE_DELAY   = 200_000;
    localparam integer NUM_REGS     = 108;

`ifndef CAM0_FRONTEND
    wire pl_clk;
    wire pl_resetn0;
    wire [94:0] emio_gpio_i;
    wire [94:0] emio_gpio_o_unused;
    wire [94:0] emio_gpio_t_unused;
    ps_clk u_ps (
        .pl_clk0(pl_clk), .pl_resetn0(pl_resetn0),
        .emio_gpio_i(emio_gpio_i),
        .emio_gpio_o(emio_gpio_o_unused),
        .emio_gpio_t(emio_gpio_t_unused)
    );
`endif

    wire clk200;
    wire clk200_locked;
    wire ref_locked = clk200_locked;
    wire clocks_locked;
    dphy_ref_clock u_dphy_ref_clock (
      .clk_in1(pl_clk), .clk_out1(clk200), .reset(1'b0),
      .locked(clk200_locked)
    );

    // CSI RX v6.0 on this UltraScale+ device synthesizes C_PLL_SHARING=1.
    // The HSSIO requires a real 1 GHz CLKOUTPHY and its PLL LOCKED signal.
    wire phy_clkout;
    wire phy_pll_locked;
    wire phy_clkfb;
    wire phy_clk200_unused;
    PLLE3_BASE #(
        .STARTUP_WAIT("FALSE"),
        .DIVCLK_DIVIDE(1),
        .CLKFBOUT_MULT(5),
        .CLKFBOUT_PHASE(0.000),
        .CLKOUT0_DIVIDE(5),
        .CLKOUT0_PHASE(0.000),
        .CLKOUT0_DUTY_CYCLE(0.500),
        .CLKIN_PERIOD(5.000),
        .CLKOUTPHY_MODE("VCO")
    ) u_phy_pll (
        .CLKFBOUT(phy_clkfb), .CLKFBIN(phy_clkfb),
        .CLKOUT0(phy_clk200_unused), .CLKOUTPHY(phy_clkout),
        .CLKOUTPHYEN(1'b1), .LOCKED(phy_pll_locked),
        .CLKIN(clk200), .PWRDWN(1'b0), .RST(1'b0)
    );
    assign clocks_locked = clk200_locked && phy_pll_locked;

    reg [2:0] mclk_div = 0;
    reg mclk_enable = 0;
    reg pwdn = 1;
    reg [22:0] startup_count = 0;
    reg start_i2c = 0;
    always @(posedge pl_clk) begin
        mclk_div <= mclk_div + 1'b1;
        start_i2c <= 1'b0;
        if (startup_count < START_DELAY + WAKE_DELAY + WAKE_DELAY)
            startup_count <= startup_count + 1'b1;
        if (startup_count == START_DELAY) mclk_enable <= 1'b1;
        if (startup_count == START_DELAY + WAKE_DELAY) pwdn <= 1'b0;
        if (startup_count == START_DELAY + WAKE_DELAY + WAKE_DELAY - 1)
            start_i2c <= 1'b1;
    end
    // Runtime PL0 is switched to the locked IOPLL at 100 MHz, so XCLK=25 MHz.
    assign cam0_mclk = mclk_enable ? mclk_div[1] : 1'b0;
    assign cam0_pwdn = pwdn;
    assign cam0_tri0 = trigger0;
    assign cam0_tri1 = 1'b0;

    function automatic [15:0] sensor_addr(input [6:0] n);
        case (n)
          0: sensor_addr=16'h0103; 1: sensor_addr=16'h0100; 2: sensor_addr=16'h3039; 3: sensor_addr=16'h3034;
          4: sensor_addr=16'h3001; 5: sensor_addr=16'h3018; 6: sensor_addr=16'h3019; 7: sensor_addr=16'h301f;
          8: sensor_addr=16'h3022; 9: sensor_addr=16'h302b; 10:sensor_addr=16'h3030; 11:sensor_addr=16'h3000;
          12:sensor_addr=16'h3031; 13:sensor_addr=16'h3035; 14:sensor_addr=16'h3036; 15:sensor_addr=16'h3038;
          16:sensor_addr=16'h303a; 17:sensor_addr=16'h303b; 18:sensor_addr=16'h303c; 19:sensor_addr=16'h303d;
          20:sensor_addr=16'h303f; 21:sensor_addr=16'h3202; 22:sensor_addr=16'h3203; 23:sensor_addr=16'h3205;
          24:sensor_addr=16'h3206; 25:sensor_addr=16'h3207; 26:sensor_addr=16'h320a; 27:sensor_addr=16'h320b;
          28:sensor_addr=16'h320c; 29:sensor_addr=16'h320d; 30:sensor_addr=16'h320e; 31:sensor_addr=16'h320f;
          32:sensor_addr=16'h3211; 33:sensor_addr=16'h3213; 34:sensor_addr=16'h3300; 35:sensor_addr=16'h3302;
          36:sensor_addr=16'h3306; 37:sensor_addr=16'h3308; 38:sensor_addr=16'h330a; 39:sensor_addr=16'h330b;
          40:sensor_addr=16'h330e; 41:sensor_addr=16'h3310; 42:sensor_addr=16'h3311; 43:sensor_addr=16'h3319;
          44:sensor_addr=16'h3333; 45:sensor_addr=16'h3334; 46:sensor_addr=16'h3348; 47:sensor_addr=16'h3349;
          48:sensor_addr=16'h334a; 49:sensor_addr=16'h334b; 50:sensor_addr=16'h335d; 51:sensor_addr=16'h3380;
          52:sensor_addr=16'h3382; 53:sensor_addr=16'h3383; 54:sensor_addr=16'h3384; 55:sensor_addr=16'h3400;
          56:sensor_addr=16'h3416; 57:sensor_addr=16'h3518; 58:sensor_addr=16'h3519; 59:sensor_addr=16'h3620;
          60:sensor_addr=16'h3621; 61:sensor_addr=16'h3622; 62:sensor_addr=16'h3623; 63:sensor_addr=16'h3624;
          64:sensor_addr=16'h3625; 65:sensor_addr=16'h3626; 66:sensor_addr=16'h3627; 67:sensor_addr=16'h3630;
          68:sensor_addr=16'h3632; 69:sensor_addr=16'h3633; 70:sensor_addr=16'h3634; 71:sensor_addr=16'h3635;
          72:sensor_addr=16'h3638; 73:sensor_addr=16'h3639; 74:sensor_addr=16'h363a; 75:sensor_addr=16'h363b;
          76:sensor_addr=16'h3640; 77:sensor_addr=16'h3658; 78:sensor_addr=16'h3663; 79:sensor_addr=16'h3664;
          80:sensor_addr=16'h3c00; 81:sensor_addr=16'h3d08; 82:sensor_addr=16'h3e01; 83:sensor_addr=16'h3e02;
          84:sensor_addr=16'h3e03; 85:sensor_addr=16'h3e08; 86:sensor_addr=16'h3e09; 87:sensor_addr=16'h3e0e;
          88:sensor_addr=16'h3e0f; 89:sensor_addr=16'h3e14; 90:sensor_addr=16'h3f08; 91:sensor_addr=16'h4501;
          92:sensor_addr=16'h4502; 93:sensor_addr=16'h5000; 94:sensor_addr=16'h5b00; 95:sensor_addr=16'h5b01;
          96:sensor_addr=16'h5b02; 97:sensor_addr=16'h5b03; 98:sensor_addr=16'h3039; 99:sensor_addr=16'h3034;
          100:sensor_addr=16'h320e; 101:sensor_addr=16'h320f;
          102:sensor_addr=16'h3e01; 103:sensor_addr=16'h3e02;
          104:sensor_addr=16'h3218; 105:sensor_addr=16'h3219;
          106:sensor_addr=16'h3234; 107:sensor_addr=16'h0100;
          default:sensor_addr=16'h0100;
        endcase
    endfunction
    function automatic [7:0] sensor_data(input [6:0] n);
        case (n)
          0:sensor_data=8'h01; 1:sensor_data=8'h00; 2:sensor_data=8'h80; 3:sensor_data=8'h80;
          4:sensor_data=8'h00; 5:sensor_data=8'h70; 6:sensor_data=8'h00; 7:sensor_data=8'h17;
          8:sensor_data=8'h10; 9:sensor_data=8'h80; 10:sensor_data=8'h01;11:sensor_data=8'h00;
          12:sensor_data=8'h0a;13:sensor_data=8'h2a;14:sensor_data=8'h00;15:sensor_data=8'h4b;
          16:sensor_data=8'h35;17:sensor_data=8'h0e;18:sensor_data=8'h06;19:sensor_data=8'h03;
          20:sensor_data=8'h11;21:sensor_data=8'h00;22:sensor_data=8'h00;23:sensor_data=8'h8b;
          24:sensor_data=8'h02;25:sensor_data=8'h04;26:sensor_data=8'h04;27:sensor_data=8'h00;
          28:sensor_data=8'h03;29:sensor_data=8'h0c;30:sensor_data=8'h02;31:sensor_data=8'h53;
          32:sensor_data=8'h0c;33:sensor_data=8'h04;34:sensor_data=8'h20;35:sensor_data=8'h0c;
          36:sensor_data=8'h48;37:sensor_data=8'h50;38:sensor_data=8'h01;39:sensor_data=8'h20;
          40:sensor_data=8'h1a;41:sensor_data=8'hf0;42:sensor_data=8'h10;43:sensor_data=8'he8;
          44:sensor_data=8'h90;45:sensor_data=8'h30;46:sensor_data=8'h02;47:sensor_data=8'hee;
          48:sensor_data=8'h02;49:sensor_data=8'he0;50:sensor_data=8'h00;51:sensor_data=8'hff;
          52:sensor_data=8'he0;53:sensor_data=8'h0a;54:sensor_data=8'he4;55:sensor_data=8'h53;
          56:sensor_data=8'h31;57:sensor_data=8'h07;58:sensor_data=8'hc8;59:sensor_data=8'h24;
          60:sensor_data=8'h0a;61:sensor_data=8'h06;62:sensor_data=8'h14;63:sensor_data=8'h20;
          64:sensor_data=8'h00;65:sensor_data=8'h00;66:sensor_data=8'h01;67:sensor_data=8'h63;
          68:sensor_data=8'h74;69:sensor_data=8'h63;70:sensor_data=8'hff;71:sensor_data=8'h44;
          72:sensor_data=8'h82;73:sensor_data=8'h74;74:sensor_data=8'h24;75:sensor_data=8'h00;
          76:sensor_data=8'h03;77:sensor_data=8'h9a;78:sensor_data=8'h88;79:sensor_data=8'h06;
          80:sensor_data=8'h41;81:sensor_data=8'h00;82:sensor_data=8'h24;83:sensor_data=8'hf0;
          84:sensor_data=8'h0b;85:sensor_data=8'h06;86:sensor_data=8'h20;87:sensor_data=8'h00;
          88:sensor_data=8'h15;89:sensor_data=8'hb0;90:sensor_data=8'h04;91:sensor_data=8'hc0;
          92:sensor_data=8'h16;93:sensor_data=8'h01;94:sensor_data=8'h02;95:sensor_data=8'h03;
          96:sensor_data=8'h01;97:sensor_data=8'h01;98:sensor_data=8'h53;99:sensor_data=8'h0d;
          // 7020-qualified Master-mode starting values. BZ-10 uses a
          // different 25-MHz MCLK, so hardware image qualification is still
          // required before considering 240 fps valid here.
          100:sensor_data=8'h02; 101:sensor_data=8'h0f;
          102:sensor_data=8'h20; 103:sensor_data=8'h50;
          104:sensor_data=8'h00; 105:sensor_data=8'h44;
          106:sensor_data=8'hb0; 107:sensor_data=8'h01;
          default:sensor_data=8'h00;
        endcase
    endfunction
    reg scl_low=0, sda_low=0;
    wire scl_in=cam0_scl, sda_in=cam0_sda;
    assign cam0_scl=scl_low?1'b0:1'bz;
    assign cam0_sda=sda_low?1'b0:1'bz;
    reg [9:0] i2c_div=0;
    wire i2c_tick=(i2c_div==I2C_HALF_DIV-1);
    always @(posedge pl_clk) i2c_div <= i2c_tick ? 0 : i2c_div+1'b1;

    localparam [3:0] I_IDLE=0,I_START_A=1,I_START_B=2,I_TX_LOW=3,I_TX_HIGH=4,
      I_ACK_LOW=5,I_ACK_HIGH=6,I_STOP_A=7,I_STOP_B=8,I_STOP_C=9,I_GAP=10,I_DONE=11;
    reg [3:0] i_state=I_IDLE;
    reg [2:0] bit_index=7;
    reg [2:0] byte_phase=0;
    reg [7:0] tx_byte=0;
    reg [6:0] reg_index=0;
    wire [15:0] current_sensor_addr = sensor_addr(reg_index);
    reg [10:0] gap_ticks=0;
    reg [7:0] nack_count=0;
    reg sensor_done=0;
    always @(posedge pl_clk) begin
      if (start_i2c && i_state==I_IDLE) begin
        reg_index<=0; byte_phase<=0; tx_byte<=8'h60; bit_index<=7;
        nack_count<=0; sensor_done<=0; i_state<=I_START_A;
      end else if (i2c_tick) case(i_state)
        I_IDLE: begin scl_low<=0; sda_low<=0; end
        I_START_A: begin scl_low<=0;sda_low<=0;i_state<=I_START_B;end
        I_START_B: begin scl_low<=0;sda_low<=1;i_state<=I_TX_LOW;end
        I_TX_LOW: begin scl_low<=1;sda_low<=~tx_byte[bit_index];i_state<=I_TX_HIGH;end
        I_TX_HIGH: begin scl_low<=0;if(bit_index==0)i_state<=I_ACK_LOW;else begin bit_index<=bit_index-1'b1;i_state<=I_TX_LOW;end end
        I_ACK_LOW: begin scl_low<=1;sda_low<=0;i_state<=I_ACK_HIGH;end
        I_ACK_HIGH: begin
          scl_low<=0;if(sda_in && nack_count!=8'hff)nack_count<=nack_count+1'b1;bit_index<=7;
          case(byte_phase)
            0:begin byte_phase<=1;tx_byte<=current_sensor_addr[15:8];i_state<=I_TX_LOW;end
            1:begin byte_phase<=2;tx_byte<=current_sensor_addr[7:0];i_state<=I_TX_LOW;end
            2:begin byte_phase<=3;tx_byte<=sensor_data(reg_index);i_state<=I_TX_LOW;end
            default:i_state<=I_STOP_A;
          endcase
        end
        I_STOP_A:begin scl_low<=1;sda_low<=1;i_state<=I_STOP_B;end
        I_STOP_B:begin scl_low<=0;sda_low<=1;i_state<=I_STOP_C;end
        I_STOP_C:begin scl_low<=0;sda_low<=0;gap_ticks<=0;i_state<=I_GAP;end
        I_GAP:begin
          if(gap_ticks >= ((reg_index==0)?1100:2)) begin
            if(reg_index==NUM_REGS-1)begin sensor_done<=1;i_state<=I_DONE;end
            else begin reg_index<=reg_index+1'b1;byte_phase<=0;tx_byte<=8'h60;bit_index<=7;i_state<=I_START_A;end
          end else gap_ticks<=gap_ticks+1'b1;
        end
        I_DONE:begin scl_low<=0;sda_low<=0;end
        default:i_state<=I_IDLE;
      endcase
    end

    // AXI-Lite write sequencer: reset controller, select four lanes, enable.
    reg [3:0] ax_state=0;
    reg [7:0] awaddr=0;
    reg [31:0] wdata=0;
    reg awvalid=0,wvalid=0,bready=0;
    reg aw_done=0,w_done=0;
    reg [9:0] ax_wait=0;
    reg axi_done=0;
    wire awready,wready,bvalid;
    wire [1:0] bresp;
    always @(posedge clk200) begin
      if(!clocks_locked) begin ax_state<=0;awvalid<=0;wvalid<=0;bready<=0;aw_done<=0;w_done<=0;ax_wait<=0;axi_done<=0;end
      else case(ax_state)
        0:begin if(ax_wait==500)begin awaddr<=8'h00;wdata<=32'h2;awvalid<=1;wvalid<=1;aw_done<=0;w_done<=0;ax_state<=1;end else ax_wait<=ax_wait+1'b1;end
        1:begin
          if(awvalid&&awready)begin awvalid<=0;aw_done<=1;end
          if(wvalid&&wready)begin wvalid<=0;w_done<=1;end
          if((aw_done||awready)&&(w_done||wready))begin bready<=1;ax_state<=2;end
        end
        2:if(bvalid)begin bready<=0;ax_wait<=0;ax_state<=3;end
        3:begin if(ax_wait==200)begin awaddr<=8'h04;wdata<=32'h3;awvalid<=1;wvalid<=1;aw_done<=0;w_done<=0;ax_state<=4;end else ax_wait<=ax_wait+1'b1;end
        4:begin
          if(awvalid&&awready)begin awvalid<=0;aw_done<=1;end
          if(wvalid&&wready)begin wvalid<=0;w_done<=1;end
          if((aw_done||awready)&&(w_done||wready))begin bready<=1;ax_state<=5;end
        end
        5:if(bvalid)begin bready<=0;awaddr<=8'h00;wdata<=32'h1;awvalid<=1;wvalid<=1;aw_done<=0;w_done<=0;ax_state<=6;end
        6:begin
          if(awvalid&&awready)begin awvalid<=0;aw_done<=1;end
          if(wvalid&&wready)begin wvalid<=0;w_done<=1;end
          if((aw_done||awready)&&(w_done||wready))begin bready<=1;ax_state<=7;end
        end
        7:if(bvalid)begin bready<=0;axi_done<=1;ax_state<=8;end
        default:;
      endcase
    end

`ifdef CAM0_DIRECT40
    wire [39:0] axis_data;
`else
    wire [23:0] axis_data;
`endif
    wire [9:0] axis_dest;
    wire axis_last,axis_valid;
    wire [0:0] axis_user;
`ifdef CAM0_FRONTEND
    reg capture_active = 1'b0;
    // Ignore the running camera stream until software has armed VDMA.  Open
    // only on a real SOF beat, so the first forwarded beat starts a frame.
    wire forward_video = capture_active || (capture_enable && axis_user[0]);
    wire axis_ready = forward_video ? video_tready : 1'b1;
    always @(posedge clk200) begin
      if (!clocks_locked || !capture_enable)
        capture_active <= 1'b0;
      else if (axis_valid && axis_user[0] && axis_ready)
        capture_active <= 1'b1;
    end
`ifdef CAM0_STREAM
    // Count only SOFs actually forwarded to VDMA. Gray-code crossing keeps
    // the PS-visible count coherent across the 200/100 MHz clock boundary.
    reg [31:0] stream_sof_bin = 0;
    wire [31:0] stream_sof_gray = stream_sof_bin ^ (stream_sof_bin >> 1);
    (* ASYNC_REG = "TRUE" *) reg [31:0] stream_gray_meta = 0;
    (* ASYNC_REG = "TRUE" *) reg [31:0] stream_gray_sync = 0;
    reg [31:0] stream_sof_decoded;
    integer stream_bit;
    always @(posedge clk200) begin
      if (!clocks_locked)
        stream_sof_bin <= 0;
      else if (axis_valid && axis_ready && axis_user[0] && forward_video)
        stream_sof_bin <= stream_sof_bin + 1'b1;
    end
    always @(posedge pl_clk) begin
      stream_gray_meta <= stream_sof_gray;
      stream_gray_sync <= stream_gray_meta;
    end
    always @* begin
      stream_sof_decoded[31] = stream_gray_sync[31];
      for (stream_bit = 30; stream_bit >= 0; stream_bit = stream_bit - 1)
        stream_sof_decoded[stream_bit] =
          stream_sof_decoded[stream_bit + 1] ^ stream_gray_sync[stream_bit];
    end
    assign stream_sof_count = stream_sof_decoded;
`endif
`else
    wire axis_ready = 1'b1;
`endif
    wire csi_irq;
    cam0_csi u_csi (
      .lite_aclk(clk200),.lite_aresetn(clocks_locked),.dphy_clk_200M(clk200),.rxbyteclkhs(),
      .clkoutphy_in(phy_clkout),.pll_lock_in(phy_pll_locked),.csirxss_csi_irq(csi_irq),
      .video_aclk(clk200),.video_aresetn(clocks_locked),
      .csirxss_s_axi_araddr(8'b0),.csirxss_s_axi_arready(),.csirxss_s_axi_arvalid(1'b0),
      .csirxss_s_axi_awaddr(awaddr),.csirxss_s_axi_awready(awready),.csirxss_s_axi_awvalid(awvalid),
      .csirxss_s_axi_bready(bready),.csirxss_s_axi_bresp(bresp),.csirxss_s_axi_bvalid(bvalid),
      .csirxss_s_axi_rdata(),.csirxss_s_axi_rready(1'b1),.csirxss_s_axi_rresp(),.csirxss_s_axi_rvalid(),
      .csirxss_s_axi_wdata(wdata),.csirxss_s_axi_wready(wready),.csirxss_s_axi_wstrb(4'hf),.csirxss_s_axi_wvalid(wvalid),
      .video_out_tdata(axis_data),.video_out_tdest(axis_dest),.video_out_tlast(axis_last),
      .video_out_tready(axis_ready),.video_out_tuser(axis_user),.video_out_tvalid(axis_valid),
      .mipi_phy_if_clk_n(cam0_clk_n),.mipi_phy_if_clk_p(cam0_clk_p),
      .mipi_phy_if_data_n(cam0_data_n),.mipi_phy_if_data_p(cam0_data_p)
    );

    reg [31:0] beat_count=0,line_count=0;
    reg [2:0] frame_count=0;
    always @(posedge clk200) if(clocks_locked && axis_valid && axis_ready) begin
      beat_count<=beat_count+1'b1;
      if(axis_last) line_count<=line_count+1'b1;
      if(axis_user[0]) frame_count<=frame_count+1'b1;
    end
    wire sensor_busy=(i_state!=I_IDLE && i_state!=I_DONE);
    // The leading zero makes the 31-bit EMIO bank layout explicit.
    // flags: PS PL reset release, ref clock lock, sensor done, sensor busy.
    wire [30:0] status_hi={pl_resetn0,7'h5a,ref_locked,sensor_done,sensor_busy,phy_pll_locked,nack_count,reg_index,axi_done,frame_count};
    assign emio_gpio_i={status_hi,line_count,beat_count};
`ifdef CAM0_FRONTEND
    assign video_tdata = axis_data;
    assign video_clk200 = clk200;
    assign video_resetn = clocks_locked;
`ifndef CAM0_DIRECT40
    assign video_tkeep = 3'b111;
`endif
    assign video_tlast = axis_last;
    assign video_tvalid = axis_valid && forward_video;
    // Width converter carries one TUSER bit per input byte.  SOF is bit 0;
    // the other two byte positions carry no sideband information.
`ifdef CAM0_DIRECT40
`ifdef CAM0_USER5
    assign video_tuser = {4'b0000, axis_user};
`else
    assign video_tuser = axis_user;
`endif
`else
    assign video_tuser = {2'b00, axis_user};
`endif
`endif
endmodule
