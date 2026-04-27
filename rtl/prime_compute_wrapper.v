`timescale 1ns / 1ps

// Prime compute wrapper — groups the entire prime computation datapath:
//   mode_fsm           : dispatch FSM for N-max / time / single-check modes
//   prime_engine (x2)  : 6k+1 and 6k-1 trial-division engines
//   prime_accumulator (x2) : bit-packing + async FIFO to DDR2 write domain
//   elapsed_timer      : cycle/second counter for time-limit mode
//   stopwatch_bcd      : native BCD stopwatch for SSD display
//   prime_tracker      : circular buffer of last 64 engine-found primes
//   results_bcd        : sorts tracker primes, converts to 9-digit BCD
//
// Clock domains:
//   clk    (100 MHz) — engines, mode_fsm, tracker, timer, stopwatch, results write
//   ui_clk (~75 MHz) — accumulator FIFO read side, results_bcd read port

module prime_compute_wrapper #(
    parameter WIDTH = 27
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        ui_clk,

    // User interface (from keypad / top)
    input  wire [1:0]  mode_sel,
    input  wire [WIDTH-1:0] n_limit,
    input  wire [31:0] t_limit,
    input  wire [WIDTH-1:0] check_candidate,
    input  wire        go,

    // Results BCD read port (ui_clk domain, from frame_renderer)
    input  wire [WIDTH-1:0] effective_n_limit,   // for 2/3 inclusion logic
    input  wire [4:0]  rbcd_rd_addr,
    output wire [35:0] rbcd_rd_data,
    output wire [4:0]  results_display_count,
    output wire        results_done,

    // Accumulator FIFO read interface (ui_clk domain, from mem_arbiter)
    input  wire        arb_rd_en_plus,
    input  wire        arb_rd_en_minus,
    output wire [127:0] acc_plus_rd_data,
    output wire        acc_plus_fifo_empty,
    output wire [127:0] acc_minus_rd_data,
    output wire        acc_minus_fifo_empty,

    // Prime count outputs (for prime_total calculation)
    output wire [31:0] prime_count_plus,
    output wire [31:0] prime_count_minus,

    // Mode FSM status
    output wire        done,
    output wire        is_prime_result,
    output wire [3:0]  state_out,

    // Timer outputs (for remaining_time and CDC at top level)
    output wire        timer_restart,
    output wire [31:0] seconds,
    output wire [31:0] t_limit_out,

    // Stopwatch BCD output (for SSD and bcd_converter_wrapper)
    output wire [31:0] sw_bcd,

    // Engine candidates (for engine_limit capture at top level)
    output wire [WIDTH-1:0] eng_plus_candidate,
    output wire [WIDTH-1:0] eng_minus_candidate
);

    // -----------------------------------------------------------------------
    // mode_fsm <-> engine wires
    // -----------------------------------------------------------------------
    wire             eng_plus_start, eng_plus_done, eng_plus_is_prime, eng_plus_busy;
    wire             eng_minus_start, eng_minus_done, eng_minus_is_prime, eng_minus_busy;

    // -----------------------------------------------------------------------
    // mode_fsm <-> accumulator wires
    // -----------------------------------------------------------------------
    wire acc_plus_valid, acc_plus_is_prime, acc_plus_flush, acc_plus_flush_done, acc_plus_fifo_full;
    wire acc_minus_valid, acc_minus_is_prime, acc_minus_flush, acc_minus_flush_done, acc_minus_fifo_full;

    // -----------------------------------------------------------------------
    // Timer wires
    // -----------------------------------------------------------------------
    wire        timer_freeze;
    wire [31:0] cycle_count;

    // -----------------------------------------------------------------------
    // Prime tracker wires
    // -----------------------------------------------------------------------
    wire [5:0]       tracker_rd_idx;
    wire [WIDTH-1:0] tracker_rd_data;
    wire [6:0]       tracker_count;

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
        .acc_plus_flush_done    (acc_plus_flush_done),
        .acc_plus_fifo_full     (acc_plus_fifo_full),
        .acc_minus_valid_ff     (acc_minus_valid),
        .acc_minus_is_prime_ff  (acc_minus_is_prime),
        .acc_minus_flush_ff     (acc_minus_flush),
        .acc_minus_flush_done   (acc_minus_flush_done),
        .acc_minus_fifo_full    (acc_minus_fifo_full),
        .timer_restart_ff       (timer_restart),
        .timer_freeze_ff        (timer_freeze),
        .seconds_ff             (seconds),
        .cycle_count_ff         (cycle_count),
        .done_ff                (done),
        .is_prime_result_ff     (is_prime_result),
        .state_out_ff           (state_out),
        .t_limit_out            (t_limit_out)
    );

    // -----------------------------------------------------------------------
    // prime_engine instances (clk domain)
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
    // prime_accumulator instances (write: clk, read: ui_clk)
    // -----------------------------------------------------------------------
    prime_accumulator u_acc_plus (
        .clk(clk), .rst_n(rst_n), .rd_clk(ui_clk),
        .clear(timer_restart),
        .prime_valid(acc_plus_valid), .is_prime(acc_plus_is_prime),
        .flush(acc_plus_flush), .flush_done_ff(acc_plus_flush_done),
        .prime_fifo_rd_en(arb_rd_en_plus), .prime_fifo_rd_data(acc_plus_rd_data),
        .prime_fifo_empty(acc_plus_fifo_empty), .prime_fifo_full(acc_plus_fifo_full),
        .prime_count_ff(prime_count_plus)
    );

    prime_accumulator u_acc_minus (
        .clk(clk), .rst_n(rst_n), .rd_clk(ui_clk),
        .clear(timer_restart),
        .prime_valid(acc_minus_valid), .is_prime(acc_minus_is_prime),
        .flush(acc_minus_flush), .flush_done_ff(acc_minus_flush_done),
        .prime_fifo_rd_en(arb_rd_en_minus), .prime_fifo_rd_data(acc_minus_rd_data),
        .prime_fifo_empty(acc_minus_fifo_empty), .prime_fifo_full(acc_minus_fifo_full),
        .prime_count_ff(prime_count_minus)
    );

    // -----------------------------------------------------------------------
    // elapsed_timer (clk domain)
    // -----------------------------------------------------------------------
    elapsed_timer #(.TICK_PERIOD(100_000_000)) u_timer (
        .clk(clk), .rst_n(rst_n),
        .restart(timer_restart), .freeze(timer_freeze),
        .cycle_count_ff(cycle_count), .seconds_ff(seconds), .second_tick_ff()
    );

    // -----------------------------------------------------------------------
    // stopwatch_bcd (clk domain)
    // -----------------------------------------------------------------------
    stopwatch_bcd #(.PRESCALE(10_000)) u_stopwatch (
        .clk    (clk),
        .rst_n  (rst_n),
        .restart(timer_restart),
        .freeze (timer_freeze),
        .bcd_ff (sw_bcd)
    );

    // -----------------------------------------------------------------------
    // prime_tracker — circular buffer for last 64 engine-found primes
    // -----------------------------------------------------------------------
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
    // results_bcd — sorts tracker primes and converts to 9-digit BCD
    // Triggered on rising edge of done (detected here).
    // -----------------------------------------------------------------------
    reg done_prev_ff;
    reg done_prev_next;

    always @(*) begin
        done_prev_next = done;
        if (!rst_n)
            done_prev_next = 1'b0;
    end

    always @(posedge clk) begin
        done_prev_ff <= done_prev_next;
    end

    wire results_bcd_start = done & ~done_prev_ff;

    results_bcd #(.WIDTH(WIDTH)) u_results_bcd (
        .clk              (clk),
        .rst_n            (rst_n),
        .start            (results_bcd_start),
        .tracker_count    (tracker_count),
        .tracker_data     (tracker_rd_data),
        .tracker_idx_ff   (tracker_rd_idx),
        .n_limit          (effective_n_limit),
        .seconds_bcd      (sw_bcd[31:16]),
        .display_count_ff (results_display_count),
        .done_ff          (results_done),
        .ui_clk           (ui_clk),
        .rd_addr          (rbcd_rd_addr),
        .rd_data_ff       (rbcd_rd_data)
    );

endmodule
