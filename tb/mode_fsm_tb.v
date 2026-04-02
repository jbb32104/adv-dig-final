`timescale 1ns / 1ps
// Self-checking integration testbench for mode_fsm.v + 2x prime_engine.v +
// elapsed_timer.v + 2x prime_accumulator.v (bitmap version).
//
// Tests:
//   T1: Mode 1, N=50 — 6k+1 engine finds 6 primes (7,13,19,31,37,43)
//                       6k-1 engine finds 7 primes (5,11,17,23,29,41,47)
//   T2: PRIME_DONE + go → IDLE (done deasserts, timer unfreezes)
//   T3: Mode 2, T=2 sim-seconds — timed termination + flush
//   T4: Mode 3, candidate=97 (prime)
//   T5: Mode 3, candidate=99 (composite: 9x11)
//   T6: Mode 3, candidate=2  (edge case, smallest prime)
//
// Candidates 2 and 3 are intentionally skipped in Modes 1/2 (per MEMORY.md).
//
// Requires tb/prime_fifo_ip.v behavioral stub (no Vivado IP needed in simulation).
//
// Compile: iverilog -g2001 -o sim\mode_fsm_tb.vvp rtl\divider.v rtl\prime_engine.v rtl\elapsed_timer.v rtl\prime_accumulator.v tb\prime_fifo_ip.v rtl\mode_fsm.v tb\mode_fsm_tb.v
// Run:     vvp sim\mode_fsm_tb.vvp

module mode_fsm_tb;

    // -----------------------------------------------------------------------
    // Parameters
    // -----------------------------------------------------------------------
    parameter WIDTH       = 27;
    parameter TICK_PERIOD = 100;    // 1 sim-second = 100 clock cycles

    // -----------------------------------------------------------------------
    // Clock and reset
    // -----------------------------------------------------------------------
    reg clk;
    reg rst;

    initial clk = 0;
    always #5 clk = ~clk;   // 10 ns period = 100 MHz

    // -----------------------------------------------------------------------
    // Testbench-driven inputs
    // -----------------------------------------------------------------------
    reg [1:0]       mode_sel;
    reg [WIDTH-1:0] n_limit;
    reg [31:0]      t_limit;
    reg [WIDTH-1:0] check_candidate;
    reg             go;

    // -----------------------------------------------------------------------
    // Inter-module wires
    // -----------------------------------------------------------------------

    // 6k+1 engine
    wire             eng_plus_start_w;
    wire [WIDTH-1:0] eng_plus_candidate_w;
    wire             eng_plus_done_w;
    wire             eng_plus_is_prime_w;
    wire             eng_plus_busy_w;

    // 6k-1 engine
    wire             eng_minus_start_w;
    wire [WIDTH-1:0] eng_minus_candidate_w;
    wire             eng_minus_done_w;
    wire             eng_minus_is_prime_w;
    wire             eng_minus_busy_w;

    // 6k+1 accumulator
    wire             acc_plus_valid_w;
    wire             acc_plus_is_prime_w;
    wire             acc_plus_flush_w;
    wire             acc_plus_flush_done_w;
    wire             acc_plus_fifo_full_w;

    // 6k-1 accumulator
    wire             acc_minus_valid_w;
    wire             acc_minus_is_prime_w;
    wire             acc_minus_flush_w;
    wire             acc_minus_flush_done_w;
    wire             acc_minus_fifo_full_w;

    // Elapsed timer
    wire             timer_freeze_w;
    wire [31:0]      seconds_w;
    wire [31:0]      cycle_count_w;

    // Status
    wire             done_w;
    wire             is_prime_result_w;
    wire [3:0]       state_out_w;

    // -----------------------------------------------------------------------
    // DUT: mode_fsm
    // -----------------------------------------------------------------------
    mode_fsm #(.WIDTH(WIDTH)) u_fsm (
        .clk                    (clk),
        .rst                    (rst),
        .mode_sel               (mode_sel),
        .n_limit                (n_limit),
        .t_limit                (t_limit),
        .check_candidate        (check_candidate),
        .go                     (go),
        .eng_plus_start_ff      (eng_plus_start_w),
        .eng_plus_candidate_ff  (eng_plus_candidate_w),
        .eng_plus_done          (eng_plus_done_w),
        .eng_plus_is_prime      (eng_plus_is_prime_w),
        .eng_plus_busy          (eng_plus_busy_w),
        .eng_minus_start_ff     (eng_minus_start_w),
        .eng_minus_candidate_ff (eng_minus_candidate_w),
        .eng_minus_done         (eng_minus_done_w),
        .eng_minus_is_prime     (eng_minus_is_prime_w),
        .eng_minus_busy         (eng_minus_busy_w),
        .acc_plus_valid_ff      (acc_plus_valid_w),
        .acc_plus_is_prime_ff   (acc_plus_is_prime_w),
        .acc_plus_flush_ff      (acc_plus_flush_w),
        .acc_plus_flush_done    (acc_plus_flush_done_w),
        .acc_plus_fifo_full     (acc_plus_fifo_full_w),
        .acc_minus_valid_ff     (acc_minus_valid_w),
        .acc_minus_is_prime_ff  (acc_minus_is_prime_w),
        .acc_minus_flush_ff     (acc_minus_flush_w),
        .acc_minus_flush_done   (acc_minus_flush_done_w),
        .acc_minus_fifo_full    (acc_minus_fifo_full_w),
        .timer_freeze_ff        (timer_freeze_w),
        .seconds_ff             (seconds_w),
        .cycle_count_ff         (cycle_count_w),
        .done_ff                (done_w),
        .is_prime_result_ff     (is_prime_result_w),
        .state_out_ff           (state_out_w)
    );

    // -----------------------------------------------------------------------
    // Sub-modules: prime_engine instances
    // -----------------------------------------------------------------------
    prime_engine #(.WIDTH(WIDTH)) u_eng_plus (
        .clk        (clk),
        .rst        (rst),
        .start      (eng_plus_start_w),
        .candidate  (eng_plus_candidate_w),
        .done_ff    (eng_plus_done_w),
        .is_prime_ff(eng_plus_is_prime_w),
        .busy_ff    (eng_plus_busy_w)
    );

    prime_engine #(.WIDTH(WIDTH)) u_eng_minus (
        .clk        (clk),
        .rst        (rst),
        .start      (eng_minus_start_w),
        .candidate  (eng_minus_candidate_w),
        .done_ff    (eng_minus_done_w),
        .is_prime_ff(eng_minus_is_prime_w),
        .busy_ff    (eng_minus_busy_w)
    );

    // -----------------------------------------------------------------------
    // Sub-modules: prime_accumulator instances
    // rd_clk tied to clk (no DDR2 in simulation); rd_en tied low.
    // -----------------------------------------------------------------------
    prime_accumulator u_acc_plus (
        .clk                  (clk),
        .rst                  (rst),
        .rd_clk               (clk),
        .prime_valid          (acc_plus_valid_w),
        .is_prime             (acc_plus_is_prime_w),
        .flush                (acc_plus_flush_w),
        .flush_done_ff        (acc_plus_flush_done_w),
        .prime_fifo_rd_en     (1'b0),
        .prime_fifo_rd_data   (),
        .prime_fifo_empty     (),
        .prime_fifo_full      (acc_plus_fifo_full_w),
        .prime_count_ff       ()
    );

    prime_accumulator u_acc_minus (
        .clk                  (clk),
        .rst                  (rst),
        .rd_clk               (clk),
        .prime_valid          (acc_minus_valid_w),
        .is_prime             (acc_minus_is_prime_w),
        .flush                (acc_minus_flush_w),
        .flush_done_ff        (acc_minus_flush_done_w),
        .prime_fifo_rd_en     (1'b0),
        .prime_fifo_rd_data   (),
        .prime_fifo_empty     (),
        .prime_fifo_full      (acc_minus_fifo_full_w),
        .prime_count_ff       ()
    );

    // Hierarchical access to prime_count (not exposed as top-level ports)
    wire [31:0] plus_prime_count;
    wire [31:0] minus_prime_count;
    assign plus_prime_count  = u_acc_plus.prime_count_ff;
    assign minus_prime_count = u_acc_minus.prime_count_ff;

    // -----------------------------------------------------------------------
    // Sub-module: elapsed_timer
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
    // Error tracking
    // -----------------------------------------------------------------------
    integer error_count;
    integer timeout_cnt;
    reg [31:0] saved_seconds;

    initial error_count = 0;

    // -----------------------------------------------------------------------
    // Tasks
    // -----------------------------------------------------------------------
    task do_reset;
        begin
            rst = 1'b1;
            go  = 1'b0;
            repeat(5) @(posedge clk);
            rst = 1'b0;
            repeat(2) @(posedge clk);
        end
    endtask

    task pulse_go;
        begin
            @(posedge clk);
            go = 1'b1;
            @(posedge clk);
            go = 1'b0;
        end
    endtask

    // Spin on done_w up to max_cycles; abort simulation on timeout.
    task wait_done;
        input integer max_cycles;
        begin
            timeout_cnt = 0;
            while (done_w !== 1'b1 && timeout_cnt < max_cycles) begin
                @(posedge clk);
                timeout_cnt = timeout_cnt + 1;
            end
            if (done_w !== 1'b1) begin
                $display("TIMEOUT: done_w never asserted after %0d cycles (state=%0d)",
                         max_cycles, state_out_w);
                $display("FAILED: simulation aborted on timeout");
                $finish;
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // Main test sequence
    // -----------------------------------------------------------------------
    initial begin
        $dumpfile("sim/mode_fsm_tb.vcd");
        $dumpvars(0, mode_fsm_tb);

        rst             = 1'b1;
        go              = 1'b0;
        mode_sel        = 2'd0;
        n_limit         = {WIDTH{1'b0}};
        t_limit         = 32'd0;
        check_candidate = {WIDTH{1'b0}};

        // ===================================================================
        // T1: Mode 1, N=50
        //
        // Engines start at k=1 and step by k++ (candidate += 6) independently.
        // Candidates 2 and 3 are skipped (hardcoded prime at output layer).
        //
        // 6k+1 candidates tested: 7,13,19,25,31,37,43,49 → primes: 7,13,19,31,37,43
        // 6k-1 candidates tested: 5,11,17,23,29,35,41,47 → primes: 5,11,17,23,29,41,47
        //
        // Expected: plus_prime_count=6, minus_prime_count=7
        // ===================================================================
        $display("--- T1: Mode 1, N=50 ---");
        do_reset;

        mode_sel = 2'd1;
        n_limit  = 27'd50;
        pulse_go;

        // ~8 candidates/engine, each ~30-100 cycles, running in parallel.
        // 100000-cycle timeout is very conservative.
        wait_done(100000);
        repeat(3) @(posedge clk); #1;

        if (plus_prime_count !== 32'd6) begin
            $display("FAIL T1a: plus  prime_count=%0d, expected 6", plus_prime_count);
            error_count = error_count + 1;
        end else
            $display("PASS T1a: plus prime_count = 6");

        if (minus_prime_count !== 32'd7) begin
            $display("FAIL T1b: minus prime_count=%0d, expected 7", minus_prime_count);
            error_count = error_count + 1;
        end else
            $display("PASS T1b: minus prime_count = 7");

        if (done_w !== 1'b1) begin
            $display("FAIL T1c: done_w not asserted");
            error_count = error_count + 1;
        end else
            $display("PASS T1c: done_w asserted");

        if (timer_freeze_w !== 1'b1) begin
            $display("FAIL T1d: timer not frozen at done");
            error_count = error_count + 1;
        end else
            $display("PASS T1d: timer frozen");

        $display("  cycle_count=%0d  plus=%0d  minus=%0d",
                 cycle_count_w, plus_prime_count, minus_prime_count);

        // ===================================================================
        // T2: PRIME_DONE + go → IDLE (done deasserts, timer unfreezes)
        // Performed immediately after T1 while still in PRIME_DONE state.
        // ===================================================================
        $display("--- T2: PRIME_DONE + go -> IDLE ---");
        pulse_go;
        @(posedge clk); #1;

        if (done_w !== 1'b0) begin
            $display("FAIL T2a: done_w did not deassert after go");
            error_count = error_count + 1;
        end else
            $display("PASS T2a: done_w deasserted");

        if (timer_freeze_w !== 1'b0) begin
            $display("FAIL T2b: timer still frozen after go");
            error_count = error_count + 1;
        end else
            $display("PASS T2b: timer unfrozen");

        // ===================================================================
        // T3: Mode 2, T=2 sim-seconds (200 cycles with TICK_PERIOD=100)
        // Both engines run until timeout fires, then flush and assert done.
        // Checks: done asserts, timer frozen, timer stays frozen, some primes found.
        // ===================================================================
        $display("--- T3: Mode 2, T=2 sim-seconds ---");
        do_reset;

        mode_sel = 2'd2;
        t_limit  = 32'd2;
        pulse_go;

        // 200-cycle timeout + in-flight engine completion + flush ≈ ~400 cycles.
        // 5000-cycle timeout is conservative.
        wait_done(5000);
        repeat(3) @(posedge clk); #1;

        if (seconds_w < 32'd2) begin
            $display("FAIL T3a: seconds_w=%0d, expected >= 2", seconds_w);
            error_count = error_count + 1;
        end else
            $display("PASS T3a: seconds_w=%0d (>= 2)", seconds_w);

        if (timer_freeze_w !== 1'b1) begin
            $display("FAIL T3b: timer not frozen at done");
            error_count = error_count + 1;
        end else
            $display("PASS T3b: timer frozen");

        // Verify timer stays frozen
        saved_seconds = seconds_w;
        repeat(20) @(posedge clk); #1;
        if (seconds_w !== saved_seconds) begin
            $display("FAIL T3c: seconds_w changed after freeze (%0d -> %0d)",
                     saved_seconds, seconds_w);
            error_count = error_count + 1;
        end else
            $display("PASS T3c: seconds frozen");

        if ((plus_prime_count + minus_prime_count) == 32'd0) begin
            $display("FAIL T3d: no primes found in T=2s");
            error_count = error_count + 1;
        end else
            $display("PASS T3d: primes found: plus=%0d minus=%0d",
                     plus_prime_count, minus_prime_count);

        // ===================================================================
        // T4: Mode 3, candidate=97 (prime)
        // eng_plus tests candidate directly; accumulators not used.
        // ===================================================================
        $display("--- T4: Mode 3, candidate=97 (expect prime) ---");
        do_reset;

        mode_sel        = 2'd3;
        check_candidate = 27'd97;
        pulse_go;

        wait_done(10000);
        @(posedge clk); #1;

        if (is_prime_result_w !== 1'b1) begin
            $display("FAIL T4: 97 not prime (got %0b)", is_prime_result_w);
            error_count = error_count + 1;
        end else
            $display("PASS T4: 97 is prime");

        if (timer_freeze_w !== 1'b1) begin
            $display("FAIL T4b: timer not frozen");
            error_count = error_count + 1;
        end else
            $display("PASS T4b: timer frozen");

        // ===================================================================
        // T5: Mode 3, candidate=99 (composite: 9 x 11)
        // ===================================================================
        $display("--- T5: Mode 3, candidate=99 (expect composite) ---");
        do_reset;

        mode_sel        = 2'd3;
        check_candidate = 27'd99;
        pulse_go;

        wait_done(10000);
        @(posedge clk); #1;

        if (is_prime_result_w !== 1'b0) begin
            $display("FAIL T5: 99 not composite (got %0b)", is_prime_result_w);
            error_count = error_count + 1;
        end else
            $display("PASS T5: 99 is composite");

        // ===================================================================
        // T6: Mode 3, candidate=2 (edge case — smallest prime, handled in
        // prime_engine's CHECK_2_3 state before any divider is invoked)
        // ===================================================================
        $display("--- T6: Mode 3, candidate=2 (edge case) ---");
        do_reset;

        mode_sel        = 2'd3;
        check_candidate = 27'd2;
        pulse_go;

        wait_done(5000);
        @(posedge clk); #1;

        if (is_prime_result_w !== 1'b1) begin
            $display("FAIL T6: 2 not prime (got %0b)", is_prime_result_w);
            error_count = error_count + 1;
        end else
            $display("PASS T6: 2 is prime (edge case)");

        // ===================================================================
        // Final verdict
        // ===================================================================
        $display("---");
        if (error_count == 0)
            $display("ALL TESTS PASSED");
        else
            $display("FAILED: %0d errors", error_count);
        $finish;
    end

endmodule
