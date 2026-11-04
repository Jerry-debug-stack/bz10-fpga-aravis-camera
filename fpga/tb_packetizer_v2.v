`timescale 1ns/1ps
module tb_packetizer_v2;
    reg clk = 0;
    always #3.2 clk = ~clk;
    reg rst = 1, start_toggle = 0, send_enable = 0;
    wire s_ready, m_valid, m_last;
    wire [63:0] m_data;
    wire [7:0] m_keep;
    wire [31:0] errors, frames_sent;
    reg [31:0] cycles = 0;
    reg [31:0] source_word = 0, output_word = 0;
    wire s_valid = !rst && send_enable && source_word < 409600;
    wire [63:0] s_data = {32'hca00_0000, source_word};
    wire s_last = source_word % 200 == 199;
    wire s_user = source_word % 204800 == 0;
    wire m_ready = cycles % 11 != 0;

    camera_l2_live_packetizer dut (
        .clk(clk), .rst(rst), .run_start_toggle_async(start_toggle),
        .s_axis_tdata(s_data), .s_axis_tkeep(8'hff),
        .s_axis_tvalid(s_valid), .s_axis_tready(s_ready),
        .s_axis_tlast(s_last), .s_axis_tuser(s_user),
        .m_axis_tdata(m_data), .m_axis_tkeep(m_keep),
        .m_axis_tvalid(m_valid), .m_axis_tready(m_ready),
        .m_axis_tlast(m_last),
        .input_error_count(errors), .frames_sent(frames_sent)
    );

    reg [31:0] packet, frame, packet_in_frame, expected_frame_id;
    reg [31:0] expected_run_id, beat, offset, expected_count;
    reg [63:0] expected;
    always @(posedge clk) begin
        cycles <= cycles + 1;
        if (cycles > 2400000) $fatal(1, "timeout source=%0d output=%0d", source_word, output_word);
        if (s_valid && s_ready) source_word <= source_word + 1;
        if (!rst && m_valid && m_ready) begin
            packet = output_word / 134;
            frame = packet / 1600;
            expected_run_id = frame / 2 + 1;
            expected_frame_id = frame % 2 + 1;
            packet_in_frame = packet % 1600;
            beat = output_word % 134;
            offset = packet_in_frame << 10;
            expected_count = (packet % 3200) * 128 + beat - 6;
            case (beat)
                0: expected = 64'h0002_ffff_ffff_ffff;
                1: expected = 64'h5a42_b588_0400_0000;
                2: expected = 64'h0002_5741_524d_4143;
                3: expected = {offset[15:0], expected_frame_id, 16'h0000};
                4: expected = {16'h0400, 32'h0019_0000, offset[31:16]};
                5: expected = {expected_run_id, 16'h0400, 16'h0500};
                default: expected = {32'hca00_0000, expected_count};
            endcase
            if (m_data !== expected || m_keep !== 8'hff || m_last !== (beat == 133))
                $fatal(1, "packet=%0d beat=%0d got=%h expected=%h last=%b",
                       packet, beat, m_data, expected, m_last);
            output_word <= output_word + 1;
        end
        if (!rst && frames_sent == 4) begin
            if (errors != 0 || source_word != 409600 || output_word != 857600)
                $fatal(1, "completion source=%0d output=%0d errors=%0d",
                       source_word, output_word, errors);
            $display("PASS: two runs, frame IDs 1,2 per run, run IDs 1,2, 6400 packets");
            $finish;
        end
    end

    initial begin
        repeat (8) @(negedge clk);
        rst = 0;
        start_toggle = 1;
        repeat (8) @(negedge clk);
        send_enable = 1;
        wait (frames_sent == 2);
        @(negedge clk);
        send_enable = 0;
        repeat (12) @(negedge clk);
        source_word = 0;
        start_toggle = 0;
        repeat (8) @(negedge clk);
        send_enable = 1;
    end
endmodule
