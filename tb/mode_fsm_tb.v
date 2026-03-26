`timescale 1ns / 1ps
// Self-checking integration testbench for mode_fsm.v + prime_engine.v +
// elapsed_timer.v + prime_accumulator.v.
// Tests: Mode 1 (N=100, expect 25 primes), Mode 2 (T=3 sim-seconds),
//        Mode 3 (prime=97), Mode 3 (composite=99), Mode 3 (edge case=2).
//
// Compile: iverilog -g2001 -o sim/mode_fsm_tb.vvp rtl/divider.v rtl/prime_engine.v rtl/elapsed_timer.v rtl/prime_accumulator.v rtl/mode_fsm.v tb/mode_fsm_tb.v
// Run:     vvp sim/mode_fsm_tb.vvp

module mode_fsm_tb;

    // -----------------------------------------------------------------------
    // Parameters
    // -----------------------------------------------------------------------
    parameter WIDTH       = 27;
    parameter TICK_PERIOD = 100;   // Shrink 1 second to 100 cycles for simulation

    // -----------------------------------------------------------------------
    // Testbench-driven signals (regs)
    // -----------------------------------------------------------------------
    reg             clk;
    reg             rst;
    reg  [1:0]      mode_sel;
    reg  [WIDTH-1:0] n_limit;
    reg  [31:0]     t_limit;
    reg  [WIDTH-1:0] check_candidate;
    reg             go;

    // -----------------------------------------------------------------------
    // Inter-module wires (mode_fsm output regs drive these wires)
    // -----------------------------------------------------------------------
    wire            eng_start_w;
    wire [WIDTH-1:0] eng_candidate_w;
    wire            eng_done_w;
    wire            eng_is_prime_w;
    wire            eng_busy_w;

    wire            prime_valid_w;
    wire [WIDTH-1:0] prime_data_w;
    wire            prime_fifo_full_w;

    wire            timer_freeze_w;
    wire [31:0]     seconds_w;
    wire [31:0]     cycle_count_w;

    wire            done_w;
    wire            is_prime_result_w;
    wire [3:0]      state_out_w;

    // Accumulator last-20 output wires
    wire [WIDTH-1:0] last20_0_w,  last20_1_w,  last20_2_w,  last20_3_w;
    wire [WIDTH-1:0] last20_4_w,  last20_5_w,  last20_6_w,  last20_7_w;
    wire [WIDTH-1:0] last20_8_w,  last20_9_w,  last20_10_w, last20_11_w;
    wire [WIDTH-1:0] last20_12_w, last20_13_w, last20_14_w, last20_15_w;
    wire [WIDTH-1:0] last20_16_w, last20_17_w, last20_18_w, last20_19_w;

    // -----------------------------------------------------------------------
    // DUT: mode_fsm
    // -----------------------------------------------------------------------
    mode_fsm #(.WIDTH(WIDTH)) u_fsm (
        .clk               (clk),
        .rst               (rst),
        .mode_sel          (mode_sel),
        .n_limit           (n_limit),
        .t_limit           (t_limit),
        .check_candidate   (check_candidate),
        .go                (go),
        .eng_start_ff      (eng_start_w),
        .eng_candidate_ff  (eng_candidate_w),
        .eng_done_ff       (eng_done_w),
        .eng_is_prime_ff   (eng_is_prime_w),
        .eng_busy_ff       (eng_busy_w),
        .prime_valid_ff    (prime_valid_w),
        .prime_data_ff     (prime_data_w),
        .prime_fifo_full_ff(prime_fifo_full_w),
        .timer_freeze_ff   (timer_freeze_w),
        .seconds_ff        (seconds_w),
        .cycle_count_ff    (cycle_count_w),
        .done_ff           (done_w),
        .is_prime_result_ff(is_prime_result_w),
        .state_out_ff      (state_out_w)
    );

    // -----------------------------------------------------------------------
    // Sub-module: prime_engine (wired to mode_fsm eng_* signals)
    // -----------------------------------------------------------------------
    prime_engine #(.WIDTH(WIDTH)) u_eng (
        .clk        (clk),
        .rst        (rst),
        .start      (eng_start_w),
        .candidate  (eng_candidate_w),
        .done_ff    (eng_done_w),
        .is_prime_ff(eng_is_prime_w),
        .busy_ff    (eng_busy_w)
    );

    // -----------------------------------------------------------------------
    // Sub-module: elapsed_timer (TICK_PERIOD=100 for fast simulation)
    // -----------------------------------------------------------------------
    elapsed_timer #(.TICK_PERIOD(TICK_PERIOD)) u_timer (
        .clk           (clk),
        .rst           (rst),
        .freeze        (timer_freeze_w),
        .cycle_count_ff(cycle_count_w),
        .seconds_ff    (seconds_w),
        .second_tick_ff()
    );

    // -----------------------------------------------------------------------
    // Sub-module: prime_accumulator (read side tied off — no DDR2 in Phase 2)
    // -----------------------------------------------------------------------
    prime_accumulator #(.WIDTH(WIDTH), .FIFO_DEPTH(32)) u_acc (
        .clk                  (clk),
        .rst                  (rst),
        .prime_valid          (prime_valid_w),
        .prime_data           (prime_data_w),
        .prime_fifo_rd_en     (1'b0),
        .prime_fifo_rd_data_ff(),
        .prime_fifo_empty_ff  (),
        .prime_fifo_full_ff   (prime_fifo_full_w),
        .prime_count_ff       (),
        .last20_0_ff          (last20_0_w),
        .last20_1_ff          (last20_1_w),
        .last20_2_ff          (last20_2_w),
        .last20_3_ff          (last20_3_w),
        .last20_4_ff          (last20_4_w),
        .last20_5_ff          (last20_5_w),
        .last20_6_ff          (last20_6_w),
        .last20_7_ff          (last20_7_w),
        .last20_8_ff          (last20_8_w),
        .last20_9_ff          (last20_9_w),
        .last20_10_ff         (last20_10_w),
        .last20_11_ff         (last20_11_w),
        .last20_12_ff         (last20_12_w),
        .last20_13_ff         (last20_13_w),
        .last20_14_ff         (last20_14_w),
        .last20_15_ff         (last20_15_w),
        .last20_16_ff         (last20_16_w),
        .last20_17_ff         (last20_17_w),
        .last20_18_ff         (last20_18_w),
        .last20_19_ff         (last20_19_w)
    );

    // -----------------------------------------------------------------------
    // Dedicated prime_count wire from u_acc (for test checks)
    // -----------------------------------------------------------------------
    wire [31:0] prime_count_w;
    assign prime_count_w = u_acc.prime_count_ff;

    // -----------------------------------------------------------------------
    // Clock generation: 100 MHz (10 ns period)
    // -----------------------------------------------------------------------
    initial clk = 0;
    always #5 clk = ~clk;

    // -----------------------------------------------------------------------
    // Error tracking
    // -----------------------------------------------------------------------
    integer error_count;
    integer timeout_cnt;
    reg [31:0] saved_cycle_count;

    initial error_count = 0;

    // -----------------------------------------------------------------------
    // Task: do_reset — assert rst for 20 ns (4 cycles), deassert, wait 2 more
    // -----------------------------------------------------------------------
    task do_reset;
        begin
            rst  = 1'b1;
            go   = 1'b0;
            @(posedge clk);
            @(posedge clk);
            @(posedge clk);
            @(posedge clk);
            @(posedge clk);
            rst  = 1'b0;
            @(posedge clk);
            @(posedge clk);
        end
    endtask

    // -----------------------------------------------------------------------
    // Task: pulse_go — assert go for one clock cycle, then deassert
    // -----------------------------------------------------------------------
    task pulse_go;
        begin
            @(posedge clk);
            go = 1'b1;
            @(posedge clk);
            go = 1'b0;
        end
    endtask

    // -----------------------------------------------------------------------
    // Task: wait_done — spin on done_w up to max_cycles; $fatal on timeout
    // -----------------------------------------------------------------------
    task wait_done;
        input integer max_cycles;
        begin
            timeout_cnt = 0;
            while (done_w !== 1'b1 && timeout_cnt < max_cycles) begin
                @(posedge clk);
                timeout_cnt = timeout_cnt + 1;
            end
            if (done_w !== 1'b1) begin
                $display("FATAL: done_w never asserted after %0d cycles (state=%0d)",
                         max_cycles, state_out_w);
                $fatal;
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // Main test sequence
    // -----------------------------------------------------------------------
    initial begin
        $dumpfile("sim/mode_fsm_tb.vcd");
        $dumpvars(0, mode_fsm_tb);

        // Initialize inputs
        rst            = 1'b1;
        go             = 1'b0;
        mode_sel       = 2'd0;
        n_limit        = {WIDTH{1'b0}};
        t_limit        = 32'd0;
        check_candidate = {WIDTH{1'b0}};

        // ===================================================================
        // TEST 1: Mode 1, N=100 — find all primes <= 100 (expect 25 primes)
        // Requirements: PRIME-02 (mode 1), PRIME-05 (prime_count / last20)
        // ===================================================================
        $display("--- Test 1: Mode 1, N=100 ---");
        do_reset;

        mode_sel = 2'd1;
        n_limit  = 27'd100;
        pulse_go;

        // N=100 has 25 primes. Engine takes ~100-200 cycles per candidate.
        // With ~50 candidates checked, expect ~10000-20000 cycles. Use 500000.
        wait_done(500000);

        // Check prime count
        @(posedge clk); // extra cycle for accumulator pipeline to settle
        if (prime_count_w !== 32'd25) begin
            $display("FAIL T1: expected prime_count=25 got %0d", prime_count_w);
            error_count = error_count + 1;
        end else begin
            $display("PASS T1a: prime_count = 25");
        end

        // Check timer_freeze
        if (timer_freeze_w !== 1'b1) begin
            $display("FAIL T1: timer_freeze_w not asserted at done");
            error_count = error_count + 1;
        end else begin
            $display("PASS T1b: timer frozen");
        end

        // Check done stays asserted
        if (done_w !== 1'b1) begin
            $display("FAIL T1: done_w not asserted");
            error_count = error_count + 1;
        end else begin
            $display("PASS T1c: done_w asserted");
        end

        // Verify cycle_count_w freezes after done
        saved_cycle_count = cycle_count_w;
        repeat(10) @(posedge clk);
        if (cycle_count_w !== saved_cycle_count) begin
            $display("FAIL T1: cycle_count moved after done (%0d -> %0d)",
                     saved_cycle_count, cycle_count_w);
            error_count = error_count + 1;
        end else begin
            $display("PASS T1d: cycle_count frozen after done");
        end

        // Check last20 contains 97 (the largest prime <= 100)
        // 25 primes, ring pointer wraps: last5 are in positions 0-4 (after 25 writes:
        // positions 0,1,2,3,4 hold writes 21-25 = 71,79,83,89,97 approximately).
        // Exact check: scan all 20 for value 97.
        // Extra cycles for last20 output pipeline (internal array -> output regs = +1 clk)
        repeat(5) @(posedge clk);
        if (last20_0_w  !== 27'd97 && last20_1_w  !== 27'd97 &&
            last20_2_w  !== 27'd97 && last20_3_w  !== 27'd97 &&
            last20_4_w  !== 27'd97 && last20_5_w  !== 27'd97 &&
            last20_6_w  !== 27'd97 && last20_7_w  !== 27'd97 &&
            last20_8_w  !== 27'd97 && last20_9_w  !== 27'd97 &&
            last20_10_w !== 27'd97 && last20_11_w !== 27'd97 &&
            last20_12_w !== 27'd97 && last20_13_w !== 27'd97 &&
            last20_14_w !== 27'd97 && last20_15_w !== 27'd97 &&
            last20_16_w !== 27'd97 && last20_17_w !== 27'd97 &&
            last20_18_w !== 27'd97 && last20_19_w !== 27'd97) begin
            $display("FAIL T1: 97 not found in last20 ring buffer");
            $display("  last20: %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                     last20_0_w, last20_1_w, last20_2_w, last20_3_w, last20_4_w,
                     last20_5_w, last20_6_w, last20_7_w, last20_8_w, last20_9_w);
            $display("         %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                     last20_10_w, last20_11_w, last20_12_w, last20_13_w, last20_14_w,
                     last20_15_w, last20_16_w, last20_17_w, last20_18_w, last20_19_w);
            error_count = error_count + 1;
        end else begin
            $display("PASS T1e: 97 found in last20 ring buffer");
        end
        $display("  prime_count=%0d, cycle_count=%0d", prime_count_w, cycle_count_w);

        // ===================================================================
        // TEST 2: Mode 2, T=3 sim-seconds (TICK_PERIOD=100 => 300 cycles)
        // Requirements: PRIME-03 (mode 2 timed termination), PRIME-06 (freeze)
        // ===================================================================
        $display("--- Test 2: Mode 2, T=3 (TICK_PERIOD=100) ---");
        do_reset;

        mode_sel = 2'd2;
        t_limit  = 32'd3;
        pulse_go;

        // With TICK_PERIOD=100, 3 seconds = 300 cycles. Use 1000 cycle timeout.
        wait_done(1000);

        // Check seconds_w >= 3
        if (seconds_w < 32'd3) begin
            $display("FAIL T2: seconds_w=%0d expected >= 3", seconds_w);
            error_count = error_count + 1;
        end else begin
            $display("PASS T2a: seconds_w=%0d (>= 3)", seconds_w);
        end

        // Check at least some primes were found
        if (prime_count_w == 32'd0) begin
            $display("FAIL T2: prime_count_w=0, expected > 0");
            error_count = error_count + 1;
        end else begin
            $display("PASS T2b: prime_count_w=%0d > 0", prime_count_w);
        end

        // Check timer frozen
        if (timer_freeze_w !== 1'b1) begin
            $display("FAIL T2: timer_freeze_w not asserted at done");
            error_count = error_count + 1;
        end else begin
            $display("PASS T2c: timer frozen");
        end

        // Verify seconds_w does not change after freeze
        saved_cycle_count = seconds_w;
        repeat(10) @(posedge clk);
        if (seconds_w !== saved_cycle_count) begin
            $display("FAIL T2: seconds_w changed after done (%0d -> %0d)",
                     saved_cycle_count, seconds_w);
            error_count = error_count + 1;
        end else begin
            $display("PASS T2d: seconds_w frozen after done");
        end
        $display("  primes found in T=3s: %0d", prime_count_w);

        // ===================================================================
        // TEST 3: Mode 3, candidate=97 (prime)
        // Requirement: PRIME-04
        // ===================================================================
        $display("--- Test 3: Mode 3, candidate=97 (expect prime) ---");
        do_reset;

        mode_sel        = 2'd3;
        check_candidate = 27'd97;
        pulse_go;

        wait_done(5000);

        if (is_prime_result_w !== 1'b1) begin
            $display("FAIL T3: expected is_prime_result=1 for 97, got %0b", is_prime_result_w);
            error_count = error_count + 1;
        end else begin
            $display("PASS T3a: 97 identified as prime");
        end

        if (timer_freeze_w !== 1'b1) begin
            $display("FAIL T3: timer_freeze_w not asserted");
            error_count = error_count + 1;
        end else begin
            $display("PASS T3b: timer frozen for mode 3");
        end

        // ===================================================================
        // TEST 4: Mode 3, candidate=99 (composite: 9 x 11)
        // Requirement: PRIME-04
        // ===================================================================
        $display("--- Test 4: Mode 3, candidate=99 (expect composite) ---");
        do_reset;

        mode_sel        = 2'd3;
        check_candidate = 27'd99;
        pulse_go;

        wait_done(5000);

        if (is_prime_result_w !== 1'b0) begin
            $display("FAIL T4: expected is_prime_result=0 for 99, got %0b", is_prime_result_w);
            error_count = error_count + 1;
        end else begin
            $display("PASS T4a: 99 identified as composite");
        end

        if (timer_freeze_w !== 1'b1) begin
            $display("FAIL T4: timer_freeze_w not asserted");
            error_count = error_count + 1;
        end else begin
            $display("PASS T4b: timer frozen for mode 3");
        end

        // ===================================================================
        // TEST 5: Mode 3, candidate=2 (edge case — smallest prime)
        // ===================================================================
        $display("--- Test 5: Mode 3, candidate=2 (edge case, expect prime) ---");
        do_reset;

        mode_sel        = 2'd3;
        check_candidate = 27'd2;
        pulse_go;

        wait_done(5000);

        if (is_prime_result_w !== 1'b1) begin
            $display("FAIL T5: expected is_prime_result=1 for 2, got %0b", is_prime_result_w);
            error_count = error_count + 1;
        end else begin
            $display("PASS T5: 2 identified as prime (edge case)");
        end

        // ===================================================================
        // Final verdict
        // ===================================================================
        $display("---");
        if (error_count == 0) begin
            $display("ALL TESTS PASSED");
        end else begin
            $display("FAILED: %0d errors", error_count);
            $fatal;
        end
        $finish;
    end

endmodule
