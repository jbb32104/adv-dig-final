`timescale 1ns / 1ps

// bitmap_tracker — tracks whether a prime bitmap has been written to DDR2.
//
// Sets has_bitmap high when mode_fsm completes for N-max or time-limit
// modes.  Clears on test completion (test_done_rising), allowing a new
// computation run.  Gates test mode navigation in keypad_nav.
//
// Clock domain: clk (100 MHz).

module bitmap_tracker (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       done,
    input  wire [1:0] latched_mode,
    input  wire       test_done_rising,
    output reg        has_bitmap
);

    reg has_bitmap_next;

    always @(*) begin
        has_bitmap_next = has_bitmap;
        if (test_done_rising)
            has_bitmap_next = 1'b0;
        else if (done && (latched_mode == 2'd1 || latched_mode == 2'd2))
            has_bitmap_next = 1'b1;
        if (!rst_n)
            has_bitmap_next = 1'b0;
    end

    always @(posedge clk) begin
        has_bitmap <= has_bitmap_next;
    end

endmodule
