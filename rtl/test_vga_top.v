// test_vga_top.v — Synthesizable VGA test for Nexys A7.
// Displays three solid white horizontal bars at text line y-positions
// (y=64..79, 320..335, 352..367) on a black background.
// A simple feeder pushes all-white pixels into pixel_fifo.
// FIFO underrun shows as magenta (debug indicator from vga_driver).
//
// LED debug:
//   LED[0]  — PLL locked
//   LED[1]  — pixel_fifo empty
//   LED[2]  — pixel_fifo full
//   LED[3]  — feeder active (writing to FIFO)
//   LED[15] — 25 MHz heartbeat (~1 Hz blink)

module test_vga_top (
    input  wire        clk,        // 100 MHz board clock
    input  wire        cpu_rst_n,  // active-low CPU_RESETN button

    output wire [15:0] LED,

    // VGA output
    output wire [3:0]  VGA_R,
    output wire [3:0]  VGA_G,
    output wire [3:0]  VGA_B,
    output wire        VGA_HS,
    output wire        VGA_VS
);

    // =======================================================================
    // PLL: 100 MHz → 25 MHz (clk_vga), 200 MHz (clk_mem), 50 MHz (clk_sd)
    // =======================================================================
    wire clk_vga, clk_mem, clk_sd;
    wire pll_locked;

    pll u_pll (
        .clk_in  (clk),
        .resetn  (cpu_rst_n),
        .clk_mem (clk_mem),
        .clk_sd  (clk_sd),
        .clk_vga (clk_vga),
        .locked  (pll_locked)
    );

    // =======================================================================
    // Reset synchronizer (clk_vga domain)
    // Active-high reset, deasserts after PLL locks.
    // =======================================================================
    reg rst_meta_ff, rst_sync_ff;
    always @(posedge clk_vga) begin
        rst_meta_ff <= ~pll_locked;
        rst_sync_ff <= rst_meta_ff;
    end
    wire vga_rst = rst_sync_ff;

    // =======================================================================
    // VGA Controller
    // =======================================================================
    wire       hsync, vsync, video_on;
    wire [9:0] x, y;

    vga_controller u_vga_ctrl (
        .clk_25MHz   (clk_vga),
        .rst         (vga_rst),
        .hsync_ff    (hsync),
        .vsync_ff    (vsync),
        .video_on_ff (video_on),
        .x_ff        (x),
        .y_ff        (y)
    );

    // =======================================================================
    // Pixel FIFO (128-bit write, 16-bit read, FWFT, independent clocks)
    // Both sides use clk_vga for this test.
    // =======================================================================
    wire [127:0] fifo_din;
    wire         fifo_wr_en;
    wire         fifo_full;
    wire [15:0]  fifo_dout;
    wire         fifo_rd_en;
    wire         fifo_empty;
    wire         fifo_wr_rst_busy;
    wire         fifo_rd_rst_busy;

    pixel_fifo u_pixel_fifo (
        .rst          (vga_rst),
        .wr_clk       (clk_vga),
        .rd_clk       (clk_vga),
        .din          (fifo_din),
        .wr_en        (fifo_wr_en),
        .rd_en        (fifo_rd_en),
        .dout         (fifo_dout),
        .full         (fifo_full),
        .empty        (fifo_empty),
        .wr_rst_busy  (fifo_wr_rst_busy),
        .rd_rst_busy  (fifo_rd_rst_busy)
    );

    // =======================================================================
    // FIFO Feeder
    // Writes all-white pixels (RGB332 = 0xFF) when approaching or inside
    // a text line region. Starts 2 scanlines early so FIFO is primed.
    // =======================================================================
    assign fifo_din = {128{1'b1}}; // 16 white pixels per 128-bit write

    wire feed_line0 = (y >= 10'd62)  && (y < 10'd96);   // line 0: y=64..95 (32 px)
    wire feed_line1 = (y >= 10'd286) && (y < 10'd304);  // line 1: y=288..303 (16 px)
    wire feed_line2 = (y >= 10'd350) && (y < 10'd368);  // line 2: y=352..367 (16 px)
    wire feed_active = feed_line0 || feed_line1 || feed_line2;

    assign fifo_wr_en = feed_active && !fifo_full && !fifo_wr_rst_busy && !vga_rst;

    // =======================================================================
    // VGA Driver
    // =======================================================================
    vga_driver u_vga_drv (
        .clk_vga      (clk_vga),
        .rst          (vga_rst),
        .hsync_in     (hsync),
        .vsync_in     (vsync),
        .video_on_in  (video_on),
        .x_in         (x),
        .y_in         (y),
        .fifo_dout    (fifo_dout),
        .fifo_empty   (fifo_empty),
        .fifo_rd_en   (fifo_rd_en),
        .vga_r_ff     (VGA_R),
        .vga_g_ff     (VGA_G),
        .vga_b_ff     (VGA_B),
        .vga_hs_ff    (VGA_HS),
        .vga_vs_ff    (VGA_VS)
    );

    // =======================================================================
    // LED Debug
    // =======================================================================
    reg [23:0] heartbeat_ff;
    always @(posedge clk_vga) begin
        if (vga_rst)
            heartbeat_ff <= 24'd0;
        else
            heartbeat_ff <= heartbeat_ff + 24'd1;
    end

    assign LED[0]    = pll_locked;
    assign LED[1]    = fifo_empty;
    assign LED[2]    = fifo_full;
    assign LED[3]    = feed_active;
    assign LED[14:4] = 11'd0;
    assign LED[15]   = heartbeat_ff[23]; // ~1.5 Hz blink at 25 MHz

endmodule
