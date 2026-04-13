`timescale 1ns / 1ps

// Physical-pin wrapper for the prime engine + accumulator bring-up test top.
// Contains NO logic — only port-to-port pass-through assigns to the
// test_top_logic instance.
//
// Reset: cpu_rst_n is the raw active-low Nexys A7 CPU_RESETN pin. It is
// fed directly to the logic module; no inversion happens here. Each
// sub-module inside handles its own active-low reset convention.

module test_top_with_ssd (
    input  wire        clk,
    input  wire        cpu_rst_n,
    input  wire [15:0] SW,
    input  wire        BTNC,
    input  wire        BTNR,
    input  wire        BTNL,
    output wire [7:0]  LED,
    output wire [6:0]  SEG,
    output wire [7:0]  AN,
    output wire        DP_n
);

    wire        clk_i;
    wire        rst_n_i;
    wire [15:0] sw_i;
    wire        btnc_i;
    wire        btnr_i;
    wire        btnl_i;
    wire [7:0]  led_o;
    wire [6:0]  seg_o;
    wire [7:0]  an_o;
    wire        dp_n_o;

    assign clk_i   = clk;
    assign rst_n_i = cpu_rst_n;
    assign sw_i    = SW;
    assign btnc_i  = BTNC;
    assign btnr_i  = BTNR;
    assign btnl_i  = BTNL;

    assign LED  = led_o;
    assign SEG  = seg_o;
    assign AN   = an_o;
    assign DP_n = dp_n_o;

    test_top_logic u_logic (
        .clk  (clk_i),
        .rst_n(rst_n_i),
        .SW   (sw_i),
        .BTNC (btnc_i),
        .BTNR (btnr_i),
        .BTNL (btnl_i),
        .LED  (led_o),
        .SEG  (seg_o),
        .AN   (an_o),
        .DP_n (dp_n_o)
    );

endmodule
