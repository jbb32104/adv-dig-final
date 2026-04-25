`timescale 1ns / 1ps

// Frame renderer — reads text from screen_text_rom, rasterizes glyphs via
// font_rom, writes RGB332 pixel data to DDR2 through the arbiter's render
// write port (port 1).
//
// Line 0 is rendered at 2x scale (16 px wide x 32 px tall per character).
// Lines 1-2 are rendered at 1x scale (8 px wide x 16 px tall).
// The font_rom stores single-size 8x16 glyphs; this module doubles
// horizontally and vertically for Line 0.
//
// Word-to-character alignment:
//   Line 0 (2x): 1 char = 16 pixels = 1 DDR2 word. Words 10-29 are text.
//   Lines 1-2 (1x): 2 chars = 16 pixels = 1 DDR2 word. Words 15-24 are text.
//
// Triggered on screen_id change or initial render after calibration.
// Writes to the back buffer (render_buf selects FB_A or FB_B).
// No write-side FIFO — direct req/grant handshake with the arbiter.
//
// Clock domain: ui_clk (~75 MHz, same as arbiter).

module frame_renderer #(
    parameter [26:0] FB_A     = 27'h050_0000,
    parameter [26:0] FB_B     = 27'h050_A000,
    parameter [7:0]  FG_COLOR = 8'hFF,        // white  (RGB332)
    parameter [7:0]  BG_COLOR = 8'h00,        // black  (RGB332)
    parameter [7:0]  HL_COLOR = 8'hE0         // red    (RGB332) — cursor highlight
) (
    input  wire        ui_clk,
    input  wire        rst_n,
    input  wire        init_calib_complete,

    // Screen ID (clk domain — CDC'd internally)
    input  wire [2:0]  screen_id,

    // Dynamic digit display (clk domain — CDC'd internally)
    input  wire [31:0] bcd_digits,    // 8 BCD digits: d7[31:28]..d0[3:0]
    input  wire [3:0]  cursor_pos,    // active cursor digit index (0-7)
    input  wire        digit_toggle,  // flips on each digit change (edge-detect trigger)

    // Loading screen live data (clk domain — CDC'd internally)
    input  wire [31:0] prime_bcd,       // prime count total in BCD (8 digits)
    input  wire        prime_bcd_toggle, // flips on each new BCD conversion
    input  wire [31:0] input_bcd,       // latched user input in BCD (8 digits)
    input  wire [31:0] countdown_bcd,   // remaining seconds in BCD (4 digits, time mode)

    // Which buffer to write: 0 = FB_A, 1 = FB_B
    input  wire        render_buf,

    // Arbiter render write port (ui_clk domain)
    output reg         wr_req_ff,
    output reg  [26:0] wr_addr_ff,
    output reg [127:0] wr_data_ff,
    input  wire        wr_grant,

    // Status
    output reg         render_done_ff
);

    // -----------------------------------------------------------------------
    // Screen ID CDC (clk -> ui_clk): 2-FF synchronizer per bit
    // -----------------------------------------------------------------------
    reg [2:0] sid_meta_ff, sid_sync_ff;
    always @(posedge ui_clk) begin
        sid_meta_ff <= screen_id;
        sid_sync_ff <= sid_meta_ff;
    end

    // -----------------------------------------------------------------------
    // Digit data CDC (clk -> ui_clk): 2-FF synchronizers
    // These are slow-changing (human keypad presses), safe for multi-bit CDC.
    // -----------------------------------------------------------------------
    reg [31:0] bcd_meta_ff, bcd_sync_ff;
    reg [3:0]  cur_meta_ff, cur_sync_ff;
    reg        dtog_meta_ff, dtog_sync_ff;
    reg        dtog_rendered_ff;  // toggle value at last render start

    // Loading screen CDC
    reg [31:0] pbcd_meta_ff, pbcd_sync_ff;   // prime count BCD
    reg        ptog_meta_ff, ptog_sync_ff;    // prime BCD toggle
    reg        ptog_rendered_ff;              // toggle value at last render start
    reg [31:0] ibcd_meta_ff, ibcd_sync_ff;   // input BCD (latched)
    reg [31:0] cbcd_meta_ff, cbcd_sync_ff;   // countdown BCD (time mode)

    always @(posedge ui_clk) begin
        bcd_meta_ff  <= bcd_digits;
        bcd_sync_ff  <= bcd_meta_ff;
        cur_meta_ff  <= cursor_pos;
        cur_sync_ff  <= cur_meta_ff;
        dtog_meta_ff <= digit_toggle;
        dtog_sync_ff <= dtog_meta_ff;
        pbcd_meta_ff <= prime_bcd;
        pbcd_sync_ff <= pbcd_meta_ff;
        ptog_meta_ff <= prime_bcd_toggle;
        ptog_sync_ff <= ptog_meta_ff;
        ibcd_meta_ff <= input_bcd;
        ibcd_sync_ff <= ibcd_meta_ff;
        cbcd_meta_ff <= countdown_bcd;
        cbcd_sync_ff <= cbcd_meta_ff;
    end

    // digit_dirty: true when digits changed since last render started.
    // Cannot be missed even if renderer is busy — compares current toggle
    // to the value latched at render start.
    wire digit_dirty = (dtog_sync_ff != dtog_rendered_ff);

    // prime_dirty: true when prime count BCD changed since last render.
    // Drives continuous re-render on loading screen.
    wire prime_dirty = (ptog_sync_ff != ptog_rendered_ff);

    // -----------------------------------------------------------------------
    // Internal ROM instances (clocked on ui_clk)
    // -----------------------------------------------------------------------
    reg  [6:0] font_char;
    reg  [3:0] font_row;
    wire [7:0] font_pixels;

    font_rom u_font (
        .clk          (ui_clk),
        .char_code    (font_char),
        .row          (font_row),
        .pixel_row_ff (font_pixels)
    );

    reg  [2:0] txt_sid;
    reg  [1:0] txt_line;
    reg  [4:0] txt_pos;
    wire [7:0] txt_code;

    screen_text_rom u_text (
        .clk         (ui_clk),
        .screen_id   (txt_sid),
        .line_num    (txt_line),
        .char_pos    (txt_pos),
        .char_code_ff(txt_code)
    );

    // -----------------------------------------------------------------------
    // FSM states
    // -----------------------------------------------------------------------
    localparam [3:0]
        S_IDLE       = 4'd0,
        S_SETUP      = 4'd1,
        S_WORD_START = 4'd2,
        S_TEXT_ROM_A = 4'd3,
        S_FONT_ROM_A = 4'd4,
        S_FONT_ROM_B = 4'd5,
        S_WRITE      = 4'd6,
        S_NEXT       = 4'd7,
        S_DONE       = 4'd8;

    // -----------------------------------------------------------------------
    // Registered state
    // -----------------------------------------------------------------------
    reg [3:0]   state_ff;
    reg [1:0]   line_idx_ff;
    reg [4:0]   pixel_row_ff;
    reg [5:0]   word_idx_ff;
    reg [26:0]  addr_ff;
    reg [2:0]   render_sid_ff;
    reg [2:0]   sid_prev_ff;
    reg         first_ff;
    reg [7:0]   glyph_a_ff;
    reg         cursor_a_ff;   // char A of current word is the cursor digit
    reg         cursor_b_ff;   // char B of current word is the cursor digit

    // -----------------------------------------------------------------------
    // Combinational next-state signals
    // -----------------------------------------------------------------------
    reg [3:0]   state_next;
    reg [1:0]   line_idx_next;
    reg [4:0]   pixel_row_next;
    reg [5:0]   word_idx_next;
    reg [26:0]  addr_next;
    reg [2:0]   render_sid_next;
    reg [2:0]   sid_prev_next;
    reg         first_next;
    reg [7:0]   glyph_a_next;
    reg         cursor_a_next;
    reg         cursor_b_next;
    reg         dtog_rendered_next;
    reg         ptog_rendered_next;
    reg         wr_req_next;
    reg [26:0]  wr_addr_next;
    reg [127:0] wr_data_next;
    reg         render_done_next;

    // -----------------------------------------------------------------------
    // Helper combinational signals
    // -----------------------------------------------------------------------
    reg         is_line0;
    reg         is_text;
    reg [4:0]   char_pos_0;
    reg [4:0]   word_off_12;
    reg [4:0]   char_a_pos;
    reg [4:0]   char_b_pos;
    reg [127:0] bg_word;
    reg [127:0] word_2x;
    reg [127:0] word_1x;
    reg         trigger;

    // Per-character foreground color (white normally, red for cursor digit)
    reg [7:0]   fg_a, fg_b;

    // Active BCD bus (selected per screen/line)
    reg [31:0]  active_bcd;

    // -----------------------------------------------------------------------
    // Digit position lookup — maps (screen_id, char_pos) to digit index.
    // Returns 4'hF when the position is not a dynamic digit.
    // -----------------------------------------------------------------------
    // Screen 1 & 3 (8-digit):  "     00 000 000     "
    //   pos 5→d7, 6→d6,  8→d5, 9→d4, 10→d3,  12→d2, 13→d1, 14→d0
    // Screen 2 (4-digit):      "     0 000  SEC     "
    //   pos 5→d3,  7→d2, 8→d1, 9→d0
    // -----------------------------------------------------------------------
    reg [3:0] dig_idx_a, dig_idx_b;   // digit index for char A/B
    reg [3:0] dig_val_a, dig_val_b;   // BCD value for char A/B
    reg       dig_en_a,  dig_en_b;    // position is a dynamic digit

    // Lookup digit index for an 8-digit screen (screens 1 & 3)
    function [3:0] idx8;
        input [4:0] p;
        case (p)
            5'd5:  idx8 = 4'd7;  5'd6:  idx8 = 4'd6;
            5'd8:  idx8 = 4'd5;  5'd9:  idx8 = 4'd4;  5'd10: idx8 = 4'd3;
            5'd12: idx8 = 4'd2;  5'd13: idx8 = 4'd1;  5'd14: idx8 = 4'd0;
            default: idx8 = 4'hF;
        endcase
    endfunction

    // Lookup digit index for a 4-digit screen (screen 2)
    function [3:0] idx4;
        input [4:0] p;
        case (p)
            5'd5: idx4 = 4'd3;
            5'd7: idx4 = 4'd2;  5'd8: idx4 = 4'd1;  5'd9: idx4 = 4'd0;
            default: idx4 = 4'hF;
        endcase
    endfunction

    // Extract one BCD digit from the 32-bit bus
    function [3:0] bcd_val;
        input [31:0] bcd;
        input [3:0]  idx;
        case (idx)
            4'd0: bcd_val = bcd[3:0];    4'd1: bcd_val = bcd[7:4];
            4'd2: bcd_val = bcd[11:8];   4'd3: bcd_val = bcd[15:12];
            4'd4: bcd_val = bcd[19:16];  4'd5: bcd_val = bcd[23:20];
            4'd6: bcd_val = bcd[27:24];  4'd7: bcd_val = bcd[31:28];
            default: bcd_val = 4'd0;
        endcase
    endfunction

    // Screens with dynamic digit display
    wire is_entry_screen   = (render_sid_ff == 3'd1) ||
                             (render_sid_ff == 3'd2) ||
                             (render_sid_ff == 3'd3);
    wire is_loading_screen = (render_sid_ff == 3'd5) || (render_sid_ff == 3'd7);
    wire is_time_loading   = (render_sid_ff == 3'd7);

    // Which lines have dynamic digits?
    //   Entry screens (1-3): line 1 only
    //   Loading screen (5):  lines 1 and 2
    wire line_has_digits = (is_entry_screen && line_idx_ff == 2'd1) ||
                           (is_loading_screen && (line_idx_ff == 2'd1 || line_idx_ff == 2'd2));

    always @(*) begin
        is_line0 = (line_idx_ff == 2'd0);

        // Text region for current word
        // On screen 0 line 0 is rendered as a bouncing sprite by vga_driver,
        // so the framebuffer writes all-background there (no static text).
        if (is_line0)
            is_text = (render_sid_ff != 3'd0 && word_idx_ff >= 6'd10 && word_idx_ff < 6'd30);
        else
            is_text = (word_idx_ff >= 6'd15 && word_idx_ff < 6'd25);

        // Character position within the 20-char string
        char_pos_0  = word_idx_ff[4:0] - 5'd10;
        word_off_12 = word_idx_ff[4:0] - 5'd15;
        char_a_pos  = {word_off_12[3:0], 1'b0};
        char_b_pos  = {word_off_12[3:0], 1'b1};

        // Digit position lookup for char A and char B
        // Screen 2 uses 4-digit layout; screen 7 line 2 uses 4-digit layout;
        // all others use 8-digit layout.
        if (render_sid_ff == 3'd2 || (is_time_loading && line_idx_ff == 2'd2)) begin
            dig_idx_a = idx4(char_a_pos);
            dig_idx_b = idx4(char_b_pos);
        end else begin
            dig_idx_a = idx8(char_a_pos);
            dig_idx_b = idx8(char_b_pos);
        end

        dig_en_a = (is_entry_screen || is_loading_screen) && line_has_digits && (dig_idx_a != 4'hF);
        dig_en_b = (is_entry_screen || is_loading_screen) && line_has_digits && (dig_idx_b != 4'hF);

        // Select BCD source per screen/line:
        //   Loading screens line 1: prime count BCD
        //   Screen 5 line 2: latched input BCD (n_limit display)
        //   Screen 7 line 2: countdown BCD (remaining seconds)
        //   Entry screens line 1: digit_entry BCD
        if (is_loading_screen && line_idx_ff == 2'd1)
            active_bcd = pbcd_sync_ff;
        else if (is_time_loading && line_idx_ff == 2'd2)
            active_bcd = cbcd_sync_ff;
        else if (is_loading_screen && line_idx_ff == 2'd2)
            active_bcd = ibcd_sync_ff;
        else
            active_bcd = bcd_sync_ff;

        dig_val_a = bcd_val(active_bcd, dig_idx_a);
        dig_val_b = bcd_val(active_bcd, dig_idx_b);

        // Background word: 16 pixels of BG_COLOR
        bg_word = {16{BG_COLOR}};

        // Per-character foreground: red for cursor digit, white otherwise
        fg_a = (cursor_a_ff && line_idx_ff == 2'd1) ? HL_COLOR : FG_COLOR;
        fg_b = (cursor_b_ff && line_idx_ff == 2'd1) ? HL_COLOR : FG_COLOR;

        // 2x expanded word: each glyph bit -> 2 adjacent pixels (line 0)
        word_2x = {
            {2{font_pixels[7] ? FG_COLOR : BG_COLOR}},
            {2{font_pixels[6] ? FG_COLOR : BG_COLOR}},
            {2{font_pixels[5] ? FG_COLOR : BG_COLOR}},
            {2{font_pixels[4] ? FG_COLOR : BG_COLOR}},
            {2{font_pixels[3] ? FG_COLOR : BG_COLOR}},
            {2{font_pixels[2] ? FG_COLOR : BG_COLOR}},
            {2{font_pixels[1] ? FG_COLOR : BG_COLOR}},
            {2{font_pixels[0] ? FG_COLOR : BG_COLOR}}
        };

        // 1x word: glyph A (8 px) + glyph B (8 px) = 16 pixels (lines 1-2)
        // Uses per-character foreground color for cursor highlight
        word_1x = {
            glyph_a_ff[7] ? fg_a : BG_COLOR,
            glyph_a_ff[6] ? fg_a : BG_COLOR,
            glyph_a_ff[5] ? fg_a : BG_COLOR,
            glyph_a_ff[4] ? fg_a : BG_COLOR,
            glyph_a_ff[3] ? fg_a : BG_COLOR,
            glyph_a_ff[2] ? fg_a : BG_COLOR,
            glyph_a_ff[1] ? fg_a : BG_COLOR,
            glyph_a_ff[0] ? fg_a : BG_COLOR,
            font_pixels[7] ? fg_b : BG_COLOR,
            font_pixels[6] ? fg_b : BG_COLOR,
            font_pixels[5] ? fg_b : BG_COLOR,
            font_pixels[4] ? fg_b : BG_COLOR,
            font_pixels[3] ? fg_b : BG_COLOR,
            font_pixels[2] ? fg_b : BG_COLOR,
            font_pixels[1] ? fg_b : BG_COLOR,
            font_pixels[0] ? fg_b : BG_COLOR
        };

        // Trigger: screen_id changed, first render, digits changed, or prime count changed
        trigger = init_calib_complete &&
                  (first_ff || (sid_sync_ff != sid_prev_ff) || digit_dirty || prime_dirty);
    end

    // -----------------------------------------------------------------------
    // Combinational ROM address driving + digit override
    // When rendering line 1 on screens 1-3, dynamic digit positions
    // override the ROM char code with the BCD digit + 0x30 (ASCII '0').
    // -----------------------------------------------------------------------
    always @(*) begin
        txt_sid   = render_sid_ff;
        txt_line  = line_idx_ff;
        txt_pos   = 5'd0;
        font_char = 7'd0;
        font_row  = 4'd0;

        case (state_ff)
            S_WORD_START: begin
                if (is_line0)
                    txt_pos = char_pos_0;
                else
                    txt_pos = char_a_pos;
            end

            S_TEXT_ROM_A: begin
                // Char A: override with dynamic digit if applicable
                if (dig_en_a)
                    font_char = {3'd0, dig_val_a} + 7'h30;  // ASCII '0'-'9'
                else
                    font_char = txt_code[6:0];
                font_row  = is_line0 ? pixel_row_ff[4:1] : pixel_row_ff[3:0];
                if (!is_line0)
                    txt_pos = char_b_pos;
            end

            S_FONT_ROM_A: begin
                if (!is_line0) begin
                    // Char B: override with dynamic digit if applicable
                    if (dig_en_b)
                        font_char = {3'd0, dig_val_b} + 7'h30;
                    else
                        font_char = txt_code[6:0];
                    font_row  = pixel_row_ff[3:0];
                end
            end

            default: ;
        endcase
    end

    // -----------------------------------------------------------------------
    // FSM next-state logic (combinational)
    // -----------------------------------------------------------------------
    always @(*) begin
        if (!rst_n) begin
            state_next       = S_IDLE;
            line_idx_next    = 2'd0;
            pixel_row_next   = 5'd0;
            word_idx_next    = 6'd0;
            addr_next        = FB_A;
            render_sid_next  = 3'd0;
            sid_prev_next    = 3'd0;
            first_next          = 1'b1;
            glyph_a_next        = 8'd0;
            cursor_a_next       = 1'b0;
            cursor_b_next       = 1'b0;
            dtog_rendered_next  = 1'b0;
            ptog_rendered_next  = 1'b0;
            wr_req_next         = 1'b0;
            wr_addr_next        = 27'd0;
            wr_data_next        = 128'd0;
            render_done_next    = 1'b0;
        end else begin

        // Default: hold all registers
        state_next          = state_ff;
        line_idx_next       = line_idx_ff;
        pixel_row_next      = pixel_row_ff;
        word_idx_next       = word_idx_ff;
        addr_next           = addr_ff;
        render_sid_next     = render_sid_ff;
        sid_prev_next       = sid_prev_ff;
        first_next          = first_ff;
        glyph_a_next        = glyph_a_ff;
        cursor_a_next       = cursor_a_ff;
        cursor_b_next       = cursor_b_ff;
        dtog_rendered_next  = dtog_rendered_ff;
        ptog_rendered_next  = ptog_rendered_ff;
        wr_req_next         = wr_req_ff;
        wr_addr_next        = wr_addr_ff;
        wr_data_next        = wr_data_ff;
        render_done_next    = render_done_ff;

        case (state_ff)

            S_IDLE: begin
                wr_req_next = 1'b0;
                if (trigger) begin
                    render_done_next = 1'b0;
                    state_next       = S_SETUP;
                end
            end

            S_SETUP: begin
                render_sid_next    = sid_sync_ff;
                sid_prev_next      = sid_sync_ff;
                dtog_rendered_next = dtog_sync_ff;   // mark digit toggle as consumed
                ptog_rendered_next = ptog_sync_ff;   // mark prime toggle as consumed
                first_next         = 1'b0;
                addr_next          = render_buf ? FB_B : FB_A;
                line_idx_next   = 2'd0;
                pixel_row_next  = 5'd0;
                word_idx_next   = 6'd0;
                state_next      = S_WORD_START;
            end

            S_WORD_START: begin
                if (!is_text) begin
                    wr_data_next = bg_word;
                    wr_addr_next = addr_ff;
                    wr_req_next  = 1'b1;
                    state_next   = S_WRITE;
                end else begin
                    state_next = S_TEXT_ROM_A;
                end
            end

            S_TEXT_ROM_A: begin
                // Latch cursor flag for char A (entry screens only, not loading)
                cursor_a_next = dig_en_a && is_entry_screen && (dig_idx_a == cur_sync_ff);
                // Pre-compute cursor flag for char B
                cursor_b_next = dig_en_b && is_entry_screen && (dig_idx_b == cur_sync_ff);
                state_next = S_FONT_ROM_A;
            end

            S_FONT_ROM_A: begin
                if (is_line0) begin
                    wr_data_next = word_2x;
                    wr_addr_next = addr_ff;
                    wr_req_next  = 1'b1;
                    state_next   = S_WRITE;
                end else begin
                    glyph_a_next = font_pixels;
                    state_next   = S_FONT_ROM_B;
                end
            end

            S_FONT_ROM_B: begin
                wr_data_next = word_1x;
                wr_addr_next = addr_ff;
                wr_req_next  = 1'b1;
                state_next   = S_WRITE;
            end

            S_WRITE: begin
                if (wr_grant) begin
                    wr_req_next = 1'b0;
                    state_next  = S_NEXT;
                end
            end

            S_NEXT: begin
                addr_next = addr_ff + 27'd16;
                if (word_idx_ff == 6'd39) begin
                    word_idx_next = 6'd0;
                    if (pixel_row_ff == (is_line0 ? 5'd31 : 5'd15)) begin
                        pixel_row_next = 5'd0;
                        if (line_idx_ff == 2'd2) begin
                            state_next = S_DONE;
                        end else begin
                            line_idx_next = line_idx_ff + 2'd1;
                            state_next    = S_WORD_START;
                        end
                    end else begin
                        pixel_row_next = pixel_row_ff + 5'd1;
                        state_next     = S_WORD_START;
                    end
                end else begin
                    word_idx_next = word_idx_ff + 6'd1;
                    state_next    = S_WORD_START;
                end
            end

            S_DONE: begin
                if (sid_sync_ff != render_sid_ff) begin
                    state_next = S_SETUP;
                end else begin
                    render_done_next = 1'b1;
                    state_next       = S_IDLE;
                end
            end

            default: state_next = S_IDLE;

        endcase
        end // else !rst_n
    end

    // -----------------------------------------------------------------------
    // Sequential block — flops only
    // -----------------------------------------------------------------------
    always @(posedge ui_clk) begin
        state_ff       <= state_next;
        line_idx_ff    <= line_idx_next;
        pixel_row_ff   <= pixel_row_next;
        word_idx_ff    <= word_idx_next;
        addr_ff        <= addr_next;
        render_sid_ff  <= render_sid_next;
        sid_prev_ff    <= sid_prev_next;
        first_ff       <= first_next;
        glyph_a_ff     <= glyph_a_next;
        cursor_a_ff       <= cursor_a_next;
        cursor_b_ff       <= cursor_b_next;
        dtog_rendered_ff  <= dtog_rendered_next;
        ptog_rendered_ff  <= ptog_rendered_next;
        wr_req_ff         <= wr_req_next;
        wr_addr_ff     <= wr_addr_next;
        wr_data_ff     <= wr_data_next;
        render_done_ff <= render_done_next;
    end

endmodule
