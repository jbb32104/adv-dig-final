`timescale 1ns / 1ps
// Self-checking testbench for prime_accumulator.v (bitmap version).
// Tests: bit packing (all-ones, alternating, sparse), prime_count accuracy,
//        flush (partial word, empty shift register), FIFO read integrity,
//        FIFO full write-drop, simultaneous read+write at word boundary.
//
// Compile: iverilog -g2001 -o sim/accumulator_tb.vvp rtl/prime_accumulator.v tb/accumulator_tb.v
// Run:     vvp sim/accumulator_tb.vvp

module accumulator_tb;

    // -----------------------------------------------------------------------
    // Clock and reset
    // -----------------------------------------------------------------------
    reg clk;
    reg rst;

    initial clk = 0;
    always #5 clk = ~clk;   // 10 ns period = 100 MHz

    // -----------------------------------------------------------------------
    // DUT signals
    // -----------------------------------------------------------------------
    reg         prime_valid;
    reg         is_prime;
    reg         flush;
    wire        flush_done;
    reg         prime_fifo_rd_en;
    wire [31:0] prime_fifo_rd_data;
    wire        prime_fifo_empty;
    wire        prime_fifo_full;
    wire [31:0] prime_count;

    // -----------------------------------------------------------------------
    // DUT instantiation (FIFO_DEPTH=8 for fast fill/drain in simulation)
    // -----------------------------------------------------------------------
    prime_accumulator #(.FIFO_DEPTH(8)) u_acc (
        .clk                  (clk),
        .rst                  (rst),
        .prime_valid          (prime_valid),
        .is_prime             (is_prime),
        .flush                (flush),
        .flush_done_ff        (flush_done),
        .prime_fifo_rd_en     (prime_fifo_rd_en),
        .prime_fifo_rd_data_ff(prime_fifo_rd_data),
        .prime_fifo_empty_ff  (prime_fifo_empty),
        .prime_fifo_full_ff   (prime_fifo_full),
        .prime_count_ff       (prime_count)
    );

    // -----------------------------------------------------------------------
    // Error tracking
    // -----------------------------------------------------------------------
    integer error_count;
    initial error_count = 0;

    task check;
        input [255:0] test_name;
        input [31:0]  actual;
        input [31:0]  expected;
        begin
            if (actual !== expected) begin
                $display("FAIL: %0s -- got 0x%08h, expected 0x%08h at time %0t",
                         test_name, actual, expected, $time);
                error_count = error_count + 1;
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // Task: send one candidate result (prime_valid pulse, 1 cycle wide).
    // Idle posedge first so signals are stable well before the active edge.
    // -----------------------------------------------------------------------
    task send_candidate;
        input is_prime_val;
        begin
            @(posedge clk);
            prime_valid = 1'b1;
            is_prime    = is_prime_val;
            @(posedge clk);
            prime_valid = 1'b0;
            is_prime    = 1'b0;
        end
    endtask

    // -----------------------------------------------------------------------
    // Task: send 32 candidates whose is_prime bits match the 32-bit pattern.
    // Bit 0 of pattern = first candidate sent (LSB of packed FIFO word).
    // -----------------------------------------------------------------------
    task send_word_pattern;
        input [31:0] pattern;
        integer      j;
        begin
            for (j = 0; j < 32; j = j + 1)
                send_candidate(pattern[j]);
        end
    endtask

    // -----------------------------------------------------------------------
    // Task: read one 32-bit word from FIFO.
    // Assert rd_en, clock posedge latches data into rd_data_ff, deassert,
    // sample after #1 (NBA settle), idle posedge before next operation.
    // -----------------------------------------------------------------------
    task read_word;
        output [31:0] data_out;
        begin
            prime_fifo_rd_en = 1'b1;
            @(posedge clk);
            #1;
            data_out         = prime_fifo_rd_data;
            prime_fifo_rd_en = 1'b0;
            @(posedge clk);     // idle posedge before next operation
        end
    endtask

    // -----------------------------------------------------------------------
    // Temporaries
    // -----------------------------------------------------------------------
    integer i;
    reg [31:0] rd_result;

    // -----------------------------------------------------------------------
    // Main test sequence
    // -----------------------------------------------------------------------
    initial begin
        $dumpfile("sim/accumulator_tb.vcd");
        $dumpvars(0, accumulator_tb);

        // Init inputs
        prime_valid      = 1'b0;
        is_prime         = 1'b0;
        flush            = 1'b0;
        prime_fifo_rd_en = 1'b0;

        // -------------------------------------------------------------------
        // Reset: hold 4 cycles, settle 2 more
        // -------------------------------------------------------------------
        rst = 1'b1;
        repeat(4) @(posedge clk);
        rst = 1'b0;
        repeat(2) @(posedge clk);

        // -------------------------------------------------------------------
        // Test A: All-ones word
        // 32 candidates, all is_prime=1.
        // Expected packed word  : 0xFFFFFFFF
        // Expected prime_count  : 32
        // -------------------------------------------------------------------
        send_word_pattern(32'hFFFFFFFF);
        @(posedge clk); #1;
        check("A: FIFO not empty after full word", prime_fifo_empty, 1'b0);
        check("A: prime_count = 32",               prime_count,      32'd32);

        read_word(rd_result);
        check("A: packed word = 0xFFFFFFFF",  rd_result,        32'hFFFFFFFF);
        @(posedge clk); #1;
        check("A: FIFO empty after read",     prime_fifo_empty, 1'b1);

        // -------------------------------------------------------------------
        // Test B: Alternating pattern 0xAAAAAAAA
        // is_prime[i] = i[0] → bits 1,3,5,...,31 set.
        // Expected word         : 0xAAAAAAAA
        // Expected prime_count  : 32 + 16 = 48
        // -------------------------------------------------------------------
        send_word_pattern(32'hAAAAAAAA);
        @(posedge clk); #1;
        check("B: prime_count = 48",              prime_count,      32'd48);

        read_word(rd_result);
        check("B: packed word = 0xAAAAAAAA",  rd_result,        32'hAAAAAAAA);
        @(posedge clk); #1;
        check("B: FIFO empty after read",     prime_fifo_empty, 1'b1);

        // -------------------------------------------------------------------
        // Test C: Sparse pattern 0x00000096
        // Bits 1,2,4,7 set (is_prime=1 for positions 1,2,4,7; rest 0).
        // Expected word         : 0x00000096
        // Expected prime_count  : 48 + 4 = 52
        // -------------------------------------------------------------------
        send_word_pattern(32'h00000096);
        @(posedge clk); #1;
        check("C: prime_count = 52",              prime_count,      32'd52);

        read_word(rd_result);
        check("C: packed word = 0x00000096",  rd_result,        32'h00000096);
        @(posedge clk); #1;
        check("C: FIFO empty after read",     prime_fifo_empty, 1'b1);

        // -------------------------------------------------------------------
        // Test D: Flush partial word
        // 5 candidates: is_prime = 1,0,1,1,0
        //   bit0=1, bit1=0, bit2=1, bit3=1, bit4=0  → shift_reg = 0x0000000D
        // flush pulse: zero-pads upper 27 bits, writes 0x0000000D to FIFO.
        // flush_done_ff pulses one cycle after the flush posedge.
        // Expected prime_count  : 52 + 3 = 55
        // -------------------------------------------------------------------
        send_candidate(1'b1);   // bit 0 = 1
        send_candidate(1'b0);   // bit 1 = 0
        send_candidate(1'b1);   // bit 2 = 1
        send_candidate(1'b1);   // bit 3 = 1
        send_candidate(1'b0);   // bit 4 = 0

        @(posedge clk); #1;
        check("D: prime_count = 55 before flush", prime_count,       32'd55);
        check("D: FIFO empty before flush",       prime_fifo_empty,  1'b1);

        // Assert flush for one cycle
        @(posedge clk);
        flush = 1'b1;
        @(posedge clk);         // flush captured: FIFO write + flush_done latch here
        flush = 1'b0;
        #1;                     // NBA settle
        check("D: flush_done pulses",          flush_done,       1'b1);
        check("D: FIFO not empty after flush", prime_fifo_empty, 1'b0);

        @(posedge clk); #1;
        check("D: flush_done deasserts next cycle", flush_done, 1'b0);

        read_word(rd_result);
        check("D: flushed word = 0x0000000D", rd_result, 32'h0000000D);
        @(posedge clk); #1;
        check("D: FIFO empty after read",     prime_fifo_empty, 1'b1);

        // -------------------------------------------------------------------
        // Test E: Flush with empty shift register (bit_count = 0)
        // flush_done should still pulse, but no FIFO write (nothing to flush).
        // -------------------------------------------------------------------
        @(posedge clk);
        flush = 1'b1;
        @(posedge clk);
        flush = 1'b0;
        #1;
        check("E: flush_done pulses on empty shift_reg", flush_done,      1'b1);
        check("E: FIFO stays empty",                     prime_fifo_empty, 1'b1);

        // -------------------------------------------------------------------
        // Test F: Fill FIFO to full
        // FIFO_DEPTH=8 words = 256 candidates.
        // Send 8 complete words of all-ones.
        // Expected prime_fifo_full_ff : 1
        // Expected prime_count        : 55 + 256 = 311
        // -------------------------------------------------------------------
        for (i = 0; i < 8; i = i + 1)
            send_word_pattern(32'hFFFFFFFF);

        @(posedge clk); #1;
        check("F: FIFO full after 8 words", prime_fifo_full, 1'b1);
        check("F: prime_count = 311",       prime_count,     32'd311);

        // -------------------------------------------------------------------
        // Test G: Write while FIFO full (word silently dropped)
        // One more complete all-ones word while FIFO is full.
        // FIFO write is dropped, but prime_count still advances (tracks primes
        // found, not primes stored) — upstream stall via prime_fifo_full_ff
        // prevents this in normal operation.
        // Expected prime_fifo_full_ff : still 1
        // Expected prime_count        : 311 + 32 = 343
        // -------------------------------------------------------------------
        send_word_pattern(32'hFFFFFFFF);
        @(posedge clk); #1;
        check("G: FIFO still full after overflow", prime_fifo_full, 1'b1);
        check("G: prime_count = 343 (counts finds, not stores)", prime_count, 32'd343);

        // -------------------------------------------------------------------
        // Test H: Drain FIFO and verify all 8 stored words are 0xFFFFFFFF
        // (the overflow word from Test G was dropped, not stored)
        // -------------------------------------------------------------------
        for (i = 0; i < 8; i = i + 1) begin
            read_word(rd_result);
            check("H: drained word = 0xFFFFFFFF", rd_result, 32'hFFFFFFFF);
        end
        @(posedge clk); #1;
        check("H: FIFO empty after full drain", prime_fifo_empty, 1'b1);

        // -------------------------------------------------------------------
        // Test I: Simultaneous read (on empty FIFO) and word-completing write
        // Queue 31 bits, then assert both prime_valid and rd_en on the 32nd.
        // FIFO is empty so the read is blocked; write completes successfully.
        // Expected: FIFO has exactly 1 word after the posedge.
        // -------------------------------------------------------------------
        for (i = 0; i < 31; i = i + 1)
            send_candidate(1'b1);

        // 32nd candidate coincides with rd_en (FIFO empty — read blocked)
        @(posedge clk);
        prime_valid      = 1'b1;
        is_prime         = 1'b1;
        prime_fifo_rd_en = 1'b1;    // FIFO empty: read will be ignored
        @(posedge clk);             // word completes, FIFO write succeeds; read blocked
        prime_valid      = 1'b0;
        is_prime         = 1'b0;
        prime_fifo_rd_en = 1'b0;
        @(posedge clk); #1;
        check("I: FIFO has 1 word after blocked-read + write", prime_fifo_empty, 1'b0);
        check("I: FIFO not spuriously full",                   prime_fifo_full,  1'b0);

        read_word(rd_result);
        check("I: word = 0xFFFFFFFF", rd_result, 32'hFFFFFFFF);
        @(posedge clk); #1;
        check("I: FIFO empty after read", prime_fifo_empty, 1'b1);

        // -------------------------------------------------------------------
        // Final verdict
        // -------------------------------------------------------------------
        if (error_count == 0) begin
            $display("ALL TESTS PASSED");
        end else begin
            $display("FAILED: %0d errors", error_count);
        end
        $finish;
    end

endmodule
