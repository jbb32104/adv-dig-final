`timescale 1ns / 1ps

// BCD converter wrapper — groups all BCD conversion modules:
//   bcd_to_bin      : keypad BCD digits -> binary value
//   bin_to_bcd (x2) : prime count + countdown timer -> BCD for display
//   bin_to_bcd9 (x3): test expected/got/match_count -> 9-digit BCD
//
// Handles auto-restart logic for count and countdown converters internally,
// as well as the one-cycle delay for test BCD start and toggle generation.
//
// Clock domain: clk (100 MHz).

module bcd_converter_wrapper #(
    parameter WIDTH = 27
) (
    input  wire        clk,
    input  wire        rst_n,

    // ---- bcd_to_bin (keypad entry -> binary) ----
    input  wire [31:0] bcd_digits,
    input  wire        bcd_start,           // de_changed pulse
    output wire [26:0] bin_value,
    output wire        bin_valid,

    // ---- bin_to_bcd count (prime total -> BCD) ----
    input  wire [26:0] prime_total,         // prime_total[26:0]
    input  wire        go,                  // nav_go
    input  wire [2:0]  screen_id,           // for auto-restart gating
    output wire [31:0] count_bcd,
    output wire        count_bcd_valid,
    output wire        count_bcd_toggle,

    // ---- bin_to_bcd countdown (remaining time -> BCD) ----
    input  wire [26:0] remaining_time,
    output wire [31:0] countdown_bcd,
    output wire        countdown_bcd_valid,

    // ---- bin_to_bcd9 test results (expected/got/match -> 9-digit BCD) ----
    input  wire [WIDTH-1:0] test_expected,
    input  wire [WIDTH-1:0] test_got,
    input  wire [13:0]      test_match_count,
    input  wire             test_done_rising,   // single-cycle pulse
    output wire [35:0]      test_exp_bcd,
    output wire [35:0]      test_got_bcd,
    output wire [35:0]      test_mc_bcd,
    output reg              test_bcd_toggle_ff
);

    // -----------------------------------------------------------------------
    // bcd_to_bin — keypad BCD digits to binary
    // -----------------------------------------------------------------------
    bcd_to_bin u_bcd_to_bin (
        .clk          (clk),
        .rst_n        (rst_n),
        .bcd_digits   (bcd_digits),
        .start        (bcd_start),
        .bin_value_ff (bin_value),
        .valid_ff     (bin_valid)
    );

    // -----------------------------------------------------------------------
    // bin_to_bcd — prime count (auto-restart on loading/results screens)
    // -----------------------------------------------------------------------
    reg is_active_scr;
    always @(*) begin
        is_active_scr = (screen_id == 3'd5) || (screen_id == 3'd6) ||
                        (screen_id == 3'd7);
    end

    reg count_bcd_start;
    always @(*) begin
        count_bcd_start = go || (count_bcd_valid && is_active_scr);
    end

    bin_to_bcd u_count_bcd (
        .clk       (clk),
        .rst_n     (rst_n),
        .bin_in    (prime_total),
        .start     (count_bcd_start),
        .bcd_out_ff(count_bcd),
        .valid_ff  (count_bcd_valid),
        .toggle_ff (count_bcd_toggle)
    );

    // -----------------------------------------------------------------------
    // bin_to_bcd — countdown timer (auto-restart on time-loading screen)
    // -----------------------------------------------------------------------
    reg countdown_bcd_start;
    always @(*) begin
        countdown_bcd_start = go || (countdown_bcd_valid && screen_id == 3'd7);
    end

    bin_to_bcd u_countdown_bcd (
        .clk       (clk),
        .rst_n     (rst_n),
        .bin_in    (remaining_time),
        .start     (countdown_bcd_start),
        .bcd_out_ff(countdown_bcd),
        .valid_ff  (countdown_bcd_valid),
        .toggle_ff ()
    );

    // -----------------------------------------------------------------------
    // Test BCD start — delay test_done_rising by one cycle so latched
    // test values are stable before converters sample them.
    // -----------------------------------------------------------------------
    reg  test_bcd_start_d_ff;
    reg  test_bcd_start_d_next;

    always @(*) begin
        test_bcd_start_d_next = test_done_rising;
        if (!rst_n)
            test_bcd_start_d_next = 1'b0;
    end

    always @(posedge clk) begin
        test_bcd_start_d_ff <= test_bcd_start_d_next;
    end

    wire test_bcd_start = test_bcd_start_d_ff;

    // -----------------------------------------------------------------------
    // bin_to_bcd9 — test expected value
    // -----------------------------------------------------------------------
    wire test_exp_bcd_valid;

    bin_to_bcd9 u_test_exp_bcd (
        .clk       (clk),
        .rst_n     (rst_n),
        .bin_in    (test_expected),
        .start     (test_bcd_start),
        .bcd_out_ff(test_exp_bcd),
        .valid_ff  (test_exp_bcd_valid)
    );

    // -----------------------------------------------------------------------
    // bin_to_bcd9 — test got value
    // -----------------------------------------------------------------------
    bin_to_bcd9 u_test_got_bcd (
        .clk       (clk),
        .rst_n     (rst_n),
        .bin_in    (test_got),
        .start     (test_bcd_start),
        .bcd_out_ff(test_got_bcd),
        .valid_ff  ()
    );

    // -----------------------------------------------------------------------
    // bin_to_bcd9 — test match count
    // -----------------------------------------------------------------------
    bin_to_bcd9 u_test_mc_bcd (
        .clk       (clk),
        .rst_n     (rst_n),
        .bin_in    ({13'd0, test_match_count}),
        .start     (test_bcd_start),
        .bcd_out_ff(test_mc_bcd),
        .valid_ff  ()
    );

    // -----------------------------------------------------------------------
    // Test BCD toggle — toggles when test BCD conversion completes
    // -----------------------------------------------------------------------
    reg test_bcd_toggle_next;

    always @(*) begin
        test_bcd_toggle_next = test_bcd_toggle_ff;
        if (!rst_n)
            test_bcd_toggle_next = 1'b0;
        else if (test_exp_bcd_valid)
            test_bcd_toggle_next = ~test_bcd_toggle_ff;
    end

    always @(posedge clk) begin
        test_bcd_toggle_ff <= test_bcd_toggle_next;
    end

endmodule
