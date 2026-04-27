// test_vga_top.v — Combined VGA + prime engine test top for Nexys A7.
//
// Exercises all four arbiter ports simultaneously:
//   Port 0: VGA reader      — DDR2 reads into pixel_fifo (highest priority)
//   Port 1: Frame renderer  — text-to-pixel rendering into DDR2 frame buffer
//   Port 2: Prime plus      — 6k+1 bitmap writes from accumulator FIFO
//   Port 3: Prime minus     — 6k-1 bitmap writes from accumulator FIFO
//
// screen_id driven by keypad_nav (A/B/C/D selects mode, * starts, # returns home).
// Double-buffer swap is edge-triggered on render_done (no partial frames).
//
// Clock domains:
//   clk      (100 MHz) — engines, accumulators (write side), mode_fsm, SSD
//   clk_vga  (25 MHz)  — VGA controller, VGA driver, pixel_fifo read side
//   clk_mem  (200 MHz) — MIG reference clock
//   ui_clk   (~75 MHz) — arbiter, accumulators (read side), DDR2, VGA reader
//
// LED debug (all focused on VGA/renderer integration):
//   Normal mode:
//   LED[0]  init_calib_complete    LED[8]  pixel_fifo empty
//   LED[1]  pll_locked             LED[9]  pixel_fifo full
//   LED[2]  render_done            LED[10] render wr req (stuck=stall)
//   LED[3]  vga_enable (latched)   LED[11] VGA rd req (stuck=stall)
//   LED[4]  swap_pending           LED[12] test_done
//   LED[5]  fb_display (0=A,1=B)  LED[13] test_active
//   LED[6]  render wr activity     LED[14] test_pass
//   LED[7]  VGA rd activity        LED[15] test FAIL
//   When test_done: LED[6:0] = match_count (binary)

module test_vga_top #(
    parameter WIDTH = 27
) (
    input  wire        clk,        // 100 MHz board clock
    input  wire        cpu_rst_n,  // active-low CPU_RESETN button
    input  wire [15:0] SW,
    input  wire        BTNC,
    input  wire        BTNR,
    input  wire        BTNL,
    input  wire        BTND,

    // SD card
    output wire        sdcard_pwr_n,
    output wire        sdclk,
    inout              sdcmd,
    input  wire        sddat0,
    output wire        sddat1,
    output wire        sddat2,
    output wire        sddat3,

    // Keypad PMOD JA — pin mapping matches physical keypad wiring
    input  wire        JA1,        // row 1 input
    input  wire        JA2,        // row 3 input
    output wire        JA3,        // column 1 output
    output wire        JA4,        // column 3 output
    input  wire        JA7,        // row 0 input
    input  wire        JA8,        // row 2 input
    output wire        JA9,        // column 0 output
    output wire        JA10,       // column 2 output

    output wire [15:0] LED,
    output wire [6:0]  SEG,
    output wire [7:0]  AN,
    output wire        DP_n,

    // VGA output
    output wire [3:0]  VGA_R,
    output wire [3:0]  VGA_G,
    output wire [3:0]  VGA_B,
    output wire        VGA_HS,
    output wire        VGA_VS,

    // DDR2 pins
    inout  wire [15:0] ddr2_dq,
    inout  wire [1:0]  ddr2_dqs_p,
    inout  wire [1:0]  ddr2_dqs_n,
    output wire [12:0] ddr2_addr,
    output wire [2:0]  ddr2_ba,
    output wire        ddr2_ras_n,
    output wire        ddr2_cas_n,
    output wire        ddr2_we_n,
    output wire [0:0]  ddr2_ck_p,
    output wire [0:0]  ddr2_ck_n,
    output wire [0:0]  ddr2_cke,
    output wire [0:0]  ddr2_cs_n,
    output wire [1:0]  ddr2_dm,
    output wire [0:0]  ddr2_odt
);

    // =======================================================================
    // Reset synchronizer (clk domain, 100 MHz)
    // =======================================================================
    wire rst_sync_n;

    reset_sync u_rst_sync (
        .clk    (clk),
        .rst_n  (cpu_rst_n),
        .rst_ff (),
        .rst_n_ff (rst_sync_n)
    );

    // =======================================================================
    // Debounced button pulses (clk domain)
    // =======================================================================
    wire btnc_pulse, btnr_pulse, btnl_pulse, btnd_pulse;

    btn_debounce_wrapper u_btn_dbnc (
        .clk        (clk),
        .rst_n      (rst_sync_n),
        .btnc_in    (BTNC),
        .btnr_in    (BTNR),
        .btnl_in    (BTNL),
        .btnd_in    (BTND),
        .btnc_pulse (btnc_pulse),
        .btnr_pulse (btnr_pulse),
        .btnl_pulse (btnl_pulse),
        .btnd_pulse (btnd_pulse)
    );

    // =======================================================================
    // Keypad wrapper — column driver, row debouncers, row reader, keypad_nav,
    // digit_entry all grouped inside.
    // Pin mapping: c_0→JA9, c_1→JA3, c_2→JA10, c_3→JA4
    //              row_0←JA7, row_1←JA1, row_2←JA8, row_3←JA2
    // =======================================================================
    wire [2:0]  screen_id_ff;
    wire [1:0]  nav_mode_sel;
    wire        nav_go;
    wire [31:0] de_bcd_digits;
    wire [3:0]  de_cursor_pos;
    wire        de_changed;
    wire        de_toggle;

    keypad_wrapper u_keypad (
        .clk           (clk),
        .rst_n         (rst_sync_n),
        .row_0         (JA7),
        .row_1         (JA1),
        .row_2         (JA8),
        .row_3         (JA2),
        .col_0         (JA9),
        .col_1         (JA3),
        .col_2         (JA10),
        .col_3         (JA4),
        .mode_done     (effective_done),
        .primes_ready  (has_bitmap_ff),
        .screen_id     (screen_id_ff),
        .mode_sel      (nav_mode_sel),
        .go            (nav_go),
        .bcd_digits    (de_bcd_digits),
        .cursor_pos    (de_cursor_pos),
        .digit_changed (de_changed),
        .digit_toggle  (de_toggle)
    );

    // =======================================================================
    // BCD converter wrapper — bcd_to_bin, 2x bin_to_bcd, 3x bin_to_bcd9
    // Auto-restart and test BCD delay/toggle logic handled inside.
    // =======================================================================
    wire [26:0] bin_value;
    wire        bin_valid;
    wire [31:0] count_bcd;
    wire        count_bcd_valid;
    wire        count_bcd_toggle;
    wire [31:0] countdown_bcd;
    wire        countdown_bcd_valid;
    wire [35:0] test_exp_bcd, test_got_bcd, test_mc_bcd;
    wire        test_bcd_toggle_ff;

    bcd_converter_wrapper #(.WIDTH(WIDTH)) u_bcd (
        .clk              (clk),
        .rst_n            (rst_sync_n),
        // bcd_to_bin
        .bcd_digits       (de_bcd_digits),
        .bcd_start        (de_changed),
        .bin_value        (bin_value),
        .bin_valid        (bin_valid),
        // count bin_to_bcd
        .prime_total      (prime_total[26:0]),
        .go               (nav_go),
        .screen_id        (screen_id_ff),
        .count_bcd        (count_bcd),
        .count_bcd_valid  (count_bcd_valid),
        .count_bcd_toggle (count_bcd_toggle),
        // countdown bin_to_bcd
        .remaining_time   (remaining_time[26:0]),
        .countdown_bcd    (countdown_bcd),
        .countdown_bcd_valid (countdown_bcd_valid),
        // test bin_to_bcd9
        .test_expected    (test_exp_clk_ff),
        .test_got         (test_got_clk_ff),
        .test_match_count (test_mc_clk_ff),
        .test_done_rising (test_done_clk_meta && !test_done_clk_ff),
        .test_exp_bcd     (test_exp_bcd),
        .test_got_bcd     (test_got_bcd),
        .test_mc_bcd      (test_mc_bcd),
        .test_bcd_toggle_ff (test_bcd_toggle_ff)
    );

    // =======================================================================
    // Input interpretation — from keypad BCD-to-binary converter
    // n_limit (27-bit), t_limit (32-bit), check_candidate (27-bit)
    // all driven from the same bin_value since only one mode is active.
    // =======================================================================
    wire [WIDTH-1:0] n_limit         = bin_value;
    wire [31:0]      t_limit         = {5'd0, bin_value};
    wire [WIDTH-1:0] check_candidate = bin_value;

    // =======================================================================
    // Latched input BCD — captured on nav_go (before digit_entry resets)
    // Held constant while on loading/results screen for display.
    // =======================================================================
    reg [31:0] latched_bcd_ff;
    always @(posedge clk) begin
        if (!rst_sync_n)
            latched_bcd_ff <= 32'd0;
        else if (nav_go)
            latched_bcd_ff <= de_bcd_digits;
    end

    // =======================================================================
    // Latched N-limit (binary) — captured on go, before digit_entry resets.
    // Used for conditional prime count (+2/+1/+0) and results_bcd inclusion.
    // =======================================================================
    reg [WIDTH-1:0] latched_n_limit_ff;
    always @(posedge clk) begin
        if (!rst_sync_n)
            latched_n_limit_ff <= {WIDTH{1'b0}};
        else if (nav_go)
            latched_n_limit_ff <= bin_value;
    end

    // =======================================================================
    // Prime count total — sum of both engines plus 0/1/2 for primes 2 and 3.
    // For time mode, n_limit carries the time value; always include 2 and 3.
    // Converted to BCD for live display on loading and results screens.
    // =======================================================================
    wire [WIDTH-1:0] effective_n_limit = (latched_mode_ff == 2'd2) ? {WIDTH{1'b1}}
                                                                    : latched_n_limit_ff;
    wire [1:0] hardcoded_prime_adj = (effective_n_limit >= {{WIDTH-2{1'b0}}, 2'd3}) ? 2'd2 :
                                     (effective_n_limit >= {{WIDTH-2{1'b0}}, 2'd2}) ? 2'd1 : 2'd0;
    wire [31:0] prime_total = prime_count_plus + prime_count_minus
                              + {30'd0, hardcoded_prime_adj};

    // =======================================================================
    // Countdown timer — remaining seconds for time mode display
    // =======================================================================
    wire [31:0] remaining_time = (t_limit_out > seconds) ? (t_limit_out - seconds) : 32'd0;

    // =======================================================================
    // PLL: 100 MHz -> 25 MHz (clk_vga), 200 MHz (clk_mem), 50 MHz (clk_sd)
    // =======================================================================
    wire clk_vga, clk_mem, clk_sd;
    wire pll_locked;

    pll u_pll (
        .clk_in  (clk),
        .resetn  (rst_sync_n),
        .clk_mem (clk_mem),
        .clk_sd  (clk_sd),
        .clk_vga (clk_vga),
        .locked  (pll_locked)
    );

    wire sys_rst_n = rst_sync_n & pll_locked;

    // =======================================================================
    // SD card infrastructure (clk_sd domain)
    // Reads CSEE4280Primes.txt, parses to binary, feeds to prime bridge.
    // =======================================================================
    assign sdcard_pwr_n = 1'b0;
    assign {sddat1, sddat2, sddat3} = 3'b111;

    wire       sd_outen;
    wire [7:0] sd_outbyte;
    wire [3:0] sd_card_stat;
    wire [1:0] sd_card_type;
    wire [1:0] sd_filesystem_type;
    wire       sd_file_found;
    wire [2:0] sd_filesystem_state;
    wire       sd_pause;

    sd_file_reader #(
        .FILE_NAME_LEN (18),
        .FILE_NAME     ("CSEE4280Primes.txt"),
        .CLK_DIV       (3'd2),
        .SIMULATE      (0)
    ) u_sd_file_reader (
        .rstn            (sys_rst_n),
        .clk             (clk_sd),
        .sdclk           (sdclk),
        .sdcmd           (sdcmd),
        .sddat0          (sddat0),
        .card_stat       (sd_card_stat),
        .card_type       (sd_card_type),
        .filesystem_type (sd_filesystem_type),
        .file_found      (sd_file_found),
        .outen           (sd_outen),
        .outbyte         (sd_outbyte),
        .filesystem_state(sd_filesystem_state),
        .pause           (sd_pause)
    );

    wire [31:0] sd_parsed_value;
    wire        sd_parsed_valid;

    sd_line_parser u_sd_parser (
        .clk       (clk_sd),
        .rst_n     (sys_rst_n),
        .byte_en   (sd_outen),
        .byte_data (sd_outbyte),
        .value     (sd_parsed_value),
        .valid     (sd_parsed_valid)
    );

    // SD file is done when filesystem_state == DONE (3'd6)
    wire sd_file_done = (sd_filesystem_state == 3'd6);

    // Bridge: clk_sd FIFO -> ui_clk handshake for test_prime_checker
    wire [31:0] sd_bridge_data;
    wire        sd_bridge_valid;
    wire        sd_bridge_eof;
    wire        sd_bridge_consume;

    sd_prime_bridge u_sd_bridge (
        .clk_sd       (clk_sd),
        .rst_sd_n     (sys_rst_n),
        .parsed_value (sd_parsed_value),
        .parsed_valid (sd_parsed_valid),
        .file_done    (sd_file_done),
        .sd_pause     (sd_pause),
        .ui_clk       (ui_clk),
        .rst_ui_n     (arb_rst_n),
        .start        (test_start_ui),
        .consume      (sd_bridge_consume),
        .prime_data   (sd_bridge_data),
        .prime_valid  (sd_bridge_valid),
        .prime_eof    (sd_bridge_eof)
    );

    // =======================================================================
    // Reset synchronizer (clk_vga domain)
    // =======================================================================
    wire vga_rst, vga_rst_n;

    reset_sync u_vga_rst_sync (
        .clk    (clk_vga),
        .rst_n  (pll_locked),
        .rst_ff (vga_rst),
        .rst_n_ff (vga_rst_n)
    );

    // =======================================================================
    // screen_id CDC (clk -> clk_vga): 2-FF synchronizer, slow-changing
    // =======================================================================
    reg [2:0] sid_vga_meta, sid_vga_sync;
    always @(posedge clk_vga) begin
        sid_vga_meta <= screen_id_ff;
        sid_vga_sync <= sid_vga_meta;
    end
    wire sprite_enable = (sid_vga_sync == 3'd0);

    // =======================================================================
    // DDR2 wrapper (MIG)
    // =======================================================================
    wire         ui_clk;
    wire         ui_clk_sync_rst;
    wire         init_calib_complete;
    wire         arb_rst_n = ~ui_clk_sync_rst;

    wire [26:0]  arb_app_addr;
    wire [2:0]   arb_app_cmd;
    wire         arb_app_en;
    wire [127:0] arb_app_wdf_data;
    wire         arb_app_wdf_end;
    wire [15:0]  arb_app_wdf_mask;
    wire         arb_app_wdf_wren;
    wire         arb_app_rdy;
    wire         arb_app_wdf_rdy;
    wire [127:0] arb_app_rd_data;
    wire         arb_app_rd_data_valid;
    wire         arb_app_rd_data_end;

    ddr2_wrapper u_ddr2 (
        .ddr2_dq             (ddr2_dq),
        .ddr2_dqs_p          (ddr2_dqs_p),
        .ddr2_dqs_n          (ddr2_dqs_n),
        .ddr2_addr           (ddr2_addr),
        .ddr2_ba             (ddr2_ba),
        .ddr2_ras_n          (ddr2_ras_n),
        .ddr2_cas_n          (ddr2_cas_n),
        .ddr2_we_n           (ddr2_we_n),
        .ddr2_ck_p           (ddr2_ck_p),
        .ddr2_ck_n           (ddr2_ck_n),
        .ddr2_cke            (ddr2_cke),
        .ddr2_cs_n           (ddr2_cs_n),
        .ddr2_dm             (ddr2_dm),
        .ddr2_odt            (ddr2_odt),

        .app_addr            (arb_app_addr),
        .app_cmd             (arb_app_cmd),
        .app_en              (arb_app_en),
        .app_wdf_data        (arb_app_wdf_data),
        .app_wdf_end         (arb_app_wdf_end),
        .app_wdf_mask        (arb_app_wdf_mask),
        .app_wdf_wren        (arb_app_wdf_wren),
        .app_rd_data         (arb_app_rd_data),
        .app_rd_data_end     (arb_app_rd_data_end),
        .app_rd_data_valid   (arb_app_rd_data_valid),
        .app_rdy             (arb_app_rdy),
        .app_wdf_rdy         (arb_app_wdf_rdy),
        .app_sr_req          (1'b0),
        .app_ref_req         (1'b0),
        .app_zq_req          (1'b0),
        .app_sr_active       (),
        .app_ref_ack         (),
        .app_zq_ack          (),

        .ui_clk              (ui_clk),
        .ui_clk_sync_rst     (ui_clk_sync_rst),
        .init_calib_complete (init_calib_complete),
        .sys_clk_i           (clk_mem),
        .sys_rst             (sys_rst_n)
    );

    // =======================================================================
    // Prime compute wrapper — mode_fsm, engines, accumulators, timer,
    // stopwatch, prime_tracker, results_bcd all grouped inside.
    // =======================================================================
    wire        done, is_prime_result;
    wire [3:0]  state_out;
    wire        timer_restart;
    wire [31:0] seconds, t_limit_out, sw_bcd;
    wire [WIDTH-1:0] eng_plus_candidate, eng_minus_candidate;
    wire [31:0] prime_count_plus, prime_count_minus;

    wire [127:0] acc_plus_rd_data,  acc_minus_rd_data;
    wire         acc_plus_fifo_empty, acc_minus_fifo_empty;
    wire         arb_rd_en_plus, arb_rd_en_minus;

    wire [4:0]  rbcd_rd_addr;
    wire [35:0] rbcd_rd_data;
    wire [4:0]  results_display_count;
    wire        results_done;

    prime_compute_wrapper #(.WIDTH(WIDTH)) u_compute (
        .clk                (clk),
        .rst_n              (rst_sync_n),
        .ui_clk             (ui_clk),
        // User interface
        .mode_sel           (nav_mode_sel),
        .n_limit            (n_limit),
        .t_limit            (t_limit),
        .check_candidate    (check_candidate),
        .go                 (nav_go),
        // Results BCD read port (ui_clk domain)
        .effective_n_limit  (effective_n_limit),
        .rbcd_rd_addr       (rbcd_rd_addr),
        .rbcd_rd_data       (rbcd_rd_data),
        .results_display_count (results_display_count),
        .results_done       (results_done),
        // Accumulator FIFO read (ui_clk domain)
        .arb_rd_en_plus     (arb_rd_en_plus),
        .arb_rd_en_minus    (arb_rd_en_minus),
        .acc_plus_rd_data   (acc_plus_rd_data),
        .acc_plus_fifo_empty(acc_plus_fifo_empty),
        .acc_minus_rd_data  (acc_minus_rd_data),
        .acc_minus_fifo_empty(acc_minus_fifo_empty),
        // Prime counts
        .prime_count_plus   (prime_count_plus),
        .prime_count_minus  (prime_count_minus),
        // Status
        .done               (done),
        .is_prime_result    (is_prime_result),
        .state_out          (state_out),
        // Timer
        .timer_restart      (timer_restart),
        .seconds            (seconds),
        .t_limit_out        (t_limit_out),
        .sw_bcd             (sw_bcd),
        // Engine candidates
        .eng_plus_candidate (eng_plus_candidate),
        .eng_minus_candidate(eng_minus_candidate)
    );

    // Latch mode_sel on go pulse — holds the active mode for display logic
    reg [1:0] latched_mode_ff;
    always @(posedge clk) begin
        if (!rst_sync_n)
            latched_mode_ff <= 2'd0;
        else if (nav_go)
            latched_mode_ff <= nav_mode_sel;
    end

    // Bitmap written to DDR2 — gates test mode (D key) navigation.
    // Latches high when mode_fsm completes for N-max or time-limit modes.
    // Cleared after test mode completes, allowing a new computation run.
    reg has_bitmap_ff;
    always @(posedge clk) begin
        if (!rst_sync_n)
            has_bitmap_ff <= 1'b0;
        else if (test_done_clk_meta && !test_done_clk_ff)
            has_bitmap_ff <= 1'b0;
        else if (done && (latched_mode_ff == 2'd1 || latched_mode_ff == 2'd2))
            has_bitmap_ff <= 1'b1;
    end

    // =======================================================================
    // CDC: timer_restart (clk) -> bitmap_reset (ui_clk)
    // Resets arbiter bitmap write pointers so re-runs start at base address.
    // Toggle-based CDC to avoid losing the single-cycle pulse.
    // =======================================================================
    reg timer_restart_toggle_ff;
    always @(posedge clk) begin
        if (!rst_sync_n)
            timer_restart_toggle_ff <= 1'b0;
        else if (timer_restart)
            timer_restart_toggle_ff <= ~timer_restart_toggle_ff;
    end

    reg [2:0] tr_sync_ui_ff;
    always @(posedge ui_clk) begin
        if (ui_clk_sync_rst)
            tr_sync_ui_ff <= 3'b0;
        else
            tr_sync_ui_ff <= {tr_sync_ui_ff[1:0], timer_restart_toggle_ff};
    end
    wire bitmap_reset_ui = tr_sync_ui_ff[2] ^ tr_sync_ui_ff[1];

    // =======================================================================
    // Engine limit capture — highest candidate at done, CDC'd to ui_clk
    // =======================================================================
    reg [WIDTH-1:0] engine_limit_ff;
    always @(posedge clk) begin
        if (!rst_sync_n)
            engine_limit_ff <= {WIDTH{1'b0}};
        else if (done & ~done_prev_ff) begin
            if (eng_plus_candidate > eng_minus_candidate)
                engine_limit_ff <= eng_plus_candidate;
            else
                engine_limit_ff <= eng_minus_candidate;
        end
    end

    // done_prev_ff for engine_limit edge detect (results_bcd_start is inside wrapper)
    reg done_prev_ff;
    always @(posedge clk) begin
        if (!rst_sync_n)
            done_prev_ff <= 1'b0;
        else
            done_prev_ff <= done;
    end

    // CDC engine_limit to ui_clk (stable for millions of cycles, 2-FF safe)
    reg [WIDTH-1:0] engine_limit_ui_meta, engine_limit_ui_ff;
    always @(posedge ui_clk) begin
        if (ui_clk_sync_rst) begin
            engine_limit_ui_meta <= {WIDTH{1'b0}};
            engine_limit_ui_ff   <= {WIDTH{1'b0}};
        end else begin
            engine_limit_ui_meta <= engine_limit_ff;
            engine_limit_ui_ff   <= engine_limit_ui_meta;
        end
    end

    // =======================================================================
    // Frame renderer (ui_clk domain)
    // =======================================================================
    wire         fr_wr_req;
    wire [26:0]  fr_wr_addr;
    wire [127:0] fr_wr_data;
    wire         fr_wr_grant;
    wire         render_done;

    frame_renderer u_renderer (
        .ui_clk              (ui_clk),
        .rst_n               (arb_rst_n),
        .init_calib_complete (init_calib_complete),
        .screen_id           (screen_id_ff),
        .bcd_digits          (de_bcd_digits),
        .cursor_pos          (de_cursor_pos),
        .digit_toggle        (de_toggle),
        .mode_sel            (latched_mode_ff),
        .prime_bcd           (count_bcd),
        .prime_bcd_toggle    (count_bcd_toggle),
        .input_bcd           (latched_bcd_ff),
        .countdown_bcd       (countdown_bcd),
        .stopwatch_bcd       (sw_bcd),
        .rbcd_rd_addr_ff     (rbcd_rd_addr),
        .rbcd_rd_data        (rbcd_rd_data),
        .results_display_count (results_display_count),
        .results_done        (results_done),
        .test_pass           (test_pass),
        .test_exp_bcd        (test_exp_bcd),
        .test_got_bcd        (test_got_bcd),
        .test_mc_bcd         (test_mc_bcd),
        .test_bcd_toggle     (test_bcd_toggle_ff),
        .is_prime_result     (is_prime_result),
        .render_buf          (~fb_display_ff),
        .wr_req_ff           (fr_wr_req),
        .wr_addr_ff          (fr_wr_addr),
        .wr_data_ff          (fr_wr_data),
        .wr_grant            (fr_wr_grant),
        .render_done_ff      (render_done)
    );

    // =======================================================================
    // mem_arbiter (ui_clk domain)
    // =======================================================================
    wire        vga_rd_req;
    wire [26:0] vga_rd_addr;
    wire [127:0] arb_rd_data;
    wire         arb_rd_data_valid;

    mem_arbiter u_arb (
        .ui_clk               (ui_clk),
        .rst_n                (arb_rst_n),
        .init_calib_complete  (init_calib_complete),
        .bitmap_reset         (bitmap_reset_ui),

        // Port 0: Read (muxed between VGA reader and test checker)
        .vga_rd_req           (mux_rd_req),
        .vga_rd_addr          (mux_rd_addr),
        .vga_rd_grant_ff      (mux_rd_grant),

        // Port 1: Frame renderer
        .render_wr_req        (fr_wr_req),
        .render_wr_addr       (fr_wr_addr),
        .render_wr_data       (fr_wr_data),
        .render_wr_grant_ff   (fr_wr_grant),

        // Port 2: Prime plus write
        .prime_plus_rd_data   (acc_plus_rd_data),
        .prime_plus_empty     (acc_plus_fifo_empty),
        .prime_plus_rd_en_ff  (arb_rd_en_plus),

        // Port 3: Prime minus write
        .prime_minus_rd_data  (acc_minus_rd_data),
        .prime_minus_empty    (acc_minus_fifo_empty),
        .prime_minus_rd_en_ff (arb_rd_en_minus),

        // MIG interface
        .app_addr_ff          (arb_app_addr),
        .app_cmd_ff           (arb_app_cmd),
        .app_en_ff            (arb_app_en),
        .app_wdf_data_ff      (arb_app_wdf_data),
        .app_wdf_end_ff       (arb_app_wdf_end),
        .app_wdf_mask_ff      (arb_app_wdf_mask),
        .app_wdf_wren_ff      (arb_app_wdf_wren),
        .app_rdy              (arb_app_rdy),
        .app_wdf_rdy          (arb_app_wdf_rdy),

        // MIG read data passthrough
        .app_rd_data          (arb_app_rd_data),
        .app_rd_data_valid    (arb_app_rd_data_valid),
        .app_rd_data_end      (arb_app_rd_data_end),
        .rd_data              (arb_rd_data),
        .rd_data_valid        (arb_rd_data_valid)
    );

    // =======================================================================
    // DDR2 write counters (ui_clk domain, informal CDC to SSD)
    // =======================================================================
    reg [31:0] wr_count_plus_ff, wr_count_minus_ff;
    reg        wr_toggle_plus_ff, wr_toggle_minus_ff;

    always @(posedge ui_clk) begin
        if (ui_clk_sync_rst) begin
            wr_count_plus_ff   <= 32'd0;
            wr_count_minus_ff  <= 32'd0;
            wr_toggle_plus_ff  <= 1'b0;
            wr_toggle_minus_ff <= 1'b0;
        end else begin
            if (arb_rd_en_plus) begin
                wr_count_plus_ff  <= wr_count_plus_ff  + 32'd1;
                wr_toggle_plus_ff <= ~wr_toggle_plus_ff;
            end
            if (arb_rd_en_minus) begin
                wr_count_minus_ff  <= wr_count_minus_ff  + 32'd1;
                wr_toggle_minus_ff <= ~wr_toggle_minus_ff;
            end
        end
    end

    // =======================================================================
    // Pixel FIFO (128-bit write @ ui_clk, 16-bit read @ clk_vga, FWFT)
    // Xilinx IP — active-high reset, stays at top level.
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
        .wr_clk       (ui_clk),
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
    // Double-buffer swap controller (ui_clk domain)
    // =======================================================================
    reg        fb_display_ff;
    reg        swap_pending_ff;
    reg        rd_prev_ff;
    reg        vs_meta_top, vs_sync_top, vs_prev_top;

    always @(posedge ui_clk) begin
        if (ui_clk_sync_rst) begin
            vs_meta_top    <= 1'b0;
            vs_sync_top    <= 1'b0;
            vs_prev_top    <= 1'b0;
            fb_display_ff  <= 1'b0;
            swap_pending_ff <= 1'b0;
            rd_prev_ff     <= 1'b0;
        end else begin
            vs_meta_top <= vsync;
            vs_sync_top <= vs_meta_top;
            vs_prev_top <= vs_sync_top;
            rd_prev_ff  <= render_done;
            if (render_done && !rd_prev_ff)
                swap_pending_ff <= 1'b1;
            if (vs_sync_top && !vs_prev_top && swap_pending_ff) begin
                fb_display_ff   <= ~fb_display_ff;
                swap_pending_ff <= 1'b0;
            end
        end
    end

    // VGA reader enable: latches high after first render completes.
    reg vga_enable_ff;
    always @(posedge ui_clk) begin
        if (ui_clk_sync_rst)
            vga_enable_ff <= 1'b0;
        else if (render_done)
            vga_enable_ff <= 1'b1;
    end

    // =======================================================================
    // VGA Reader (ui_clk domain)
    // =======================================================================
    vga_reader u_vga_reader (
        .ui_clk              (ui_clk),
        .rst_n               (arb_rst_n),
        .init_calib_complete (init_calib_complete),
        .enable              (vga_enable_ff && !test_active_ff),

        .fb_select           (fb_display_ff),
        .vsync_vga           (vsync),

        .vga_rd_req_ff       (vga_rd_req),
        .vga_rd_addr_ff      (vga_rd_addr),
        .vga_rd_grant        (vga_rd_grant_wire),

        .rd_data             (arb_rd_data),
        .rd_data_valid       (arb_rd_data_valid & vga_rd_inflight_ff),

        .fifo_din            (fifo_din),
        .fifo_wr_en          (fifo_wr_en),
        .fifo_full           (fifo_full),
        .fifo_wr_rst_busy    (fifo_wr_rst_busy)
    );

    // =======================================================================
    // Test prime checker (ui_clk domain)
    // =======================================================================

    // ---- CDC: btnd_pulse (clk) -> test_start_ui (ui_clk) via toggle ----
    reg  test_toggle_clk_ff;
    always @(posedge clk) begin
        if (!rst_sync_n)
            test_toggle_clk_ff <= 1'b0;
        else if (btnd_pulse)
            test_toggle_clk_ff <= ~test_toggle_clk_ff;
    end

    // ---- CDC: keypad * on TEST screen (clk) -> kp_test_start_ui (ui_clk) ----
    reg  kp_test_toggle_ff;
    always @(posedge clk) begin
        if (!rst_sync_n)
            kp_test_toggle_ff <= 1'b0;
        else if (nav_go && nav_mode_sel == 2'd0)
            kp_test_toggle_ff <= ~kp_test_toggle_ff;
    end

    reg kp_test_meta_ff, kp_test_sync_ff, kp_test_prev_ff;
    always @(posedge ui_clk) begin
        if (ui_clk_sync_rst) begin
            kp_test_meta_ff <= 1'b0;
            kp_test_sync_ff <= 1'b0;
            kp_test_prev_ff <= 1'b0;
        end else begin
            kp_test_meta_ff <= kp_test_toggle_ff;
            kp_test_sync_ff <= kp_test_meta_ff;
            kp_test_prev_ff <= kp_test_sync_ff;
        end
    end
    wire kp_test_start_ui = kp_test_sync_ff ^ kp_test_prev_ff;

    reg test_tog_meta_ff, test_tog_sync_ff, test_tog_prev_ff;
    always @(posedge ui_clk) begin
        if (ui_clk_sync_rst) begin
            test_tog_meta_ff <= 1'b0;
            test_tog_sync_ff <= 1'b0;
            test_tog_prev_ff <= 1'b0;
        end else begin
            test_tog_meta_ff <= test_toggle_clk_ff;
            test_tog_sync_ff <= test_tog_meta_ff;
            test_tog_prev_ff <= test_tog_sync_ff;
        end
    end
    wire test_start_ui = (test_tog_sync_ff ^ test_tog_prev_ff) | kp_test_start_ui;

    // ---- CDC: btnc_pulse (clk) -> browse_step_ui (ui_clk) via toggle ----
    reg  browse_toggle_clk_ff;
    always @(posedge clk) begin
        if (!rst_sync_n)
            browse_toggle_clk_ff <= 1'b0;
        else if (btnc_pulse)
            browse_toggle_clk_ff <= ~browse_toggle_clk_ff;
    end

    reg browse_tog_meta_ff, browse_tog_sync_ff, browse_tog_prev_ff;
    always @(posedge ui_clk) begin
        if (ui_clk_sync_rst) begin
            browse_tog_meta_ff <= 1'b0;
            browse_tog_sync_ff <= 1'b0;
            browse_tog_prev_ff <= 1'b0;
        end else begin
            browse_tog_meta_ff <= browse_toggle_clk_ff;
            browse_tog_sync_ff <= browse_tog_meta_ff;
            browse_tog_prev_ff <= browse_tog_sync_ff;
        end
    end
    wire browse_step_ui = browse_tog_sync_ff ^ browse_tog_prev_ff;

    // ---- Test checker instance ----
    wire        test_done;
    wire        test_pass;
    wire [13:0] test_match_count;
    wire [WIDTH-1:0] test_expected, test_got;
    wire        test_rd_req;
    wire [26:0] test_rd_addr;

    test_prime_checker #(.WIDTH(WIDTH)) u_test_checker (
        .clk                 (ui_clk),
        .rst_n               (arb_rst_n),
        .init_calib_complete (init_calib_complete),
        .start               (test_start_ui),
        .check_limit         (engine_limit_ui_ff),
        .done_ff             (test_done),
        .pass_ff             (test_pass),
        .match_count_ff      (test_match_count),
        .expected_ff         (test_expected),
        .got_ff              (test_got),
        .sd_prime_data       (sd_bridge_data),
        .sd_prime_valid      (sd_bridge_valid),
        .sd_prime_consume_ff (sd_bridge_consume),
        .sd_prime_eof        (sd_bridge_eof),
        .rd_req_ff           (test_rd_req),
        .rd_addr_ff          (test_rd_addr),
        .rd_grant            (test_rd_grant),
        .rd_data             (arb_rd_data),
        .rd_data_valid       (arb_rd_data_valid & test_rd_inflight_ff & !vga_rd_inflight_ff)
    );

    // Test is active from start until done (blocks VGA reader from read port).
    reg test_active_ff;
    reg test_pending_ff;
    always @(posedge ui_clk) begin
        if (ui_clk_sync_rst) begin
            test_active_ff  <= 1'b0;
            test_pending_ff <= 1'b0;
        end else if (test_start_ui) begin
            test_pending_ff <= 1'b1;
        end else if (test_pending_ff && vs_sync_top && !vs_prev_top) begin
            test_active_ff  <= 1'b1;
            test_pending_ff <= 1'b0;
        end else if (test_done && !test_pending_ff) begin
            test_active_ff  <= 1'b0;
        end
    end

    // =======================================================================
    // DDR2 memory browser (ui_clk domain)
    // =======================================================================
    reg [1:0]   browse_state_ff;
    reg [26:0]  browse_addr_ff;
    reg [26:0]  browse_disp_addr_ff;
    reg [127:0] browse_data_ff;
    reg         browse_rd_req_ff;
    reg         browse_has_data_ff;
    reg         browse_data_toggle_ff;

    always @(posedge ui_clk) begin
        if (ui_clk_sync_rst) begin
            browse_state_ff      <= 2'd0;
            browse_addr_ff       <= 27'd0;
            browse_disp_addr_ff  <= 27'd0;
            browse_data_ff       <= 128'd0;
            browse_rd_req_ff     <= 1'b0;
            browse_has_data_ff   <= 1'b0;
            browse_data_toggle_ff <= 1'b0;
        end else begin
            case (browse_state_ff)
                2'd0: begin
                    browse_rd_req_ff <= 1'b0;
                    if (browse_step_ui && init_calib_complete) begin
                        browse_rd_req_ff <= 1'b1;
                        browse_state_ff  <= 2'd1;
                    end
                end
                2'd1: begin
                    browse_rd_req_ff <= 1'b1;
                    if (browse_rd_grant) begin
                        browse_rd_req_ff <= 1'b0;
                        browse_state_ff  <= 2'd2;
                    end
                end
                2'd2: begin
                    if (arb_rd_data_valid && !vga_rd_inflight_ff) begin
                        browse_data_ff        <= arb_rd_data;
                        browse_disp_addr_ff   <= browse_addr_ff;
                        browse_addr_ff        <= browse_addr_ff + 27'd16;
                        browse_has_data_ff    <= 1'b1;
                        browse_data_toggle_ff <= ~browse_data_toggle_ff;
                        browse_state_ff       <= 2'd0;
                    end
                end
                default: browse_state_ff <= 2'd0;
            endcase
        end
    end

    wire browse_active = (browse_state_ff != 2'd0);

    // ---- Track VGA in-flight DDR2 reads ----
    reg vga_rd_inflight_ff;
    always @(posedge ui_clk) begin
        if (ui_clk_sync_rst)
            vga_rd_inflight_ff <= 1'b0;
        else if (vga_rd_grant_wire)
            vga_rd_inflight_ff <= 1'b1;
        else if (arb_rd_data_valid && vga_rd_inflight_ff)
            vga_rd_inflight_ff <= 1'b0;
    end

    // ---- Track test checker in-flight DDR2 reads ----
    reg test_rd_inflight_ff;
    always @(posedge ui_clk) begin
        if (ui_clk_sync_rst || test_start_ui)
            test_rd_inflight_ff <= 1'b0;
        else if (test_rd_req && mux_rd_grant)
            test_rd_inflight_ff <= 1'b1;
        else if (arb_rd_data_valid && test_rd_inflight_ff && !vga_rd_inflight_ff)
            test_rd_inflight_ff <= 1'b0;
    end

    wire test_needs_port = test_active_ff && (test_rd_req || test_rd_inflight_ff);

    // ---- Read port mux: test > VGA > browse ----
    wire        mux_rd_req   = test_needs_port ? test_rd_req
                             : vga_rd_req      ? 1'b1
                             :                   browse_rd_req_ff;
    wire [26:0] mux_rd_addr  = test_needs_port ? test_rd_addr
                             : vga_rd_req      ? vga_rd_addr
                             :                   browse_addr_ff;
    wire        mux_rd_grant;

    reg [1:0] rd_owner_ff;
    reg       rd_owner_valid_ff;

    always @(posedge ui_clk) begin
        if (ui_clk_sync_rst) begin
            rd_owner_ff       <= 2'd0;
            rd_owner_valid_ff <= 1'b0;
        end else if (mux_rd_grant) begin
            rd_owner_valid_ff <= 1'b0;
        end else if (mux_rd_req && !rd_owner_valid_ff) begin
            rd_owner_valid_ff <= 1'b1;
            rd_owner_ff       <= test_needs_port ? 2'd1
                               : vga_rd_req      ? 2'd0
                               :                   2'd2;
        end
    end

    wire        test_rd_grant     = (rd_owner_ff == 2'd1) ? mux_rd_grant : 1'b0;
    wire        browse_rd_grant   = (rd_owner_ff == 2'd2) ? mux_rd_grant : 1'b0;
    wire        vga_rd_grant_wire = (rd_owner_ff == 2'd0) ? mux_rd_grant : 1'b0;

    // =======================================================================
    // VGA display wrapper — vga_controller, sprite_animator, vga_driver
    // =======================================================================
    wire vsync;

    vga_display_wrapper u_vga_display (
        .clk_vga       (clk_vga),
        .rst_n         (vga_rst_n),
        .sprite_enable (sprite_enable),
        .fifo_dout     (fifo_dout),
        .fifo_empty    (fifo_empty),
        .fifo_rd_en    (fifo_rd_en),
        .vga_r         (VGA_R),
        .vga_g         (VGA_G),
        .vga_b         (VGA_B),
        .vga_hs        (VGA_HS),
        .vga_vs        (VGA_VS),
        .vsync         (vsync)
    );

    // =======================================================================
    // SSD display (clk domain) — stopwatch timer: SSSS.FFFF
    // =======================================================================
    ssd #(
        .CLK_FREQ_HZ (100_000_000),
        .REFRESH_RATE (500)
    ) u_ssd (
        .clk   (clk),
        .rst_n (rst_sync_n),
        .value (sw_bcd),
        .dp_en (8'h10),
        .SEG   (SEG),
        .AN    (AN),
        .DP_n  (DP_n)
    );

    // =======================================================================
    // Activity toggles (ui_clk domain)
    // =======================================================================
    reg render_wr_toggle_ff;
    reg vga_rd_toggle_ff;

    always @(posedge ui_clk) begin
        if (ui_clk_sync_rst) begin
            render_wr_toggle_ff <= 1'b0;
            vga_rd_toggle_ff    <= 1'b0;
        end else begin
            if (fr_wr_grant)
                render_wr_toggle_ff <= ~render_wr_toggle_ff;
            if (mux_rd_grant)
                vga_rd_toggle_ff <= ~vga_rd_toggle_ff;
        end
    end

    // =======================================================================
    // Heartbeat counters
    // =======================================================================
    reg [23:0] vga_heartbeat_ff;
    always @(posedge clk_vga) begin
        if (vga_rst) vga_heartbeat_ff <= 24'd0;
        else         vga_heartbeat_ff <= vga_heartbeat_ff + 24'd1;
    end

    reg [23:0] ui_heartbeat_ff;
    always @(posedge ui_clk) begin
        if (ui_clk_sync_rst) ui_heartbeat_ff <= 24'd0;
        else                 ui_heartbeat_ff <= ui_heartbeat_ff + 24'd1;
    end

    // =======================================================================
    // Test debug CDC: latch test results into clk domain for SSD/LEDs.
    // =======================================================================
    reg [13:0]      test_mc_clk_ff;
    reg [WIDTH-1:0] test_exp_clk_ff;
    reg [WIDTH-1:0] test_got_clk_ff;
    reg             test_done_clk_meta, test_done_clk_ff;

    always @(posedge clk) begin
        if (!rst_sync_n) begin
            test_done_clk_meta <= 1'b0;
            test_done_clk_ff  <= 1'b0;
            test_mc_clk_ff    <= 14'd0;
            test_exp_clk_ff   <= {WIDTH{1'b0}};
            test_got_clk_ff   <= {WIDTH{1'b0}};
        end else begin
            test_done_clk_meta <= test_done;
            test_done_clk_ff  <= test_done_clk_meta;
            if (test_done_clk_meta && !test_done_clk_ff) begin
                test_mc_clk_ff  <= test_match_count;
                test_exp_clk_ff <= test_expected;
                test_got_clk_ff <= test_got;
            end
        end
    end

    // =======================================================================
    // Test done for navigation — clears on test start, sets on completion
    // =======================================================================
    reg test_done_for_nav_ff;
    always @(posedge clk) begin
        if (!rst_sync_n)
            test_done_for_nav_ff <= 1'b0;
        else if (nav_go)
            test_done_for_nav_ff <= 1'b0;
        else if (test_done_clk_meta && !test_done_clk_ff)
            test_done_for_nav_ff <= 1'b1;
    end

    // Mux done signal: test mode uses test checker, others use mode_fsm.
    wire effective_done = nav_go ? 1'b0 :
                          (latched_mode_ff == 2'd0) ? test_done_for_nav_ff : done;

    // =======================================================================
    // Browse data CDC (ui_clk -> clk)
    // =======================================================================
    reg        br_tog_meta_ff, br_tog_sync_ff, br_tog_prev_ff;
    reg        browse_hd_clk_ff;
    reg [31:0] br_data0_clk_ff, br_data1_clk_ff, br_data2_clk_ff, br_data3_clk_ff;
    reg [26:0] br_addr_clk_ff;

    always @(posedge clk) begin
        if (!rst_sync_n) begin
            br_tog_meta_ff  <= 1'b0;
            br_tog_sync_ff  <= 1'b0;
            br_tog_prev_ff  <= 1'b0;
            browse_hd_clk_ff <= 1'b0;
            br_data0_clk_ff <= 32'd0;
            br_data1_clk_ff <= 32'd0;
            br_data2_clk_ff <= 32'd0;
            br_data3_clk_ff <= 32'd0;
            br_addr_clk_ff  <= 27'd0;
        end else begin
            br_tog_meta_ff <= browse_data_toggle_ff;
            br_tog_sync_ff <= br_tog_meta_ff;
            br_tog_prev_ff <= br_tog_sync_ff;
            if (br_tog_sync_ff != br_tog_prev_ff) begin
                browse_hd_clk_ff <= 1'b1;
                br_data0_clk_ff  <= browse_data_ff[31:0];
                br_data1_clk_ff  <= browse_data_ff[63:32];
                br_data2_clk_ff  <= browse_data_ff[95:64];
                br_data3_clk_ff  <= browse_data_ff[127:96];
                br_addr_clk_ff   <= browse_disp_addr_ff;
            end
        end
    end

    // =======================================================================
    // LED status
    // =======================================================================
    assign LED[0]  = test_done_clk_ff ? test_mc_clk_ff[0] : init_calib_complete;
    assign LED[1]  = test_done_clk_ff ? test_mc_clk_ff[1] : pll_locked;
    assign LED[2]  = test_done_clk_ff ? test_mc_clk_ff[2] : render_done;
    assign LED[3]  = test_done_clk_ff ? test_mc_clk_ff[3] : vga_enable_ff;
    assign LED[4]  = test_done_clk_ff ? test_mc_clk_ff[4] : swap_pending_ff;
    assign LED[5]  = test_done_clk_ff ? test_mc_clk_ff[5] : fb_display_ff;
    assign LED[6]  = test_done_clk_ff ? test_mc_clk_ff[6] : render_wr_toggle_ff;
    assign LED[7]  = vga_rd_toggle_ff;
    assign LED[8]  = fifo_empty;
    assign LED[9]  = fifo_full;
    assign LED[10] = fr_wr_req;
    assign LED[11] = vga_rd_req;
    assign LED[12] = test_done;
    assign LED[13] = test_active_ff;
    assign LED[14] = test_pass;
    assign LED[15] = test_done & ~test_pass;

endmodule
