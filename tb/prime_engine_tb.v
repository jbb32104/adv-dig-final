// prime_engine_tb.v
// Self-checking testbench for prime_engine.v.
// Sweeps candidates 2..10007, compares engine output against golden_primes.mem.
// Reports PASS if all results match; FAIL with candidate details on any mismatch.
// Detects FSM hangs via 200000-cycle per-candidate timeout.
// Detects missing/zeroed golden_primes.mem via load guard on index 2.
//
// Run from project root:
//   iverilog -g2001 -o sim/prime_engine_tb.vvp rtl/divider.v rtl/prime_engine.v tb/prime_engine_tb.v
//   vvp sim/prime_engine_tb.vvp

`timescale 1ns/1ps
module prime_engine_tb;

    // -----------------------------------------------------------------------
    // Parameters
    // -----------------------------------------------------------------------
    parameter WIDTH          = 27;
    parameter CLK_PERIOD     = 10;       // 100 MHz
    parameter MAX_CANDIDATE  = 10007;
    parameter TIMEOUT_CYCLES = 200000;

    // -----------------------------------------------------------------------
    // DUT signals
    // -----------------------------------------------------------------------
    reg             clk;
    reg             rst;
    reg             start;
    reg [WIDTH-1:0] candidate;
    wire            done_ff;
    wire            is_prime_ff;
    wire            busy_ff;

    // -----------------------------------------------------------------------
    // Golden list memory (1-bit wide, indexed 0..MAX_CANDIDATE)
    // -----------------------------------------------------------------------
    reg golden [0:MAX_CANDIDATE];

    initial begin
        $readmemb("tb/golden_primes.mem", golden);
        // GUARD: iVerilog silently zeroes memory when the file is missing or
        // the path is wrong. golden[2] MUST be 1 (2 is prime). If it is 0,
        // the file did not load -- abort immediately so we don't produce
        // misleading all-fail results.
        if (golden[2] !== 1'b1) begin
            $display("FATAL: golden_primes.mem not loaded or path wrong");
            $finish;
        end
    end

    // -----------------------------------------------------------------------
    // Test tracking registers
    // -----------------------------------------------------------------------
    integer errors;
    integer test_count;
    integer timeout_counter;
    integer i;  // loop variable (for loops permitted in testbenches: INFRA-05)

    // -----------------------------------------------------------------------
    // DUT instantiation (exact port names from rtl/prime_engine.v)
    // -----------------------------------------------------------------------
    prime_engine #(.WIDTH(WIDTH)) dut (
        .clk        (clk),
        .rst        (rst),
        .start      (start),
        .candidate  (candidate),
        .done_ff    (done_ff),
        .is_prime_ff(is_prime_ff),
        .busy_ff    (busy_ff)
    );

    // -----------------------------------------------------------------------
    // Clock generation: 100 MHz (period = 10 ns)
    // -----------------------------------------------------------------------
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // -----------------------------------------------------------------------
    // Task: apply_and_check
    // Present one candidate to the DUT, wait for done_ff, compare result.
    // Uses a cycle timeout to detect FSM hangs.
    // -----------------------------------------------------------------------
    task apply_and_check;
        input [WIDTH-1:0] cand;
        input             expected_prime;
        begin
            // Drive candidate and assert start for one cycle
            @(posedge clk);
            candidate = cand;
            start = 1'b1;
            @(posedge clk);
            start = 1'b0;

            // Wait for done_ff with timeout
            timeout_counter = 0;
            while (done_ff !== 1'b1 && timeout_counter < TIMEOUT_CYCLES) begin
                @(posedge clk);
                timeout_counter = timeout_counter + 1;
            end

            if (timeout_counter >= TIMEOUT_CYCLES) begin
                $display("FAIL: TIMEOUT candidate=%0d after %0d cycles", cand, TIMEOUT_CYCLES);
                errors = errors + 1;
            end else if (is_prime_ff !== expected_prime) begin
                $display("FAIL: candidate=%0d expected_prime=%0b got=%0b",
                          cand, expected_prime, is_prime_ff);
                errors = errors + 1;
            end

            // Wait for done_ff to deassert before starting the next test
            @(posedge clk);
        end
    endtask

    // -----------------------------------------------------------------------
    // Main test sequence
    // -----------------------------------------------------------------------
    initial begin
        // Optional VCD dump for debugging (written to sim/ directory)
        $dumpfile("sim/prime_engine_tb.vcd");
        $dumpvars(0, prime_engine_tb);

        errors     = 0;
        test_count = 0;
        rst        = 1'b1;
        start      = 1'b0;
        candidate  = {WIDTH{1'b0}};

        // Hold reset for 4 clock cycles (synchronous reset)
        repeat(4) @(posedge clk);
        rst = 1'b0;
        @(posedge clk);

        // Sweep candidates 2 through MAX_CANDIDATE (inclusive)
        for (i = 2; i <= MAX_CANDIDATE; i = i + 1) begin
            apply_and_check(i[WIDTH-1:0], golden[i]);
            test_count = test_count + 1;
            // Progress report every 1000 candidates to show the sim is alive
            if (i % 1000 == 0)
                $display("INFO: tested up to candidate %0d, errors so far: %0d", i, errors);
        end

        // Final result report
        $display("---");
        $display("Tested %0d candidates (2..%0d)", test_count, MAX_CANDIDATE);
        if (errors == 0)
            $display("PASS: all %0d tests passed", test_count);
        else
            $display("FAIL: %0d errors out of %0d tests", errors, test_count);
        $display("---");
        $finish;
    end

endmodule
