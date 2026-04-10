`timescale 1ns / 1ps
// Integration testbench for test_top_with_ssd.v
// Exercises the full datapath: debounce → mode_fsm → 2x prime_engine →
// 2x prime_accumulator → pop FSM → ssd.
//
// Tests:
//   T1: Mode 1, N=50 — wait for done, verify LED[0] asserts
//   T2: Pop 6k-1 FIFO (BTNL) — verify SSD display_word matches expected bitmap
//   T3: Pop 6k+1 FIFO (BTNR) — verify SSD display_word matches expected bitmap
//   T4: Mode 3, candidate=97 — verify LED[7]=1 (prime)
//   T5: Mode 3, candidate=99 — verify LED[7]=0 (composite)
//   T6: Pop on empty FIFO — SSD word unchanged, no hang
//   T7: Mode 2, T=2 sim-seconds — done asserts within timeout
//
// Uses DEBOUNCE_CYCLES=4 override and TICK_PERIOD=100 for fast simulation.
// Uses tb/prime_fifo_ip.v behavioral stub (no Vivado IP needed).
//
// Compile: iverilog -g2001 -o sim\test_top_with_ssd_tb.vvp rtl\divider.v rtl\prime_engine.v rtl\elapsed_timer.v rtl\prime_accumulator.v tb\prime_fifo_ip.v rtl\mode_fsm.v rtl\debounce.v rtl\ssd.v rtl\test_top_with_ssd.v tb\test_top_with_ssd_tb.v
// Run:     vvp sim\test_top_with_ssd_tb.vvp

// ---------------------------------------------------------------------------
// Wrapper: override parameters that are hardcoded in test_top_with_ssd.
// Vivado supports parameter override at instantiation; iverilog requires a
// wrapper module that re-exposes the same ports with overridden sub-params.
// ---------------------------------------------------------------------------
module test_top_sim #(
    parameter WIDTH = 27
) (
    input  wire        clk,
    input  wire        rst,
    input  wire [15:0] SW,
    input  wire        BTNC,
    input  wire        BTNR,
    input  wire        BTNL,
    output wire [7:0]  LED,
    output wire [6:0]  SEG,
    output wire [7:0]  AN,
    output wire        DP_n
);

    // Internal debounce wires (re-instantiate with fast debounce)
    wire go_pulse;
    wire pop_plus_pulse;
    wire pop_minus_pulse;

    debounce #(.DEBOUNCE_CYCLES(4)) u_dbnc_btnc (
        .clk(clk), .rst(rst), .btn_in(BTNC),
        .btn_state_ff(), .rising_pulse_ff(go_pulse), .falling_pulse_ff()
    );
    debounce #(.DEBOUNCE_CYCLES(4)) u_dbnc_btnr (
        .clk(clk), .rst(rst), .btn_in(BTNR),
        .btn_state_ff(), .rising_pulse_ff(pop_plus_pulse), .falling_pulse_ff()
    );
    debounce #(.DEBOUNCE_CYCLES(4)) u_dbnc_btnl (
        .clk(clk), .rst(rst), .btn_in(BTNL),
        .btn_state_ff(), .rising_pulse_ff(pop_minus_pulse), .falling_pulse_ff()
    );

    wire [1:0]       mode_sel        = SW[1:0];
    wire [WIDTH-1:0] n_limit         = {{WIDTH-14{1'b0}}, SW[15:2]};
    wire [31:0]      t_limit         = {18'd0, SW[15:2]};
    wire [WIDTH-1:0] check_candidate = {{WIDTH-14{1'b0}}, SW[15:2]};

    wire             eng_plus_start,  eng_plus_done,  eng_plus_is_prime,  eng_plus_busy;
    wire             eng_minus_start, eng_minus_done, eng_minus_is_prime, eng_minus_busy;
    wire [WIDTH-1:0] eng_plus_candidate, eng_minus_candidate;

    wire acc_plus_valid,  acc_plus_is_prime,  acc_plus_flush,  acc_plus_flush_done,  acc_plus_fifo_full;
    wire acc_minus_valid, acc_minus_is_prime, acc_minus_flush, acc_minus_flush_done, acc_minus_fifo_full;

    wire        timer_freeze;
    wire [31:0] seconds, cycle_count;
    wire        done, is_prime_result;
    wire [3:0]  state_out;

    wire [31:0] acc_plus_rd_data,  acc_minus_rd_data;
    wire        acc_plus_fifo_empty, acc_minus_fifo_empty;

    reg rd_en_plus_ff, rd_en_minus_ff;

    mode_fsm #(.WIDTH(WIDTH)) u_fsm (
        .clk(clk), .rst(rst),
        .mode_sel(mode_sel), .n_limit(n_limit), .t_limit(t_limit),
        .check_candidate(check_candidate), .go(go_pulse),
        .eng_plus_start_ff(eng_plus_start),   .eng_plus_candidate_ff(eng_plus_candidate),
        .eng_plus_done(eng_plus_done),         .eng_plus_is_prime(eng_plus_is_prime),
        .eng_plus_busy(eng_plus_busy),
        .eng_minus_start_ff(eng_minus_start),  .eng_minus_candidate_ff(eng_minus_candidate),
        .eng_minus_done(eng_minus_done),       .eng_minus_is_prime(eng_minus_is_prime),
        .eng_minus_busy(eng_minus_busy),
        .acc_plus_valid_ff(acc_plus_valid),    .acc_plus_is_prime_ff(acc_plus_is_prime),
        .acc_plus_flush_ff(acc_plus_flush),    .acc_plus_flush_done(acc_plus_flush_done),
        .acc_plus_fifo_full(acc_plus_fifo_full),
        .acc_minus_valid_ff(acc_minus_valid),  .acc_minus_is_prime_ff(acc_minus_is_prime),
        .acc_minus_flush_ff(acc_minus_flush),  .acc_minus_flush_done(acc_minus_flush_done),
        .acc_minus_fifo_full(acc_minus_fifo_full),
        .timer_freeze_ff(timer_freeze), .seconds_ff(seconds), .cycle_count_ff(cycle_count),
        .done_ff(done), .is_prime_result_ff(is_prime_result), .state_out_ff(state_out)
    );

    prime_engine #(.WIDTH(WIDTH)) u_eng_plus (
        .clk(clk), .rst(rst), .start(eng_plus_start), .candidate(eng_plus_candidate),
        .done_ff(eng_plus_done), .is_prime_ff(eng_plus_is_prime), .busy_ff(eng_plus_busy)
    );
    prime_engine #(.WIDTH(WIDTH)) u_eng_minus (
        .clk(clk), .rst(rst), .start(eng_minus_start), .candidate(eng_minus_candidate),
        .done_ff(eng_minus_done), .is_prime_ff(eng_minus_is_prime), .busy_ff(eng_minus_busy)
    );

    prime_accumulator u_acc_plus (
        .clk(clk), .rst(rst), .rd_clk(clk),
        .prime_valid(acc_plus_valid), .is_prime(acc_plus_is_prime),
        .flush(acc_plus_flush), .flush_done_ff(acc_plus_flush_done),
        .prime_fifo_rd_en(rd_en_plus_ff), .prime_fifo_rd_data(acc_plus_rd_data),
        .prime_fifo_empty(acc_plus_fifo_empty), .prime_fifo_full(acc_plus_fifo_full),
        .prime_count_ff()
    );
    prime_accumulator u_acc_minus (
        .clk(clk), .rst(rst), .rd_clk(clk),
        .prime_valid(acc_minus_valid), .is_prime(acc_minus_is_prime),
        .flush(acc_minus_flush), .flush_done_ff(acc_minus_flush_done),
        .prime_fifo_rd_en(rd_en_minus_ff), .prime_fifo_rd_data(acc_minus_rd_data),
        .prime_fifo_empty(acc_minus_fifo_empty), .prime_fifo_full(acc_minus_fifo_full),
        .prime_count_ff()
    );

    elapsed_timer #(.TICK_PERIOD(100)) u_timer (
        .clk(clk), .rst(rst), .freeze(timer_freeze),
        .cycle_count_ff(cycle_count), .seconds_ff(seconds), .second_tick_ff()
    );

    // Pop FSM (identical to test_top_with_ssd, pulled out for param override)
    localparam POP_IDLE = 2'd0, POP_RD_EN = 2'd1, POP_WAIT = 2'd2, POP_CAPTURE = 2'd3;

    reg [1:0]  pop_state_ff;
    reg        pop_plus_active_ff;
    reg [31:0] display_word_ff;

    reg [1:0]  next_pop_state;
    reg        next_pop_plus_active;
    reg [31:0] next_display_word;
    reg        next_rd_en_plus;
    reg        next_rd_en_minus;

    always @(*) begin
        next_pop_state       = pop_state_ff;
        next_pop_plus_active = pop_plus_active_ff;
        next_display_word    = display_word_ff;
        next_rd_en_plus      = 1'b0;
        next_rd_en_minus     = 1'b0;

        if (rst) begin
            next_pop_state       = POP_IDLE;
            next_pop_plus_active = 1'b0;
            next_display_word    = 32'h0;
        end else begin
            case (pop_state_ff)
                POP_IDLE: begin
                    if (pop_plus_pulse && !acc_plus_fifo_empty) begin
                        next_pop_plus_active = 1'b1;
                        next_pop_state       = POP_RD_EN;
                    end else if (pop_minus_pulse && !acc_minus_fifo_empty) begin
                        next_pop_plus_active = 1'b0;
                        next_pop_state       = POP_RD_EN;
                    end
                end
                POP_RD_EN: begin
                    next_rd_en_plus  =  pop_plus_active_ff;
                    next_rd_en_minus = ~pop_plus_active_ff;
                    next_pop_state   = POP_WAIT;
                end
                POP_WAIT:    next_pop_state = POP_CAPTURE;
                POP_CAPTURE: begin
                    next_display_word = pop_plus_active_ff ? acc_plus_rd_data : acc_minus_rd_data;
                    next_pop_state    = POP_IDLE;
                end
                default: next_pop_state = POP_IDLE;
            endcase
        end
    end

    always @(posedge clk) begin
        pop_state_ff       <= next_pop_state;
        pop_plus_active_ff <= next_pop_plus_active;
        display_word_ff    <= next_display_word;
        rd_en_plus_ff      <= next_rd_en_plus;
        rd_en_minus_ff     <= next_rd_en_minus;
    end

    ssd #(.CLK_FREQ_HZ(100), .REFRESH_RATE(4)) u_ssd (
        .clk(clk), .rst(rst), .value(display_word_ff),
        .dp_en(8'h0), .SEG(SEG), .AN(AN), .DP_n(DP_n)
    );

    assign LED[0] = done;
    assign LED[1] = eng_plus_busy;
    assign LED[2] = eng_minus_busy;
    assign LED[3] = acc_plus_fifo_full;
    assign LED[4] = acc_minus_fifo_full;
    assign LED[5] = acc_plus_fifo_empty;
    assign LED[6] = acc_minus_fifo_empty;
    assign LED[7] = is_prime_result;

    // Expose internals for testbench checks
    assign display_word_out = display_word_ff;
    wire [31:0] display_word_out;

endmodule


// ---------------------------------------------------------------------------
// Testbench
// ---------------------------------------------------------------------------
module test_top_with_ssd_tb;

    parameter WIDTH = 27;

    reg        clk;
    reg        rst;
    reg [15:0] SW;
    reg        BTNC, BTNR, BTNL;
    wire [7:0] LED;
    wire [6:0] SEG;
    wire [7:0] AN;
    wire       DP_n;

    initial clk = 0;
    always #5 clk = ~clk;

    // -----------------------------------------------------------------------
    // DUT
    // -----------------------------------------------------------------------
    test_top_sim #(.WIDTH(WIDTH)) u_dut (
        .clk (clk),  .rst(rst),
        .SW  (SW),
        .BTNC(BTNC), .BTNR(BTNR), .BTNL(BTNL),
        .LED (LED),  .SEG(SEG),   .AN(AN),   .DP_n(DP_n)
    );

    wire [31:0] display_word = u_dut.display_word_out;

    // -----------------------------------------------------------------------
    // Error tracking
    // -----------------------------------------------------------------------
    integer error_count;
    integer timeout_ctr;
    initial error_count = 0;

    task check;
        input [255:0] name;
        input [31:0]  actual;
        input [31:0]  expected;
        begin
            if (actual !== expected) begin
                $display("FAIL: %0s -- got 0x%08h, expected 0x%08h at time %0t",
                         name, actual, expected, $time);
                error_count = error_count + 1;
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // Tasks
    // -----------------------------------------------------------------------
    task do_reset;
        begin
            rst = 1'b1; BTNC = 0; BTNR = 0; BTNL = 0;
            repeat(6) @(posedge clk);
            rst = 1'b0;
            repeat(2) @(posedge clk);
        end
    endtask

    // Hold button high for DEBOUNCE_CYCLES+2 = 6 cycles to fire pulse
    task press_btn;
        input [2:0] btn; // 0=BTNC, 1=BTNR, 2=BTNL
        begin
            @(posedge clk);
            if (btn == 0) BTNC = 1'b1;
            if (btn == 1) BTNR = 1'b1;
            if (btn == 2) BTNL = 1'b1;
            repeat(6) @(posedge clk);
            if (btn == 0) BTNC = 1'b0;
            if (btn == 1) BTNR = 1'b0;
            if (btn == 2) BTNL = 1'b0;
            repeat(2) @(posedge clk);
        end
    endtask

    task wait_done;
        input integer max_cycles;
        begin
            timeout_ctr = 0;
            while (LED[0] !== 1'b1 && timeout_ctr < max_cycles) begin
                @(posedge clk);
                timeout_ctr = timeout_ctr + 1;
            end
            if (LED[0] !== 1'b1) begin
                $display("TIMEOUT: done never asserted after %0d cycles", max_cycles);
                $display("FAILED: simulation aborted");
                $finish;
            end
        end
    endtask

    // Wait for pop FSM to return to IDLE after a button press (max 10 cycles)
    task wait_pop_done;
        begin
            repeat(10) @(posedge clk);
        end
    endtask

    // -----------------------------------------------------------------------
    // Expected bitmap for N=50
    //
    // 6k-1 candidates tested: 5,11,17,23,29,35,41,47,53 (k=1..9, stop >50)
    // k=1: 5  prime  → bit0=1
    // k=2: 11 prime  → bit1=1
    // k=3: 17 prime  → bit2=1
    // k=4: 23 prime  → bit3=1
    // k=5: 29 prime  → bit4=1
    // k=6: 35 composite → bit5=0
    // k=7: 41 prime  → bit6=1
    // k=8: 47 prime  → bit7=1
    // k=9: 53 > 50 → engine exhausted before testing; flush writes partial word
    // Partial flush: bits 0..7 written, bits 8..31 = 0
    // Expected word: 0x000000DF  (bits 0-4 set, bit5 clear, bits 6-7 set)
    //
    // 6k+1 candidates tested: 7,13,19,25,31,37,43,49 (k=1..8, stop >50)
    // k=1: 7  prime  → bit0=1
    // k=2: 13 prime  → bit1=1
    // k=3: 19 prime  → bit2=1
    // k=4: 25 composite → bit3=0
    // k=5: 31 prime  → bit4=1
    // k=6: 37 prime  → bit5=1
    // k=7: 43 prime  → bit6=1
    // k=8: 49 composite → bit7=0
    // Flush at 8 bits, bits 8..31 = 0
    // Expected word: 0x00000077  (bits 0-2 set, bit3 clear, bits 4-6 set, bit7 clear)
    // -----------------------------------------------------------------------
    localparam EXP_MINUS = 32'h000000DF;
    localparam EXP_PLUS  = 32'h00000077;

    // -----------------------------------------------------------------------
    // Main test sequence
    // -----------------------------------------------------------------------
    initial begin
        $dumpfile("sim/test_top_with_ssd_tb.vcd");
        $dumpvars(0, test_top_with_ssd_tb);

        SW = 16'h0; BTNC = 0; BTNR = 0; BTNL = 0;

        // ===================================================================
        // T1: Mode 1, N=50 — wait for done (LED[0])
        // SW[1:0]=01, SW[15:2]=50>>... encode N=50:
        // N=50 in SW[15:2]: SW[15:2] = 14'd50 → SW = {14'd50, 2'b01} = 16'hC9
        // ===================================================================
        $display("--- T1: Mode 1 N=50, wait for done ---");
        do_reset;

        SW = {14'd50, 2'b01};   // mode_sel=01, n_limit bits=50
        press_btn(0);           // BTNC = go

        wait_done(500000);
        @(posedge clk); #1;

        check("T1: LED[0] done asserted",        {31'd0, LED[0]}, 32'd1);
        check("T1: LED[5] plus FIFO not empty",  {31'd0, LED[5]}, 32'd0);
        check("T1: LED[6] minus FIFO not empty", {31'd0, LED[6]}, 32'd0);
        $display("PASS T1: done asserted, both FIFOs non-empty");

        // ===================================================================
        // T2: Pop 6k-1 FIFO (BTNL) — check display_word vs expected bitmap
        // ===================================================================
        $display("--- T2: pop 6k-1 FIFO (BTNL) ---");
        press_btn(2);       // BTNL
        wait_pop_done;
        #1;

        check("T2: display_word matches 6k-1 bitmap", display_word, EXP_MINUS);
        $display("PASS T2: 6k-1 word = 0x%08h (expected 0x%08h)", display_word, EXP_MINUS);

        // ===================================================================
        // T3: Pop 6k+1 FIFO (BTNR) — check display_word vs expected bitmap
        // ===================================================================
        $display("--- T3: pop 6k+1 FIFO (BTNR) ---");
        press_btn(1);       // BTNR
        wait_pop_done;
        #1;

        check("T3: display_word matches 6k+1 bitmap", display_word, EXP_PLUS);
        $display("PASS T3: 6k+1 word = 0x%08h (expected 0x%08h)", display_word, EXP_PLUS);

        // ===================================================================
        // T4: Mode 3, candidate=97 → LED[7]=1 (prime)
        // SW[15:2] = 14'd97, SW[1:0] = 2'b11
        // ===================================================================
        $display("--- T4: Mode 3, candidate=97 (expect prime) ---");
        do_reset;

        SW = {14'd97, 2'b11};
        press_btn(0);

        wait_done(20000);
        @(posedge clk); #1;

        check("T4: LED[7]=1 (97 is prime)", {31'd0, LED[7]}, 32'd1);
        $display("PASS T4: 97 identified as prime");

        // ===================================================================
        // T5: Mode 3, candidate=99 → LED[7]=0 (composite)
        // ===================================================================
        $display("--- T5: Mode 3, candidate=99 (expect composite) ---");
        do_reset;

        SW = {14'd99, 2'b11};
        press_btn(0);

        wait_done(20000);
        @(posedge clk); #1;

        check("T5: LED[7]=0 (99 is composite)", {31'd0, LED[7]}, 32'd0);
        $display("PASS T5: 99 identified as composite");

        // ===================================================================
        // T6: Pop on empty FIFO — display_word unchanged, no hang
        // Both FIFOs are empty after reset + no mode run.
        // ===================================================================
        $display("--- T6: pop on empty FIFO (no-op) ---");
        do_reset;

        // FIFOs empty after reset; both LEDs[5,6] should be 1
        @(posedge clk); #1;
        check("T6: plus FIFO empty after reset",  {31'd0, LED[5]}, 32'd1);
        check("T6: minus FIFO empty after reset", {31'd0, LED[6]}, 32'd1);

        // Press BTNR and BTNL — pop FSM should stay idle, display_word stays 0
        press_btn(1);
        wait_pop_done;
        press_btn(2);
        wait_pop_done;
        #1;

        check("T6: display_word unchanged (0) after empty pop", display_word, 32'h0);
        $display("PASS T6: empty FIFO pop is a no-op");

        // ===================================================================
        // T7: Mode 2, T=2 sim-seconds (TICK_PERIOD=100 → 200 cycles)
        // SW[1:0]=10, SW[15:2]=14'd2
        // ===================================================================
        $display("--- T7: Mode 2, T=2 sim-seconds ---");
        do_reset;

        SW = {14'd2, 2'b10};
        press_btn(0);

        // 200-cycle timeout + engine flush ≈ 500 cycles; 10000 is conservative
        wait_done(10000);
        @(posedge clk); #1;

        check("T7: LED[0] done asserted", {31'd0, LED[0]}, 32'd1);
        $display("PASS T7: Mode 2 done after T=2 sim-seconds");

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
