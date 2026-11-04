`timescale 1ns/1ps
module tb_trigger;
    reg clk = 0;
    reg resetn = 0;
    reg arm = 0;
    reg start_toggle = 0;
    reg [15:0] period = 16'd5;
    reg [13:0] frames = 14'd3;
    wire trigger0;
    wire frame_odd;
    wire run_start_toggle;
    wire [31:0] status;
    integer rises = 0;
    integer run_rises = 0;
    integer starts = 0;

    always #5 clk = ~clk;
    always @(posedge trigger0) begin
        rises = rises + 1;
        run_rises = run_rises + 1;
        #1;
        if (frame_odd !== run_rises[0])
            $fatal(1, "frame parity mismatch: frame=%0d odd=%b", run_rises, frame_odd);
    end
    always @(run_start_toggle) if (resetn) starts = starts + 1;

    sc130gs_trigger_pulse #(.CLK_PER_US(1), .PULSE_US(1)) dut (
        .clk(clk), .resetn(resetn), .arm_async(arm),
        .start_toggle_async(start_toggle), .period_us_async(period),
        .frame_count_async(frames), .trigger0(trigger0), .frame_odd(frame_odd),
        .run_start_toggle(run_start_toggle),
        .debug_status(status)
    );

    initial begin
        repeat (5) @(negedge clk);
        resetn = 1;
        arm = 1;
        repeat (5) @(negedge clk);
        start_toggle = 1;
        repeat (40) @(negedge clk);
        if (rises != 3 || starts != 1 || status[31] || status[27:14] != 3 || frame_odd)
            $fatal(1, "finite count wrong: rises=%0d status=%08x", rises, status);

        arm = 0;
        repeat (5) @(negedge clk);
        run_rises = 0;
        frames = 14'h3fff;
        arm = 1;
        repeat (5) @(negedge clk);
        start_toggle = 0;
        repeat (75) @(negedge clk);
        if (rises < 12 || !status[31] || !status[28])
            $fatal(1, "continuous run failed: rises=%0d status=%08x", rises, status);
        // A fresh start while still armed must restart at odd/high.
        run_rises = 0;
        start_toggle = 1;
        repeat (10) @(negedge clk);
        if (run_rises < 1 || starts != 3 || !status[31])
            $fatal(1, "continuous restart failed: rises=%0d status=%08x", run_rises, status);
        arm = 0;
        repeat (5) @(negedge clk);
        if (status[31] || trigger0 || frame_odd)
            $fatal(1, "disarm failed: status=%08x", status);
        $display("PASS: finite 3 + continuous + stop, total rises=%0d", rises);
        $finish;
    end
endmodule
