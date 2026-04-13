`timescale 1ns / 1ps

// All logic for the prime engine + accumulator bring-up test top.
// The top-level wrapper (test_top_with_ssd) contains only pass-through
// assigns to physical pins; every piece of logic lives here.
//
// Reset convention: rst_n is active-low throughout and is passed directly to
// every sub-module. No active-high rst is ever created.

module test_top_logic #(
    parameter WIDTH = 27
) (
    input  wire        clk,
    input  wire        rst_n,
    // Switches
    input  wire [15:0] SW,
    // Buttons (raw — debounced internally)
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

    // -----------------------------------------------------------------------
    // Input interpretation (derived from SW)
    // SW[1:0]      = mode_sel
    // SW[15:2]     = upper bits of n_limit / t_limit / check_candidate
    // -----------------------------------------------------------------------
    wire [1:0]       mode_sel;
    wire [WIDTH-1:0] n_limit;
    wire [31:0]      t_limit;
    wire [WIDTH-1:0] check_candidate;

    assign mode_sel        = SW[1:0];
    assign n_limit         = {SW[15:2], {WIDTH-14{1'b0}}};
    assign t_limit         = {18'd0, SW[15:2]};
    assign check_candidate = {SW[15:2], {WIDTH-14{1'b0}}};

    // -----------------------------------------------------------------------
    // Debounced button pulses
    // -----------------------------------------------------------------------
    wire go_pulse;
    wire pop_plus_pulse;
    wire pop_minus_pulse;

    debounce #(.DEBOUNCE_CYCLES(500_000)) u_dbnc_btnc (
        .clk             (clk),
        .rst_n           (rst_n),
        .btn_in          (BTNC),
        .btn_state_ff    (),
        .rising_pulse_ff (go_pulse),
        .falling_pulse_ff()
    );

    debounce #(.DEBOUNCE_CYCLES(500_000)) u_dbnc_btnr (
        .clk             (clk),
        .rst_n           (rst_n),
        .btn_in          (BTNR),
        .btn_state_ff    (),
        .rising_pulse_ff (pop_plus_pulse),
        .falling_pulse_ff()
    );

    debounce #(.DEBOUNCE_CYCLES(500_000)) u_dbnc_btnl (
        .clk             (clk),
        .rst_n           (rst_n),
        .btn_in          (BTNL),
        .btn_state_ff    (),
        .rising_pulse_ff (pop_minus_pulse),
        .falling_pulse_ff()
    );

    // -----------------------------------------------------------------------
    // mode_fsm <-> engine wires
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
    // mode_fsm <-> accumulator wires
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
    // FIFO read wires (accumulators -> pop FSM)
    // Read data is 128 bits (four packed 32-bit bitmap words).
    // -----------------------------------------------------------------------
    wire [127:0] acc_plus_rd_data;
    wire         acc_plus_fifo_empty;
    wire [127:0] acc_minus_rd_data;
    wire         acc_minus_fifo_empty;

    // -----------------------------------------------------------------------
    // mode_fsm
    // -----------------------------------------------------------------------
    mode_fsm #(.WIDTH(WIDTH)) u_fsm (
        .clk                    (clk),
        .rst_n                  (rst_n),
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
        .rst_n      (rst_n),
        .start      (eng_plus_start),
        .candidate  (eng_plus_candidate),
        .done_ff    (eng_plus_done),
        .is_prime_ff(eng_plus_is_prime),
        .busy_ff    (eng_plus_busy)
    );

    prime_engine #(.WIDTH(WIDTH)) u_eng_minus (
        .clk        (clk),
        .rst_n      (rst_n),
        .start      (eng_minus_start),
        .candidate  (eng_minus_candidate),
        .done_ff    (eng_minus_done),
        .is_prime_ff(eng_minus_is_prime),
        .busy_ff    (eng_minus_busy)
    );

    // -----------------------------------------------------------------------
    // prime_accumulator instances
    // rd_clk = clk for this test top (no DDR2 here -> single clock domain)
    // -----------------------------------------------------------------------
    wire        rd_en_plus;
    wire        rd_en_minus;

    prime_accumulator u_acc_plus (
        .clk                  (clk),
        .rst_n                (rst_n),
        .rd_clk               (clk),
        .prime_valid          (acc_plus_valid),
        .is_prime             (acc_plus_is_prime),
        .flush                (acc_plus_flush),
        .flush_done_ff        (acc_plus_flush_done),
        .prime_fifo_rd_en     (rd_en_plus),
        .prime_fifo_rd_data   (acc_plus_rd_data),
        .prime_fifo_empty     (acc_plus_fifo_empty),
        .prime_fifo_full      (acc_plus_fifo_full),
        .prime_count_ff       ()
    );

    prime_accumulator u_acc_minus (
        .clk                  (clk),
        .rst_n                (rst_n),
        .rd_clk               (clk),
        .prime_valid          (acc_minus_valid),
        .is_prime             (acc_minus_is_prime),
        .flush                (acc_minus_flush),
        .flush_done_ff        (acc_minus_flush_done),
        .prime_fifo_rd_en     (rd_en_minus),
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
        .rst_n         (rst_n),
        .freeze        (timer_freeze),
        .cycle_count_ff(cycle_count),
        .seconds_ff    (seconds),
        .second_tick_ff()
    );

    // -----------------------------------------------------------------------
    // FIFO pop FSM (two-block pattern)
    // Handles the 2-cycle read latency of the Vivado FIFO IP.
    // BTNR pops from 6k+1 (plus), BTNL pops from 6k-1 (minus).
    // Button presses cannot overlap after debounce, so one FSM serves both.
    //
    // States: IDLE -> RD_EN -> WAIT1 -> WAIT2 -> CAPTURE -> IDLE
    // CAPTURE latches the lower 32 bits of the 128-bit FIFO word for display.
    // -----------------------------------------------------------------------
    localparam [2:0]
        POP_IDLE    = 3'd0,
        POP_RD_EN   = 3'd1,
        POP_WAIT1   = 3'd2,
        POP_WAIT2   = 3'd3,
        POP_CAPTURE = 3'd4;

    reg [2:0]  pop_state_ff;
    reg        pop_plus_active_ff;
    reg [31:0] display_word_ff;
    reg        rd_en_plus_ff;
    reg        rd_en_minus_ff;

    reg [2:0]  next_pop_state;
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

        if (!rst_n) begin
            next_pop_state       = POP_IDLE;
            next_pop_plus_active = 1'b0;
            next_display_word    = 32'h0;
            next_rd_en_plus      = 1'b0;
            next_rd_en_minus     = 1'b0;
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
                    next_rd_en_plus  = pop_plus_active_ff;
                    next_rd_en_minus = ~pop_plus_active_ff;
                    next_pop_state   = POP_WAIT1;
                end

                POP_WAIT1: next_pop_state = POP_WAIT2;
                POP_WAIT2: next_pop_state = POP_CAPTURE;

                POP_CAPTURE: begin
                    next_display_word = pop_plus_active_ff ? acc_plus_rd_data[31:0]
                                                           : acc_minus_rd_data[31:0];
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

    assign rd_en_plus  = rd_en_plus_ff;
    assign rd_en_minus = rd_en_minus_ff;

    // -----------------------------------------------------------------------
    // Seven-segment display
    // -----------------------------------------------------------------------
    ssd #(
        .CLK_FREQ_HZ (100_000_000),
        .REFRESH_RATE(500)
    ) u_ssd (
        .clk  (clk),
        .rst_n(rst_n),
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
