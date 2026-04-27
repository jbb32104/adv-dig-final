`timescale 1ns / 1ps

// engine_limit_capture — captures the highest engine candidate on the
// rising edge of done, then CDC's the value to the ui_clk domain.
//
// The captured value is stable for millions of cycles after done,
// so a simple 2-FF synchroniser is safe for multi-bit CDC.
//
// Clock domains: clk (100 MHz), ui_clk (~75 MHz).

module engine_limit_capture #(
    parameter WIDTH = 27
) (
    input  wire             clk,
    input  wire             rst_n,
    input  wire             done,
    input  wire [WIDTH-1:0] eng_plus_candidate,
    input  wire [WIDTH-1:0] eng_minus_candidate,

    input  wire             ui_clk,
    input  wire             ui_rst_n,
    output wire [WIDTH-1:0] engine_limit_ui
);

    // -------------------------------------------------------------------
    // Done rising-edge detect (clk domain)
    // -------------------------------------------------------------------
    reg done_prev_ff;
    reg done_prev_next;

    always @(*) begin
        done_prev_next = done;
        if (!rst_n)
            done_prev_next = 1'b0;
    end

    always @(posedge clk) begin
        done_prev_ff <= done_prev_next;
    end

    // -------------------------------------------------------------------
    // Capture max(plus, minus) on done rising edge
    // -------------------------------------------------------------------
    reg [WIDTH-1:0] engine_limit_ff;
    reg [WIDTH-1:0] engine_limit_next;

    always @(*) begin
        engine_limit_next = engine_limit_ff;
        if (done && !done_prev_ff) begin
            if (eng_plus_candidate > eng_minus_candidate)
                engine_limit_next = eng_plus_candidate;
            else
                engine_limit_next = eng_minus_candidate;
        end
        if (!rst_n)
            engine_limit_next = {WIDTH{1'b0}};
    end

    always @(posedge clk) begin
        engine_limit_ff <= engine_limit_next;
    end

    // -------------------------------------------------------------------
    // 2-FF CDC to ui_clk (value is stable for millions of cycles)
    // -------------------------------------------------------------------
    reg [WIDTH-1:0] meta_ff, sync_ff;
    reg [WIDTH-1:0] meta_next, sync_next;

    always @(*) begin
        meta_next = engine_limit_ff;
        sync_next = meta_ff;
        if (!ui_rst_n) begin
            meta_next = {WIDTH{1'b0}};
            sync_next = {WIDTH{1'b0}};
        end
    end

    always @(posedge ui_clk) begin
        meta_ff <= meta_next;
        sync_ff <= sync_next;
    end

    assign engine_limit_ui = sync_ff;

endmodule
