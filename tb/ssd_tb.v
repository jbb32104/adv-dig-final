`timescale 1ns / 1ps
// Self-checking testbench for ssd.v
// Tests: reset state, each hex digit 0-F decodes correctly, anode scan
//        sequence, decimal point control, digit ordering (MSB left / LSB right).
//
// REFRESH_RATE=4 keeps the scan period short (100/4 = 25 cycles per digit slot).
//
// Compile: iverilog -g2001 -o sim\ssd_tb.vvp rtl\ssd.v tb\ssd_tb.v
// Run:     vvp sim\ssd_tb.vvp

module ssd_tb;

    // -----------------------------------------------------------------------
    // Parameters — fast refresh for simulation
    // -----------------------------------------------------------------------
    parameter CLK_FREQ_HZ  = 100;
    parameter REFRESH_RATE = 4;     // 100/4 = 25 cycles per digit slot

    localparam CYCLES_PER_DIGIT = CLK_FREQ_HZ / REFRESH_RATE;  // 25

    // -----------------------------------------------------------------------
    // Clock
    // -----------------------------------------------------------------------
    reg clk;
    reg rst;
    initial clk = 0;
    always #5 clk = ~clk;

    // -----------------------------------------------------------------------
    // DUT signals
    // -----------------------------------------------------------------------
    reg  [31:0] value;
    reg  [7:0]  dp_en;
    wire [6:0]  SEG;
    wire [7:0]  AN;
    wire        DP_n;

    // -----------------------------------------------------------------------
    // DUT
    // -----------------------------------------------------------------------
    ssd #(
        .CLK_FREQ_HZ (CLK_FREQ_HZ),
        .REFRESH_RATE(REFRESH_RATE)
    ) u_dut (
        .clk  (clk),
        .rst  (rst),
        .value(value),
        .dp_en(dp_en),
        .SEG  (SEG),
        .AN   (AN),
        .DP_n (DP_n)
    );

    // -----------------------------------------------------------------------
    // Expected segment patterns (active-high: 1 = segment ON)
    // SEG[6:0] = {g,f,e,d,c,b,a}
    // -----------------------------------------------------------------------
    function [6:0] expected_seg_active_high;
        input [3:0] nibble;
        begin
            case (nibble)
                4'h0: expected_seg_active_high = 7'b0111111;
                4'h1: expected_seg_active_high = 7'b0000110;
                4'h2: expected_seg_active_high = 7'b1011011;
                4'h3: expected_seg_active_high = 7'b1001111;
                4'h4: expected_seg_active_high = 7'b1100110;
                4'h5: expected_seg_active_high = 7'b1101101;
                4'h6: expected_seg_active_high = 7'b1111101;
                4'h7: expected_seg_active_high = 7'b0000111;
                4'h8: expected_seg_active_high = 7'b1111111;
                4'h9: expected_seg_active_high = 7'b1101111;
                4'hA: expected_seg_active_high = 7'b1110111;
                4'hB: expected_seg_active_high = 7'b1111100;
                4'hC: expected_seg_active_high = 7'b0111001;
                4'hD: expected_seg_active_high = 7'b1011110;
                4'hE: expected_seg_active_high = 7'b1111001;
                4'hF: expected_seg_active_high = 7'b1110001;
                default: expected_seg_active_high = 7'b0000000;
            endcase
        end
    endfunction

    // -----------------------------------------------------------------------
    // Error tracking
    // -----------------------------------------------------------------------
    integer error_count;
    initial error_count = 0;

    task check;
        input [255:0] name;
        input [31:0]  actual;
        input [31:0]  expected;
        begin
            if (actual !== expected) begin
                $display("FAIL: %0s -- got 0x%02h, expected 0x%02h at time %0t",
                         name, actual, expected, $time);
                error_count = error_count + 1;
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // Task: advance to the middle of a specific digit slot and sample outputs.
    // digit 0 = rightmost (LSB nibble), digit 7 = leftmost (MSB nibble).
    // Waits up to 8*CYCLES_PER_DIGIT for the anode to match.
    // -----------------------------------------------------------------------
    task wait_for_digit;
        input [2:0]  target_digit;
        output [6:0] seg_out;
        output       dp_out;
        integer      watchdog;
        begin
            watchdog = 0;
            @(posedge clk); #1;
            while (AN !== ~(8'h01 << target_digit) && watchdog < 8*CYCLES_PER_DIGIT) begin
                @(posedge clk); #1;
                watchdog = watchdog + 1;
            end
            if (AN !== ~(8'h01 << target_digit)) begin
                $display("FAIL: digit %0d anode never asserted (AN=0x%02h)", target_digit, AN);
                error_count = error_count + 1;
            end
            seg_out = SEG;
            dp_out  = DP_n;
        end
    endtask

    // -----------------------------------------------------------------------
    // Temporaries
    // -----------------------------------------------------------------------
    integer i;
    reg [6:0] seg_got;
    reg       dp_got;
    reg [3:0] nibble_expected;
    reg [6:0] seg_expected_al; // active-low

    // -----------------------------------------------------------------------
    // Main test sequence
    // -----------------------------------------------------------------------
    initial begin
        $dumpfile("sim/ssd_tb.vcd");
        $dumpvars(0, ssd_tb);

        value = 32'h0;
        dp_en = 8'h0;

        // -------------------------------------------------------------------
        // Reset
        // -------------------------------------------------------------------
        rst = 1'b1;
        repeat(4) @(posedge clk);
        #1; // sample while rst still asserted

        // -------------------------------------------------------------------
        // Test A: Reset state — all segments and anodes off (active-low = 1)
        // Sample while rst=1 before the scan starts.
        // -------------------------------------------------------------------
        check("A: SEG all off during reset", {25'd0, SEG}, 32'h7F);
        check("A: AN  all off during reset", {24'd0, AN},  32'hFF);
        check("A: DP_n off during reset",    {31'd0, DP_n}, 32'h1);

        rst = 1'b0;
        repeat(2) @(posedge clk);

        // -------------------------------------------------------------------
        // Test B: All hex digits 0-F decode correctly
        // Drive value so digit 0 (rightmost) holds the nibble under test.
        // Wait for digit 0's anode to assert, then check SEG.
        // -------------------------------------------------------------------
        $display("--- B: hex decode 0-F ---");
        for (i = 0; i < 16; i = i + 1) begin : decode_loop
            reg [255:0] tname;
            value = i[31:0];    // nibble in bits [3:0], digit 0
            dp_en = 8'h0;

            wait_for_digit(3'd0, seg_got, dp_got);

            seg_expected_al = ~expected_seg_active_high(i[3:0]);
            if (seg_got !== seg_expected_al) begin
                $display("FAIL B: digit=%0h SEG=0x%02h expected=0x%02h",
                         i, seg_got, seg_expected_al);
                error_count = error_count + 1;
            end
        end
        $display("PASS B: all 16 hex digits decoded correctly");

        // -------------------------------------------------------------------
        // Test C: Anode scan visits all 8 digits in order 0..7
        // Set value=32'h76543210 so digit N shows nibble N.
        // Capture one full scan and verify each anode fires exactly once
        // and SEG matches the expected nibble for that digit.
        // -------------------------------------------------------------------
        $display("--- C: anode scan sequence ---");
        value = 32'h76543210;
        dp_en = 8'h0;

        for (i = 0; i < 8; i = i + 1) begin : scan_loop
            wait_for_digit(i[2:0], seg_got, dp_got);
            seg_expected_al = ~expected_seg_active_high(i[3:0]);
            if (seg_got !== seg_expected_al) begin
                $display("FAIL C: digit=%0d SEG=0x%02h expected=0x%02h",
                         i, seg_got, seg_expected_al);
                error_count = error_count + 1;
            end
            check("C: AN active-low correct", {24'd0, AN}, {24'd0, ~(8'h01 << i[2:0])});
        end
        $display("PASS C: all 8 anodes scanned in order with correct segments");

        // -------------------------------------------------------------------
        // Test D: Digit ordering — MSB in digit 7, LSB in digit 0
        // value=32'hABCDEF01: digit 0 = 1, digit 7 = A
        // -------------------------------------------------------------------
        $display("--- D: digit ordering MSB/LSB ---");
        value = 32'hABCDEF01;
        dp_en = 8'h0;

        // digit 0 → nibble 0x1
        wait_for_digit(3'd0, seg_got, dp_got);
        seg_expected_al = ~expected_seg_active_high(4'h1);
        check("D: digit0 = 0x1", {25'd0, seg_got}, {25'd0, seg_expected_al});

        // digit 7 → nibble 0xA
        wait_for_digit(3'd7, seg_got, dp_got);
        seg_expected_al = ~expected_seg_active_high(4'hA);
        check("D: digit7 = 0xA", {25'd0, seg_got}, {25'd0, seg_expected_al});
        $display("PASS D: MSB in digit 7, LSB in digit 0");

        // -------------------------------------------------------------------
        // Test E: Decimal point control
        // dp_en[3]=1 → DP_n=0 (on) for digit 3; all others DP_n=1 (off).
        // -------------------------------------------------------------------
        $display("--- E: decimal point ---");
        value = 32'h0;
        dp_en = 8'b00001000;    // only digit 3 has DP enabled

        // digit 3: DP should be on (DP_n = 0)
        wait_for_digit(3'd3, seg_got, dp_got);
        check("E: DP_n=0 for digit 3 (dp_en[3]=1)", {31'd0, dp_got}, 32'd0);

        // digit 2: DP should be off (DP_n = 1)
        wait_for_digit(3'd2, seg_got, dp_got);
        check("E: DP_n=1 for digit 2 (dp_en[2]=0)", {31'd0, dp_got}, 32'd1);
        $display("PASS E: decimal point active only for enabled digit");

        // -------------------------------------------------------------------
        // Final verdict
        // -------------------------------------------------------------------
        $display("---");
        if (error_count == 0)
            $display("ALL TESTS PASSED");
        else
            $display("FAILED: %0d errors", error_count);
        $finish;
    end

endmodule
