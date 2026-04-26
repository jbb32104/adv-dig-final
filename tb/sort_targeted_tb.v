`timescale 1ns / 1ps

// Targeted testbench: directly loads the 20 largest engine primes below 1M
// into a mock tracker and runs results_bcd to verify the sort and BCD
// conversion produce the correct output.
//
// This bypasses the slow engine simulation and tests the exact values
// that would be present for N=1,000,000.
//
// Compile:
//   iverilog -g2001 -o sim/sort_targeted_tb.vvp \
//     rtl/bin_to_bcd9.v rtl/results_bcd.v tb/sort_targeted_tb.v
// Run:
//   vvp sim/sort_targeted_tb.vvp

module sort_targeted_tb;

    parameter WIDTH = 27;

    // -------------------------------------------------------------------
    // Clocks and reset
    // -------------------------------------------------------------------
    reg clk, ui_clk, rst_n;
    initial clk    = 0;
    initial ui_clk = 0;
    always #5    clk    = ~clk;
    always #6.67 ui_clk = ~ui_clk;

    // -------------------------------------------------------------------
    // Mock tracker: register file with known values
    // -------------------------------------------------------------------
    // The 20 largest engine primes below 1,000,000 (excluding 2,3):
    // In tracker order: index 0 = most recent, index 19 = oldest.
    // The exact ordering depends on engine interleaving. We'll test
    // the worst case: interleaved such that 999983 is NOT at index 0.
    reg [WIDTH-1:0] mock_mem [0:39];
    reg [5:0]       mock_rd_idx;
    reg [WIDTH-1:0] mock_rd_data_ff;

    // Registered read (mimics prime_tracker)
    always @(posedge clk) begin
        mock_rd_data_ff <= mock_mem[mock_rd_idx];
    end

    // -------------------------------------------------------------------
    // results_bcd DUT
    // -------------------------------------------------------------------
    reg         start;
    wire [5:0]  tracker_idx;
    reg  [4:0]  rd_addr;
    wire [35:0] rd_data;
    wire [4:0]  display_count;
    wire        done;

    results_bcd #(.WIDTH(WIDTH)) u_dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .start            (start),
        .tracker_count    (7'd20),
        .tracker_data     (mock_rd_data_ff),
        .tracker_idx_ff   (tracker_idx),
        .n_limit          (27'd1_000_000),
        .seconds_bcd      (16'h0000),
        .display_count_ff (display_count),
        .done_ff          (done),
        .ui_clk           (ui_clk),
        .rd_addr          (rd_addr),
        .rd_data_ff       (rd_data)
    );

    // Connect tracker_idx to mock
    always @(*) mock_rd_idx = tracker_idx;

    // -------------------------------------------------------------------
    // BCD-to-binary helper
    // -------------------------------------------------------------------
    function [31:0] bcd_to_bin;
        input [35:0] bcd;
        integer di;
        reg [31:0] result;
        begin
            result = 0;
            for (di = 8; di >= 0; di = di - 1)
                result = result * 10 + bcd[di*4 +: 4];
            bcd_to_bin = result;
        end
    endfunction

    // -------------------------------------------------------------------
    // Test
    // -------------------------------------------------------------------
    integer error_count;
    integer ti;
    reg [35:0] bcd_val;
    reg [31:0] bin_val, prev_bin;

    initial begin
        $dumpfile("sim/sort_targeted_tb.vcd");
        $dumpvars(0, sort_targeted_tb);

        error_count = 0;
        rst_n  = 0;
        start  = 0;
        rd_addr = 0;

        // ============================================================
        // Load mock tracker with INTERLEAVED ordering
        // Simulates how engines would deposit primes:
        // Minus and plus engines alternate writing to the circular buffer.
        // Worst case: 999979 (plus) arrives AFTER 999983 (minus),
        // making 999979 the most recent (index 0).
        // ============================================================
        // Index 0 = most recent, mimicking tracker read order
        // Deliberately put them OUT of descending order to exercise sort
        mock_mem[0]  = 27'd999979;   // plus  (most recent)
        mock_mem[1]  = 27'd999983;   // minus
        mock_mem[2]  = 27'd999961;   // plus
        mock_mem[3]  = 27'd999959;   // minus
        mock_mem[4]  = 27'd999931;   // plus
        mock_mem[5]  = 27'd999953;   // minus
        mock_mem[6]  = 27'd999907;   // plus
        mock_mem[7]  = 27'd999917;   // minus
        mock_mem[8]  = 27'd999883;   // plus
        mock_mem[9]  = 27'd999863;   // minus
        mock_mem[10] = 27'd999853;   // plus
        mock_mem[11] = 27'd999809;   // minus
        mock_mem[12] = 27'd999769;   // plus
        mock_mem[13] = 27'd999773;   // minus
        mock_mem[14] = 27'd999763;   // plus
        mock_mem[15] = 27'd999749;   // minus
        mock_mem[16] = 27'd999727;   // plus
        mock_mem[17] = 27'd999721;   // plus (two plus in a row is possible)
        mock_mem[18] = 27'd999683;   // minus
        mock_mem[19] = 27'd999671;   // minus

        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // ============================================================
        // T1: Sort with worst-case interleaving
        // ============================================================
        $display("");
        $display("=== T1: Sort 20 primes near 1M (interleaved) ===");

        @(posedge clk);
        start = 1;
        @(posedge clk);
        start = 0;

        // Wait for done
        repeat (50_000) begin
            @(posedge clk);
            if (done) disable T1_wait;
        end
        begin : T1_wait end
        if (!done) begin
            $display("TIMEOUT: results_bcd never finished");
            $finish;
        end
        $display("  results_bcd done. display_count=%0d", display_count);

        // Dump sorted_mem via hierarchy
        $display("  sorted_mem[] after sort:");
        for (ti = 0; ti < 20; ti = ti + 1)
            $display("    sorted_mem[%0d] = %0d", ti, u_dut.sorted_mem[ti]);

        // Read back BCD memory
        $display("  bcd_mem[] readback:");
        prev_bin = 32'hFFFF_FFFF;
        for (ti = 0; ti < 20; ti = ti + 1) begin
            @(posedge ui_clk); rd_addr = ti[4:0];
            @(posedge ui_clk);
            @(posedge ui_clk);
            #1;
            bcd_val = rd_data;
            bin_val = bcd_to_bin(bcd_val);
            $display("    bcd_mem[%0d] = %0d", ti, bin_val);
            if (bin_val > prev_bin) begin
                $display("FAIL: bcd_mem[%0d]=%0d > bcd_mem[%0d]=%0d — not descending!",
                         ti, bin_val, ti-1, prev_bin);
                error_count = error_count + 1;
            end
            prev_bin = bin_val;
        end

        // Check position 0 = 999983 (largest)
        @(posedge ui_clk); rd_addr = 5'd0;
        @(posedge ui_clk);
        @(posedge ui_clk);
        #1;
        bin_val = bcd_to_bin(rd_data);
        if (bin_val !== 32'd999983) begin
            $display("FAIL: bcd_mem[0]=%0d, expected 999983", bin_val);
            error_count = error_count + 1;
        end else
            $display("PASS: bcd_mem[0] = 999983");

        // Check position 1 = 999979
        @(posedge ui_clk); rd_addr = 5'd1;
        @(posedge ui_clk);
        @(posedge ui_clk);
        #1;
        bin_val = bcd_to_bin(rd_data);
        if (bin_val !== 32'd999979) begin
            $display("FAIL: bcd_mem[1]=%0d, expected 999979", bin_val);
            error_count = error_count + 1;
        end else
            $display("PASS: bcd_mem[1] = 999979");

        // ============================================================
        // T2: Same values but 999983 already at index 0 (no swap needed)
        // ============================================================
        $display("");
        $display("=== T2: Sort with 999983 already at index 0 ===");

        rst_n = 0;
        repeat (5) @(posedge clk);

        // Reload with 999983 at index 0
        mock_mem[0]  = 27'd999983;
        mock_mem[1]  = 27'd999979;
        mock_mem[2]  = 27'd999961;
        mock_mem[3]  = 27'd999959;
        mock_mem[4]  = 27'd999953;
        mock_mem[5]  = 27'd999931;
        mock_mem[6]  = 27'd999917;
        mock_mem[7]  = 27'd999907;
        mock_mem[8]  = 27'd999883;
        mock_mem[9]  = 27'd999863;
        mock_mem[10] = 27'd999853;
        mock_mem[11] = 27'd999809;
        mock_mem[12] = 27'd999773;
        mock_mem[13] = 27'd999769;
        mock_mem[14] = 27'd999763;
        mock_mem[15] = 27'd999749;
        mock_mem[16] = 27'd999727;
        mock_mem[17] = 27'd999721;
        mock_mem[18] = 27'd999683;
        mock_mem[19] = 27'd999671;

        rst_n = 1;
        repeat (2) @(posedge clk);

        @(posedge clk);
        start = 1;
        @(posedge clk);
        start = 0;

        repeat (50_000) begin
            @(posedge clk);
            if (done) disable T2_wait;
        end
        begin : T2_wait end
        if (!done) begin
            $display("TIMEOUT");
            $finish;
        end
        $display("  results_bcd done. display_count=%0d", display_count);

        $display("  sorted_mem[] after sort:");
        for (ti = 0; ti < 20; ti = ti + 1)
            $display("    sorted_mem[%0d] = %0d", ti, u_dut.sorted_mem[ti]);

        // Check position 0
        @(posedge ui_clk); rd_addr = 5'd0;
        @(posedge ui_clk);
        @(posedge ui_clk);
        #1;
        bin_val = bcd_to_bin(rd_data);
        if (bin_val !== 32'd999983) begin
            $display("FAIL: bcd_mem[0]=%0d, expected 999983", bin_val);
            error_count = error_count + 1;
        end else
            $display("PASS: bcd_mem[0] = 999983");

        // ============================================================
        // Final
        // ============================================================
        $display("");
        $display("===========================");
        if (error_count == 0)
            $display("ALL TESTS PASSED");
        else
            $display("FAILED: %0d error(s)", error_count);
        $display("===========================");
        $finish;
    end

    initial begin
        #10_000_000;
        $display("GLOBAL TIMEOUT");
        $finish;
    end

endmodule
