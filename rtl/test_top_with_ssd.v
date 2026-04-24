`timescale 1ns / 1ps

// Physical-pin wrapper for the prime engine + DDR2 integration test top.
// Contains NO logic — only port-to-port pass-through assigns to the
// test_top_logic instance.
//
// Reset: cpu_rst_n is the raw active-low Nexys A7 CPU_RESETN pin.

module test_top_with_ssd (
    input  wire        clk,
    input  wire        cpu_rst_n,
    input  wire [15:0] SW,
    input  wire        BTNC,
    input  wire        BTNR,
    input  wire        BTNL,
    output wire [15:0] LED,
    output wire [6:0]  SEG,
    output wire [7:0]  AN,
    output wire        DP_n,

    // DDR2 pins
    inout  wire [15:0] ddr2_dq,
    inout  wire [1:0]  ddr2_dqs_p,
    inout  wire [1:0]  ddr2_dqs_n,
    output wire [12:0] ddr2_addr,
    output wire [2:0]  ddr2_ba,
    output wire        ddr2_ras_n,
    output wire        ddr2_cas_n,
    output wire        ddr2_we_n,
    output wire [0:0]  ddr2_ck_p,
    output wire [0:0]  ddr2_ck_n,
    output wire [0:0]  ddr2_cke,
    output wire [0:0]  ddr2_cs_n,
    output wire [1:0]  ddr2_dm,
    output wire [0:0]  ddr2_odt
);

    test_top_logic u_logic (
        .clk       (clk),
        .rst_n     (cpu_rst_n),
        .SW        (SW),
        .BTNC      (BTNC),
        .BTNR      (BTNR),
        .BTNL      (BTNL),
        .LED       (LED),
        .SEG       (SEG),
        .AN        (AN),
        .DP_n      (DP_n),
        .ddr2_dq   (ddr2_dq),
        .ddr2_dqs_p(ddr2_dqs_p),
        .ddr2_dqs_n(ddr2_dqs_n),
        .ddr2_addr (ddr2_addr),
        .ddr2_ba   (ddr2_ba),
        .ddr2_ras_n(ddr2_ras_n),
        .ddr2_cas_n(ddr2_cas_n),
        .ddr2_we_n (ddr2_we_n),
        .ddr2_ck_p (ddr2_ck_p),
        .ddr2_ck_n (ddr2_ck_n),
        .ddr2_cke  (ddr2_cke),
        .ddr2_cs_n (ddr2_cs_n),
        .ddr2_dm   (ddr2_dm),
        .ddr2_odt  (ddr2_odt)
    );

endmodule
