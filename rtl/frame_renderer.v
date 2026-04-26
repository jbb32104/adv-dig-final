`timescale 1ns / 1ps

// Frame renderer — reads text from screen_text_rom, rasterizes glyphs via
// font_rom, writes RGB332 pixel data to DDR2 through the arbiter's render
// write port (port 1).
//
// 12 text lines per frame:
//   Line 0: 2x scale (16 px wide x 32 px tall per character).
//   Lines 1-11: 1x scale (8 px wide x 16 px tall).
//   Lines 3-11 on non-results screens render as all-background.
//
// For screen 6 (results), lines 2-11 display prime BCD values from the
// results_bcd dual-port RAM.  Two 9-digit primes per line with leading-
// zero suppression.
//
// Word-to-character alignment:
//   Line 0 (2x): 1 char = 16 pixels = 1 DDR2 word. Words 10-29 are text.
//   Lines 1+ (1x): 2 chars = 16 pixels = 1 DDR2 word. Words 15-24 are text.
//
// Triggered on screen_id change, initial render after calibration,
// digit change, or prime count change.
//
// Clock domain: ui_clk (~75 MHz, same as arbiter).

module frame_renderer #(
    parameter [26:0] FB_A     = 27'h050_0000,
    parameter [26:0] FB_B     = 27'h052_2000,
    parameter [7:0]  FG_COLOR = 8'hFF,        // white  (RGB332)
    parameter [7:0]  BG_COLOR = 8'h00,        // black  (RGB332)
    parameter [7:0]  HL_COLOR = 8'hE0,        // red    (RGB332) — cursor highlight
    parameter [7:0]  GR_COLOR = 8'h1C         // green  (RGB332) — test pass
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

    // Latched mode selector (clk domain — CDC'd internally)
    // 0=test, 1=nmax, 2=timer, 3=single
    input  wire [1:0]  mode_sel,

    // Stopwatch BCD for results time display (clk domain — CDC'd internally)
    // Format: {seconds[31:16], fractional[15:0]} — upper 4 digits = seconds
    input  wire [31:0] stopwatch_bcd,

    // Results BCD dual-port RAM read (ui_clk domain — no CDC needed)
    output reg  [4:0]  rbcd_rd_addr_ff,  // address into results_bcd memory
    input  wire [35:0] rbcd_rd_data,     // registered read data (1-cycle latency)

    // Results display count (clk domain — CDC'd internally)
    input  wire [4:0]  results_display_count,
    input  wire        results_done,       // toggles when BCD conversion finishes

    // Test results (test_pass is ui_clk domain; BCD values are clk domain)
    input  wire        test_pass,          // 1=pass, 0=fail (ui_clk — no CDC)
    input  wire [35:0] test_exp_bcd,       // expected value in 9-digit BCD (clk)
    input  wire [35:0] test_got_bcd,       // got value in 9-digit BCD (clk)
    input  wire        test_bcd_toggle,    // flips on test BCD conversion done (clk)

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

    // Mode selector CDC
    reg [1:0]  mode_meta_ff, mode_sync_ff;

    // Stopwatch BCD CDC
    reg [31:0] swbcd_meta_ff, swbcd_sync_ff;

    // Results display count CDC
    reg [4:0]  rdcnt_meta_ff, rdcnt_sync_ff;
    reg        rdone_meta_ff, rdone_sync_ff;
    reg        rdone_rendered_ff;

    // Test results BCD CDC (clk → ui_clk)
    reg [35:0] texp_meta_ff, texp_sync_ff;
    reg [35:0] tgot_meta_ff, tgot_sync_ff;
    reg        ttog_meta_ff, ttog_sync_ff;
    reg        ttog_rendered_ff;

    always @(posedge ui_clk) begin
        mode_meta_ff  <= mode_sel;
        mode_sync_ff  <= mode_meta_ff;
        bcd_meta_ff   <= bcd_digits;
        bcd_sync_ff   <= bcd_meta_ff;
        cur_meta_ff   <= cursor_pos;
        cur_sync_ff   <= cur_meta_ff;
        dtog_meta_ff  <= digit_toggle;
        dtog_sync_ff  <= dtog_meta_ff;
        pbcd_meta_ff  <= prime_bcd;
        pbcd_sync_ff  <= pbcd_meta_ff;
        ptog_meta_ff  <= prime_bcd_toggle;
        ptog_sync_ff  <= ptog_meta_ff;
        ibcd_meta_ff  <= input_bcd;
        ibcd_sync_ff  <= ibcd_meta_ff;
        cbcd_meta_ff  <= countdown_bcd;
        cbcd_sync_ff  <= cbcd_meta_ff;
        swbcd_meta_ff <= stopwatch_bcd;
        swbcd_sync_ff <= swbcd_meta_ff;
        rdcnt_meta_ff <= results_display_count;
        rdcnt_sync_ff <= rdcnt_meta_ff;
        rdone_meta_ff <= results_done;
        rdone_sync_ff <= rdone_meta_ff;
        texp_meta_ff  <= test_exp_bcd;
        texp_sync_ff  <= texp_meta_ff;
        tgot_meta_ff  <= test_got_bcd;
        tgot_sync_ff  <= tgot_meta_ff;
        ttog_meta_ff  <= test_bcd_toggle;
        ttog_sync_ff  <= ttog_meta_ff;
    end

    // digit_dirty: true when digits changed since last render started.
    wire digit_dirty = (dtog_sync_ff != dtog_rendered_ff);

    // prime_dirty: true when prime count BCD changed since last render.
    wire prime_dirty = (ptog_sync_ff != ptog_rendered_ff);

    // results_dirty: true when results BCD conversion completed since last render.
    wire results_dirty = (rdone_sync_ff != rdone_rendered_ff);

    // test_dirty: true when test BCD conversion completed since last render.
    wire test_dirty = (ttog_sync_ff != ttog_rendered_ff);

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
        S_DONE       = 4'd8,
        S_RFETCH_L   = 4'd9,    // results: set read addr for left prime
        S_RFETCH_LW  = 4'd10,   // results: wait for BRAM read (left)
        S_RFETCH_R   = 4'd11,   // results: latch left, set read addr for right
        S_RFETCH_RW  = 4'd12,   // results: wait for BRAM read (right)
        S_RFETCH_D   = 4'd13;   // results: latch right, proceed to rendering

    // -----------------------------------------------------------------------
    // Registered state
    // -----------------------------------------------------------------------
    reg [3:0]   state_ff;
    reg [3:0]   line_idx_ff;     // 0-11 (4 bits for 12 lines)
    reg [4:0]   pixel_row_ff;
    reg [5:0]   word_idx_ff;
    reg [26:0]  addr_ff;
    reg [2:0]   render_sid_ff;
    reg [2:0]   sid_prev_ff;
    reg         first_ff;
    reg [7:0]   glyph_a_ff;
    reg         cursor_a_ff;
    reg         cursor_b_ff;

    // Results BCD latches (valid during results line rendering)
    reg [35:0]  left_bcd_ff;     // BCD of left prime for current line
    reg [35:0]  right_bcd_ff;    // BCD of right prime for current line

    // -----------------------------------------------------------------------
    // Combinational next-state signals
    // -----------------------------------------------------------------------
    reg [3:0]   state_next;
    reg [3:0]   line_idx_next;
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
    reg         rdone_rendered_next;
    reg         ttog_rendered_next;
    reg         wr_req_next;
    reg [26:0]  wr_addr_next;
    reg [127:0] wr_data_next;
    reg         render_done_next;
    reg [35:0]  left_bcd_next;
    reg [35:0]  right_bcd_next;
    reg [4:0]   rbcd_rd_addr_next;

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
    reg [7:0]   line0_fg;   // line 0 foreground (green/red for test mode)

    // Active BCD bus (selected per screen/line)
    reg [31:0]  active_bcd;

    // -----------------------------------------------------------------------
    // Digit position lookups
    // -----------------------------------------------------------------------
    reg [3:0] dig_idx_a, dig_idx_b;   // digit index for char A/B
    reg [3:0] dig_val_a, dig_val_b;   // BCD value for char A/B
    reg       dig_en_a,  dig_en_b;    // position is a dynamic digit

    // 8-digit layout: "     00 000 000     "
    function [3:0] idx8;
        input [4:0] p;
        case (p)
            5'd5:  idx8 = 4'd7;  5'd6:  idx8 = 4'd6;
            5'd8:  idx8 = 4'd5;  5'd9:  idx8 = 4'd4;  5'd10: idx8 = 4'd3;
            5'd12: idx8 = 4'd2;  5'd13: idx8 = 4'd1;  5'd14: idx8 = 4'd0;
            default: idx8 = 4'hF;
        endcase
    endfunction

    // 4-digit layout: "     0 000  SEC     "
    function [3:0] idx4;
        input [4:0] p;
        case (p)
            5'd5: idx4 = 4'd3;
            5'd7: idx4 = 4'd2;  5'd8: idx4 = 4'd1;  5'd9: idx4 = 4'd0;
            default: idx4 = 4'hF;
        endcase
    endfunction

    // Extract one BCD digit from a 32-bit bus
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

    // Extract one BCD digit from a 36-bit (9-digit) bus
    function [3:0] bcd9_val;
        input [35:0] bcd;
        input [3:0]  idx;
        case (idx)
            4'd0: bcd9_val = bcd[3:0];    4'd1: bcd9_val = bcd[7:4];
            4'd2: bcd9_val = bcd[11:8];   4'd3: bcd9_val = bcd[15:12];
            4'd4: bcd9_val = bcd[19:16];  4'd5: bcd9_val = bcd[23:20];
            4'd6: bcd9_val = bcd[27:24];  4'd7: bcd9_val = bcd[31:28];
            4'd8: bcd9_val = bcd[35:32];
            default: bcd9_val = 4'd0;
        endcase
    endfunction

    // Results prime digit index: pos 1→d8, 2���d7, ..., 9→d0 (left)
    //                            pos 11→d8, 12→d7, ..., 19→d0 (right)
    function [3:0] res_dig_idx;
        input [4:0] p;
        case (p)
            5'd1: res_dig_idx = 4'd8;   5'd2: res_dig_idx = 4'd7;
            5'd3: res_dig_idx = 4'd6;   5'd4: res_dig_idx = 4'd5;
            5'd5: res_dig_idx = 4'd4;   5'd6: res_dig_idx = 4'd3;
            5'd7: res_dig_idx = 4'd2;   5'd8: res_dig_idx = 4'd1;
            5'd9: res_dig_idx = 4'd0;
            5'd11: res_dig_idx = 4'd8;  5'd12: res_dig_idx = 4'd7;
            5'd13: res_dig_idx = 4'd6;  5'd14: res_dig_idx = 4'd5;
            5'd15: res_dig_idx = 4'd4;  5'd16: res_dig_idx = 4'd3;
            5'd17: res_dig_idx = 4'd2;  5'd18: res_dig_idx = 4'd1;
            5'd19: res_dig_idx = 4'd0;
            default: res_dig_idx = 4'hF;
        endcase
    endfunction

    // Results info line (line 1): N value at pos 2-9, seconds at pos 13-16
    // N: pos 2→d7, 3→d6, ..., 9→d0 (8 digits)
    function [3:0] res_info_n_idx;
        input [4:0] p;
        case (p)
            5'd2: res_info_n_idx = 4'd7;  5'd3: res_info_n_idx = 4'd6;
            5'd4: res_info_n_idx = 4'd5;  5'd5: res_info_n_idx = 4'd4;
            5'd6: res_info_n_idx = 4'd3;  5'd7: res_info_n_idx = 4'd2;
            5'd8: res_info_n_idx = 4'd1;  5'd9: res_info_n_idx = 4'd0;
            default: res_info_n_idx = 4'hF;
        endcase
    endfunction

    // Prime count: pos 12→d7, 13→d6, ..., 19→d0
    function [3:0] res_info_cnt_idx;
        input [4:0] p;
        case (p)
            5'd12: res_info_cnt_idx = 4'd7;  5'd13: res_info_cnt_idx = 4'd6;
            5'd14: res_info_cnt_idx = 4'd5;  5'd15: res_info_cnt_idx = 4'd4;
            5'd16: res_info_cnt_idx = 4'd3;  5'd17: res_info_cnt_idx = 4'd2;
            5'd18: res_info_cnt_idx = 4'd1;  5'd19: res_info_cnt_idx = 4'd0;
            default: res_info_cnt_idx = 4'hF;
        endcase
    endfunction

    // Leading-zero suppression: returns highest non-zero digit position (0-8).
    // For value 0, returns 0 (always show ones digit).
    function [3:0] first_nz;
        input [35:0] bcd;
        if      (bcd[35:32] != 4'd0) first_nz = 4'd8;
        else if (bcd[31:28] != 4'd0) first_nz = 4'd7;
        else if (bcd[27:24] != 4'd0) first_nz = 4'd6;
        else if (bcd[23:20] != 4'd0) first_nz = 4'd5;
        else if (bcd[19:16] != 4'd0) first_nz = 4'd4;
        else if (bcd[15:12] != 4'd0) first_nz = 4'd3;
        else if (bcd[11:8]  != 4'd0) first_nz = 4'd2;
        else if (bcd[7:4]   != 4'd0) first_nz = 4'd1;
        else                          first_nz = 4'd0;
    endfunction

    // Timer results info line: time digits at positions 2-5 (4-digit)
    // Layout: "T:DDDD SEC #DDDDDDDD"
    function [3:0] timer_info_t_idx;
        input [4:0] p;
        case (p)
            5'd2: timer_info_t_idx = 4'd3;
            5'd3: timer_info_t_idx = 4'd2;
            5'd4: timer_info_t_idx = 4'd1;
            5'd5: timer_info_t_idx = 4'd0;
            default: timer_info_t_idx = 4'hF;
        endcase
    endfunction

    // Test BCD leading-zero positions
    wire [3:0] exp_fnz = first_nz(texp_sync_ff);
    wire [3:0] got_fnz = first_nz(tgot_sync_ff);

    // Test foreground color: green for pass, red for fail
    wire [7:0] test_fg_color = test_pass ? GR_COLOR : HL_COLOR;

    // Test digit index: char positions 6-14 map to BCD indices 8-0
    function [3:0] test_dig_idx;
        input [4:0] p;
        if (p >= 5'd6 && p <= 5'd14)
            test_dig_idx = 4'd14 - p[3:0];
        else
            test_dig_idx = 4'hF;
    endfunction

    // -----------------------------------------------------------------------
    // Screen / line classification
    // -----------------------------------------------------------------------
    wire is_results_screen = (render_sid_ff == 3'd6);
    wire mode_is_timer     = (mode_sync_ff == 2'd2);
    wire mode_is_test      = (mode_sync_ff == 2'd0);
    wire is_test_results   = mode_is_test && is_results_screen;
    wire is_entry_screen   = (render_sid_ff == 3'd1) ||
                             (render_sid_ff == 3'd2) ||
                             (render_sid_ff == 3'd3);
    wire is_loading_screen = (render_sid_ff == 3'd5) || (render_sid_ff == 3'd7);
    wire is_time_loading   = (render_sid_ff == 3'd7);

    // Results prime lines: screen 6, lines 2-11
    wire is_results_prime_line = is_results_screen && (line_idx_ff >= 4'd2);
    // Results info line: screen 6, line 1
    wire is_results_info_line  = is_results_screen && (line_idx_ff == 4'd1);

    // Which lines have standard dynamic digits (entry/loading)?
    wire line_has_digits = (is_entry_screen && line_idx_ff == 4'd1) ||
                           (is_loading_screen && (line_idx_ff == 4'd1 || line_idx_ff == 4'd2));

    // Results: prime indices for current line
    wire [4:0] left_prime_idx  = {line_idx_ff - 4'd2, 1'b0};   // (line-2)*2
    wire [4:0] right_prime_idx = {line_idx_ff - 4'd2, 1'b1};   // (line-2)*2+1

    // Results: leading-zero positions for latched BCD values
    wire [3:0] left_fnz  = first_nz(left_bcd_ff);
    wire [3:0] right_fnz = first_nz(right_bcd_ff);

    // Results: is this prime slot populated?
    wire left_valid  = (left_prime_idx  < rdcnt_sync_ff);
    wire right_valid = (right_prime_idx < rdcnt_sync_ff);

    // -----------------------------------------------------------------------
    // Main combinational block (helpers)
    // -----------------------------------------------------------------------
    always @(*) begin
        is_line0 = (line_idx_ff == 4'd0);

        // Text region: which words contain character data
        // Test mode: only lines 0-2 have text (pass: 0-1, fail: 0-2)
        if (is_line0)
            is_text = (render_sid_ff != 3'd0 && word_idx_ff >= 6'd10 && word_idx_ff < 6'd30);
        else if (line_idx_ff <= 4'd2)
            is_text = (word_idx_ff >= 6'd15 && word_idx_ff < 6'd25);
        else if (is_results_screen && !mode_is_test)
            is_text = (word_idx_ff >= 6'd15 && word_idx_ff < 6'd25);
        else
            is_text = 1'b0;  // lines 3-11 on non-results or test: all background

        // Character position within the 20-char line
        char_pos_0  = word_idx_ff[4:0] - 5'd10;
        word_off_12 = word_idx_ff[4:0] - 5'd15;
        char_a_pos  = {word_off_12[3:0], 1'b0};
        char_b_pos  = {word_off_12[3:0], 1'b1};

        // ---- Standard digit position lookup (entry / loading screens) ----
        if (render_sid_ff == 3'd2 || (is_time_loading && line_idx_ff == 4'd2)) begin
            dig_idx_a = idx4(char_a_pos);
            dig_idx_b = idx4(char_b_pos);
        end else begin
            dig_idx_a = idx8(char_a_pos);
            dig_idx_b = idx8(char_b_pos);
        end

        dig_en_a = (is_entry_screen || is_loading_screen) && line_has_digits && (dig_idx_a != 4'hF);
        dig_en_b = (is_entry_screen || is_loading_screen) && line_has_digits && (dig_idx_b != 4'hF);

        // ---- Results info line override (screen 6, line 1) ----
        if (is_results_info_line) begin
            if (mode_is_timer) begin
                // Timer mode: T:DDDD SEC #DDDDDDDD
                // Time digits at positions 2-5 (4-digit from ibcd)
                if (timer_info_t_idx(char_a_pos) != 4'hF) begin
                    dig_en_a  = 1'b1;
                    dig_idx_a = timer_info_t_idx(char_a_pos);
                end
                if (timer_info_t_idx(char_b_pos) != 4'hF) begin
                    dig_en_b  = 1'b1;
                    dig_idx_b = timer_info_t_idx(char_b_pos);
                end
            end else begin
                // N-max mode: N:DDDDDDDD #DDDDDDDD
                // N value digits at pos 2-9
                if (res_info_n_idx(char_a_pos) != 4'hF) begin
                    dig_en_a  = 1'b1;
                    dig_idx_a = res_info_n_idx(char_a_pos);
                end
                if (res_info_n_idx(char_b_pos) != 4'hF) begin
                    dig_en_b  = 1'b1;
                    dig_idx_b = res_info_n_idx(char_b_pos);
                end
            end
            // Prime count digits at positions 12-19 (same for both modes)
            if (res_info_cnt_idx(char_a_pos) != 4'hF) begin
                dig_en_a  = 1'b1;
                dig_idx_a = res_info_cnt_idx(char_a_pos);
            end
            if (res_info_cnt_idx(char_b_pos) != 4'hF) begin
                dig_en_b  = 1'b1;
                dig_idx_b = res_info_cnt_idx(char_b_pos);
            end
        end

        // ---- Results prime line override (screen 6, lines 2-11) ----
        // Digit enable/index handled separately below in ROM address driving,
        // since these use 9-digit BCD from the left/right latches, not the
        // standard 8-digit active_bcd bus.

        // ---- Select BCD source per screen/line ----
        if (is_results_info_line) begin
            // Results info: N value for positions 2-9, prime count for 12-19
            // Use ibcd for N, pbcd for count
            if (res_info_cnt_idx(char_a_pos) != 4'hF || res_info_cnt_idx(char_b_pos) != 4'hF)
                active_bcd = pbcd_sync_ff;
            else
                active_bcd = ibcd_sync_ff;
        end else if (is_loading_screen && line_idx_ff == 4'd1)
            active_bcd = pbcd_sync_ff;
        else if (is_time_loading && line_idx_ff == 4'd2)
            active_bcd = cbcd_sync_ff;
        else if (is_loading_screen && line_idx_ff == 4'd2)
            active_bcd = ibcd_sync_ff;
        else
            active_bcd = bcd_sync_ff;

        dig_val_a = bcd_val(active_bcd, dig_idx_a);
        dig_val_b = bcd_val(active_bcd, dig_idx_b);

        // Background word: 16 pixels of BG_COLOR
        bg_word = {16{BG_COLOR}};

        // Per-character foreground: test mode uses green/red, else cursor=red, default=white
        if (is_test_results) begin
            fg_a = test_fg_color;
            fg_b = test_fg_color;
        end else begin
            fg_a = (cursor_a_ff && line_idx_ff == 4'd1) ? HL_COLOR : FG_COLOR;
            fg_b = (cursor_b_ff && line_idx_ff == 4'd1) ? HL_COLOR : FG_COLOR;
        end

        // Line 0 foreground: green/red for test results, white otherwise
        line0_fg = is_test_results ? test_fg_color : FG_COLOR;

        // 2x expanded word: each glyph bit -> 2 adjacent pixels (line 0)
        word_2x = {
            {2{font_pixels[7] ? line0_fg : BG_COLOR}},
            {2{font_pixels[6] ? line0_fg : BG_COLOR}},
            {2{font_pixels[5] ? line0_fg : BG_COLOR}},
            {2{font_pixels[4] ? line0_fg : BG_COLOR}},
            {2{font_pixels[3] ? line0_fg : BG_COLOR}},
            {2{font_pixels[2] ? line0_fg : BG_COLOR}},
            {2{font_pixels[1] ? line0_fg : BG_COLOR}},
            {2{font_pixels[0] ? line0_fg : BG_COLOR}}
        };

        // 1x word: glyph A (8 px) + glyph B (8 px) = 16 pixels (lines 1+)
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

        // Trigger: screen_id changed, first render, digits changed,
        //          prime count changed, results BCD finished, or test BCD finished
        trigger = init_calib_complete &&
                  (first_ff || (sid_sync_ff != sid_prev_ff) ||
                   digit_dirty || prime_dirty || results_dirty || test_dirty);
    end

    // -----------------------------------------------------------------------
    // Results prime line: digit character override
    // For char A/B on lines 2-11 of screen 6, compute the font character
    // from the latched left/right BCD values with leading-zero suppression.
    // Returns 7'd0 (blank glyph) for spaces, leading zeros, or empty slots.
    // -----------------------------------------------------------------------
    reg [6:0] res_char_a, res_char_b;
    always @(*) begin
        res_char_a = 7'd0;
        res_char_b = 7'd0;

        if (is_results_prime_line) begin
            // Char A
            if (char_a_pos <= 5'd9 && char_a_pos >= 5'd1) begin
                // Left prime digit
                if (left_valid) begin
                    if (res_dig_idx(char_a_pos) > left_fnz)
                        res_char_a = 7'd0;  // leading zero → blank
                    else
                        res_char_a = {3'd0, bcd9_val(left_bcd_ff, res_dig_idx(char_a_pos))} + 7'h30;
                end
            end else if (char_a_pos >= 5'd11) begin
                // Right prime digit
                if (right_valid) begin
                    if (res_dig_idx(char_a_pos) > right_fnz)
                        res_char_a = 7'd0;
                    else
                        res_char_a = {3'd0, bcd9_val(right_bcd_ff, res_dig_idx(char_a_pos))} + 7'h30;
                end
            end
            // pos 0, 10 → blank (res_char_a stays 0)

            // Char B
            if (char_b_pos <= 5'd9 && char_b_pos >= 5'd1) begin
                if (left_valid) begin
                    if (res_dig_idx(char_b_pos) > left_fnz)
                        res_char_b = 7'd0;
                    else
                        res_char_b = {3'd0, bcd9_val(left_bcd_ff, res_dig_idx(char_b_pos))} + 7'h30;
                end
            end else if (char_b_pos >= 5'd11) begin
                if (right_valid) begin
                    if (res_dig_idx(char_b_pos) > right_fnz)
                        res_char_b = 7'd0;
                    else
                        res_char_b = {3'd0, bcd9_val(right_bcd_ff, res_dig_idx(char_b_pos))} + 7'h30;
                end
            end
        end
    end

    // -----------------------------------------------------------------------
    // Timer mode character overrides (screen 6 in timer mode)
    // Line 0: title "    TIME RESULTS    " replaces "   N-MAX RESULTS    "
    // Line 1: info  "T:DDDD SEC #DDDDDDDD" replaces "N:DDDDDDDD #DDDDDDDD"
    // -----------------------------------------------------------------------
    wire timer_title_active = mode_is_timer && is_results_screen && is_line0;
    wire timer_info_active  = mode_is_timer && is_results_info_line;

    reg [6:0] timer_ovr_a, timer_ovr_b;
    always @(*) begin
        timer_ovr_a = 7'd0;
        timer_ovr_b = 7'd0;
        if (mode_is_timer && is_results_screen) begin
            if (is_line0) begin
                // "    TIME RESULTS    " (positions 4-15)
                case (char_pos_0)
                    5'd4:  timer_ovr_a = 7'h54; // T
                    5'd5:  timer_ovr_a = 7'h49; // I
                    5'd6:  timer_ovr_a = 7'h4D; // M
                    5'd7:  timer_ovr_a = 7'h45; // E
                    5'd9:  timer_ovr_a = 7'h52; // R
                    5'd10: timer_ovr_a = 7'h45; // E
                    5'd11: timer_ovr_a = 7'h53; // S
                    5'd12: timer_ovr_a = 7'h55; // U
                    5'd13: timer_ovr_a = 7'h4C; // L
                    5'd14: timer_ovr_a = 7'h54; // T
                    5'd15: timer_ovr_a = 7'h53; // S
                    default: timer_ovr_a = 7'd0;
                endcase
            end else if (line_idx_ff == 4'd1) begin
                // char_a (even positions): 0=T, 8=E
                case (char_a_pos)
                    5'd0:  timer_ovr_a = 7'h54; // T
                    5'd8:  timer_ovr_a = 7'h45; // E
                    default: timer_ovr_a = 7'd0;
                endcase
                // char_b (odd positions): 7=S, 9=C
                case (char_b_pos)
                    5'd7:  timer_ovr_b = 7'h53; // S
                    5'd9:  timer_ovr_b = 7'h43; // C
                    default: timer_ovr_b = 7'd0;
                endcase
            end
        end
    end

    // -----------------------------------------------------------------------
    // Test mode character overrides (screen 6 in test mode)
    // Line 0: "   TEST PASSED  " or "   TEST FAILED  "
    // Line 1 (pass): "  COMPARED:  100   "
    // Line 1 (fail): " EXP: DDDDDDDDD   " (9-digit BCD with LZ suppression)
    // Line 2 (fail): " GOT: DDDDDDDDD   "
    // -----------------------------------------------------------------------
    reg [6:0] test_ovr_a, test_ovr_b;
    always @(*) begin
        test_ovr_a = 7'd0;
        test_ovr_b = 7'd0;
        if (is_test_results) begin
            if (is_line0) begin
                // "   TEST PASSED  " or "   TEST FAILED  "
                case (char_pos_0)
                    5'd3:  test_ovr_a = 7'h54; // T
                    5'd4:  test_ovr_a = 7'h45; // E
                    5'd5:  test_ovr_a = 7'h53; // S
                    5'd6:  test_ovr_a = 7'h54; // T
                    // 5'd7 = space
                    5'd8:  test_ovr_a = test_pass ? 7'h50 : 7'h46; // P or F
                    5'd9:  test_ovr_a = 7'h41; // A
                    5'd10: test_ovr_a = test_pass ? 7'h53 : 7'h49; // S or I
                    5'd11: test_ovr_a = test_pass ? 7'h53 : 7'h4C; // S or L
                    5'd12: test_ovr_a = 7'h45; // E
                    5'd13: test_ovr_a = 7'h44; // D
                    default: test_ovr_a = 7'd0;
                endcase
            end else if (line_idx_ff == 4'd1) begin
                if (test_pass) begin
                    // "  COMPARED:  100   "
                    case (char_a_pos)
                        5'd2:  test_ovr_a = 7'h43; // C
                        5'd4:  test_ovr_a = 7'h4D; // M
                        5'd6:  test_ovr_a = 7'h41; // A
                        5'd8:  test_ovr_a = 7'h45; // E
                        5'd10: test_ovr_a = 7'h3A; // :
                        5'd14: test_ovr_a = 7'h30; // 0
                        default: test_ovr_a = 7'd0;
                    endcase
                    case (char_b_pos)
                        5'd3:  test_ovr_b = 7'h4F; // O
                        5'd5:  test_ovr_b = 7'h50; // P
                        5'd7:  test_ovr_b = 7'h52; // R
                        5'd9:  test_ovr_b = 7'h44; // D
                        5'd13: test_ovr_b = 7'h31; // 1
                        5'd15: test_ovr_b = 7'h30; // 0
                        default: test_ovr_b = 7'd0;
                    endcase
                end else begin
                    // " EXP: DDDDDDDDD   "
                    case (char_a_pos)
                        5'd2:  test_ovr_a = 7'h58; // X
                        5'd4:  test_ovr_a = 7'h3A; // :
                        default: begin
                            if (test_dig_idx(char_a_pos) != 4'hF) begin
                                if (test_dig_idx(char_a_pos) > exp_fnz)
                                    test_ovr_a = 7'd0;
                                else
                                    test_ovr_a = {3'd0, bcd9_val(texp_sync_ff, test_dig_idx(char_a_pos))} + 7'h30;
                            end
                        end
                    endcase
                    case (char_b_pos)
                        5'd1:  test_ovr_b = 7'h45; // E
                        5'd3:  test_ovr_b = 7'h50; // P
                        default: begin
                            if (test_dig_idx(char_b_pos) != 4'hF) begin
                                if (test_dig_idx(char_b_pos) > exp_fnz)
                                    test_ovr_b = 7'd0;
                                else
                                    test_ovr_b = {3'd0, bcd9_val(texp_sync_ff, test_dig_idx(char_b_pos))} + 7'h30;
                            end
                        end
                    endcase
                end
            end else if (line_idx_ff == 4'd2 && !test_pass) begin
                // " GOT: DDDDDDDDD   "
                case (char_a_pos)
                    5'd2:  test_ovr_a = 7'h4F; // O
                    5'd4:  test_ovr_a = 7'h3A; // :
                    default: begin
                        if (test_dig_idx(char_a_pos) != 4'hF) begin
                            if (test_dig_idx(char_a_pos) > got_fnz)
                                test_ovr_a = 7'd0;
                            else
                                test_ovr_a = {3'd0, bcd9_val(tgot_sync_ff, test_dig_idx(char_a_pos))} + 7'h30;
                        end
                    end
                endcase
                case (char_b_pos)
                    5'd1:  test_ovr_b = 7'h47; // G
                    5'd3:  test_ovr_b = 7'h54; // T
                    default: begin
                        if (test_dig_idx(char_b_pos) != 4'hF) begin
                            if (test_dig_idx(char_b_pos) > got_fnz)
                                test_ovr_b = 7'd0;
                            else
                                test_ovr_b = {3'd0, bcd9_val(tgot_sync_ff, test_dig_idx(char_b_pos))} + 7'h30;
                        end
                    end
                endcase
            end
        end
    end

    // -----------------------------------------------------------------------
    // Combinational ROM address driving + digit/results override
    // -----------------------------------------------------------------------
    always @(*) begin
        txt_sid   = render_sid_ff;
        // Cap txt_line to 0-2 (ROM only has 3 lines); for line 3+ send 0
        // which returns blank for most screens.
        txt_line  = (line_idx_ff <= 4'd2) ? line_idx_ff[1:0] : 2'd0;
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
                if (is_test_results) begin
                    // Test mode: override all characters on screen 6
                    font_char = test_ovr_a;
                end else if (is_results_prime_line) begin
                    // Results prime lines: use pre-computed character
                    font_char = res_char_a;
                end else if (timer_title_active) begin
                    // Timer mode title: override entire line
                    font_char = timer_ovr_a;
                end else if (timer_info_active && timer_ovr_a != 7'd0) begin
                    // Timer mode info: override static text positions
                    font_char = timer_ovr_a;
                end else if (dig_en_a) begin
                    font_char = {3'd0, dig_val_a} + 7'h30;
                end else begin
                    font_char = txt_code[6:0];
                end
                font_row  = is_line0 ? pixel_row_ff[4:1] : pixel_row_ff[3:0];
                if (!is_line0)
                    txt_pos = char_b_pos;
            end

            S_FONT_ROM_A: begin
                if (!is_line0) begin
                    if (is_test_results) begin
                        font_char = test_ovr_b;
                    end else if (is_results_prime_line) begin
                        font_char = res_char_b;
                    end else if (timer_info_active && timer_ovr_b != 7'd0) begin
                        font_char = timer_ovr_b;
                    end else if (dig_en_b) begin
                        font_char = {3'd0, dig_val_b} + 7'h30;
                    end else begin
                        font_char = txt_code[6:0];
                    end
                    font_row = pixel_row_ff[3:0];
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
            state_next          = S_IDLE;
            line_idx_next       = 4'd0;
            pixel_row_next      = 5'd0;
            word_idx_next       = 6'd0;
            addr_next           = FB_A;
            render_sid_next     = 3'd0;
            sid_prev_next       = 3'd0;
            first_next          = 1'b1;
            glyph_a_next        = 8'd0;
            cursor_a_next       = 1'b0;
            cursor_b_next       = 1'b0;
            dtog_rendered_next  = 1'b0;
            ptog_rendered_next  = 1'b0;
            rdone_rendered_next = 1'b0;
            ttog_rendered_next  = 1'b0;
            wr_req_next         = 1'b0;
            wr_addr_next        = 27'd0;
            wr_data_next        = 128'd0;
            render_done_next    = 1'b0;
            left_bcd_next       = 36'd0;
            right_bcd_next      = 36'd0;
            rbcd_rd_addr_next   = 5'd0;
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
        rdone_rendered_next = rdone_rendered_ff;
        ttog_rendered_next  = ttog_rendered_ff;
        wr_req_next         = wr_req_ff;
        wr_addr_next        = wr_addr_ff;
        wr_data_next        = wr_data_ff;
        render_done_next    = render_done_ff;
        left_bcd_next       = left_bcd_ff;
        right_bcd_next      = right_bcd_ff;
        rbcd_rd_addr_next   = rbcd_rd_addr_ff;

        case (state_ff)

            S_IDLE: begin
                wr_req_next = 1'b0;
                if (trigger) begin
                    render_done_next = 1'b0;
                    state_next       = S_SETUP;
                end
            end

            S_SETUP: begin
                render_sid_next     = sid_sync_ff;
                sid_prev_next       = sid_sync_ff;
                dtog_rendered_next  = dtog_sync_ff;
                ptog_rendered_next  = ptog_sync_ff;
                rdone_rendered_next = rdone_sync_ff;
                ttog_rendered_next  = ttog_sync_ff;
                first_next          = 1'b0;
                addr_next           = render_buf ? FB_B : FB_A;
                line_idx_next       = 4'd0;
                pixel_row_next      = 5'd0;
                word_idx_next       = 6'd0;
                state_next          = S_WORD_START;
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
                cursor_a_next = dig_en_a && is_entry_screen && (dig_idx_a == cur_sync_ff);
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
                        if (line_idx_ff == 4'd11) begin
                            state_next = S_DONE;
                        end else begin
                            line_idx_next = line_idx_ff + 4'd1;
                            // If next line is a results prime line, prefetch BCD
                            // (skip for test mode — no prime list to display)
                            if (is_results_screen && !mode_is_test && (line_idx_ff + 4'd1 >= 4'd2))
                                state_next = S_RFETCH_L;
                            else
                                state_next = S_WORD_START;
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

            // ---- Results BCD prefetch: 5-state pipeline per line ----
            // rbcd_rd_addr_ff (reg) → rd_addr (wire) → bcd_mem → rd_data_ff (reg)
            // = 1-cycle read latency after address is registered.

            S_RFETCH_L: begin
                // Set read address for left prime
                rbcd_rd_addr_next = left_prime_idx;
                state_next        = S_RFETCH_LW;
            end

            S_RFETCH_LW: begin
                // Wait for BRAM registered read to capture bcd_mem[left]
                state_next = S_RFETCH_R;
            end

            S_RFETCH_R: begin
                // rd_data now valid for left prime — latch it
                left_bcd_next     = rbcd_rd_data;
                // Set read address for right prime
                rbcd_rd_addr_next = right_prime_idx;
                state_next        = S_RFETCH_RW;
            end

            S_RFETCH_RW: begin
                // Wait for BRAM registered read to capture bcd_mem[right]
                state_next = S_RFETCH_D;
            end

            S_RFETCH_D: begin
                // rd_data now valid for right prime �� latch it
                right_bcd_next = rbcd_rd_data;
                state_next     = S_WORD_START;
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
        state_ff            <= state_next;
        line_idx_ff         <= line_idx_next;
        pixel_row_ff        <= pixel_row_next;
        word_idx_ff         <= word_idx_next;
        addr_ff             <= addr_next;
        render_sid_ff       <= render_sid_next;
        sid_prev_ff         <= sid_prev_next;
        first_ff            <= first_next;
        glyph_a_ff          <= glyph_a_next;
        cursor_a_ff         <= cursor_a_next;
        cursor_b_ff         <= cursor_b_next;
        dtog_rendered_ff    <= dtog_rendered_next;
        ptog_rendered_ff    <= ptog_rendered_next;
        rdone_rendered_ff   <= rdone_rendered_next;
        ttog_rendered_ff    <= ttog_rendered_next;
        wr_req_ff           <= wr_req_next;
        wr_addr_ff          <= wr_addr_next;
        wr_data_ff          <= wr_data_next;
        render_done_ff      <= render_done_next;
        left_bcd_ff         <= left_bcd_next;
        right_bcd_ff        <= right_bcd_next;
        rbcd_rd_addr_ff     <= rbcd_rd_addr_next;
    end

endmodule
