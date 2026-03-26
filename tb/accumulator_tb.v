`timescale 1ns / 1ps
// Self-checking unit testbench for prime_accumulator.v and elapsed_timer.v
// Tests: FIFO write/read, full/empty flags, prime_count, last-20 ring buffer,
//        elapsed_timer cycle count, seconds tick, freeze semantics.
//
// Compile: iverilog -g2001 -o sim/accumulator_tb.vvp rtl/elapsed_timer.v rtl/prime_accumulator.v tb/accumulator_tb.v
// Run:     vvp sim/accumulator_tb.vvp
//
// Write protocol: idle posedge, then set data+valid, then write posedge, then deassert.
// Read protocol:  set rd_en, then read posedge, then #1 sample, then deassert rd_en.
//                 Idle posedge between consecutive reads.

module accumulator_tb;

    // -----------------------------------------------------------------------
    // Clock and reset
    // -----------------------------------------------------------------------
    reg clk;
    reg rst;

    initial clk = 0;
    always #5 clk = ~clk;   // 10 ns period = 100 MHz

    // -----------------------------------------------------------------------
    // elapsed_timer DUT signals
    // -----------------------------------------------------------------------
    reg         freeze;
    wire [31:0] timer_cycle_count;
    wire [31:0] timer_seconds;
    wire        timer_second_tick;

    // -----------------------------------------------------------------------
    // prime_accumulator DUT signals
    // -----------------------------------------------------------------------
    reg             prime_valid;
    reg  [26:0]     prime_data;
    reg             prime_fifo_rd_en;
    wire [26:0]     prime_fifo_rd_data;
    wire            prime_fifo_empty;
    wire            prime_fifo_full;
    wire [31:0]     prime_count;
    wire [26:0]     last20_0,  last20_1,  last20_2,  last20_3;
    wire [26:0]     last20_4,  last20_5,  last20_6,  last20_7;
    wire [26:0]     last20_8,  last20_9,  last20_10, last20_11;
    wire [26:0]     last20_12, last20_13, last20_14, last20_15;
    wire [26:0]     last20_16, last20_17, last20_18, last20_19;

    // -----------------------------------------------------------------------
    // DUT instantiation -- elapsed_timer (TICK_PERIOD=100 for simulation)
    // -----------------------------------------------------------------------
    elapsed_timer #(.TICK_PERIOD(100)) u_timer (
        .clk           (clk),
        .rst           (rst),
        .freeze        (freeze),
        .cycle_count_ff(timer_cycle_count),
        .seconds_ff    (timer_seconds),
        .second_tick_ff(timer_second_tick)
    );

    // -----------------------------------------------------------------------
    // DUT instantiation -- prime_accumulator (WIDTH=27, FIFO_DEPTH=32)
    // -----------------------------------------------------------------------
    prime_accumulator #(.WIDTH(27), .FIFO_DEPTH(32)) u_acc (
        .clk                  (clk),
        .rst                  (rst),
        .prime_valid          (prime_valid),
        .prime_data           (prime_data),
        .prime_fifo_rd_en     (prime_fifo_rd_en),
        .prime_fifo_rd_data_ff(prime_fifo_rd_data),
        .prime_fifo_empty_ff  (prime_fifo_empty),
        .prime_fifo_full_ff   (prime_fifo_full),
        .prime_count_ff       (prime_count),
        .last20_0_ff          (last20_0),
        .last20_1_ff          (last20_1),
        .last20_2_ff          (last20_2),
        .last20_3_ff          (last20_3),
        .last20_4_ff          (last20_4),
        .last20_5_ff          (last20_5),
        .last20_6_ff          (last20_6),
        .last20_7_ff          (last20_7),
        .last20_8_ff          (last20_8),
        .last20_9_ff          (last20_9),
        .last20_10_ff         (last20_10),
        .last20_11_ff         (last20_11),
        .last20_12_ff         (last20_12),
        .last20_13_ff         (last20_13),
        .last20_14_ff         (last20_14),
        .last20_15_ff         (last20_15),
        .last20_16_ff         (last20_16),
        .last20_17_ff         (last20_17),
        .last20_18_ff         (last20_18),
        .last20_19_ff         (last20_19)
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
                $display("FAIL: %0s -- got %0d, expected %0d at time %0t",
                         test_name, actual, expected, $time);
                error_count = error_count + 1;
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // Write helper task: one idle posedge, then set data+valid, write posedge,
    //                    deassert valid.  Data is stable well before posedge.
    // -----------------------------------------------------------------------
    task write_prime;
        input [26:0] data;
        begin
            @(posedge clk);           // idle posedge (signals stable LOW here)
            prime_data  = data;
            prime_valid = 1'b1;
            @(posedge clk);           // write posedge: DUT latches data+valid
            prime_valid = 1'b0;
            prime_data  = 27'd0;
        end
    endtask

    // -----------------------------------------------------------------------
    // Read helper task: set rd_en, read posedge, sample after #1, deassert.
    //                   One explicit idle posedge after deassert so the next
    //                   call starts cleanly.
    // -----------------------------------------------------------------------
    task read_prime;
        output [26:0] data_out;
        begin
            prime_fifo_rd_en = 1'b1;
            @(posedge clk);           // read posedge: DUT latches rd_en, outputs data
            #1;                       // let NBA settle
            data_out         = prime_fifo_rd_data;
            prime_fifo_rd_en = 1'b0;
            @(posedge clk);           // idle posedge before next read
        end
    endtask

    // -----------------------------------------------------------------------
    // Temporaries
    // -----------------------------------------------------------------------
    integer        i;
    reg [31:0]     saved_cycle;
    reg [31:0]     saved_seconds;
    reg [26:0]     rd_result;

    // -----------------------------------------------------------------------
    // Main test sequence
    // -----------------------------------------------------------------------
    initial begin
        $dumpfile("sim/accumulator_tb.vcd");
        $dumpvars(0, accumulator_tb);

        // Initialise inputs
        freeze           = 1'b0;
        prime_valid      = 1'b0;
        prime_data       = 27'd0;
        prime_fifo_rd_en = 1'b0;

        // -------------------------------------------------------------------
        // Reset: hold for 4 clock cycles (synchronous), settle 2 more cycles
        // -------------------------------------------------------------------
        rst = 1'b1;
        repeat(4) @(posedge clk);
        rst = 1'b0;
        repeat(2) @(posedge clk);

        // -------------------------------------------------------------------
        // Test A: elapsed_timer basic counting
        //
        // Sample cycle_count_ff after NBA settles (posedge + #1), advance
        // exactly 50 posedges, verify delta = 50.
        // -------------------------------------------------------------------
        begin : test_A
            reg [31:0] count_before;
            reg [31:0] count_after;
            @(posedge clk); #1;
            count_before = timer_cycle_count;
            repeat(50) @(posedge clk);
            #1;
            count_after = timer_cycle_count;
            check("A: cycle_count advanced by 50",
                  count_after - count_before, 32'd50);
        end

        // Let timer run until seconds_ff reaches 1 (TICK_PERIOD=100 cycles)
        begin : test_A2
            integer watchdog;
            watchdog = 0;
            while (timer_seconds < 32'd1 && watchdog < 400) begin
                @(posedge clk); #1;
                watchdog = watchdog + 1;
            end
            check("A: seconds_ff reached 1", timer_seconds, 32'd1);
        end

        // -------------------------------------------------------------------
        // Test B: elapsed_timer freeze
        //
        // Assert freeze, then on the NEXT posedge sample the now-frozen value.
        // Verify after 20 more posedges the values haven't changed.
        // Deassert freeze, verify counting resumes.
        // -------------------------------------------------------------------
        @(posedge clk); #1;
        freeze = 1'b1;
        @(posedge clk); #1;           // one cycle for freeze to take effect
        saved_cycle   = timer_cycle_count;
        saved_seconds = timer_seconds;
        repeat(20) @(posedge clk);
        #1;
        check("B: cycle_count frozen",  timer_cycle_count, saved_cycle);
        check("B: seconds frozen",      timer_seconds,     saved_seconds);

        // Deassert freeze, confirm counting resumes
        freeze = 1'b0;
        @(posedge clk); #1;
        @(posedge clk); #1;
        if (timer_cycle_count <= saved_cycle) begin
            $display("FAIL: B: counting did not resume -- cycle=%0d saved=%0d at %0t",
                     timer_cycle_count, saved_cycle, $time);
            error_count = error_count + 1;
        end

        // -------------------------------------------------------------------
        // Test C: prime_accumulator -- write 5 primes, check count and FIFO
        //
        // Use write_prime task (each write has a preceding idle posedge so
        // data is stable well before the active posedge).
        // -------------------------------------------------------------------
        write_prime(27'd2);
        write_prime(27'd3);
        write_prime(27'd5);
        write_prime(27'd7);
        write_prime(27'd11);

        // Settle and sample
        @(posedge clk); #1;
        check("C: prime_count after 5 writes", prime_count,      32'd5);
        check("C: FIFO not empty",             prime_fifo_empty, 1'b0);
        check("C: FIFO not full",              prime_fifo_full,  1'b0);

        // -------------------------------------------------------------------
        // Test D: prime_accumulator -- read back 5 entries from FIFO
        //
        // Use read_prime task.  Each call includes a trailing idle posedge so
        // FIFO state is stable before the next read.
        // Expected FIFO read order: 2, 3, 5, 7, 11.
        // -------------------------------------------------------------------
        read_prime(rd_result); check("D: FIFO[0] = 2",  {5'd0, rd_result}, 32'd2);
        read_prime(rd_result); check("D: FIFO[1] = 3",  {5'd0, rd_result}, 32'd3);
        read_prime(rd_result); check("D: FIFO[2] = 5",  {5'd0, rd_result}, 32'd5);
        read_prime(rd_result); check("D: FIFO[3] = 7",  {5'd0, rd_result}, 32'd7);
        read_prime(rd_result); check("D: FIFO[4] = 11", {5'd0, rd_result}, 32'd11);

        @(posedge clk); #1;
        check("D: FIFO empty after 5 reads", prime_fifo_empty, 1'b1);

        // -------------------------------------------------------------------
        // Test E: prime_accumulator -- fill FIFO to full (32 entries)
        //
        // Write values 100..131.  After 32 writes prime_fifo_full_ff = 1.
        // prime_count = 37 (5 from C + 32 from E).
        // A 33rd write must NOT increment prime_count (FIFO full blocks it).
        // -------------------------------------------------------------------
        for (i = 0; i < 32; i = i + 1) begin
            write_prime(27'd100 + i[26:0]);
        end
        @(posedge clk); #1;
        check("E: FIFO full after 32 writes", prime_fifo_full,  1'b1);
        check("E: prime_count is 37",         prime_count,      32'd37);

        // Attempt blocked write (FIFO full)
        @(posedge clk);
        prime_data  = 27'd200;
        prime_valid = 1'b1;
        @(posedge clk);
        prime_valid = 1'b0;
        prime_data  = 27'd0;
        @(posedge clk); #1;
        check("E: prime_count still 37 after blocked write", prime_count, 32'd37);

        // -------------------------------------------------------------------
        // Test F: last-20 ring buffer wrap
        //
        // After 37 successful writes:
        //   ring_wr_ptr_ff = 17  (next write position)
        //
        // Ring buffer layout:
        //   slot  0: value 115  (write #21, counted from 1)
        //   slot  1: value 116  (write #22)
        //   ...
        //   slot 16: value 131  (write #37)
        //   slot 17: value 112  (write #18)
        //   slot 18: value 113  (write #19)
        //   slot 19: value 114  (write #20)
        //
        // The last20_X_ff output ports have an extra pipeline cycle from the
        // output-copy always block (last20_ff updates on posedge N, output
        // port reflects that on posedge N+1).
        // Allow 2 full idle posedges after the last write before sampling.
        // -------------------------------------------------------------------
        repeat(2) @(posedge clk); #1;

        check("F: last20[0]  = 115", {{5{1'b0}}, last20_0},  32'd115);
        check("F: last20[1]  = 116", {{5{1'b0}}, last20_1},  32'd116);
        check("F: last20[2]  = 117", {{5{1'b0}}, last20_2},  32'd117);
        check("F: last20[3]  = 118", {{5{1'b0}}, last20_3},  32'd118);
        check("F: last20[4]  = 119", {{5{1'b0}}, last20_4},  32'd119);
        check("F: last20[5]  = 120", {{5{1'b0}}, last20_5},  32'd120);
        check("F: last20[6]  = 121", {{5{1'b0}}, last20_6},  32'd121);
        check("F: last20[7]  = 122", {{5{1'b0}}, last20_7},  32'd122);
        check("F: last20[8]  = 123", {{5{1'b0}}, last20_8},  32'd123);
        check("F: last20[9]  = 124", {{5{1'b0}}, last20_9},  32'd124);
        check("F: last20[10] = 125", {{5{1'b0}}, last20_10}, 32'd125);
        check("F: last20[11] = 126", {{5{1'b0}}, last20_11}, 32'd126);
        check("F: last20[12] = 127", {{5{1'b0}}, last20_12}, 32'd127);
        check("F: last20[13] = 128", {{5{1'b0}}, last20_13}, 32'd128);
        check("F: last20[14] = 129", {{5{1'b0}}, last20_14}, 32'd129);
        check("F: last20[15] = 130", {{5{1'b0}}, last20_15}, 32'd130);
        check("F: last20[16] = 131", {{5{1'b0}}, last20_16}, 32'd131);
        check("F: last20[17] = 112", {{5{1'b0}}, last20_17}, 32'd112);
        check("F: last20[18] = 113", {{5{1'b0}}, last20_18}, 32'd113);
        check("F: last20[19] = 114", {{5{1'b0}}, last20_19}, 32'd114);

        // -------------------------------------------------------------------
        // Test G: FIFO drain and re-fill
        //
        // Drain all 32 entries, verify empty, re-fill with 3, verify count=40.
        // -------------------------------------------------------------------
        for (i = 0; i < 32; i = i + 1) begin
            read_prime(rd_result);   // discard data; just drain
        end
        @(posedge clk); #1;
        check("G: FIFO empty after full drain", prime_fifo_empty, 1'b1);

        write_prime(27'd500);
        write_prime(27'd501);
        write_prime(27'd502);
        @(posedge clk); #1;
        check("G: FIFO not empty after 3 writes", prime_fifo_empty, 1'b0);
        check("G: prime_count is 40",             prime_count,      32'd40);

        // -------------------------------------------------------------------
        // Final verdict
        // -------------------------------------------------------------------
        if (error_count == 0) begin
            $display("ALL TESTS PASSED");
        end else begin
            $display("FAILED: %0d errors", error_count);
            $fatal;
        end
        $finish;
    end

endmodule
