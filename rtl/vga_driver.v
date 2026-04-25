module vga_driver (
    input  wire        clk_vga,      // 25 MHz pixel clock
    input  wire        rst,          // synchronous reset

    // From vga_controller (all registered, 1-cycle latency)
    input  wire        hsync_in,
    input  wire        vsync_in,
    input  wire        video_on_in,
    input  wire [9:0]  x_in,
    input  wire [9:0]  y_in,

    // pixel_fifo read port (FWFT, 16-bit, no pipeline registers)
    input  wire [15:0] fifo_dout,
    input  wire        fifo_empty,
    output wire        fifo_rd_en,   // combinational — not registered

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
    // Text line y-positions (fixed for now, will be CDC'd registers later)
    localparam LINE0_Y_START  = 10'd64;   // 4 char heights from top
    localparam LINE0_HEIGHT   = 10'd32;   // 2x height for title line
    localparam LINE1_Y_START  = 10'd288;  // 3 char heights above line 2
    localparam LINE2_Y_START  = 10'd352;  // 22 char heights from top
    localparam LINE12_HEIGHT  = 10'd16;   // normal height for lines 1-2

    // Sprite dimensions
    localparam [9:0] SPRITE_W    = 10'd192;  // 12 chars x 16 px (2x)
    localparam [9:0] SPRITE_H    = 10'd32;   // 16 font rows x 2  (2x)
    localparam [3:0] SPRITE_CHARS = 4'd12;

    // Background color (8-bit RGB332)
    localparam [7:0] BG_COLOR = 8'h00;

    //==================//
    // INTERNAL SIGNALS //
    //==================//
    reg        pixel_sel_ff, pixel_sel_next;
    reg  [3:0] vga_r_next, vga_g_next, vga_b_next;
    reg        vga_hs_next, vga_vs_next;

    // Text line detection
    wire in_line0 = (y_in >= LINE0_Y_START) && (y_in < LINE0_Y_START + LINE0_HEIGHT);
    wire in_line1 = (y_in >= LINE1_Y_START) && (y_in < LINE1_Y_START + LINE12_HEIGHT);
    wire in_line2 = (y_in >= LINE2_Y_START) && (y_in < LINE2_Y_START + LINE12_HEIGHT);
    wire in_text_line  = in_line0 || in_line1 || in_line2;
    wire in_text_pixel = video_on_in && in_text_line;

    // FIFO read enable: pop on second pixel of each 16-bit pair
    // Combinational so FIFO sees rd_en at the same posedge and advances dout by next cycle
    assign fifo_rd_en = in_text_pixel && !fifo_empty && pixel_sel_ff;

    // Pixel selection from 16-bit FIFO word
    // pixel_sel_ff=0: first pixel (high byte), pixel_sel_ff=1: second pixel (low byte)
    wire [7:0] pixel_byte = pixel_sel_ff ? fifo_dout[7:0] : fifo_dout[15:8];

    // 8-bit RGB332 to 12-bit RGB444 expansion
    wire [3:0] pixel_r = {pixel_byte[7:5], pixel_byte[7]};
    wire [3:0] pixel_g = {pixel_byte[4:2], pixel_byte[4]};
    wire [3:0] pixel_b = {pixel_byte[1:0], pixel_byte[1:0]};

    // Background color expansion (constant)
    wire [3:0] bg_r = {BG_COLOR[7:5], BG_COLOR[7]};
    wire [3:0] bg_g = {BG_COLOR[4:2], BG_COLOR[4]};
    wire [3:0] bg_b = {BG_COLOR[1:0], BG_COLOR[1:0]};

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
    // Sprite glyph pre-fetch FSM  (runs during hblank, ~160 cycles available)
    //
    // At x_in == 640 (first hblank pixel), if the NEXT scanline is within the
    // sprite Y range, fetch all 12 font glyph rows into glyph_buf[].
    //
    // Pipeline:  cycle 0 — address ROM with char[0]
    //            cycle 1 — ROM output = glyph[0]; address char[1]; capture [0]
    //            ...
    //            cycle 12 — ROM output = glyph[11]; capture [11]; done
    //
    // Total: 13 cycles from trigger.  Well within the 160-cycle hblank.
    // =========================================================================
    reg [7:0]  glyph_buf [0:11];  // pre-fetched glyph rows
    reg        fetch_active_ff;
    reg [3:0]  fetch_cnt_ff;      // 0..12 during fetch
    reg [3:0]  fetch_row_ff;      // font row for this fetch
    reg        glyph_valid_ff;    // buffer contains valid data for current line

    // Next scanline Y (handles frame wrap)
    wire [9:0] y_next = (y_in == 10'd524) ? 10'd0 : y_in + 10'd1;

    // Is the next scanline within the sprite's vertical extent?
    wire next_in_spr_y = (y_next >= sprite_y) && (y_next < sprite_y + SPRITE_H);

    // Font row for the next scanline (2x vertical: divide pixel row by 2)
    wire [3:0] font_row_next = (y_next - sprite_y) >> 1; // 0-15

    // Fetch trigger: first pixel of hblank, sprite enabled, next line in range
    wire fetch_trigger = (x_in == 10'd640) && sprite_en && next_in_spr_y;

    // ROM address driving (combinational, active during fetch)
    always @(*) begin
        if (fetch_active_ff && fetch_cnt_ff < SPRITE_CHARS)  begin
            spr_rom_char = sprite_char_fn(fetch_cnt_ff);
            spr_rom_row  = fetch_row_ff;
        end else begin
            spr_rom_char = 7'd0;
            spr_rom_row  = 4'd0;
        end
    end

    // Fetch sequential logic
    integer gi;
    always @(posedge clk_vga) begin
        if (rst) begin
            fetch_active_ff <= 1'b0;
            fetch_cnt_ff    <= 4'd0;
            glyph_valid_ff  <= 1'b0;
            for (gi = 0; gi < 12; gi = gi + 1)
                glyph_buf[gi] <= 8'd0;
        end else begin
            if (fetch_trigger && !fetch_active_ff) begin
                // Start a new fetch
                fetch_active_ff <= 1'b1;
                fetch_cnt_ff    <= 4'd0;
                fetch_row_ff    <= font_row_next;
                glyph_valid_ff  <= 1'b0; // mark invalid during fetch
            end else if (fetch_active_ff) begin
                // Capture ROM output from the previous address cycle
                if (fetch_cnt_ff > 4'd0)
                    glyph_buf[fetch_cnt_ff - 1] <= spr_rom_pixels;

                if (fetch_cnt_ff == SPRITE_CHARS) begin
                    // All 12 bytes captured
                    fetch_active_ff <= 1'b0;
                    glyph_valid_ff  <= 1'b1;
                end else begin
                    fetch_cnt_ff <= fetch_cnt_ff + 4'd1;
                end
            end

            // Invalidate when sprite is disabled
            if (!sprite_en)
                glyph_valid_ff <= 1'b0;
        end
    end

    // =========================================================================
    // Sprite compositing — combinational pixel lookup
    // =========================================================================
    // Sprite bounding box check (current pixel)
    wire in_spr_x = (x_in >= sprite_x) && (x_in < sprite_x + SPRITE_W);
    wire in_spr_y = (y_in >= sprite_y) && (y_in < sprite_y + SPRITE_H);
    wire in_sprite = sprite_en && glyph_valid_ff && in_spr_x && in_spr_y;

    // Relative coordinates within sprite
    wire [7:0] spr_rel_x = x_in[7:0] - sprite_x[7:0]; // 0-191 (fits 8 bits)
    wire [3:0] spr_char_idx  = spr_rel_x[7:4];         // character 0-11
    wire [2:0] spr_font_col  = spr_rel_x[3:1];         // font pixel 0-7 (2x horiz)

    // Look up glyph buffer and select the correct bit
    // font_pixels[7] = leftmost pixel, [0] = rightmost
    reg [7:0] spr_glyph_byte;
    always @(*) begin
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
    end

    wire spr_fg = spr_glyph_byte[3'd7 - spr_font_col];

    // Sprite color: RGB332 -> RGB444 expansion
    wire [3:0] spr_r = {sprite_color[7:5], sprite_color[7]};
    wire [3:0] spr_g = {sprite_color[4:2], sprite_color[4]};
    wire [3:0] spr_b = {sprite_color[1:0], sprite_color[1:0]};

    // ==========================================================================
    // Combinational Block — pixel output with sprite overlay
    // ==========================================================================
    always @(*) begin
        // Defaults
        vga_hs_next    = hsync_in;
        vga_vs_next    = vsync_in;
        vga_r_next     = 4'd0;
        vga_g_next     = 4'd0;
        vga_b_next     = 4'd0;
        pixel_sel_next = 1'b0;

        if (rst) begin
            vga_hs_next    = 1'b0;
            vga_vs_next    = 1'b0;
        end else if (!video_on_in) begin
            // Blanking region: black, reset pixel_sel for next scanline
            pixel_sel_next = 1'b0;
        end else if (in_text_line) begin
            if (fifo_empty) begin
                // FIFO underrun: magenta (visible debug indicator)
                vga_r_next = 4'hF;
                vga_g_next = 4'h0;
                vga_b_next = 4'hF;
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

        // --- Sprite underlay (behind framebuffer text lines) ---
        if (in_sprite && video_on_in && !in_text_line) begin
            if (spr_fg) begin
                // Foreground pixel: rainbow color
                vga_r_next = spr_r;
                vga_g_next = spr_g;
                vga_b_next = spr_b;
            end else begin
                // Background pixel: opaque black box
                vga_r_next = bg_r;
                vga_g_next = bg_g;
                vga_b_next = bg_b;
            end
        end
    end

    // ==========================================================================
    // Sequential Block
    // ==========================================================================
    always @(posedge clk_vga) begin
        vga_r_ff     <= vga_r_next;
        vga_g_ff     <= vga_g_next;
        vga_b_ff     <= vga_b_next;
        vga_hs_ff    <= vga_hs_next;
        vga_vs_ff    <= vga_vs_next;
        pixel_sel_ff <= pixel_sel_next;
    end

endmodule
