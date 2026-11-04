// Hardware-timed SC130GS Trigger0 scheduler for external-trigger Master mode.
// Linux presents a stable period/count and toggles start_toggle once.  All
// frame-to-frame timing then stays in PL.
module sc130gs_trigger_pulse #(
    parameter integer CLK_PER_US = 100,
    parameter integer PULSE_US   = 100
) (
    input  wire        clk,
    input  wire        resetn,
    input  wire        arm_async,
    input  wire        start_toggle_async,
    input  wire [15:0] period_us_async,
    input  wire [13:0] frame_count_async,
    output reg         trigger0,
    output reg         frame_odd,
    output reg         run_start_toggle,
    output wire [31:0] debug_status
);
    localparam integer PULSE_CYCLES = CLK_PER_US * PULSE_US;
    localparam [13:0] CONTINUOUS_FRAMES = 14'h3fff;

    (* ASYNC_REG = "TRUE" *) reg arm_meta;
    (* ASYNC_REG = "TRUE" *) reg arm_sync;
    (* ASYNC_REG = "TRUE" *) reg start_meta;
    (* ASYNC_REG = "TRUE" *) reg start_sync;
    // GPIO data is held stable around the toggle.  Synchronize both buses,
    // then latch them once when the synchronized toggle is observed.
    (* ASYNC_REG = "TRUE" *) reg [15:0] period_us_meta;
    (* ASYNC_REG = "TRUE" *) reg [15:0] period_us_sync;
    (* ASYNC_REG = "TRUE" *) reg [13:0] frame_count_meta;
    (* ASYNC_REG = "TRUE" *) reg [13:0] frame_count_sync;
    reg start_seen;
    reg done_toggle;
    reg busy;
    reg continuous;
    reg [31:0] period_cycles_left;
    reg [31:0] period_cycles_reload;
    reg [31:0] pulse_cycles_left;
    reg [13:0] frames_left;
    reg [13:0] frames_issued;

    // [31] busy, [30] live Trigger0, [29] completion toggle,
    // [28] continuous, [27:14] pulses issued, [13:0] pulses remaining.
    assign debug_status = {busy, trigger0, done_toggle, continuous,
                           frames_issued, frames_left};

    always @(posedge clk) begin
        if (!resetn) begin
            arm_meta           <= 1'b0;
            arm_sync           <= 1'b0;
            start_meta         <= 1'b0;
            start_sync         <= 1'b0;
            start_seen         <= 1'b0;
            period_us_meta     <= 16'd0;
            period_us_sync     <= 16'd0;
            frame_count_meta   <= 14'd0;
            frame_count_sync   <= 14'd0;
            done_toggle        <= 1'b0;
            busy               <= 1'b0;
            continuous         <= 1'b0;
            trigger0           <= 1'b0;
            frame_odd          <= 1'b0;
            run_start_toggle   <= 1'b0;
            period_cycles_left <= 32'd0;
            period_cycles_reload <= 32'd0;
            pulse_cycles_left  <= 32'd0;
            frames_left        <= 14'd0;
            frames_issued      <= 14'd0;
        end else begin
            arm_meta   <= arm_async;
            arm_sync   <= arm_meta;
            start_meta <= start_toggle_async;
            start_sync <= start_meta;
            period_us_meta   <= period_us_async;
            period_us_sync   <= period_us_meta;
            frame_count_meta <= frame_count_async;
            frame_count_sync <= frame_count_meta;

            if (start_sync != start_seen) begin
                start_seen <= start_sync;
                if (arm_sync && frame_count_sync != 0 &&
                    period_us_sync > PULSE_US) begin
                    busy               <= 1'b1;
                    continuous         <= frame_count_sync == CONTINUOUS_FRAMES;
                    trigger0           <= 1'b1;
                    // First trigger of every run is odd. This level stays
                    // stable for the full exposure/readout interval.
                    frame_odd          <= 1'b1;
                    run_start_toggle   <= ~run_start_toggle;
                    pulse_cycles_left  <= PULSE_CYCLES;
                    period_cycles_left <= period_us_sync * CLK_PER_US;
                    period_cycles_reload <= period_us_sync * CLK_PER_US;
                    // Direct Ethernet has no VDMA commit latency: issue
                    // exactly the requested number of sensor triggers.
                    frames_left        <= frame_count_sync == CONTINUOUS_FRAMES ?
                                          CONTINUOUS_FRAMES :
                                          frame_count_sync - 1'b1;
                    frames_issued      <= 14'd1;
                end
            end else if (busy) begin
                if (!arm_sync) begin
                    busy              <= 1'b0;
                    continuous        <= 1'b0;
                    trigger0          <= 1'b0;
                    frame_odd         <= 1'b0;
                    pulse_cycles_left <= 32'd0;
                    frames_left       <= 14'd0;
                end else begin
                    if (pulse_cycles_left != 0) begin
                        pulse_cycles_left <= pulse_cycles_left - 1'b1;
                        if (pulse_cycles_left == 1)
                            trigger0 <= 1'b0;
                    end

                    if (period_cycles_left <= 1) begin
                        if (continuous) begin
                            period_cycles_left <= period_cycles_reload;
                            pulse_cycles_left  <= PULSE_CYCLES;
                            frames_left        <= CONTINUOUS_FRAMES;
                            frames_issued      <= frames_issued + 1'b1;
                            trigger0           <= 1'b1;
                            frame_odd          <= ~frame_odd;
                        end else if (frames_left == 0) begin
                            busy               <= 1'b0;
                            trigger0           <= 1'b0;
                            frame_odd          <= 1'b0;
                            pulse_cycles_left  <= 32'd0;
                            period_cycles_left <= 32'd0;
                            frames_left        <= 14'd0;
                            done_toggle        <= ~done_toggle;
                        end else begin
                            period_cycles_left <= period_cycles_reload;
                            pulse_cycles_left  <= PULSE_CYCLES;
                            frames_left        <= frames_left - 1'b1;
                            frames_issued      <= frames_issued + 1'b1;
                            trigger0           <= 1'b1;
                            frame_odd          <= ~frame_odd;
                        end
                    end else begin
                        period_cycles_left <= period_cycles_left - 1'b1;
                    end
                end
            end
        end
    end
endmodule
