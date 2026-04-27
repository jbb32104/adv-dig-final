`timescale 1ns / 1ps

// remaining_time_calc — saturating subtract for countdown timer display.
//
// Computes t_limit_out - seconds, clamped to zero.
//
// Purely combinational, no clock domain.

module remaining_time_calc (
    input  wire [31:0] t_limit_out,
    input  wire [31:0] seconds,
    output reg  [31:0] remaining_time
);

    always @(*) begin
        if (t_limit_out > seconds)
            remaining_time = t_limit_out - seconds;
        else
            remaining_time = 32'd0;
    end

endmodule
