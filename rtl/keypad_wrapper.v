`timescale 1ns / 1ps

// Keypad subsystem wrapper — integrates column driver, row debouncers,
// row reader, navigation FSM, and digit entry into a single module.
//
// Handles all keypad scanning, button decoding, screen navigation,
// and numeric digit capture.
//
// PMOD JA pin mapping (matches Nexys A7 keypad reference):
//   Columns (outputs): col_0, col_1, col_2, col_3
//   Rows    (inputs):  row_0, row_1, row_2, row_3
//
// Clock domain: clk (100 MHz).

module keypad_wrapper #(
    parameter ROW_DEBOUNCE_CYCLES = 1_000_000,  // 10 ms at 100 MHz
    parameter NAV_COOLDOWN_CYCLES = 25_000_000   // 250 ms at 100 MHz
) (
    input  wire        clk,
    input  wire        rst_n,

    // Keypad physical pins
    input  wire        row_0,
    input  wire        row_1,
    input  wire        row_2,
    input  wire        row_3,
    output wire        col_0,
    output wire        col_1,
    output wire        col_2,
    output wire        col_3,

    // mode_fsm / test status
    input  wire        mode_done,
    input  wire        primes_ready,

    // Navigation outputs
    output wire [2:0]  screen_id,
    output wire [1:0]  mode_sel,
    output wire        go,

    // Digit entry outputs
    output wire [31:0] bcd_digits,
    output wire [3:0]  cursor_pos,
    output wire        digit_changed,
    output wire        digit_toggle
);

    // -----------------------------------------------------------------------
    // Column driver
    // -----------------------------------------------------------------------
    wire freeze;

    column_driver u_col_drv (
        .clk    (clk),
        .rst_n  (rst_n),
        .freeze (freeze),
        .c_0    (col_0),
        .c_1    (col_1),
        .c_2    (col_2),
        .c_3    (col_3)
    );

    // -----------------------------------------------------------------------
    // Row debouncers
    // -----------------------------------------------------------------------
    wire r0_clean, r1_clean, r2_clean, r3_clean;

    debounce #(.DEBOUNCE_CYCLES(ROW_DEBOUNCE_CYCLES)) u_db_r0 (
        .clk(clk), .rst_n(rst_n), .btn_in(row_0),
        .btn_state_ff(r0_clean), .rising_pulse_ff(), .falling_pulse_ff()
    );
    debounce #(.DEBOUNCE_CYCLES(ROW_DEBOUNCE_CYCLES)) u_db_r1 (
        .clk(clk), .rst_n(rst_n), .btn_in(row_1),
        .btn_state_ff(r1_clean), .rising_pulse_ff(), .falling_pulse_ff()
    );
    debounce #(.DEBOUNCE_CYCLES(ROW_DEBOUNCE_CYCLES)) u_db_r2 (
        .clk(clk), .rst_n(rst_n), .btn_in(row_2),
        .btn_state_ff(r2_clean), .rising_pulse_ff(), .falling_pulse_ff()
    );
    debounce #(.DEBOUNCE_CYCLES(ROW_DEBOUNCE_CYCLES)) u_db_r3 (
        .clk(clk), .rst_n(rst_n), .btn_in(row_3),
        .btn_state_ff(r3_clean), .rising_pulse_ff(), .falling_pulse_ff()
    );

    // -----------------------------------------------------------------------
    // Row reader
    // -----------------------------------------------------------------------
    wire [3:0] button;
    wire       button_valid;

    row_reader u_row_rdr (
        .clk             (clk),
        .rst_n           (rst_n),
        .row_0           (r0_clean),
        .row_1           (r1_clean),
        .row_2           (r2_clean),
        .row_3           (r3_clean),
        .c_0_ff          (col_0),
        .c_1_ff          (col_1),
        .c_2_ff          (col_2),
        .c_3_ff          (col_3),
        .button_ff       (button),
        .button_valid_ff (button_valid),
        .freeze_out      (freeze)
    );

    // -----------------------------------------------------------------------
    // Navigation FSM
    // -----------------------------------------------------------------------
    wire       digit_press;
    wire [3:0] digit_value;

    keypad_nav #(.COOLDOWN_CYCLES(NAV_COOLDOWN_CYCLES)) u_keypad_nav (
        .clk            (clk),
        .rst_n          (rst_n),
        .button         (button),
        .button_valid   (button_valid),
        .mode_done      (mode_done),
        .primes_ready   (primes_ready),
        .screen_id_ff   (screen_id),
        .mode_sel_ff    (mode_sel),
        .go_ff          (go),
        .digit_press_ff (digit_press),
        .digit_value_ff (digit_value)
    );

    // -----------------------------------------------------------------------
    // Digit entry
    // -----------------------------------------------------------------------
    digit_entry u_digit_entry (
        .clk           (clk),
        .rst_n         (rst_n),
        .screen_id     (screen_id),
        .digit_press   (digit_press),
        .digit_value   (digit_value),
        .bcd_digits_ff (bcd_digits),
        .cursor_pos_ff (cursor_pos),
        .changed_ff    (digit_changed),
        .toggle_ff     (digit_toggle)
    );

endmodule
