`timescale 1ns / 1ps

// test_start_cdc — merges two test-start trigger sources (button and
// keypad) in the clk domain, then CDC's each to ui_clk via toggles.
//
// Source 1: btnd_pulse       — physical button trigger
// Source 2: nav_go when mode_sel == 0 — keypad * on test screen
//
// The two CDC'd pulses are OR'd in the ui_clk domain to produce
// test_start_ui.
//
// Clock domains: clk (100 MHz source), ui_clk (~75 MHz destination).

module test_start_cdc (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       btnd_pulse,
    input  wire       nav_go,
    input  wire [1:0] nav_mode_sel,

    input  wire       ui_clk,
    input  wire       ui_rst_n,
    output reg        test_start_ui
);

    // -------------------------------------------------------------------
    // Source 1: btnd_pulse -> toggle (clk domain)
    // -------------------------------------------------------------------
    reg btn_toggle_ff, btn_toggle_next;

    always @(*) begin
        btn_toggle_next = btn_toggle_ff;
        if (btnd_pulse)
            btn_toggle_next = ~btn_toggle_ff;
        if (!rst_n)
            btn_toggle_next = 1'b0;
    end

    always @(posedge clk) begin
        btn_toggle_ff <= btn_toggle_next;
    end

    // -------------------------------------------------------------------
    // Source 2: keypad * on test screen -> toggle (clk domain)
    // -------------------------------------------------------------------
    reg kp_toggle_ff, kp_toggle_next;

    always @(*) begin
        kp_toggle_next = kp_toggle_ff;
        if (nav_go && nav_mode_sel == 2'd0)
            kp_toggle_next = ~kp_toggle_ff;
        if (!rst_n)
            kp_toggle_next = 1'b0;
    end

    always @(posedge clk) begin
        kp_toggle_ff <= kp_toggle_next;
    end

    // -------------------------------------------------------------------
    // CDC source 1 to ui_clk: 2-FF sync + edge detect
    // -------------------------------------------------------------------
    reg btn_meta_ff, btn_sync_ff, btn_prev_ff;
    reg btn_meta_next, btn_sync_next, btn_prev_next;

    always @(*) begin
        btn_meta_next = btn_toggle_ff;
        btn_sync_next = btn_meta_ff;
        btn_prev_next = btn_sync_ff;
        if (!ui_rst_n) begin
            btn_meta_next = 1'b0;
            btn_sync_next = 1'b0;
            btn_prev_next = 1'b0;
        end
    end

    always @(posedge ui_clk) begin
        btn_meta_ff <= btn_meta_next;
        btn_sync_ff <= btn_sync_next;
        btn_prev_ff <= btn_prev_next;
    end

    // -------------------------------------------------------------------
    // CDC source 2 to ui_clk: 2-FF sync + edge detect
    // -------------------------------------------------------------------
    reg kp_meta_ff, kp_sync_ff, kp_prev_ff;
    reg kp_meta_next, kp_sync_next, kp_prev_next;

    always @(*) begin
        kp_meta_next = kp_toggle_ff;
        kp_sync_next = kp_meta_ff;
        kp_prev_next = kp_sync_ff;
        if (!ui_rst_n) begin
            kp_meta_next = 1'b0;
            kp_sync_next = 1'b0;
            kp_prev_next = 1'b0;
        end
    end

    always @(posedge ui_clk) begin
        kp_meta_ff <= kp_meta_next;
        kp_sync_ff <= kp_sync_next;
        kp_prev_ff <= kp_prev_next;
    end

    // -------------------------------------------------------------------
    // Combine: either source triggers test_start_ui
    // -------------------------------------------------------------------
    always @(*) begin
        test_start_ui = (btn_sync_ff ^ btn_prev_ff) | (kp_sync_ff ^ kp_prev_ff);
    end

endmodule
