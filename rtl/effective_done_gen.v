`timescale 1ns / 1ps

// effective_done_gen — generates the effective done signal for navigation.
//
// In test mode (latched_mode == 0), done comes from the test checker
// via test_done_rising.  In all other modes, done comes from mode_fsm.
// On go, effective_done is forced low so keypad_nav sees a fresh start.
//
// Clock domain: clk (100 MHz).

module effective_done_gen (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       go,
    input  wire       test_done_rising,
    input  wire [1:0] latched_mode,
    input  wire       mode_done,
    output reg        effective_done
);

    // -------------------------------------------------------------------
    // test_done_for_nav — clears on go, sets on test completion
    // -------------------------------------------------------------------
    reg test_done_for_nav_ff;
    reg test_done_for_nav_next;

    always @(*) begin
        test_done_for_nav_next = test_done_for_nav_ff;
        if (go)
            test_done_for_nav_next = 1'b0;
        else if (test_done_rising)
            test_done_for_nav_next = 1'b1;
        if (!rst_n)
            test_done_for_nav_next = 1'b0;
    end

    always @(posedge clk) begin
        test_done_for_nav_ff <= test_done_for_nav_next;
    end

    // -------------------------------------------------------------------
    // Mux: test mode uses test checker done, others use mode_fsm done.
    // On go, force low so navigation sees a fresh start.
    // -------------------------------------------------------------------
    always @(*) begin
        if (go)
            effective_done = 1'b0;
        else if (latched_mode == 2'd0)
            effective_done = test_done_for_nav_ff;
        else
            effective_done = mode_done;
    end

endmodule
