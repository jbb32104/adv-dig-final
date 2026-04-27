`timescale 1ns / 1ps

// VGA display wrapper — groups the VGA output pipeline:
//   vga_controller   : generates hsync, vsync, video_on, x, y
//   sprite_animator  : bouncing title on home screen
//   vga_driver       : composites pixel FIFO + sprite, drives VGA pins
//
// The pixel_fifo (Xilinx IP) stays at the top level since its write port
// is in the ui_clk domain. This wrapper only handles the clk_vga domain.
//
// Clock domain: clk_vga (25 MHz).

module vga_display_wrapper (
    input  wire        clk_vga,
    input  wire        rst_n,

    // Sprite control
    input  wire        sprite_enable,    // high on screen 0 only

    // Pixel FIFO read interface (from pixel_fifo at top level)
    input  wire [15:0] fifo_dout,
    input  wire        fifo_empty,
    output wire        fifo_rd_en,

    // VGA output pins
    output wire [3:0]  vga_r,
    output wire [3:0]  vga_g,
    output wire [3:0]  vga_b,
    output wire        vga_hs,
    output wire        vga_vs,

    // vsync output (used by top level for double-buffer swap CDC)
    output wire        vsync
);

    // -----------------------------------------------------------------------
    // VGA Controller
    // -----------------------------------------------------------------------
    wire       hsync, video_on;
    wire [9:0] x, y;

    vga_controller u_vga_ctrl (
        .clk_25MHz   (clk_vga),
        .rst_n       (rst_n),
        .hsync_ff    (hsync),
        .vsync_ff    (vsync),
        .video_on_ff (video_on),
        .x_ff        (x),
        .y_ff        (y)
    );

    // -----------------------------------------------------------------------
    // Sprite Animator — bouncing "PRIME FINDER" on screen 0
    // -----------------------------------------------------------------------
    wire [9:0] sprite_x, sprite_y;
    wire [7:0] sprite_color;

    sprite_animator u_sprite_anim (
        .clk_vga        (clk_vga),
        .rst_n          (rst_n),
        .vsync          (vsync),
        .enable         (sprite_enable),
        .sprite_x_ff    (sprite_x),
        .sprite_y_ff    (sprite_y),
        .sprite_color_ff(sprite_color)
    );

    // -----------------------------------------------------------------------
    // VGA Driver — composites pixel FIFO data + sprite overlay
    // -----------------------------------------------------------------------
    vga_driver u_vga_drv (
        .clk_vga      (clk_vga),
        .rst_n        (rst_n),
        .hsync_in     (hsync),
        .vsync_in     (vsync),
        .video_on_in  (video_on),
        .x_in         (x),
        .y_in         (y),
        .fifo_dout    (fifo_dout),
        .fifo_empty   (fifo_empty),
        .fifo_rd_en   (fifo_rd_en),
        .sprite_en    (sprite_enable),
        .sprite_x     (sprite_x),
        .sprite_y     (sprite_y),
        .sprite_color (sprite_color),
        .vga_r_ff     (vga_r),
        .vga_g_ff     (vga_g),
        .vga_b_ff     (vga_b),
        .vga_hs_ff    (vga_hs),
        .vga_vs_ff    (vga_vs)
    );

endmodule
