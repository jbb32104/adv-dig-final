`timescale 1ns / 1ps

// Button debounce wrapper — instantiates four debounce filters for
// the Nexys A7 board buttons (BTNC, BTNR, BTNL, BTND).
//
// Each output is a single-cycle rising-edge pulse after debounce.
//
// Clock domain: clk (100 MHz).

module btn_debounce_wrapper #(
    parameter DEBOUNCE_CYCLES = 500_000   // 5 ms at 100 MHz
) (
    input  wire clk,
    input  wire rst_n,

    // Raw button inputs
    input  wire btnc_in,
    input  wire btnr_in,
    input  wire btnl_in,
    input  wire btnd_in,

    // Debounced rising-edge pulses
    output wire btnc_pulse,
    output wire btnr_pulse,
    output wire btnl_pulse,
    output wire btnd_pulse
);

    debounce #(.DEBOUNCE_CYCLES(DEBOUNCE_CYCLES)) u_dbnc_btnc (
        .clk             (clk),
        .rst_n           (rst_n),
        .btn_in          (btnc_in),
        .btn_state_ff    (),
        .rising_pulse_ff (btnc_pulse),
        .falling_pulse_ff()
    );

    debounce #(.DEBOUNCE_CYCLES(DEBOUNCE_CYCLES)) u_dbnc_btnr (
        .clk             (clk),
        .rst_n           (rst_n),
        .btn_in          (btnr_in),
        .btn_state_ff    (),
        .rising_pulse_ff (btnr_pulse),
        .falling_pulse_ff()
    );

    debounce #(.DEBOUNCE_CYCLES(DEBOUNCE_CYCLES)) u_dbnc_btnl (
        .clk             (clk),
        .rst_n           (rst_n),
        .btn_in          (btnl_in),
        .btn_state_ff    (),
        .rising_pulse_ff (btnl_pulse),
        .falling_pulse_ff()
    );

    debounce #(.DEBOUNCE_CYCLES(DEBOUNCE_CYCLES)) u_dbnc_btnd (
        .clk             (clk),
        .rst_n           (rst_n),
        .btn_in          (btnd_in),
        .btn_state_ff    (),
        .rising_pulse_ff (btnd_pulse),
        .falling_pulse_ff()
    );

endmodule
