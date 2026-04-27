`timescale 1ns / 1ps

// End-to-end testbench: engines → tracker → results_bcd → bcd_mem readback.
//
// Verifies the full pipeline from prime finding through BCD conversion.
// After engines complete, triggers results_bcd, waits for it to finish,
// then reads back bcd_mem via the ui_clk port and checks:
//   1. bcd_mem[0] = largest prime (descending order)
//   2. All entries are in non-ascending order
//   3. display_count is correct (engine primes + 2 + 3)
//   4. Specific known primes appear at expected positions
//
// Compile:
//   iverilog -g2001 -o sim/results_bcd_tb.vvp \
//     rtl/divider.v rtl/prime_engine.v rtl/elapsed_timer.v \
//     rtl/mode_fsm.v rtl/prime_tracker.v rtl/bin_to_bcd9.v \
//     rtl/results_bcd.v tb/results_bcd_tb.v
// Run:
//   vvp sim/results_bcd_tb.vvp

module results_bcd_tb;

    parameter WIDTH       = 27;
    parameter TICK_PERIOD = 100_000_000;

    // -------------------------------------------------------------------
    // Clocks and reset
    // -------------------------------------------------------------------
    reg clk;      // 100 MHz system clock
    reg ui_clk;   // ~75 MHz read-side clock
    reg rst_n;

    initial clk    = 0;
    initial ui_clk = 0;
    always #5    clk    = ~clk;     // 10 ns period
    always #6.67 ui_clk = ~ui_clk;  // ~13.3 ns period ≈ 75 MHz

    // -------------------------------------------------------------------
    // Testbench-driven inputs
    // -------------------------------------------------------------------
    reg [1:0]       mode_sel;
    reg [WIDTH-1:0] n_limit;
    reg [31:0]      t_limit;
    reg [WIDTH-1:0] check_candidate;
    reg             go;

    // -------------------------------------------------------------------
    // mode_fsm <-> engine wires
    // -------------------------------------------------------------------
    wire             eng_plus_start, eng_plus_done, eng_plus_is_prime, eng_plus_busy;
    wire [WIDTH-1:0] eng_plus_candidate;
    wire             eng_minus_start, eng_minus_done, eng_minus_is_prime, eng_minus_busy;
    wire [WIDTH-1:0] eng_minus_candidate;

    // -------------------------------------------------------------------
    // mode_fsm <-> accumulator stubs
    // -------------------------------------------------------------------
    wire acc_plus_valid, acc_plus_is_prime, acc_plus_flush;
    wire acc_minus_valid, acc_minus_is_prime, acc_minus_flush;

    reg flush_plus_done_ff, flush_minus_done_ff;
    always @(posedge clk) begin
        if (!rst_n) begin
            flush_plus_done_ff  <= 1'b0;
            flush_minus_done_ff <= 1'b0;
        end else begin
            flush_plus_done_ff  <= acc_plus_flush;
            flush_minus_done_ff <= acc_minus_flush;
        end
    end

    wire acc_plus_fifo_full  = 1'b0;
    wire acc_minus_fifo_full = 1'b0;

    // -------------------------------------------------------------------
    // elapsed_timer wires
    // -------------------------------------------------------------------
    wire        timer_restart, timer_freeze;
    wire [31:0] seconds, cycle_count;

    // -------------------------------------------------------------------
    // mode_fsm status
    // -------------------------------------------------------------------
    wire        done;
    wire        is_prime_result;
    wire [3:0]  state_out;

    // -------------------------------------------------------------------
    // DUT: mode_fsm
    // -------------------------------------------------------------------
    mode_fsm #(.WIDTH(WIDTH)) u_fsm (
        .clk                    (clk),
        .rst_n                  (rst_n),
        .mode_sel               (mode_sel),
        .n_limit                (n_limit),
        .t_limit                (t_limit),
        .check_candidate        (check_candidate),
        .go                     (go),
        .eng_plus_start_ff      (eng_plus_start),
        .eng_plus_candidate_ff  (eng_plus_candidate),
        .eng_plus_done          (eng_plus_done),
        .eng_plus_is_prime      (eng_plus_is_prime),
        .eng_plus_busy          (eng_plus_busy),
        .eng_minus_start_ff     (eng_minus_start),
        .eng_minus_candidate_ff (eng_minus_candidate),
        .eng_minus_done         (eng_minus_done),
        .eng_minus_is_prime     (eng_minus_is_prime),
        .eng_minus_busy         (eng_minus_busy),
        .acc_plus_valid_ff      (acc_plus_valid),
        .acc_plus_is_prime_ff   (acc_plus_is_prime),
        .acc_plus_flush_ff      (acc_plus_flush),
        .acc_plus_flush_done    (flush_plus_done_ff),
        .acc_plus_fifo_full     (acc_plus_fifo_full),
        .acc_minus_valid_ff     (acc_minus_valid),
        .acc_minus_is_prime_ff  (acc_minus_is_prime),
        .acc_minus_flush_ff     (acc_minus_flush),
        .acc_minus_flush_done   (flush_minus_done_ff),
        .acc_minus_fifo_full    (acc_minus_fifo_full),
        .timer_restart_ff       (timer_restart),
        .timer_freeze_ff        (timer_freeze),
        .seconds_ff             (seconds),
        .cycle_count_ff         (cycle_count),
        .done_ff                (done),
        .is_prime_result_ff     (is_prime_result),
        .state_out_ff           (state_out),
        .t_limit_out            ()
    );

    // -------------------------------------------------------------------
    // prime_engine instances
    // -------------------------------------------------------------------
    prime_engine #(.WIDTH(WIDTH)) u_eng_plus (
        .clk(clk), .rst_n(rst_n),
        .start(eng_plus_start), .candidate(eng_plus_candidate),
        .done_ff(eng_plus_done), .is_prime_ff(eng_plus_is_prime), .busy_ff(eng_plus_busy)
    );
    prime_engine #(.WIDTH(WIDTH)) u_eng_minus (
        .clk(clk), .rst_n(rst_n),
        .start(eng_minus_start), .candidate(eng_minus_candidate),
        .done_ff(eng_minus_done), .is_prime_ff(eng_minus_is_prime), .busy_ff(eng_minus_busy)
    );

    // -------------------------------------------------------------------
    // elapsed_timer
    // -------------------------------------------------------------------
    elapsed_timer #(.TICK_PERIOD(TICK_PERIOD)) u_timer (
        .clk(clk), .rst_n(rst_n),
        .restart(timer_restart), .freeze(timer_freeze),
        .cycle_count_ff(cycle_count), .seconds_ff(seconds), .second_tick_ff()
    );

    // -------------------------------------------------------------------
    // prime_tracker — wired exactly as in top.v
    // read_idx driven by results_bcd's tracker_idx_ff
    // -------------------------------------------------------------------
    wire [5:0]       tracker_rd_idx;   // driven by results_bcd
    wire [WIDTH-1:0] tracker_rd_data;
    wire [6:0]       tracker_count;

    prime_tracker #(.WIDTH(WIDTH)) u_tracker (
        .clk          (clk),
        .rst_n        (rst_n),
        .clear        (timer_restart),
        .plus_found   (acc_plus_valid & acc_plus_is_prime),
        .plus_value   (eng_plus_candidate),
        .minus_found  (acc_minus_valid & acc_minus_is_prime),
        .minus_value  (eng_minus_candidate),
        .read_idx     (tracker_rd_idx),
        .read_data_ff (tracker_rd_data),
        .count_ff     (tracker_count)
    );

    // -------------------------------------------------------------------
    // results_bcd — DUT under primary test
    // -------------------------------------------------------------------
    reg         rbcd_start;
    reg  [4:0]  rbcd_rd_addr;
    wire [35:0] rbcd_rd_data;
    wire [4:0]  results_display_count;
    wire        results_done;

    results_bcd #(.WIDTH(WIDTH)) u_results_bcd (
        .clk              (clk),
        .rst_n            (rst_n),
        .start            (rbcd_start),
        .tracker_count    (tracker_count),
        .tracker_data     (tracker_rd_data),
        .tracker_idx_ff   (tracker_rd_idx),
        .n_limit          (n_limit),
        .seconds_bcd      (16'h0000),      // seconds not relevant for this test
        .display_count_ff (results_display_count),
        .done_ff          (results_done),
        .ui_clk           (ui_clk),
        .rd_addr          (rbcd_rd_addr),
        .rd_data_ff       (rbcd_rd_data)
    );

    // -------------------------------------------------------------------
    // Monitor: log primes as they enter the tracker
    // -------------------------------------------------------------------
    always @(posedge clk) begin
        if (acc_plus_valid && acc_plus_is_prime)
            $display("  [TRACKER +] value=%0d", eng_plus_candidate);
        if (acc_minus_valid && acc_minus_is_prime)
            $display("  [TRACKER -] value=%0d", eng_minus_candidate);
    end

    // -------------------------------------------------------------------
    // BCD-to-binary conversion function for checking
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
    // Error tracking
    // -------------------------------------------------------------------
    integer error_count;
    integer timeout_cnt;
    initial error_count = 0;

    // -------------------------------------------------------------------
    // Tasks
    // -------------------------------------------------------------------
    task do_reset;
        begin
            rst_n = 1'b0;
            go    = 1'b0;
            rbcd_start  = 1'b0;
            rbcd_rd_addr = 5'd0;
            repeat (5) @(posedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
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

    task wait_done;
        input integer max_cycles;
        begin
            timeout_cnt = 0;
            while (done !== 1'b1 && timeout_cnt < max_cycles) begin
                @(posedge clk);
                timeout_cnt = timeout_cnt + 1;
            end
            if (done !== 1'b1) begin
                $display("TIMEOUT: mode_fsm done never asserted after %0d cycles", max_cycles);
                $finish;
            end
        end
    endtask

    task pulse_rbcd_start;
        begin
            @(posedge clk);
            rbcd_start = 1'b1;
            @(posedge clk);
            rbcd_start = 1'b0;
        end
    endtask

    task wait_rbcd_done;
        input integer max_cycles;
        begin
            timeout_cnt = 0;
            while (results_done !== 1'b1 && timeout_cnt < max_cycles) begin
                @(posedge clk);
                timeout_cnt = timeout_cnt + 1;
            end
            if (results_done !== 1'b1) begin
                $display("TIMEOUT: results_bcd done never asserted after %0d cycles", max_cycles);
                $finish;
            end
        end
    endtask

    // Read bcd_mem via ui_clk port (registered: set addr, wait 1 ui_clk, read)
    task read_bcd_mem;
        input  [4:0]  addr;
        output [35:0] data;
        begin
            @(posedge ui_clk);
            rbcd_rd_addr = addr;
            @(posedge ui_clk);  // addr registered
            @(posedge ui_clk);  // data available
            #1;
            data = rbcd_rd_data;
        end
    endtask

    // -------------------------------------------------------------------
    // Main test sequence
    // -------------------------------------------------------------------
    reg [35:0] bcd_val;
    reg [31:0] bin_val;
    reg [31:0] prev_bin_val;
    integer ti;

    initial begin
        $dumpfile("sim/results_bcd_tb.vcd");
        $dumpvars(0, results_bcd_tb);

        rst_n           = 1'b0;
        go              = 1'b0;
        rbcd_start      = 1'b0;
        rbcd_rd_addr    = 5'd0;
        mode_sel        = 2'd0;
        n_limit         = {WIDTH{1'b0}};
        t_limit         = 32'd0;
        check_candidate = {WIDTH{1'b0}};

        // =============================================================
        // T1: N=50 — 13 engine primes + 2 + 3 = 15 display entries
        // Expected sorted descending: 47,43,41,37,31,29,23,19,17,13,11,7,5,3,2
        // =============================================================
        $display("");
        $display("=== T1: Mode 1, N=50 — full pipeline ===");
        do_reset;

        mode_sel = 2'd1;
        n_limit  = 27'd50;
        pulse_go;

        $display("  Waiting for engines to finish...");
        wait_done(200_000);
        $display("  mode_fsm done. tracker_count=%0d", tracker_count);

        // Trigger results_bcd (like done rising edge in top)
        pulse_rbcd_start;
        $display("  results_bcd started, waiting...");
        wait_rbcd_done(10_000);
        $display("  results_bcd done. display_count=%0d", results_display_count);

        // Check display_count: 13 engine + 2 (for primes 2,3) = 15
        if (results_display_count !== 5'd15) begin
            $display("FAIL T1a: display_count=%0d, expected 15", results_display_count);
            error_count = error_count + 1;
        end else
            $display("PASS T1a: display_count = 15");

        // Read back all BCD entries and verify descending order
        $display("  BCD memory contents:");
        prev_bin_val = 32'hFFFF_FFFF;
        for (ti = 0; ti < 15; ti = ti + 1) begin
            read_bcd_mem(ti[4:0], bcd_val);
            bin_val = bcd_to_bin(bcd_val);
            $display("    bcd_mem[%0d] = %09h (BCD) = %0d (decimal)", ti, bcd_val, bin_val);
            if (bin_val > prev_bin_val) begin
                $display("FAIL T1b: bcd_mem[%0d]=%0d > bcd_mem[%0d]=%0d — not descending!",
                         ti, bin_val, ti-1, prev_bin_val);
                error_count = error_count + 1;
            end
            prev_bin_val = bin_val;
        end

        // Check bcd_mem[0] = 47 (largest prime ≤ 50)
        read_bcd_mem(5'd0, bcd_val);
        bin_val = bcd_to_bin(bcd_val);
        if (bin_val !== 32'd47) begin
            $display("FAIL T1c: bcd_mem[0]=%0d, expected 47", bin_val);
            error_count = error_count + 1;
        end else
            $display("PASS T1c: bcd_mem[0] = 47 (largest prime)");

        // Check last engine prime = 5, then 3, then 2
        read_bcd_mem(5'd12, bcd_val);
        bin_val = bcd_to_bin(bcd_val);
        if (bin_val !== 32'd5) begin
            $display("FAIL T1d: bcd_mem[12]=%0d, expected 5", bin_val);
            error_count = error_count + 1;
        end else
            $display("PASS T1d: bcd_mem[12] = 5 (smallest engine prime)");

        read_bcd_mem(5'd13, bcd_val);
        bin_val = bcd_to_bin(bcd_val);
        if (bin_val !== 32'd3) begin
            $display("FAIL T1e: bcd_mem[13]=%0d, expected 3", bin_val);
            error_count = error_count + 1;
        end else
            $display("PASS T1e: bcd_mem[13] = 3");

        read_bcd_mem(5'd14, bcd_val);
        bin_val = bcd_to_bin(bcd_val);
        if (bin_val !== 32'd2) begin
            $display("FAIL T1f: bcd_mem[14]=%0d, expected 2", bin_val);
            error_count = error_count + 1;
        end else
            $display("PASS T1f: bcd_mem[14] = 2");

        // =============================================================
        // T2: N=100 — 23 engine primes, tracker keeps 20, +2+3 = 22
        // BUT display is capped at 20 slots total.
        // So: 20 engine primes converted, then check if 3 and 2 fit.
        // Actually slot_ff counts, and 20 engine primes fill slots 0-19.
        // include_3 check: slot_ff < 20 → 20 < 20 is FALSE.
        // So 3 and 2 are NOT appended. display_count = 20.
        // Largest prime ≤ 100: 97.
        // =============================================================
        $display("");
        $display("=== T2: Mode 1, N=100 — 20 tracker slots saturated ===");
        do_reset;

        mode_sel = 2'd1;
        n_limit  = 27'd100;
        pulse_go;

        $display("  Waiting for engines to finish...");
        wait_done(500_000);
        $display("  mode_fsm done. tracker_count=%0d", tracker_count);

        pulse_rbcd_start;
        $display("  results_bcd started, waiting...");
        wait_rbcd_done(20_000);
        $display("  results_bcd done. display_count=%0d", results_display_count);

        // When tracker has 20 entries, all 20 slots used for engine primes.
        // 3 and 2 can't fit (slot >= 20). display_count = 20.
        if (results_display_count !== 5'd20) begin
            $display("FAIL T2a: display_count=%0d, expected 20", results_display_count);
            error_count = error_count + 1;
        end else
            $display("PASS T2a: display_count = 20");

        // Read back all 20 entries
        $display("  BCD memory contents:");
        prev_bin_val = 32'hFFFF_FFFF;
        for (ti = 0; ti < 20; ti = ti + 1) begin
            read_bcd_mem(ti[4:0], bcd_val);
            bin_val = bcd_to_bin(bcd_val);
            $display("    bcd_mem[%0d] = %09h (BCD) = %0d (decimal)", ti, bcd_val, bin_val);
            if (bin_val > prev_bin_val) begin
                $display("FAIL T2b: bcd_mem[%0d]=%0d > bcd_mem[%0d]=%0d — not descending!",
                         ti, bin_val, ti-1, prev_bin_val);
                error_count = error_count + 1;
            end
            prev_bin_val = bin_val;
        end

        // Check bcd_mem[0] = 97
        read_bcd_mem(5'd0, bcd_val);
        bin_val = bcd_to_bin(bcd_val);
        if (bin_val !== 32'd97) begin
            $display("FAIL T2c: bcd_mem[0]=%0d, expected 97", bin_val);
            error_count = error_count + 1;
        end else
            $display("PASS T2c: bcd_mem[0] = 97 (largest prime)");

        // =============================================================
        // T3: N=10000 — heavy wrapping, largest engine prime is 9973
        // =============================================================
        $display("");
        $display("=== T3: Mode 1, N=10000 — full pipeline with wrapping ===");
        do_reset;

        mode_sel = 2'd1;
        n_limit  = 27'd10_000;
        pulse_go;

        $display("  Waiting for engines to finish (may take a while)...");
        wait_done(50_000_000);
        $display("  mode_fsm done. tracker_count=%0d", tracker_count);

        pulse_rbcd_start;
        $display("  results_bcd started, waiting...");
        wait_rbcd_done(20_000);
        $display("  results_bcd done. display_count=%0d", results_display_count);

        // Read back all entries
        $display("  BCD memory contents:");
        prev_bin_val = 32'hFFFF_FFFF;
        for (ti = 0; ti < 20; ti = ti + 1) begin
            read_bcd_mem(ti[4:0], bcd_val);
            bin_val = bcd_to_bin(bcd_val);
            $display("    bcd_mem[%0d] = %09h (BCD) = %0d (decimal)", ti, bcd_val, bin_val);
            if (bin_val > prev_bin_val) begin
                $display("FAIL T3a: bcd_mem[%0d]=%0d > bcd_mem[%0d]=%0d — not descending!",
                         ti, bin_val, ti-1, prev_bin_val);
                error_count = error_count + 1;
            end
            prev_bin_val = bin_val;
        end

        // Check bcd_mem[0] = 9973
        read_bcd_mem(5'd0, bcd_val);
        bin_val = bcd_to_bin(bcd_val);
        if (bin_val !== 32'd9973) begin
            $display("FAIL T3b: bcd_mem[0]=%0d, expected 9973", bin_val);
            error_count = error_count + 1;
        end else
            $display("PASS T3b: bcd_mem[0] = 9973 (largest prime)");

        // Also directly inspect sorted_mem via hierarchical access
        $display("");
        $display("  sorted_mem[] (raw, before BCD conversion):");
        for (ti = 0; ti < 20; ti = ti + 1) begin
            $display("    sorted_mem[%0d] = %0d", ti,
                     u_results_bcd.sorted_mem[ti]);
        end

        // =============================================================
        // Final verdict
        // =============================================================
        $display("");
        $display("===========================");
        if (error_count == 0)
            $display("ALL TESTS PASSED");
        else
            $display("FAILED: %0d error(s)", error_count);
        $display("===========================");
        $finish;
    end

    // Safety timeout
    initial begin
        #500_000_000_000;
        $display("GLOBAL TIMEOUT — simulation killed");
        $finish;
    end

endmodule
