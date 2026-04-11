`timescale 1ns / 1ps
// Self-checking testbench for debounce.v
// Tests: clean press/release, glitch rejection (shorter than DEBOUNCE_CYCLES),
//        glitch then valid press, rapid glitch burst, reset mid-press.
//
// DEBOUNCE_CYCLES=10 keeps simulation fast.
//
// Compile: iverilog -g2001 -o sim\debounce_tb.vvp rtl\debounce.v tb\debounce_tb.v
// Run:     vvp sim\debounce_tb.vvp

module debounce_tb;

    // -----------------------------------------------------------------------
    // Parameters
    // -----------------------------------------------------------------------
    parameter DEBOUNCE_CYCLES = 10;

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
    reg  btn_in;
    wire btn_state;
    wire rising_pulse;
    wire falling_pulse;

    // -----------------------------------------------------------------------
    // DUT instantiation
    // -----------------------------------------------------------------------
    debounce #(.DEBOUNCE_CYCLES(DEBOUNCE_CYCLES)) u_dut (
        .clk             (clk),
        .rst             (rst),
        .btn_in          (btn_in),
        .btn_state_ff    (btn_state),
        .rising_pulse_ff (rising_pulse),
        .falling_pulse_ff(falling_pulse)
    );

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
                $display("FAIL: %0s -- got %0d, expected %0d at time %0t",
                         name, actual, expected, $time);
                error_count = error_count + 1;
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // Task: hold btn_in at level for N cycles then sample outputs.
    // Sync to posedge first so btn_in is always set up well before the edge.
    // -----------------------------------------------------------------------
    task hold_input;
        input       level;
        input [31:0] cycles;
        integer j;
        begin
            @(posedge clk);
            btn_in = level;
            for (j = 0; j < cycles; j = j + 1)
                @(posedge clk);
        end
    endtask

    // -----------------------------------------------------------------------
    // Task: wait for a rising_pulse within max_cycles; fail on timeout.
    // Returns the cycle it was seen in found_at (0 = not found).
    // -----------------------------------------------------------------------
    integer timeout_ctr;

    task wait_rising;
        input [31:0] max_cycles;
        output       found;
        begin
            found       = 1'b0;
            timeout_ctr = 0;
            while (timeout_ctr < max_cycles) begin
                @(posedge clk); #1;
                timeout_ctr = timeout_ctr + 1;
                if (rising_pulse === 1'b1) begin
                    found = 1'b1;
                    timeout_ctr = max_cycles; // exit loop
                end
            end
        end
    endtask

    task wait_falling;
        input [31:0] max_cycles;
        output       found;
        begin
            found       = 1'b0;
            timeout_ctr = 0;
            while (timeout_ctr < max_cycles) begin
                @(posedge clk); #1;
                timeout_ctr = timeout_ctr + 1;
                if (falling_pulse === 1'b1) begin
                    found = 1'b1;
                    timeout_ctr = max_cycles;
                end
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // Temporaries
    // -----------------------------------------------------------------------
    reg found;
    integer i;
    integer rising_count;
    integer falling_count;

    // -----------------------------------------------------------------------
    // Monitor: count rising/falling pulses over a window to catch duplicates
    // -----------------------------------------------------------------------
    reg        mon_active;
    integer    mon_rising;
    integer    mon_falling;

    always @(posedge clk) begin
        if (mon_active) begin
            if (rising_pulse  === 1'b1) mon_rising  = mon_rising  + 1;
            if (falling_pulse === 1'b1) mon_falling = mon_falling + 1;
        end
    end

    // -----------------------------------------------------------------------
    // Main test sequence
    // -----------------------------------------------------------------------
    initial begin
        $dumpfile("sim/debounce_tb.vcd");
        $dumpvars(0, debounce_tb);

        btn_in      = 1'b0;
        mon_active  = 1'b0;
        mon_rising  = 0;
        mon_falling = 0;

        // Reset
        rst = 1'b1;
        repeat(4) @(posedge clk);
        rst = 1'b0;
        repeat(2) @(posedge clk);

        // Verify outputs are clean after reset
        #1;
        check("post-reset btn_state",    btn_state,    1'b0);
        check("post-reset rising_pulse", rising_pulse, 1'b0);

        // -------------------------------------------------------------------
        // Test A: Clean press
        // Hold btn_in high for DEBOUNCE_CYCLES cycles → exactly one
        // rising_pulse, btn_state goes high and stays high.
        // -------------------------------------------------------------------
        $display("--- A: clean press ---");
        mon_active  = 1'b1;
        mon_rising  = 0;
        mon_falling = 0;

        // Drive high for DEBOUNCE_CYCLES + a few extra to let filter settle
        hold_input(1'b1, DEBOUNCE_CYCLES + 5);
        #1;

        check("A: btn_state high after press",    btn_state,   1'b1);
        check("A: exactly one rising_pulse",      mon_rising,  32'd1);
        check("A: no spurious falling_pulse",     mon_falling, 32'd0);
        mon_active = 1'b0;

        // -------------------------------------------------------------------
        // Test B: Clean release
        // Hold btn_in low for DEBOUNCE_CYCLES → exactly one falling_pulse,
        // btn_state goes low.
        // -------------------------------------------------------------------
        $display("--- B: clean release ---");
        mon_active  = 1'b1;
        mon_rising  = 0;
        mon_falling = 0;

        hold_input(1'b0, DEBOUNCE_CYCLES + 5);
        #1;

        check("B: btn_state low after release",   btn_state,   1'b0);
        check("B: exactly one falling_pulse",     mon_falling, 32'd1);
        check("B: no spurious rising_pulse",      mon_rising,  32'd0);
        mon_active = 1'b0;

        // -------------------------------------------------------------------
        // Test C: Glitch rejection — pulse shorter than DEBOUNCE_CYCLES
        // Drive high for DEBOUNCE_CYCLES-2 cycles (just under threshold),
        // then back low. btn_state must stay 0, no rising_pulse.
        // -------------------------------------------------------------------
        $display("--- C: glitch rejection (short pulse) ---");
        mon_active  = 1'b1;
        mon_rising  = 0;
        mon_falling = 0;

        hold_input(1'b1, DEBOUNCE_CYCLES - 2);   // under threshold
        hold_input(1'b0, DEBOUNCE_CYCLES + 5);   // return and settle

        #1;
        check("C: btn_state still low (glitch rejected)", btn_state,   1'b0);
        check("C: no rising_pulse",                       mon_rising,  32'd0);
        check("C: no falling_pulse",                      mon_falling, 32'd0);
        mon_active = 1'b0;

        // -------------------------------------------------------------------
        // Test D: Glitch then valid press
        // Short glitch (rejected), then a full valid press.
        // Exactly one rising_pulse for the valid press only.
        // -------------------------------------------------------------------
        $display("--- D: glitch then valid press ---");
        mon_active  = 1'b1;
        mon_rising  = 0;
        mon_falling = 0;

        hold_input(1'b1, DEBOUNCE_CYCLES - 2);   // glitch (rejected)
        hold_input(1'b0, 3);                      // brief return to 0
        hold_input(1'b1, DEBOUNCE_CYCLES + 5);   // valid press

        #1;
        check("D: btn_state high after valid press", btn_state,  1'b1);
        check("D: exactly one rising_pulse",         mon_rising, 32'd1);
        mon_active = 1'b0;

        // Release so the next test starts from a known state
        hold_input(1'b0, DEBOUNCE_CYCLES + 5);

        // -------------------------------------------------------------------
        // Test E: Rapid glitch burst — 5 pulses each 2 cycles wide
        // None should cross threshold; btn_state stays 0, no pulses.
        // -------------------------------------------------------------------
        $display("--- E: rapid glitch burst ---");
        mon_active  = 1'b1;
        mon_rising  = 0;
        mon_falling = 0;

        for (i = 0; i < 5; i = i + 1) begin
            hold_input(1'b1, 2);
            hold_input(1'b0, 2);
        end
        // Settle
        hold_input(1'b0, DEBOUNCE_CYCLES + 5);
        #1;

        check("E: btn_state still low after burst", btn_state,   1'b0);
        check("E: no rising_pulse from burst",      mon_rising,  32'd0);
        check("E: no falling_pulse from burst",     mon_falling, 32'd0);
        mon_active = 1'b0;

        // -------------------------------------------------------------------
        // Test F: Reset mid-press clears state
        // Start a valid press, then assert rst before filter completes.
        // After reset, btn_state should be 0 and no pulses seen.
        // -------------------------------------------------------------------
        $display("--- F: reset mid-press ---");
        mon_active  = 1'b1;
        mon_rising  = 0;
        mon_falling = 0;

        // Drive high partway through filter window
        @(posedge clk);
        btn_in = 1'b1;
        repeat(DEBOUNCE_CYCLES / 2) @(posedge clk);

        // Assert reset
        rst = 1'b1;
        @(posedge clk);
        @(posedge clk);
        rst    = 1'b0;
        btn_in = 1'b0;
        repeat(2) @(posedge clk);
        #1;

        check("F: btn_state 0 after reset mid-press", btn_state,  1'b0);
        check("F: no rising_pulse after reset",       mon_rising, 32'd0);
        mon_active = 1'b0;

        // -------------------------------------------------------------------
        // Test G: Full press/release cycle — verify pulse widths are 1 cycle
        // Use wait_rising/wait_falling tasks with a tight timeout.
        // -------------------------------------------------------------------
        $display("--- G: pulse width = 1 cycle ---");

        // Press
        @(posedge clk);
        btn_in = 1'b1;
        wait_rising(DEBOUNCE_CYCLES + 10, found);
        if (!found) begin
            $display("FAIL G: rising_pulse never arrived");
            error_count = error_count + 1;
        end else begin
            // On the very next cycle, rising_pulse must be gone
            @(posedge clk); #1;
            check("G: rising_pulse deasserts after 1 cycle", rising_pulse, 1'b0);
            $display("PASS G: rising_pulse is 1 cycle wide");
        end

        // Release
        @(posedge clk);
        btn_in = 1'b0;
        wait_falling(DEBOUNCE_CYCLES + 10, found);
        if (!found) begin
            $display("FAIL G: falling_pulse never arrived");
            error_count = error_count + 1;
        end else begin
            @(posedge clk); #1;
            check("G: falling_pulse deasserts after 1 cycle", falling_pulse, 1'b0);
            $display("PASS G: falling_pulse is 1 cycle wide");
        end

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
