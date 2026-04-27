// top.v — Structural top level for Nexys A7 prime finder.
//
// Purely structural: all logic lives in sub-modules.
// Only module instantiations and wire-alias assigns.
//
// Arbiter ports:
//   Port 0: VGA reader      — DDR2 reads into pixel_fifo (highest priority)
//   Port 1: Frame renderer  — text-to-pixel rendering into DDR2 frame buffer
//   Port 2: Prime plus      — 6k+1 bitmap writes from accumulator FIFO
//   Port 3: Prime minus     — 6k-1 bitmap writes from accumulator FIFO
//
// Clock domains:
//   clk      (100 MHz) — engines, accumulators (write side), mode_fsm, SSD
//   clk_vga  (25 MHz)  — VGA controller, VGA driver, pixel_fifo read side
//   clk_mem  (200 MHz) — MIG reference clock
//   ui_clk   (~75 MHz) — arbiter, accumulators (read side), DDR2, VGA reader
//
// LED debug:
//   LED[0]  init_calib_complete    LED[8]  sd_file_found
//   LED[1]  pll_locked             LED[9]  render_done
//   LED[2]  done (mode_fsm)        LED[10] vga_enable
//   LED[3]  is_prime_result        LED[11] state_out[0]
//   LED[4]  has_bitmap             LED[12] state_out[1]
//   LED[5]  test_active            LED[13] state_out[2]
//   LED[6]  test_done              LED[14] state_out[3]
//   LED[7]  test_pass              LED[15] swap_pending

module top #(
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

    // Keypad PMOD JA
    input  wire        JA1,
    input  wire        JA2,
    output wire        JA3,
    output wire        JA4,
    input  wire        JA7,
    input  wire        JA8,
    output wire        JA9,
    output wire        JA10,

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
    // Reset synchroniser (clk domain)
    // =======================================================================
    wire rst_sync_n;

    reset_sync u_rst_sync (
        .clk      (clk),
        .rst_n    (cpu_rst_n),
        .rst_ff   (),
        .rst_n_ff (rst_sync_n)
    );

    // =======================================================================
    // PLL: 100 MHz -> 25 MHz (clk_vga), 200 MHz (clk_mem), 50 MHz (clk_sd)
    // =======================================================================
    wire clk_vga, clk_mem, clk_sd;
    wire pll_locked;

    pll u_pll (
        .clk_in  (clk),
        .resetn  (1'b1),
        .clk_mem (clk_mem),
        .clk_sd  (clk_sd),
        .clk_vga (clk_vga),
        .locked  (pll_locked)
    );

    // =======================================================================
    // Composite reset generation
    // =======================================================================
    wire sys_rst_n;
    wire arb_rst_n;

    reset_gen u_reset_gen (
        .rst_sync_n      (rst_sync_n),
        .pll_locked      (pll_locked),
        .ui_clk_sync_rst (ui_clk_sync_rst),
        .sys_rst_n       (sys_rst_n),
        .arb_rst_n       (arb_rst_n)
    );

    // =======================================================================
    // VGA reset synchroniser (clk_vga domain)
    // =======================================================================
    wire vga_rst, vga_rst_n;

    reset_sync u_vga_rst_sync (
        .clk      (clk_vga),
        .rst_n    (sys_rst_n),
        .rst_ff   (vga_rst),
        .rst_n_ff (vga_rst_n)
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
    // Keypad wrapper
    // =======================================================================
    wire [2:0]  screen_id;
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
        .primes_ready  (has_bitmap),
        .screen_id     (screen_id),
        .mode_sel      (nav_mode_sel),
        .go            (nav_go),
        .bcd_digits    (de_bcd_digits),
        .cursor_pos    (de_cursor_pos),
        .digit_changed (de_changed),
        .digit_toggle  (de_toggle)
    );

    // =======================================================================
    // Input latches — capture BCD/N-limit/mode on go, provide t_limit
    // =======================================================================
    wire [31:0]      latched_bcd;
    wire [WIDTH-1:0] latched_n_limit;
    wire [1:0]       latched_mode;
    wire [31:0]      t_limit;

    input_latches #(.WIDTH(WIDTH)) u_input_latches (
        .clk             (clk),
        .rst_n           (rst_sync_n),
        .go              (nav_go),
        .bcd_digits      (de_bcd_digits),
        .bin_value        (bin_value),
        .mode_sel        (nav_mode_sel),
        .latched_bcd     (latched_bcd),
        .latched_n_limit (latched_n_limit),
        .latched_mode    (latched_mode),
        .t_limit         (t_limit)
    );

    // =======================================================================
    // BCD converter wrapper
    // =======================================================================
    wire [26:0] bin_value;
    wire        bin_valid;
    wire [31:0] count_bcd;
    wire        count_bcd_valid;
    wire        count_bcd_toggle;
    wire [31:0] countdown_bcd;
    wire        countdown_bcd_valid;
    wire [35:0] test_exp_bcd, test_got_bcd, test_mc_bcd;
    wire        test_bcd_toggle;

    bcd_converter_wrapper #(.WIDTH(WIDTH)) u_bcd (
        .clk              (clk),
        .rst_n            (rst_sync_n),
        .bcd_digits       (de_bcd_digits),
        .bcd_start        (de_changed),
        .bin_value        (bin_value),
        .bin_valid        (bin_valid),
        .prime_total      (prime_total[26:0]),
        .go               (nav_go),
        .screen_id        (screen_id),
        .count_bcd        (count_bcd),
        .count_bcd_valid  (count_bcd_valid),
        .count_bcd_toggle (count_bcd_toggle),
        .remaining_time   (remaining_time[26:0]),
        .countdown_bcd    (countdown_bcd),
        .countdown_bcd_valid (countdown_bcd_valid),
        .test_expected    (test_exp_clk),
        .test_got         (test_got_clk),
        .test_match_count (test_mc_clk),
        .test_done_rising (test_done_rising),
        .test_exp_bcd     (test_exp_bcd),
        .test_got_bcd     (test_got_bcd),
        .test_mc_bcd      (test_mc_bcd),
        .test_bcd_toggle_ff (test_bcd_toggle)
    );

    // =======================================================================
    // Prime count and remaining time calculations
    // =======================================================================
    wire [WIDTH-1:0] effective_n_limit;
    wire [31:0]      prime_total;
    wire [31:0]      remaining_time;

    prime_count_calc #(.WIDTH(WIDTH)) u_prime_calc (
        .latched_mode      (latched_mode),
        .latched_n_limit   (latched_n_limit),
        .prime_count_plus  (prime_count_plus),
        .prime_count_minus (prime_count_minus),
        .effective_n_limit (effective_n_limit),
        .prime_total       (prime_total)
    );

    remaining_time_calc u_remaining_time (
        .t_limit_out    (t_limit_out),
        .seconds        (seconds),
        .remaining_time (remaining_time)
    );

    // =======================================================================
    // Prime compute wrapper
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
        .clk                   (clk),
        .rst_n                 (rst_sync_n),
        .ui_clk                (ui_clk),
        .mode_sel              (nav_mode_sel),
        .n_limit               (bin_value),
        .t_limit               (t_limit),
        .check_candidate       (bin_value),
        .go                    (nav_go),
        .effective_n_limit     (effective_n_limit),
        .rbcd_rd_addr          (rbcd_rd_addr),
        .rbcd_rd_data          (rbcd_rd_data),
        .results_display_count (results_display_count),
        .results_done          (results_done),
        .arb_rd_en_plus        (arb_rd_en_plus),
        .arb_rd_en_minus       (arb_rd_en_minus),
        .acc_plus_rd_data      (acc_plus_rd_data),
        .acc_plus_fifo_empty   (acc_plus_fifo_empty),
        .acc_minus_rd_data     (acc_minus_rd_data),
        .acc_minus_fifo_empty  (acc_minus_fifo_empty),
        .prime_count_plus      (prime_count_plus),
        .prime_count_minus     (prime_count_minus),
        .done                  (done),
        .is_prime_result       (is_prime_result),
        .state_out             (state_out),
        .timer_restart         (timer_restart),
        .seconds               (seconds),
        .t_limit_out           (t_limit_out),
        .sw_bcd                (sw_bcd),
        .eng_plus_candidate    (eng_plus_candidate),
        .eng_minus_candidate   (eng_minus_candidate)
    );

    // =======================================================================
    // Bitmap tracker — gates test mode navigation
    // =======================================================================
    wire has_bitmap;

    bitmap_tracker u_bitmap_tracker (
        .clk              (clk),
        .rst_n            (rst_sync_n),
        .done             (done),
        .latched_mode     (latched_mode),
        .test_done_rising (test_done_rising),
        .has_bitmap       (has_bitmap)
    );

    // =======================================================================
    // Effective done generation — muxes test/mode_fsm done for navigation
    // =======================================================================
    wire effective_done;

    effective_done_gen u_effective_done (
        .clk              (clk),
        .rst_n            (rst_sync_n),
        .go               (nav_go),
        .test_done_rising (test_done_rising),
        .latched_mode     (latched_mode),
        .mode_done        (done),
        .effective_done   (effective_done)
    );

    // =======================================================================
    // CDC: timer_restart (clk) -> bitmap_reset (ui_clk)
    // =======================================================================
    wire bitmap_reset_ui;

    pulse_cdc u_timer_restart_cdc (
        .src_clk   (clk),
        .src_rst_n (rst_sync_n),
        .src_pulse (timer_restart),
        .dst_clk   (ui_clk),
        .dst_rst_n (arb_rst_n),
        .dst_pulse (bitmap_reset_ui)
    );

    // =======================================================================
    // Engine limit capture + CDC to ui_clk
    // =======================================================================
    wire [WIDTH-1:0] engine_limit_ui;

    engine_limit_capture #(.WIDTH(WIDTH)) u_eng_limit (
        .clk                 (clk),
        .rst_n               (rst_sync_n),
        .done                (done),
        .eng_plus_candidate  (eng_plus_candidate),
        .eng_minus_candidate (eng_minus_candidate),
        .ui_clk              (ui_clk),
        .ui_rst_n            (arb_rst_n),
        .engine_limit_ui     (engine_limit_ui)
    );

    // =======================================================================
    // DDR2 wrapper (MIG)
    // =======================================================================
    wire         ui_clk;
    wire         ui_clk_sync_rst;
    wire         init_calib_complete;

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
    // SD card subsystem
    // =======================================================================
    wire [31:0] sd_bridge_data;
    wire        sd_bridge_valid;
    wire        sd_bridge_eof;
    wire        sd_bridge_consume;
    wire        sd_file_found;

    sd_subsystem u_sd (
        .clk_sd       (clk_sd),
        .sys_rst_n    (sys_rst_n),
        .ui_clk       (ui_clk),
        .arb_rst_n    (arb_rst_n),
        .sdclk        (sdclk),
        .sdcmd        (sdcmd),
        .sddat0       (sddat0),
        .sdcard_pwr_n (sdcard_pwr_n),
        .sddat1       (sddat1),
        .sddat2       (sddat2),
        .sddat3       (sddat3),
        .test_start   (test_start_ui),
        .consume      (sd_bridge_consume),
        .prime_data   (sd_bridge_data),
        .prime_valid  (sd_bridge_valid),
        .prime_eof    (sd_bridge_eof),
        .file_found   (sd_file_found)
    );

    // =======================================================================
    // Double-buffer swap controller (ui_clk domain)
    // =======================================================================
    wire fb_display;
    wire render_buf;
    wire swap_pending;
    wire vga_enable;
    wire vs_sync, vs_prev;

    double_buffer_ctrl u_dbl_buf (
        .ui_clk       (ui_clk),
        .rst_n        (arb_rst_n),
        .render_done  (render_done),
        .vsync        (vsync),
        .fb_display   (fb_display),
        .render_buf   (render_buf),
        .swap_pending (swap_pending),
        .vga_enable   (vga_enable),
        .vs_sync      (vs_sync),
        .vs_prev      (vs_prev)
    );

    // =======================================================================
    // Frame renderer (ui_clk domain)
    // =======================================================================
    wire         fr_wr_req;
    wire [26:0]  fr_wr_addr;
    wire [127:0] fr_wr_data;
    wire         fr_wr_grant;
    wire         render_done;

    frame_renderer u_renderer (
        .ui_clk                (ui_clk),
        .rst_n                 (arb_rst_n),
        .init_calib_complete   (init_calib_complete),
        .screen_id             (screen_id),
        .bcd_digits            (de_bcd_digits),
        .cursor_pos            (de_cursor_pos),
        .digit_toggle          (de_toggle),
        .mode_sel              (latched_mode),
        .prime_bcd             (count_bcd),
        .prime_bcd_toggle      (count_bcd_toggle),
        .input_bcd             (latched_bcd),
        .countdown_bcd         (countdown_bcd),
        .stopwatch_bcd         (sw_bcd),
        .rbcd_rd_addr_ff       (rbcd_rd_addr),
        .rbcd_rd_data          (rbcd_rd_data),
        .results_display_count (results_display_count),
        .results_done          (results_done),
        .test_pass             (test_pass),
        .test_exp_bcd          (test_exp_bcd),
        .test_got_bcd          (test_got_bcd),
        .test_mc_bcd           (test_mc_bcd),
        .test_bcd_toggle       (test_bcd_toggle),
        .is_prime_result       (is_prime_result),
        .render_buf            (render_buf),
        .wr_req_ff             (fr_wr_req),
        .wr_addr_ff            (fr_wr_addr),
        .wr_data_ff            (fr_wr_data),
        .wr_grant              (fr_wr_grant),
        .render_done_ff        (render_done)
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
        .vga_rd_req           (mux_rd_req),
        .vga_rd_addr          (mux_rd_addr),
        .vga_rd_grant_ff      (mux_rd_grant),
        .render_wr_req        (fr_wr_req),
        .render_wr_addr       (fr_wr_addr),
        .render_wr_data       (fr_wr_data),
        .render_wr_grant_ff   (fr_wr_grant),
        .prime_plus_rd_data   (acc_plus_rd_data),
        .prime_plus_empty     (acc_plus_fifo_empty),
        .prime_plus_rd_en_ff  (arb_rd_en_plus),
        .prime_minus_rd_data  (acc_minus_rd_data),
        .prime_minus_empty    (acc_minus_fifo_empty),
        .prime_minus_rd_en_ff (arb_rd_en_minus),
        .app_addr_ff          (arb_app_addr),
        .app_cmd_ff           (arb_app_cmd),
        .app_en_ff            (arb_app_en),
        .app_wdf_data_ff      (arb_app_wdf_data),
        .app_wdf_end_ff       (arb_app_wdf_end),
        .app_wdf_mask_ff      (arb_app_wdf_mask),
        .app_wdf_wren_ff      (arb_app_wdf_wren),
        .app_rdy              (arb_app_rdy),
        .app_wdf_rdy          (arb_app_wdf_rdy),
        .app_rd_data          (arb_app_rd_data),
        .app_rd_data_valid    (arb_app_rd_data_valid),
        .app_rd_data_end      (arb_app_rd_data_end),
        .rd_data              (arb_rd_data),
        .rd_data_valid        (arb_rd_data_valid)
    );

    // =======================================================================
    // Pixel FIFO (Xilinx IP — active-high reset, stays at top level)
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
    // Read port mux — test > VGA arbitration + in-flight tracking
    // =======================================================================
    wire        mux_rd_req;
    wire [26:0] mux_rd_addr;
    wire        mux_rd_grant;
    wire        vga_rd_grant;
    wire        test_rd_grant;
    wire        vga_reader_enable;
    wire        vga_rd_data_valid;
    wire        test_rd_data_valid;
    wire        test_active;

    read_port_mux u_read_mux (
        .ui_clk             (ui_clk),
        .rst_n              (arb_rst_n),
        .test_start         (test_start_ui),
        .test_done          (test_done),
        .vs_sync            (vs_sync),
        .vs_prev            (vs_prev),
        .vga_enable         (vga_enable),
        .vga_rd_req         (vga_rd_req),
        .vga_rd_addr        (vga_rd_addr),
        .test_rd_req        (test_rd_req),
        .test_rd_addr       (test_rd_addr),
        .mux_rd_req         (mux_rd_req),
        .mux_rd_addr        (mux_rd_addr),
        .mux_rd_grant       (mux_rd_grant),
        .arb_rd_data_valid  (arb_rd_data_valid),
        .vga_rd_grant       (vga_rd_grant),
        .test_rd_grant      (test_rd_grant),
        .vga_reader_enable  (vga_reader_enable),
        .vga_rd_data_valid  (vga_rd_data_valid),
        .test_rd_data_valid (test_rd_data_valid),
        .test_active        (test_active)
    );

    // =======================================================================
    // VGA Reader (ui_clk domain)
    // =======================================================================
    vga_reader u_vga_reader (
        .ui_clk              (ui_clk),
        .rst_n               (arb_rst_n),
        .init_calib_complete (init_calib_complete),
        .enable              (vga_reader_enable),
        .fb_select           (fb_display),
        .vsync_vga           (vsync),
        .vga_rd_req_ff       (vga_rd_req),
        .vga_rd_addr_ff      (vga_rd_addr),
        .vga_rd_grant        (vga_rd_grant),
        .rd_data             (arb_rd_data),
        .rd_data_valid       (vga_rd_data_valid),
        .fifo_din            (fifo_din),
        .fifo_wr_en          (fifo_wr_en),
        .fifo_full           (fifo_full),
        .fifo_wr_rst_busy    (fifo_wr_rst_busy)
    );

    // =======================================================================
    // Sprite enable CDC (clk -> clk_vga)
    // =======================================================================
    wire sprite_enable;

    sprite_enable_cdc u_sprite_cdc (
        .clk_vga       (clk_vga),
        .screen_id     (screen_id),
        .sprite_enable (sprite_enable)
    );

    // =======================================================================
    // VGA display wrapper
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
    // Test start CDC (clk -> ui_clk)
    // =======================================================================
    wire test_start_ui;

    test_start_cdc u_test_start_cdc (
        .clk          (clk),
        .rst_n        (rst_sync_n),
        .btnd_pulse   (btnd_pulse),
        .nav_go       (nav_go),
        .nav_mode_sel (nav_mode_sel),
        .ui_clk       (ui_clk),
        .ui_rst_n     (arb_rst_n),
        .test_start_ui(test_start_ui)
    );

    // =======================================================================
    // Test prime checker (ui_clk domain)
    // =======================================================================
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
        .check_limit         (engine_limit_ui),
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
        .rd_data_valid       (test_rd_data_valid)
    );

    // =======================================================================
    // Test results CDC (ui_clk -> clk)
    // =======================================================================
    wire        test_done_rising;
    wire [13:0] test_mc_clk;
    wire [WIDTH-1:0] test_exp_clk;
    wire [WIDTH-1:0] test_got_clk;

    test_results_cdc #(.WIDTH(WIDTH)) u_test_results_cdc (
        .clk              (clk),
        .rst_n            (rst_sync_n),
        .test_done        (test_done),
        .test_match_count (test_match_count),
        .test_expected    (test_expected),
        .test_got         (test_got),
        .test_done_rising (test_done_rising),
        .test_mc_clk      (test_mc_clk),
        .test_exp_clk     (test_exp_clk),
        .test_got_clk     (test_got_clk)
    );

    // =======================================================================
    // SSD display (clk domain) — stopwatch timer
    // =======================================================================
    ssd #(
        .CLK_FREQ_HZ  (100_000_000),
        .REFRESH_RATE  (500)
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
    // LED status (active-high, simple wire aliases)
    // =======================================================================
    assign LED[0]  = init_calib_complete;
    assign LED[1]  = pll_locked;
    assign LED[2]  = done;
    assign LED[3]  = is_prime_result;
    assign LED[4]  = has_bitmap;
    assign LED[5]  = test_active;
    assign LED[6]  = test_done;
    assign LED[7]  = test_pass;
    assign LED[8]  = sd_file_found;
    assign LED[9]  = render_done;
    assign LED[10] = vga_enable;
    assign LED[11] = state_out[0];
    assign LED[12] = state_out[1];
    assign LED[13] = state_out[2];
    assign LED[14] = state_out[3];
    assign LED[15] = swap_pending;

endmodule
