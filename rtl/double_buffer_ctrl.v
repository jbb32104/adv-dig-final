`timescale 1ns / 1ps

// double_buffer_ctrl — manages VGA double-buffer swap and reader enable.
//
// CDC's vsync from clk_vga to ui_clk.  On render_done rising edge,
// sets swap_pending.  On vsync rising edge with swap_pending, toggles
// fb_display.  Also latches vga_enable high after first render completes.
//
// Outputs render_buf (which buffer to write = ~fb_display), and the
// CDC'd vsync edges (vs_sync, vs_prev) used by read_port_mux for
// test_active timing.
//
// Clock domain: ui_clk (~75 MHz).

module double_buffer_ctrl (
    input  wire ui_clk,
    input  wire rst_n,
    input  wire render_done,
    input  wire vsync,           // clk_vga domain, CDC'd here

    output reg  fb_display,      // which buffer is displayed (0=A, 1=B)
    output reg  render_buf,      // which buffer to render to (~fb_display)
    output reg  swap_pending,
    output reg  vga_enable,      // latches high after first render

    output reg  vs_sync,         // CDC'd vsync (for read_port_mux)
    output reg  vs_prev          // previous vs_sync (for edge detect)
);

    // -------------------------------------------------------------------
    // Vsync CDC (clk_vga -> ui_clk): 2-FF sync + previous for edge
    // -------------------------------------------------------------------
    reg vs_meta_ff;
    reg vs_meta_next, vs_sync_next, vs_prev_next;

    always @(*) begin
        vs_meta_next = vsync;
        vs_sync_next = vs_meta_ff;
        vs_prev_next = vs_sync;
        if (!rst_n) begin
            vs_meta_next = 1'b0;
            vs_sync_next = 1'b0;
            vs_prev_next = 1'b0;
        end
    end

    always @(posedge ui_clk) begin
        vs_meta_ff <= vs_meta_next;
        vs_sync    <= vs_sync_next;
        vs_prev    <= vs_prev_next;
    end

    // -------------------------------------------------------------------
    // Swap controller
    // -------------------------------------------------------------------
    reg rd_prev_ff;
    reg rd_prev_next, fb_display_next, swap_pending_next;

    always @(*) begin
        rd_prev_next      = render_done;
        fb_display_next   = fb_display;
        swap_pending_next = swap_pending;

        // Set pending on render_done rising edge
        if (render_done && !rd_prev_ff)
            swap_pending_next = 1'b1;

        // Swap on vsync rising edge when pending
        if (vs_sync && !vs_prev && swap_pending) begin
            fb_display_next   = ~fb_display;
            swap_pending_next = 1'b0;
        end

        if (!rst_n) begin
            rd_prev_next      = 1'b0;
            fb_display_next   = 1'b0;
            swap_pending_next = 1'b0;
        end
    end

    always @(posedge ui_clk) begin
        rd_prev_ff  <= rd_prev_next;
        fb_display  <= fb_display_next;
        swap_pending <= swap_pending_next;
    end

    // -------------------------------------------------------------------
    // render_buf = ~fb_display (combinational)
    // -------------------------------------------------------------------
    always @(*) begin
        render_buf = ~fb_display;
    end

    // -------------------------------------------------------------------
    // VGA enable — latches high after first render completes
    // -------------------------------------------------------------------
    reg vga_enable_next;

    always @(*) begin
        vga_enable_next = vga_enable;
        if (render_done)
            vga_enable_next = 1'b1;
        if (!rst_n)
            vga_enable_next = 1'b0;
    end

    always @(posedge ui_clk) begin
        vga_enable <= vga_enable_next;
    end

endmodule
