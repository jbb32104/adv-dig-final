`timescale 1ns / 1ps

// test_results_cdc — CDC test checker results from ui_clk to clk domain.
//
// Latches test_done (level), match_count, expected, and got values on
// the rising edge of test_done.  Exposes test_done_rising as a
// single-cycle pulse for downstream consumers (bitmap_tracker,
// effective_done_gen, bcd_converter_wrapper).
//
// Clock domains: ui_clk (source, ~75 MHz), clk (destination, 100 MHz).

module test_results_cdc #(
    parameter WIDTH = 27
) (
    input  wire             clk,
    input  wire             rst_n,

    // ui_clk domain inputs (informal CDC — values are stable when sampled)
    input  wire             test_done,
    input  wire [13:0]      test_match_count,
    input  wire [WIDTH-1:0] test_expected,
    input  wire [WIDTH-1:0] test_got,

    // clk domain outputs
    output reg              test_done_rising,
    output reg  [13:0]      test_mc_clk,
    output reg  [WIDTH-1:0] test_exp_clk,
    output reg  [WIDTH-1:0] test_got_clk
);

    // -------------------------------------------------------------------
    // 2-FF synchroniser for test_done level
    // -------------------------------------------------------------------
    reg done_meta_ff, done_sync_ff;
    reg done_meta_next, done_sync_next;

    always @(*) begin
        done_meta_next = test_done;
        done_sync_next = done_meta_ff;
        if (!rst_n) begin
            done_meta_next = 1'b0;
            done_sync_next = 1'b0;
        end
    end

    always @(posedge clk) begin
        done_meta_ff <= done_meta_next;
        done_sync_ff <= done_sync_next;
    end

    // -------------------------------------------------------------------
    // Rising-edge detect
    // -------------------------------------------------------------------
    always @(*) begin
        test_done_rising = done_meta_ff & ~done_sync_ff;
    end

    // -------------------------------------------------------------------
    // Latch results on rising edge of test_done
    // -------------------------------------------------------------------
    reg [13:0]      test_mc_next;
    reg [WIDTH-1:0] test_exp_next;
    reg [WIDTH-1:0] test_got_next;

    always @(*) begin
        test_mc_next  = test_mc_clk;
        test_exp_next = test_exp_clk;
        test_got_next = test_got_clk;
        if (done_meta_ff && !done_sync_ff) begin
            test_mc_next  = test_match_count;
            test_exp_next = test_expected;
            test_got_next = test_got;
        end
        if (!rst_n) begin
            test_mc_next  = 14'd0;
            test_exp_next = {WIDTH{1'b0}};
            test_got_next = {WIDTH{1'b0}};
        end
    end

    always @(posedge clk) begin
        test_mc_clk  <= test_mc_next;
        test_exp_clk <= test_exp_next;
        test_got_clk <= test_got_next;
    end

endmodule
