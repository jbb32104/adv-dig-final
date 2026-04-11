`timescale 1ns / 1ps

// Test top-level for board bring-up of the prime engine + accumulator datapath.
// No DDR2. Pops 32-bit bitmap words directly from the FIFO to the SSD.
//
// Controls:
//   SW[1:0]   mode_sel  : 01=Mode1 (count), 10=Mode2 (timed), 11=Mode3 (isprime)
//   SW[15:2]  n_limit   : bits [13:0] of n_limit for Mode 1 (up to 16383)
//                         Also used as t_limit[13:0] for Mode 2 (seconds)
//                         Also used as check_candidate[13:0] for Mode 3
//   BTNC      go        : start selected mode
//   BTNR      pop_plus  : pop one word from 6k+1 accumulator FIFO → display
//   BTNL      pop_minus : pop one word from 6k-1 accumulator FIFO → display
//
// LEDs:
//   LED[0]  done_ff
//   LED[1]  eng_plus_busy
//   LED[2]  eng_minus_busy
//   LED[3]  acc_plus_fifo_full
//   LED[4]  acc_minus_fifo_full
//   LED[5]  acc_plus_fifo_empty
//   LED[6]  acc_minus_fifo_empty
//   LED[7]  is_prime_result_ff (Mode 3)
//
// SSD: shows the last word popped from whichever FIFO was most recently read.
//      Displays 8 hex digits = 32 primality bits.
//
// FIFO read latency = 2 cycles (Vivado IP with output register enabled).
// A 3-state read FSM handles this: IDLE → LATCH_1 → LATCH_2 → IDLE.

module test_top_with_ssd #(
    parameter WIDTH = 27
) (
    input  wire        clk,
    input  wire        cpu_rst,
    // Switches
    input  wire [15:0] SW,
    // Buttons (raw, debounced internally)
    input  wire        BTNC,
    input  wire        BTNR,
    input  wire        BTNL,
    // LEDs
    output wire [7:0]  LED,
    // Seven-segment display
    output wire [6:0]  SEG,
    output wire [7:0]  AN,
    output wire        DP_n
);
    // CPU_RESETN is active-low: invert to produce active-high rst for all sub-modules
    wire rst = ~cpu_rst;
    // -----------------------------------------------------------------------
    // Input interpretation
    // -----------------------------------------------------------------------
    wire [1:0]       mode_sel        = SW[1:0];
    wire [WIDTH-1:0] n_limit         = {{WIDTH-14{1'b0}}, SW[15:2]};
    wire [31:0]      t_limit         = {18'd0, SW[15:2]};
    wire [WIDTH-1:0] check_candidate = {{WIDTH-14{1'b0}}, SW[15:2]};

    // -----------------------------------------------------------------------
    // Debounce buttons
    // -----------------------------------------------------------------------
    wire go_pulse;
    wire pop_plus_pulse;
    wire pop_minus_pulse;

    debounce #(.DEBOUNCE_CYCLES(500_000)) u_dbnc_btnc (
        .clk             (clk),
        .rst             (rst),
        .btn_in          (BTNC),
        .btn_state_ff    (),
        .rising_pulse_ff (go_pulse),
        .falling_pulse_ff()
    );

    debounce #(.DEBOUNCE_CYCLES(500_000)) u_dbnc_btnr (
        .clk             (clk),
        .rst             (rst),
        .btn_in          (BTNR),
        .btn_state_ff    (),
        .rising_pulse_ff (pop_plus_pulse),
        .falling_pulse_ff()
    );

    debounce #(.DEBOUNCE_CYCLES(500_000)) u_dbnc_btnl (
        .clk             (clk),
        .rst             (rst),
        .btn_in          (BTNL),
        .btn_state_ff    (),
        .rising_pulse_ff (pop_minus_pulse),
        .falling_pulse_ff()
    );

    // -----------------------------------------------------------------------
    // mode_fsm ↔ engine wires
    // -----------------------------------------------------------------------
    wire             eng_plus_start;
    wire [WIDTH-1:0] eng_plus_candidate;
    wire             eng_plus_done;
    wire             eng_plus_is_prime;
    wire             eng_plus_busy;

    wire             eng_minus_start;
    wire [WIDTH-1:0] eng_minus_candidate;
    wire             eng_minus_done;
    wire             eng_minus_is_prime;
    wire             eng_minus_busy;

    // -----------------------------------------------------------------------
    // mode_fsm ↔ accumulator wires
    // -----------------------------------------------------------------------
    wire             acc_plus_valid;
    wire             acc_plus_is_prime;
    wire             acc_plus_flush;
    wire             acc_plus_flush_done;
    wire             acc_plus_fifo_full;

    wire             acc_minus_valid;
    wire             acc_minus_is_prime;
    wire             acc_minus_flush;
    wire             acc_minus_flush_done;
    wire             acc_minus_fifo_full;

    // -----------------------------------------------------------------------
    // elapsed_timer wires
    // -----------------------------------------------------------------------
    wire        timer_freeze;
    wire [31:0] seconds;
    wire [31:0] cycle_count;

    // -----------------------------------------------------------------------
    // mode_fsm status wires
    // -----------------------------------------------------------------------
    wire        done;
    wire        is_prime_result;
    wire [3:0]  state_out;

    // -----------------------------------------------------------------------
    // FIFO read wires (accumulators → pop FSM)
    // -----------------------------------------------------------------------
    wire [31:0] acc_plus_rd_data;
    wire        acc_plus_fifo_empty;
    wire [31:0] acc_minus_rd_data;
    wire        acc_minus_fifo_empty;

    reg         rd_en_plus_ff;
    reg         rd_en_minus_ff;

    // -----------------------------------------------------------------------
    // mode_fsm
    // -----------------------------------------------------------------------
    mode_fsm #(.WIDTH(WIDTH)) u_fsm (
        .clk                    (clk),
        .rst                    (rst),
        .mode_sel               (mode_sel),
        .n_limit                (n_limit),
        .t_limit                (t_limit),
        .check_candidate        (check_candidate),
        .go                     (go_pulse),
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
        .acc_plus_flush_done    (acc_plus_flush_done),
        .acc_plus_fifo_full     (acc_plus_fifo_full),
        .acc_minus_valid_ff     (acc_minus_valid),
        .acc_minus_is_prime_ff  (acc_minus_is_prime),
        .acc_minus_flush_ff     (acc_minus_flush),
        .acc_minus_flush_done   (acc_minus_flush_done),
        .acc_minus_fifo_full    (acc_minus_fifo_full),
        .timer_freeze_ff        (timer_freeze),
        .seconds_ff             (seconds),
        .cycle_count_ff         (cycle_count),
        .done_ff                (done),
        .is_prime_result_ff     (is_prime_result),
        .state_out_ff           (state_out)
    );

    // -----------------------------------------------------------------------
    // prime_engine instances
    // -----------------------------------------------------------------------
    prime_engine #(.WIDTH(WIDTH)) u_eng_plus (
        .clk        (clk),
        .rst        (rst),
        .start      (eng_plus_start),
        .candidate  (eng_plus_candidate),
        .done_ff    (eng_plus_done),
        .is_prime_ff(eng_plus_is_prime),
        .busy_ff    (eng_plus_busy)
    );

    prime_engine #(.WIDTH(WIDTH)) u_eng_minus (
        .clk        (clk),
        .rst        (rst),
        .start      (eng_minus_start),
        .candidate  (eng_minus_candidate),
        .done_ff    (eng_minus_done),
        .is_prime_ff(eng_minus_is_prime),
        .busy_ff    (eng_minus_busy)
    );

    // -----------------------------------------------------------------------
    // prime_accumulator instances
    // rd_clk = clk (no DDR2 in this test top — single clock domain)
    // -----------------------------------------------------------------------
    prime_accumulator u_acc_plus (
        .clk                  (clk),
        .rst                  (rst),
        .rd_clk               (clk),
        .prime_valid          (acc_plus_valid),
        .is_prime             (acc_plus_is_prime),
        .flush                (acc_plus_flush),
        .flush_done_ff        (acc_plus_flush_done),
        .prime_fifo_rd_en     (rd_en_plus_ff),
        .prime_fifo_rd_data   (acc_plus_rd_data),
        .prime_fifo_empty     (acc_plus_fifo_empty),
        .prime_fifo_full      (acc_plus_fifo_full),
        .prime_count_ff       ()
    );

    prime_accumulator u_acc_minus (
        .clk                  (clk),
        .rst                  (rst),
        .rd_clk               (clk),
        .prime_valid          (acc_minus_valid),
        .is_prime             (acc_minus_is_prime),
        .flush                (acc_minus_flush),
        .flush_done_ff        (acc_minus_flush_done),
        .prime_fifo_rd_en     (rd_en_minus_ff),
        .prime_fifo_rd_data   (acc_minus_rd_data),
        .prime_fifo_empty     (acc_minus_fifo_empty),
        .prime_fifo_full      (acc_minus_fifo_full),
        .prime_count_ff       ()
    );

    // -----------------------------------------------------------------------
    // elapsed_timer
    // -----------------------------------------------------------------------
    elapsed_timer #(.TICK_PERIOD(100_000_000)) u_timer (
        .clk           (clk),
        .rst           (rst),
        .freeze        (timer_freeze),
        .cycle_count_ff(cycle_count),
        .seconds_ff    (seconds),
        .second_tick_ff()
    );

    // -----------------------------------------------------------------------
    // FIFO pop FSM
    // Handles 2-cycle read latency from the Vivado FIFO IP.
    // BTNR pops from 6k+1 (plus), BTNL pops from 6k-1 (minus).
    // Both share the same FSM since button presses can't overlap after debounce.
    //
    // States: IDLE(0) → RD_EN(1) → WAIT1(2) → WAIT2(3) → CAPTURE(4) → IDLE
    //   RD_EN  : next_rd_en=1 flopped to rd_en_ff (FIFO sees rd_en next cycle)
    //   WAIT1  : FIFO sees rd_en, latency cycle 1
    //   WAIT2  : latency cycle 2
    //   CAPTURE: data valid on rd_data — latch to display
    // 3 cycles total accounts for 1 flop stage on rd_en + 2-cycle FIFO latency.
    // -----------------------------------------------------------------------
    localparam POP_IDLE    = 3'd0;
    localparam POP_RD_EN   = 3'd1;
    localparam POP_WAIT1   = 3'd2;
    localparam POP_WAIT2   = 3'd3;
    localparam POP_CAPTURE = 3'd4;

    reg [2:0]  pop_state_ff;
    reg        pop_plus_active_ff;   // 1 = popping from plus FIFO
    reg [31:0] display_word_ff;

    reg [2:0]  next_pop_state;
    reg        next_pop_plus_active;
    reg [31:0] next_display_word;
    reg        next_rd_en_plus;
    reg        next_rd_en_minus;

    always @(*) begin
        next_pop_state        = pop_state_ff;
        next_pop_plus_active  = pop_plus_active_ff;
        next_display_word     = display_word_ff;
        next_rd_en_plus       = 1'b0;
        next_rd_en_minus      = 1'b0;

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
                    // Set next_rd_en — gets flopped, FIFO sees it next cycle
                    next_rd_en_plus  = pop_plus_active_ff;
                    next_rd_en_minus = ~pop_plus_active_ff;
                    next_pop_state   = POP_WAIT1;
                end

                POP_WAIT1: begin
                    // FIFO latency cycle 1
                    next_pop_state = POP_WAIT2;
                end

                POP_WAIT2: begin
                    // FIFO latency cycle 2
                    next_pop_state = POP_CAPTURE;
                end

                POP_CAPTURE: begin
                    // Data valid — latch to display register
                    next_display_word = pop_plus_active_ff ? acc_plus_rd_data
                                                           : acc_minus_rd_data;
                    next_pop_state    = POP_IDLE;
                end

                default: next_pop_state = POP_IDLE;
            endcase
        end
    end

    always @(posedge clk) begin
        pop_state_ff       <= next_pop_state;   // 3-bit
        pop_plus_active_ff <= next_pop_plus_active;
        display_word_ff    <= next_display_word;
        rd_en_plus_ff      <= next_rd_en_plus;
        rd_en_minus_ff     <= next_rd_en_minus;
    end

    // -----------------------------------------------------------------------
    // Seven-segment display
    // -----------------------------------------------------------------------
    ssd #(
        .CLK_FREQ_HZ (100_000_000),
        .REFRESH_RATE(500)
    ) u_ssd (
        .clk  (clk),
        .rst  (rst),
        .value(display_word_ff),
        .dp_en(8'h0),
        .SEG  (SEG),
        .AN   (AN),
        .DP_n (DP_n)
    );

    // -----------------------------------------------------------------------
    // LED status
    // -----------------------------------------------------------------------
    assign LED[0] = done;
    assign LED[1] = eng_plus_busy;
    assign LED[2] = eng_minus_busy;
    assign LED[3] = acc_plus_fifo_full;
    assign LED[4] = acc_minus_fifo_full;
    assign LED[5] = acc_plus_fifo_empty;
    assign LED[6] = acc_minus_fifo_empty;
    assign LED[7] = is_prime_result;

endmodule
