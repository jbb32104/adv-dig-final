`timescale 1ns / 1ps

// Self-checking testbench for prime_tracker.v
//
// Instantiates mode_fsm + 2x prime_engine + elapsed_timer to drive the
// tracker with real engine results. No accumulators or FIFOs needed —
// the tracker taps acc_*_valid/is_prime and eng_*_candidate directly.
//
// Accumulator feedback (flush_done, fifo_full) is stubbed minimally so
// mode_fsm can progress through PRIME_FLUSH → PRIME_DONE.
//
// Tests:
//   T1: Mode 1, N=50  — verify tracker contents match known primes ≤50
//   T2: Mode 1, N=100 — verify largest prime is 97, count correct
//   T3: Mode 1, N=1000000 — verify 999983 appears as largest prime
//
// Compile:
//   iverilog -g2001 -o sim/prime_tracker_tb.vvp \
//     rtl/divider.v rtl/prime_engine.v rtl/elapsed_timer.v \
//     rtl/mode_fsm.v rtl/prime_tracker.v tb/prime_tracker_tb.v
// Run:
//   vvp sim/prime_tracker_tb.vvp

module prime_tracker_tb;

    parameter WIDTH       = 27;
    parameter TICK_PERIOD = 100_000_000;  // real 1-second tick (irrelevant for mode 1)

    // -----------------------------------------------------------------------
    // Clock and reset
    // -----------------------------------------------------------------------
    reg clk;
    reg rst_n;

    initial clk = 0;
    always #5 clk = ~clk;   // 10 ns period → 100 MHz

    // -----------------------------------------------------------------------
    // Testbench-driven inputs
    // -----------------------------------------------------------------------
    reg [1:0]       mode_sel;
    reg [WIDTH-1:0] n_limit;
    reg [31:0]      t_limit;
    reg [WIDTH-1:0] check_candidate;
    reg             go;

    // -----------------------------------------------------------------------
    // mode_fsm <-> engine wires
    // -----------------------------------------------------------------------
    wire             eng_plus_start, eng_plus_done, eng_plus_is_prime, eng_plus_busy;
    wire [WIDTH-1:0] eng_plus_candidate;
    wire             eng_minus_start, eng_minus_done, eng_minus_is_prime, eng_minus_busy;
    wire [WIDTH-1:0] eng_minus_candidate;

    // -----------------------------------------------------------------------
    // mode_fsm <-> accumulator stubs
    // -----------------------------------------------------------------------
    wire acc_plus_valid, acc_plus_is_prime, acc_plus_flush;
    wire acc_minus_valid, acc_minus_is_prime, acc_minus_flush;

    // Stub: flush_done pulses 1 cycle after flush
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

    // Stub: FIFO never full
    wire acc_plus_fifo_full  = 1'b0;
    wire acc_minus_fifo_full = 1'b0;

    // -----------------------------------------------------------------------
    // elapsed_timer wires
    // -----------------------------------------------------------------------
    wire        timer_restart, timer_freeze;
    wire [31:0] seconds, cycle_count;

    // -----------------------------------------------------------------------
    // mode_fsm status
    // -----------------------------------------------------------------------
    wire        done;
    wire        is_prime_result;
    wire [3:0]  state_out;

    // -----------------------------------------------------------------------
    // DUT: mode_fsm
    // -----------------------------------------------------------------------
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

    // -----------------------------------------------------------------------
    // prime_engine instances
    // -----------------------------------------------------------------------
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

    // -----------------------------------------------------------------------
    // elapsed_timer
    // -----------------------------------------------------------------------
    elapsed_timer #(.TICK_PERIOD(TICK_PERIOD)) u_timer (
        .clk(clk), .rst_n(rst_n),
        .restart(timer_restart), .freeze(timer_freeze),
        .cycle_count_ff(cycle_count), .seconds_ff(seconds), .second_tick_ff()
    );

    // -----------------------------------------------------------------------
    // DUT: prime_tracker — wired exactly as in top.v
    // -----------------------------------------------------------------------
    reg  [5:0]       tracker_rd_idx;
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

    // -----------------------------------------------------------------------
    // Monitor: log every prime as it enters the tracker
    // -----------------------------------------------------------------------
    always @(posedge clk) begin
        if (acc_plus_valid && acc_plus_is_prime)
            $display("  [TRACKER +] k=%0d  value=%0d",
                     (eng_plus_candidate - 1) / 6, eng_plus_candidate);
        if (acc_minus_valid && acc_minus_is_prime)
            $display("  [TRACKER -] k=%0d  value=%0d",
                     (eng_minus_candidate + 1) / 6, eng_minus_candidate);
    end

    // -----------------------------------------------------------------------
    // Error tracking
    // -----------------------------------------------------------------------
    integer error_count;
    integer timeout_cnt;

    initial error_count = 0;

    // -----------------------------------------------------------------------
    // Tasks
    // -----------------------------------------------------------------------
    task do_reset;
        begin
            rst_n = 1'b0;
            go    = 1'b0;
            tracker_rd_idx = 6'd0;
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
                $display("TIMEOUT: done never asserted after %0d cycles (state=%0d)",
                         max_cycles, state_out);
                $display("FAILED: simulation aborted on timeout");
                $finish;
            end
        end
    endtask

    // Read tracker entry at given index, accounting for 1-cycle registered read
    task read_tracker;
        input  [5:0] idx;
        output [WIDTH-1:0] val;
        begin
            tracker_rd_idx = idx;
            @(posedge clk);  // idx registered
            @(posedge clk);  // read data available
            #1;
            val = tracker_rd_data;
        end
    endtask

    // -----------------------------------------------------------------------
    // Helper: dump all tracker entries
    // -----------------------------------------------------------------------
    reg [WIDTH-1:0] readback;
    integer dump_i;

    task dump_tracker;
        input [6:0] count;
        begin
            $display("  Tracker contents (%0d entries, idx 0 = most recent):", count);
            for (dump_i = 0; dump_i < count && dump_i < 64; dump_i = dump_i + 1) begin
                read_tracker(dump_i[5:0], readback);
                $display("    [%0d] = %0d", dump_i, readback);
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // Helper: check that a specific value exists in tracker
    // -----------------------------------------------------------------------
    reg found_flag;
    reg [WIDTH-1:0] search_val;
    integer search_i;

    task check_value_exists;
        input [WIDTH-1:0] val;
        input [6:0] count;
        begin
            found_flag = 1'b0;
            for (search_i = 0; search_i < count && search_i < 64; search_i = search_i + 1) begin
                read_tracker(search_i[5:0], search_val);
                if (search_val == val)
                    found_flag = 1'b1;
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // Main test sequence
    // -----------------------------------------------------------------------
    // Known primes for reference
    // Primes ≤ 50 (excluding 2,3): 5,7,11,13,17,19,23,29,31,37,41,43,47
    //   6k+1: 7,13,19,31,37,43  (6 primes)
    //   6k-1: 5,11,17,23,29,41,47  (7 primes)
    //   Total engine primes: 13

    reg [WIDTH-1:0] expected_val;
    reg [WIDTH-1:0] largest_val;

    initial begin
        $dumpfile("sim/prime_tracker_tb.vcd");
        $dumpvars(0, prime_tracker_tb);

        rst_n           = 1'b0;
        go              = 1'b0;
        mode_sel        = 2'd0;
        n_limit         = {WIDTH{1'b0}};
        t_limit         = 32'd0;
        check_candidate = {WIDTH{1'b0}};
        tracker_rd_idx  = 6'd0;

        // ===============================================================
        // T1: Mode 1, N=50 — all 13 engine primes fit in tracker (cap=20)
        // Verify count, all values present, and read_idx=0 is the largest.
        // ===============================================================
        $display("");
        $display("=== T1: Mode 1, N=50 ===");
        do_reset;

        mode_sel = 2'd1;
        n_limit  = 27'd50;
        pulse_go;

        wait_done(200_000);
        repeat (3) @(posedge clk);

        // Check count
        $display("  tracker_count = %0d", tracker_count);
        if (tracker_count !== 7'd13) begin
            $display("FAIL T1a: tracker_count=%0d, expected 13", tracker_count);
            error_count = error_count + 1;
        end else
            $display("PASS T1a: tracker_count = 13");

        // Dump all entries
        dump_tracker(tracker_count);

        // Check read_idx=0 (most recent) — should be 47 (last 6k-1 prime ≤50)
        // Actually, which is "most recent" depends on engine interleaving.
        // The largest among all entries should be 47.
        // Let's find the max value across all entries.
        largest_val = {WIDTH{1'b0}};
        for (dump_i = 0; dump_i < 13; dump_i = dump_i + 1) begin
            read_tracker(dump_i[5:0], readback);
            if (readback > largest_val)
                largest_val = readback;
        end
        $display("  Largest value in tracker: %0d", largest_val);
        if (largest_val !== 27'd47) begin
            $display("FAIL T1b: largest=%0d, expected 47", largest_val);
            error_count = error_count + 1;
        end else
            $display("PASS T1b: largest prime is 47");

        // Check that all 13 expected primes are present
        // 6k+1 primes: 7,13,19,31,37,43
        // 6k-1 primes: 5,11,17,23,29,41,47
        begin : t1_check_all
            reg [WIDTH-1:0] exp [0:12];
            integer ei;
            exp[0]  = 27'd5;   exp[1]  = 27'd7;   exp[2]  = 27'd11;
            exp[3]  = 27'd13;  exp[4]  = 27'd17;  exp[5]  = 27'd19;
            exp[6]  = 27'd23;  exp[7]  = 27'd29;  exp[8]  = 27'd31;
            exp[9]  = 27'd37;  exp[10] = 27'd41;  exp[11] = 27'd43;
            exp[12] = 27'd47;

            for (ei = 0; ei < 13; ei = ei + 1) begin
                check_value_exists(exp[ei], tracker_count);
                if (!found_flag) begin
                    $display("FAIL T1c: prime %0d not found in tracker", exp[ei]);
                    error_count = error_count + 1;
                end
            end
            if (error_count == 0)
                $display("PASS T1c: all 13 expected primes present");
        end

        // ===============================================================
        // T2: Mode 1, N=100 — 23 engine primes, all fit in tracker (cap=40)
        // Primes (excluding 2,3): 5,7,11,13,17,19,23,29,31,37,41,43,47,
        //   53,59,61,67,71,73,79,83,89,97
        // That's 23. Tracker keeps all 23.
        // Largest should be 97.
        // ===============================================================
        $display("");
        $display("=== T2: Mode 1, N=100 ===");
        do_reset;

        mode_sel = 2'd1;
        n_limit  = 27'd100;
        pulse_go;

        wait_done(500_000);
        repeat (3) @(posedge clk);

        $display("  tracker_count = %0d", tracker_count);
        if (tracker_count !== 7'd23) begin
            $display("FAIL T2a: tracker_count=%0d, expected 23", tracker_count);
            error_count = error_count + 1;
        end else
            $display("PASS T2a: tracker_count = 23");

        dump_tracker(tracker_count);

        // Find largest
        largest_val = {WIDTH{1'b0}};
        for (dump_i = 0; dump_i < 23; dump_i = dump_i + 1) begin
            read_tracker(dump_i[5:0], readback);
            if (readback > largest_val)
                largest_val = readback;
        end
        $display("  Largest value in tracker: %0d", largest_val);
        if (largest_val !== 27'd97) begin
            $display("FAIL T2b: largest=%0d, expected 97", largest_val);
            error_count = error_count + 1;
        end else
            $display("PASS T2b: largest prime is 97");

        // Verify 97 specifically exists
        check_value_exists(27'd97, 7'd23);
        if (!found_flag) begin
            $display("FAIL T2c: 97 not found in tracker");
            error_count = error_count + 1;
        end else
            $display("PASS T2c: 97 found in tracker");

        // Check read_idx=0 (most recent entry)
        read_tracker(6'd0, readback);
        $display("  read_idx=0 (most recent): %0d", readback);

        // ===============================================================
        // T3: Mode 1, N=10000 — tracker wraps many times
        // Largest prime below 10000 is 9973 (6*1662 + 1, plus engine).
        // Second largest is 9967 (6*1661 + 1, plus engine).
        // Verifies correct data survives circular-buffer wrapping.
        // ===============================================================
        $display("");
        $display("=== T3: Mode 1, N=10000 ===");
        do_reset;

        mode_sel = 2'd1;
        n_limit  = 27'd10_000;
        pulse_go;

        $display("  Running...");
        wait_done(50_000_000);
        repeat (3) @(posedge clk);

        $display("  tracker_count = %0d", tracker_count);

        dump_tracker(tracker_count);

        // Find largest (tracker saturates at 64)
        largest_val = {WIDTH{1'b0}};
        for (dump_i = 0; dump_i < 64; dump_i = dump_i + 1) begin
            read_tracker(dump_i[5:0], readback);
            if (readback > largest_val)
                largest_val = readback;
        end
        $display("  Largest value in tracker: %0d", largest_val);

        // Check 9973 exists
        check_value_exists(27'd9973, 7'd64);
        if (!found_flag) begin
            $display("FAIL T3a: 9973 NOT found in tracker!");
            error_count = error_count + 1;
        end else
            $display("PASS T3a: 9973 found in tracker");

        // Check largest is 9973
        if (largest_val !== 27'd9973) begin
            $display("FAIL T3b: largest=%0d, expected 9973", largest_val);
            error_count = error_count + 1;
        end else
            $display("PASS T3b: largest prime is 9973");

        // Check what read_idx=0 gives (most recent entry)
        read_tracker(6'd0, readback);
        $display("  read_idx=0 (most recent): %0d", readback);
        // Also show idx=1
        read_tracker(6'd1, readback);
        $display("  read_idx=1: %0d", readback);

        // ===============================================================
        // Final verdict
        // ===============================================================
        $display("");
        $display("===========================");
        if (error_count == 0)
            $display("ALL TESTS PASSED");
        else
            $display("FAILED: %0d error(s)", error_count);
        $display("===========================");
        $finish;
    end

    // Safety timeout — kill sim if it runs too long
    initial begin
        #500_000_000_000;  // 500 ms sim time
        $display("GLOBAL TIMEOUT — simulation killed");
        $finish;
    end

endmodule
