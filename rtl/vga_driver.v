`timescale 1ns / 1ps

module vga_driver (
    input  wire        clk_vga,      // 25 MHz pixel clock
    input  wire        rst_n,        // synchronous active-low reset

    // From vga_controller (all registered, 1-cycle latency)
    input  wire        hsync_in,
    input  wire        vsync_in,
    input  wire        video_on_in,
    input  wire [9:0]  x_in,
    input  wire [9:0]  y_in,

    // pixel_fifo read port (FWFT, 16-bit, no pipeline registers)
    input  wire [15:0] fifo_dout,
    input  wire        fifo_empty,
    output reg         fifo_rd_en,   // combinational

    // Sprite overlay inputs (clk_vga domain)
    input  wire        sprite_en,    // high = composite sprite (screen 0)
    input  wire [9:0]  sprite_x,     // top-left X of sprite
    input  wire [9:0]  sprite_y,     // top-left Y of sprite
    input  wire [7:0]  sprite_color, // RGB332 foreground color

    // VGA output
    output reg  [3:0]  vga_r_ff,
    output reg  [3:0]  vga_g_ff,
    output reg  [3:0]  vga_b_ff,
    output reg         vga_hs_ff,
    output reg         vga_vs_ff
);

    //==================//
    //    PARAMETERS    //
    //==================//
    // Text line Y-positions — 12 lines total.
    // Line 0 is 2x scale (32 px tall). Lines 1-11 are 1x (16 px tall).
    // Spacing: 8 px gap between adjacent lines.
    localparam LINE0_Y_START   = 10'd24;
    localparam LINE0_HEIGHT    = 10'd32;
    localparam LINE1_Y_START   = 10'd64;
    localparam LINE2_Y_START   = 10'd88;
    localparam LINE3_Y_START   = 10'd112;
    localparam LINE4_Y_START   = 10'd136;
    localparam LINE5_Y_START   = 10'd160;
    localparam LINE6_Y_START   = 10'd184;
    localparam LINE7_Y_START   = 10'd208;
    localparam LINE8_Y_START   = 10'd232;
    localparam LINE9_Y_START   = 10'd256;
    localparam LINE10_Y_START  = 10'd280;
    localparam LINE11_Y_START  = 10'd304;
    localparam LINE1X_HEIGHT   = 10'd16;   // normal height for lines 1-11

    // Sprite glyph dimensions (before border expansion)
    localparam [9:0] GLYPH_W     = 10'd192;  // 12 chars x 16 px (2x)
    localparam [9:0] GLYPH_H     = 10'd32;   // 16 font rows x 2  (2x)
    // Expanded bounding box: +1 px border on each side
    localparam [9:0] SPRITE_W    = GLYPH_W + 10'd2;  // 194
    localparam [9:0] SPRITE_H    = GLYPH_H + 10'd2;  // 34
    localparam [3:0] SPRITE_CHARS = 4'd12;

    // Background color (8-bit RGB332)
    localparam [7:0] BG_COLOR = 8'h00;

    //==================//
    // REGISTERED STATE //
    //==================//
    reg        pixel_sel_ff;
    reg        fetch_active_ff;
    reg [3:0]  fetch_cnt_ff;
    reg [3:0]  fetch_row_ff;
    reg        glyph_valid_ff;
    reg [7:0]  glyph_buf [0:11];

    //==============================//
    // COMBINATIONAL NEXT SIGNALS   //
    //==============================//
    reg [3:0]  vga_r_next, vga_g_next, vga_b_next;
    reg        vga_hs_next, vga_vs_next;
    reg        pixel_sel_next;
    reg        fetch_active_next;
    reg [3:0]  fetch_cnt_next;
    reg [3:0]  fetch_row_next;
    reg        glyph_valid_next;
    reg [7:0]  glyph_buf_next [0:11];

    // =========================================================================
    // Sprite font ROM (dedicated instance, clocked on clk_vga)
    // =========================================================================
    reg  [6:0] spr_rom_char;
    reg  [3:0] spr_rom_row;
    wire [7:0] spr_rom_pixels;

    font_rom u_sprite_font (
        .clk          (clk_vga),
        .char_code    (spr_rom_char),
        .row          (spr_rom_row),
        .pixel_row_ff (spr_rom_pixels)
    );

    // =========================================================================
    // Sprite character lookup: "PRIME FINDER" (12 characters)
    // =========================================================================
    function [6:0] sprite_char_fn;
        input [3:0] idx;
        case (idx)
            4'd0:    sprite_char_fn = 7'h50; // P
            4'd1:    sprite_char_fn = 7'h52; // R
            4'd2:    sprite_char_fn = 7'h49; // I
            4'd3:    sprite_char_fn = 7'h4D; // M
            4'd4:    sprite_char_fn = 7'h45; // E
            4'd5:    sprite_char_fn = 7'h20; // (space)
            4'd6:    sprite_char_fn = 7'h46; // F
            4'd7:    sprite_char_fn = 7'h49; // I
            4'd8:    sprite_char_fn = 7'h4E; // N
            4'd9:    sprite_char_fn = 7'h44; // D
            4'd10:   sprite_char_fn = 7'h45; // E
            4'd11:   sprite_char_fn = 7'h52; // R
            default: sprite_char_fn = 7'h00;
        endcase
    endfunction

    // =========================================================================
    // Combinational helper signals
    // =========================================================================
    reg        in_line0, in_line1, in_line2;
    reg        in_text_line, in_text_pixel;
    reg [7:0]  pixel_byte;
    reg [3:0]  pixel_r, pixel_g, pixel_b;
    reg [3:0]  bg_r, bg_g, bg_b;
    reg [9:0]  y_next_line;
    reg        next_in_spr_y;
    reg [9:0]  glyph_rel_y;
    reg [3:0]  font_row_next;
    reg        fetch_trigger;
    reg [9:0]  glyph_x0, glyph_y0;
    reg        in_spr_x, in_spr_y, in_sprite;
    reg        in_glyph_x, in_glyph_y, in_glyph;
    reg [7:0]  spr_rel_x;
    reg [3:0]  spr_char_idx;
    reg [2:0]  spr_font_col;
    reg [7:0]  spr_glyph_byte;
    reg        spr_fg;
    reg [3:0]  spr_r, spr_g, spr_b;

    reg in_line3, in_line4, in_line5, in_line6, in_line7;
    reg in_line8, in_line9, in_line10, in_line11;

    always @(*) begin
        // Text line detection — 12 lines
        in_line0  = (y_in >= LINE0_Y_START)  && (y_in < LINE0_Y_START  + LINE0_HEIGHT);
        in_line1  = (y_in >= LINE1_Y_START)  && (y_in < LINE1_Y_START  + LINE1X_HEIGHT);
        in_line2  = (y_in >= LINE2_Y_START)  && (y_in < LINE2_Y_START  + LINE1X_HEIGHT);
        in_line3  = (y_in >= LINE3_Y_START)  && (y_in < LINE3_Y_START  + LINE1X_HEIGHT);
        in_line4  = (y_in >= LINE4_Y_START)  && (y_in < LINE4_Y_START  + LINE1X_HEIGHT);
        in_line5  = (y_in >= LINE5_Y_START)  && (y_in < LINE5_Y_START  + LINE1X_HEIGHT);
        in_line6  = (y_in >= LINE6_Y_START)  && (y_in < LINE6_Y_START  + LINE1X_HEIGHT);
        in_line7  = (y_in >= LINE7_Y_START)  && (y_in < LINE7_Y_START  + LINE1X_HEIGHT);
        in_line8  = (y_in >= LINE8_Y_START)  && (y_in < LINE8_Y_START  + LINE1X_HEIGHT);
        in_line9  = (y_in >= LINE9_Y_START)  && (y_in < LINE9_Y_START  + LINE1X_HEIGHT);
        in_line10 = (y_in >= LINE10_Y_START) && (y_in < LINE10_Y_START + LINE1X_HEIGHT);
        in_line11 = (y_in >= LINE11_Y_START) && (y_in < LINE11_Y_START + LINE1X_HEIGHT);
        in_text_line  = in_line0 || in_line1 || in_line2 || in_line3 ||
                        in_line4 || in_line5 || in_line6 || in_line7 ||
                        in_line8 || in_line9 || in_line10 || in_line11;
        in_text_pixel = video_on_in && in_text_line;

        // Pixel selection from 16-bit FIFO word
        // pixel_sel_ff=0: first pixel (high byte), pixel_sel_ff=1: second pixel (low byte)
        pixel_byte = pixel_sel_ff ? fifo_dout[7:0] : fifo_dout[15:8];

        // 8-bit RGB332 to 12-bit RGB444 expansion
        pixel_r = {pixel_byte[7:5], pixel_byte[7]};
        pixel_g = {pixel_byte[4:2], pixel_byte[4]};
        pixel_b = {pixel_byte[1:0], pixel_byte[1:0]};

        // Background color expansion (constant)
        bg_r = {BG_COLOR[7:5], BG_COLOR[7]};
        bg_g = {BG_COLOR[4:2], BG_COLOR[4]};
        bg_b = {BG_COLOR[1:0], BG_COLOR[1:0]};

        // Next scanline Y (handles frame wrap)
        y_next_line = (y_in == 10'd524) ? 10'd0 : y_in + 10'd1;

        // Is the next scanline within the expanded sprite box?
        next_in_spr_y = (y_next_line >= sprite_y) && (y_next_line < sprite_y + SPRITE_H);

        // Font row for the next scanline (relative to glyph, 2x vertical)
        glyph_rel_y = y_next_line - sprite_y;
        font_row_next = (glyph_rel_y <= 10'd0) ? 4'd0
                      : (glyph_rel_y >= GLYPH_H) ? 4'd15
                      : (glyph_rel_y - 10'd1) >> 1;

        // Fetch trigger: first pixel of hblank, sprite enabled, next line in range
        fetch_trigger = (x_in == 10'd640) && sprite_en && next_in_spr_y;

        // Sprite bounding box check (includes 1 px border)
        in_spr_x  = (x_in >= sprite_x) && (x_in < sprite_x + SPRITE_W);
        in_spr_y  = (y_in >= sprite_y) && (y_in < sprite_y + SPRITE_H);
        in_sprite = sprite_en && glyph_valid_ff && in_spr_x && in_spr_y;

        // Glyph region (1 px inward from the expanded box edges)
        glyph_x0    = sprite_x + 10'd1;
        glyph_y0    = sprite_y + 10'd1;
        in_glyph_x  = (x_in >= glyph_x0) && (x_in < glyph_x0 + GLYPH_W);
        in_glyph_y  = (y_in >= glyph_y0) && (y_in < glyph_y0 + GLYPH_H);
        in_glyph    = in_glyph_x && in_glyph_y;

        // Relative coordinates within glyph (offset by 1 for the border)
        spr_rel_x    = x_in[7:0] - glyph_x0[7:0];
        spr_char_idx = spr_rel_x[7:4];
        spr_font_col = spr_rel_x[3:1];

        // Look up glyph buffer and select the correct bit
        case (spr_char_idx)
            4'd0:    spr_glyph_byte = glyph_buf[0];
            4'd1:    spr_glyph_byte = glyph_buf[1];
            4'd2:    spr_glyph_byte = glyph_buf[2];
            4'd3:    spr_glyph_byte = glyph_buf[3];
            4'd4:    spr_glyph_byte = glyph_buf[4];
            4'd5:    spr_glyph_byte = glyph_buf[5];
            4'd6:    spr_glyph_byte = glyph_buf[6];
            4'd7:    spr_glyph_byte = glyph_buf[7];
            4'd8:    spr_glyph_byte = glyph_buf[8];
            4'd9:    spr_glyph_byte = glyph_buf[9];
            4'd10:   spr_glyph_byte = glyph_buf[10];
            4'd11:   spr_glyph_byte = glyph_buf[11];
            default: spr_glyph_byte = 8'd0;
        endcase

        spr_fg = spr_glyph_byte[3'd7 - spr_font_col];

        // Sprite color: RGB332 -> RGB444 expansion
        spr_r = {sprite_color[7:5], sprite_color[7]};
        spr_g = {sprite_color[4:2], sprite_color[4]};
        spr_b = {sprite_color[1:0], sprite_color[1:0]};
    end

    // =========================================================================
    // Sprite ROM address driving (combinational, active during fetch)
    // =========================================================================
    always @(*) begin
        if (fetch_active_ff && fetch_cnt_ff < SPRITE_CHARS) begin
            spr_rom_char = sprite_char_fn(fetch_cnt_ff);
            spr_rom_row  = fetch_row_ff;
        end else begin
            spr_rom_char = 7'd0;
            spr_rom_row  = 4'd0;
        end
    end

    // =========================================================================
    // FIFO read enable (combinational)
    // =========================================================================
    always @(*) begin
        fifo_rd_en = in_text_pixel && !fifo_empty && pixel_sel_ff;
    end

    // =========================================================================
    // Sprite glyph pre-fetch — combinational next-state
    // =========================================================================
    integer gi;
    always @(*) begin
        if (!rst_n) begin
            fetch_active_next = 1'b0;
            fetch_cnt_next    = 4'd0;
            fetch_row_next    = 4'd0;
            glyph_valid_next  = 1'b0;
            for (gi = 0; gi < 12; gi = gi + 1)
                glyph_buf_next[gi] = 8'd0;
        end else begin
            // Defaults: hold
            fetch_active_next = fetch_active_ff;
            fetch_cnt_next    = fetch_cnt_ff;
            fetch_row_next    = fetch_row_ff;
            glyph_valid_next  = glyph_valid_ff;
            for (gi = 0; gi < 12; gi = gi + 1)
                glyph_buf_next[gi] = glyph_buf[gi];

            if (fetch_trigger && !fetch_active_ff) begin
                // Start a new fetch
                fetch_active_next = 1'b1;
                fetch_cnt_next    = 4'd0;
                fetch_row_next    = font_row_next;
                glyph_valid_next  = 1'b0;
            end else if (fetch_active_ff) begin
                // Capture ROM output from the previous address cycle
                if (fetch_cnt_ff > 4'd0)
                    glyph_buf_next[fetch_cnt_ff - 1] = spr_rom_pixels;

                if (fetch_cnt_ff == SPRITE_CHARS) begin
                    // All 12 bytes captured
                    fetch_active_next = 1'b0;
                    glyph_valid_next  = 1'b1;
                end else begin
                    fetch_cnt_next = fetch_cnt_ff + 4'd1;
                end
            end

            // Invalidate when sprite is disabled
            if (!sprite_en)
                glyph_valid_next = 1'b0;
        end
    end

    // =========================================================================
    // Pixel output with sprite overlay — combinational next-state
    // =========================================================================
    always @(*) begin
        if (!rst_n) begin
            vga_hs_next    = 1'b0;
            vga_vs_next    = 1'b0;
            vga_r_next     = 4'd0;
            vga_g_next     = 4'd0;
            vga_b_next     = 4'd0;
            pixel_sel_next = 1'b0;
        end else begin
            // Defaults
            vga_hs_next    = hsync_in;
            vga_vs_next    = vsync_in;
            vga_r_next     = 4'd0;
            vga_g_next     = 4'd0;
            vga_b_next     = 4'd0;
            pixel_sel_next = 1'b0;

            if (!video_on_in) begin
                // Blanking region: black, reset pixel_sel for next scanline
                pixel_sel_next = 1'b0;
            end else if (in_text_line) begin
                if (fifo_empty) begin
                    // FIFO underrun: output background color (black)
                    vga_r_next = bg_r;
                    vga_g_next = bg_g;
                    vga_b_next = bg_b;
                end else begin
                    // Text pixel from FIFO
                    vga_r_next     = pixel_r;
                    vga_g_next     = pixel_g;
                    vga_b_next     = pixel_b;
                    pixel_sel_next = ~pixel_sel_ff;
                end
            end else begin
                // Non-text visible region: background color
                vga_r_next = bg_r;
                vga_g_next = bg_g;
                vga_b_next = bg_b;
            end

            // --- Sprite underlay (behind framebuffer foreground text only) ---
            if (in_sprite && video_on_in) begin
                if (in_text_line && !fifo_empty && pixel_byte != BG_COLOR) begin
                    // Framebuffer text wins — already assigned above, keep it
                end else if (in_glyph && spr_fg) begin
                    // Sprite foreground glyph pixel: rainbow color
                    vga_r_next = spr_r;
                    vga_g_next = spr_g;
                    vga_b_next = spr_b;
                end else begin
                    // Border pixel or glyph background: opaque black
                    vga_r_next = bg_r;
                    vga_g_next = bg_g;
                    vga_b_next = bg_b;
                end
            end
        end
    end

    // =========================================================================
    // Sequential block — flops only
    // =========================================================================
    integer si;
    always @(posedge clk_vga) begin
        vga_r_ff        <= vga_r_next;
        vga_g_ff        <= vga_g_next;
        vga_b_ff        <= vga_b_next;
        vga_hs_ff       <= vga_hs_next;
        vga_vs_ff       <= vga_vs_next;
        pixel_sel_ff    <= pixel_sel_next;
        fetch_active_ff <= fetch_active_next;
        fetch_cnt_ff    <= fetch_cnt_next;
        fetch_row_ff    <= fetch_row_next;
        glyph_valid_ff  <= glyph_valid_next;
        for (si = 0; si < 12; si = si + 1)
            glyph_buf[si] <= glyph_buf_next[si];
    end

endmodule
