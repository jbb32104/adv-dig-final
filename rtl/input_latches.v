`timescale 1ns / 1ps

// input_latches — captures user inputs on the go pulse so they
// remain stable while the system is on the loading/results screen.
//
//   latched_bcd     : BCD digit string at time of go (for display)
//   latched_n_limit : binary N-limit at time of go (for prime adjustment)
//   latched_mode    : mode selector at time of go (for display logic)
//   t_limit         : bin_value zero-extended to 32 bits (for mode_fsm)
//
// Clock domain: clk (100 MHz).

module input_latches #(
    parameter WIDTH = 27
) (
    input  wire             clk,
    input  wire             rst_n,
    input  wire             go,
    input  wire [31:0]      bcd_digits,
    input  wire [WIDTH-1:0] bin_value,
    input  wire [1:0]       mode_sel,

    output reg  [31:0]      latched_bcd,
    output reg  [WIDTH-1:0] latched_n_limit,
    output reg  [1:0]       latched_mode,
    output reg  [31:0]      t_limit
);

    // -------------------------------------------------------------------
    // Latched BCD digits
    // -------------------------------------------------------------------
    reg [31:0] latched_bcd_next;

    always @(*) begin
        latched_bcd_next = latched_bcd;
        if (go)
            latched_bcd_next = bcd_digits;
        if (!rst_n)
            latched_bcd_next = 32'd0;
    end

    always @(posedge clk) begin
        latched_bcd <= latched_bcd_next;
    end

    // -------------------------------------------------------------------
    // Latched N-limit (binary)
    // -------------------------------------------------------------------
    reg [WIDTH-1:0] latched_n_limit_next;

    always @(*) begin
        latched_n_limit_next = latched_n_limit;
        if (go)
            latched_n_limit_next = bin_value;
        if (!rst_n)
            latched_n_limit_next = {WIDTH{1'b0}};
    end

    always @(posedge clk) begin
        latched_n_limit <= latched_n_limit_next;
    end

    // -------------------------------------------------------------------
    // Latched mode selector
    // -------------------------------------------------------------------
    reg [1:0] latched_mode_next;

    always @(*) begin
        latched_mode_next = latched_mode;
        if (go)
            latched_mode_next = mode_sel;
        if (!rst_n)
            latched_mode_next = 2'd0;
    end

    always @(posedge clk) begin
        latched_mode <= latched_mode_next;
    end

    // -------------------------------------------------------------------
    // t_limit — bin_value zero-extended to 32 bits (combinational)
    // -------------------------------------------------------------------
    always @(*) begin
        t_limit = {{(32-WIDTH){1'b0}}, bin_value};
    end

endmodule
