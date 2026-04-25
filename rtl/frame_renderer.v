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
    parameter [7:0]  FG_COLOR = 8'hFF,        // white (RGB332)
    parameter [7:0]  BG_COLOR = 8'h00         // black (RGB332)
) (
    input  wire        ui_clk,
    input  wire        rst_n,
    input  wire        init_calib_complete,

    // Screen ID (clk domain — CDC'd internally)
    input  wire [2:0]  screen_id,

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
    // screen_id is slow-changing (only on screen transitions), so per-bit
    // synchronization is sufficient.
    // -----------------------------------------------------------------------
    reg [2:0] sid_meta_ff, sid_sync_ff;
    always @(posedge ui_clk) begin
        sid_meta_ff <= screen_id;
        sid_sync_ff <= sid_meta_ff;
    end

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
        S_TEXT_ROM_A = 4'd3,  // wait for screen_text_rom (char A)
        S_FONT_ROM_A = 4'd4, // wait for font_rom (glyph A)
        S_FONT_ROM_B = 4'd5, // wait for font_rom (glyph B, lines 1-2 only)
        S_WRITE      = 4'd6, // assert wr_req, wait for grant
        S_NEXT       = 4'd7, // advance counters
        S_DONE       = 4'd8;

    reg [3:0]  state_ff;

    // -----------------------------------------------------------------------
    // Render counters
    // -----------------------------------------------------------------------
    reg [1:0]  line_idx_ff;     // 0, 1, 2
    reg [4:0]  pixel_row_ff;    // 0..31 for line 0, 0..15 for lines 1-2
    reg [5:0]  word_idx_ff;     // 0..39
    reg [26:0] addr_ff;         // running DDR2 write address

    reg [2:0]  render_sid_ff;   // latched screen_id for current render
    reg [2:0]  sid_prev_ff;     // last rendered screen_id (for change detect)
    reg        first_ff;        // cleared after first render
    reg [7:0]  glyph_a_ff;     // saved glyph A for lines 1-2

    // -----------------------------------------------------------------------
    // Helper wires
    // -----------------------------------------------------------------------
    wire is_line0 = (line_idx_ff == 2'd0);

    // Text region for current word
    wire is_text = is_line0
        ? (word_idx_ff >= 6'd10 && word_idx_ff < 6'd30)
        : (word_idx_ff >= 6'd15 && word_idx_ff < 6'd25);

    // Character position within the 20-char string
    wire [4:0] char_pos_0  = word_idx_ff[4:0] - 5'd10;               // line 0
    wire [4:0] word_off_12 = word_idx_ff[4:0] - 5'd15;               // lines 1-2
    wire [4:0] char_a_pos  = {word_off_12[3:0], 1'b0};               // even
    wire [4:0] char_b_pos  = {word_off_12[3:0], 1'b1};               // odd

    // Background word: 16 pixels of BG_COLOR
    wire [127:0] bg_word = {16{BG_COLOR}};

    // 2x expanded word: each glyph bit -> 2 adjacent pixels (line 0)
    // font_pixels[7] = leftmost glyph bit -> word[127:112] = leftmost 2 pixels
    wire [127:0] word_2x = {
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
    // glyph_a_ff = char A, font_pixels = char B (current ROM output)
    wire [127:0] word_1x = {
        glyph_a_ff[7] ? FG_COLOR : BG_COLOR,
        glyph_a_ff[6] ? FG_COLOR : BG_COLOR,
        glyph_a_ff[5] ? FG_COLOR : BG_COLOR,
        glyph_a_ff[4] ? FG_COLOR : BG_COLOR,
        glyph_a_ff[3] ? FG_COLOR : BG_COLOR,
        glyph_a_ff[2] ? FG_COLOR : BG_COLOR,
        glyph_a_ff[1] ? FG_COLOR : BG_COLOR,
        glyph_a_ff[0] ? FG_COLOR : BG_COLOR,
        font_pixels[7] ? FG_COLOR : BG_COLOR,
        font_pixels[6] ? FG_COLOR : BG_COLOR,
        font_pixels[5] ? FG_COLOR : BG_COLOR,
        font_pixels[4] ? FG_COLOR : BG_COLOR,
        font_pixels[3] ? FG_COLOR : BG_COLOR,
        font_pixels[2] ? FG_COLOR : BG_COLOR,
        font_pixels[1] ? FG_COLOR : BG_COLOR,
        font_pixels[0] ? FG_COLOR : BG_COLOR
    };

    // Trigger: screen_id changed or first render after calibration
    wire trigger = init_calib_complete &&
                   (first_ff || (sid_sync_ff != sid_prev_ff));

    // -----------------------------------------------------------------------
    // Combinational ROM address driving
    //
    // ROM inputs are driven combinationally so the registered output is
    // available one cycle later (next state).  In states that don't use the
    // ROMs the defaults produce a don't-care read — the output is ignored.
    // -----------------------------------------------------------------------
    always @(*) begin
        // Defaults (don't-care addresses for non-ROM states)
        txt_sid   = render_sid_ff;
        txt_line  = line_idx_ff;
        txt_pos   = 5'd0;
        font_char = 7'd0;
        font_row  = 4'd0;

        case (state_ff)
            // Address screen_text_rom for char A
            S_WORD_START: begin
                if (is_line0)
                    txt_pos = char_pos_0;
                else
                    txt_pos = char_a_pos;
            end

            // txt_code now holds char A — address font_rom for glyph A.
            // For lines 1-2, simultaneously address screen_text_rom for char B.
            S_TEXT_ROM_A: begin
                font_char = txt_code[6:0];
                font_row  = is_line0 ? pixel_row_ff[4:1] : pixel_row_ff[3:0];
                if (!is_line0)
                    txt_pos = char_b_pos;
            end

            // font_pixels now holds glyph A.
            // For lines 1-2: txt_code holds char B — address font_rom for glyph B.
            S_FONT_ROM_A: begin
                if (!is_line0) begin
                    font_char = txt_code[6:0];
                    font_row  = pixel_row_ff[3:0];
                end
            end

            default: ;
        endcase
    end

    // -----------------------------------------------------------------------
    // Sequential FSM
    // -----------------------------------------------------------------------
    always @(posedge ui_clk) begin
        if (!rst_n) begin
            state_ff       <= S_IDLE;
            line_idx_ff    <= 2'd0;
            pixel_row_ff   <= 5'd0;
            word_idx_ff    <= 6'd0;
            addr_ff        <= FB_A;
            render_sid_ff  <= 3'd0;
            sid_prev_ff    <= 3'd0;
            first_ff       <= 1'b1;
            glyph_a_ff     <= 8'd0;
            wr_req_ff      <= 1'b0;
            wr_addr_ff     <= 27'd0;
            wr_data_ff     <= 128'd0;
            render_done_ff <= 1'b0;
        end else begin
            case (state_ff)

                // ---- Wait for render trigger ----
                S_IDLE: begin
                    wr_req_ff <= 1'b0;
                    if (trigger) begin
                        render_done_ff <= 1'b0;
                        state_ff       <= S_SETUP;
                    end
                end

                // ---- Latch parameters, reset counters ----
                S_SETUP: begin
                    render_sid_ff <= sid_sync_ff;
                    sid_prev_ff   <= sid_sync_ff;
                    first_ff      <= 1'b0;
                    addr_ff       <= render_buf ? FB_B : FB_A;
                    line_idx_ff   <= 2'd0;
                    pixel_row_ff  <= 5'd0;
                    word_idx_ff   <= 6'd0;
                    state_ff      <= S_WORD_START;
                end

                // ---- Decide bg vs text; address screen_text_rom for char A ----
                S_WORD_START: begin
                    if (!is_text) begin
                        // Background word — go directly to write
                        wr_data_ff <= bg_word;
                        wr_addr_ff <= addr_ff;
                        wr_req_ff  <= 1'b1;
                        state_ff   <= S_WRITE;
                    end else begin
                        // Text word — ROM address set by combinational block
                        state_ff <= S_TEXT_ROM_A;
                    end
                end

                // ---- screen_text_rom output valid (char A code) ----
                // font_rom addressed combinationally; for lines 1-2,
                // screen_text_rom re-addressed for char B.
                S_TEXT_ROM_A: begin
                    state_ff <= S_FONT_ROM_A;
                end

                // ---- font_rom output valid (glyph A) ----
                S_FONT_ROM_A: begin
                    if (is_line0) begin
                        // 2x expand and write
                        wr_data_ff <= word_2x;
                        wr_addr_ff <= addr_ff;
                        wr_req_ff  <= 1'b1;
                        state_ff   <= S_WRITE;
                    end else begin
                        // Save glyph A; font_rom now addressed for char B
                        glyph_a_ff <= font_pixels;
                        state_ff   <= S_FONT_ROM_B;
                    end
                end

                // ---- font_rom output valid (glyph B) ----
                S_FONT_ROM_B: begin
                    // glyph_a_ff has glyph A, font_pixels has glyph B
                    wr_data_ff <= word_1x;
                    wr_addr_ff <= addr_ff;
                    wr_req_ff  <= 1'b1;
                    state_ff   <= S_WRITE;
                end

                // ---- Hold write request until arbiter grants ----
                S_WRITE: begin
                    if (wr_grant) begin
                        wr_req_ff <= 1'b0;
                        state_ff  <= S_NEXT;
                    end
                end

                // ---- Advance word/row/line counters ----
                S_NEXT: begin
                    addr_ff <= addr_ff + 27'd16;
                    if (word_idx_ff == 6'd39) begin
                        word_idx_ff <= 6'd0;
                        if (pixel_row_ff == (is_line0 ? 5'd31 : 5'd15)) begin
                            pixel_row_ff <= 5'd0;
                            if (line_idx_ff == 2'd2) begin
                                state_ff <= S_DONE;
                            end else begin
                                line_idx_ff <= line_idx_ff + 2'd1;
                                state_ff    <= S_WORD_START;
                            end
                        end else begin
                            pixel_row_ff <= pixel_row_ff + 5'd1;
                            state_ff     <= S_WORD_START;
                        end
                    end else begin
                        word_idx_ff <= word_idx_ff + 6'd1;
                        state_ff    <= S_WORD_START;
                    end
                end

                // ---- Render complete ----
                S_DONE: begin
                    // If screen_id changed during render, immediately re-render
                    if (sid_sync_ff != render_sid_ff) begin
                        state_ff <= S_SETUP;
                    end else begin
                        render_done_ff <= 1'b1;
                        state_ff       <= S_IDLE;
                    end
                end

                default: state_ff <= S_IDLE;

            endcase
        end
    end

endmodule
