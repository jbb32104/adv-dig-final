`timescale 1ns / 1ps

// Elapsed timer sub-module for Prime Modes FSM.
// Counts clock cycles and seconds with a parameterized tick period.
// Outputs a one-cycle second_tick pulse each time a second elapses.
// freeze input halts both counters (highest priority after rst).

module elapsed_timer #(
    parameter TICK_PERIOD = 100_000_000
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        freeze,
    output reg  [31:0] cycle_count_ff,
    output reg  [31:0] seconds_ff,
    output reg         second_tick_ff
);

    localparam TICK_BITS = 27;  // 2^27 = 134,217,728 > 100,000,000

    // Internal flip-flop register
    reg [TICK_BITS-1:0] tick_cnt_ff;

    // Combinational next-state signals (blocking = only)
    reg [TICK_BITS-1:0] next_tick_cnt;
    reg [31:0]          next_cycle_count;
    reg [31:0]          next_seconds;
    reg                 next_second_tick;


    //=====================================
    //========= COMBINATIONAL LOGIC =======
    //=====================================

    always @(*) begin
        // Defaults: hold current registered values
        next_tick_cnt    = tick_cnt_ff;
        next_cycle_count = cycle_count_ff;
        next_seconds     = seconds_ff;
        next_second_tick = 1'b0;  // pulse default off

        if (rst) begin
            next_tick_cnt    = {TICK_BITS{1'b0}};
            next_cycle_count = 32'd0;
            next_seconds     = 32'd0;
            next_second_tick = 1'b0;
        end else if (freeze) begin
            // Freeze has highest priority after reset: hold all counters
            next_tick_cnt    = tick_cnt_ff;
            next_cycle_count = cycle_count_ff;
            next_seconds     = seconds_ff;
            next_second_tick = 1'b0;
        end else begin
            next_cycle_count = cycle_count_ff + 32'd1;
            if (tick_cnt_ff == TICK_PERIOD - 1) begin
                next_tick_cnt    = {TICK_BITS{1'b0}};
                next_seconds     = seconds_ff + 32'd1;
                next_second_tick = 1'b1;
            end else begin
                next_tick_cnt = tick_cnt_ff + {{TICK_BITS-1{1'b0}}, 1'b1};
            end
        end
    end


    //=====================================
    //========= FLOP REGISTERS ============
    //=====================================

    always @(posedge clk) begin
        tick_cnt_ff    <= next_tick_cnt;
        cycle_count_ff <= next_cycle_count;
        seconds_ff     <= next_seconds;
        second_tick_ff <= next_second_tick;
    end

endmodule
