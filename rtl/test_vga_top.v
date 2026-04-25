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
//   LED[0]  init_calib_complete    LED[8]  pixel_fifo empty
//   LED[1]  pll_locked             LED[9]  pixel_fifo full
//   LED[2]  render_done            LED[10] render wr req (stuck=stall)
//   LED[3]  vga_enable (latched)   LED[11] VGA rd req (stuck=stall)
//   LED[4]  swap_pending           LED[12] vsync (CDC'd, frame pulse)
//   LED[5]  fb_display (0=A,1=B)  LED[13] video_on (active display)
//   LED[6]  render wr activity     LED[14] ui_clk heartbeat
//   LED[7]  VGA rd activity        LED[15] clk_vga heartbeat

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
    reg rst_meta_ff, rst_sync_n;
    always @(posedge clk) begin
        rst_meta_ff <= cpu_rst_n;
        rst_sync_n  <= rst_meta_ff;
    end

    // =======================================================================
    // Input interpretation (from switches — n_limit, t_limit, check_candidate)
    // =======================================================================
    wire [WIDTH-1:0] n_limit         = {SW[15:2], {(WIDTH-14){1'b0}}};
    wire [31:0]      t_limit         = {18'd0, SW[15:2]};
    wire [WIDTH-1:0] check_candidate = {SW[15:2], {(WIDTH-14){1'b0}}};

    // =======================================================================
    // Debounced button pulses (clk domain)
    // =======================================================================
    wire btnr_pulse, btnl_pulse;

    debounce #(.DEBOUNCE_CYCLES(500_000)) u_dbnc_btnr (
        .clk(clk), .rst_n(rst_sync_n), .btn_in(BTNR),
        .btn_state_ff(), .rising_pulse_ff(btnr_pulse), .falling_pulse_ff()
    );
    debounce #(.DEBOUNCE_CYCLES(500_000)) u_dbnc_btnl (
        .clk(clk), .rst_n(rst_sync_n), .btn_in(BTNL),
        .btn_state_ff(), .rising_pulse_ff(btnl_pulse), .falling_pulse_ff()
    );

    // =======================================================================
    // Keypad — column_driver + row debouncers + row_reader + keypad_nav
    // Pin mapping matches working keypad_top reference design:
    //   Columns: c_0→JA9, c_1→JA3, c_2→JA10, c_3→JA4
    //   Rows:    row_0←JA7, row_1←JA1, row_2←JA8, row_3←JA2
    // =======================================================================
    wire        kp_freeze;
    wire [3:0]  kp_button;
    wire        kp_button_valid;

    // Column driver — drives one column high at a time
    column_driver u_col_drv (
        .clk    (clk),
        .rst    (~rst_sync_n),
        .freeze (kp_freeze),
        .c_0    (JA9),
        .c_1    (JA3),
        .c_2    (JA10),
        .c_3    (JA4)
    );

    // Row debouncers — clean up mechanical bounce before row_reader
    wire r0_clean, r1_clean, r2_clean, r3_clean;

    debounce #(.DEBOUNCE_CYCLES(1_000_000)) u_db_r0 (
        .clk(clk), .rst_n(rst_sync_n), .btn_in(JA7),
        .btn_state_ff(r0_clean), .rising_pulse_ff(), .falling_pulse_ff()
    );
    debounce #(.DEBOUNCE_CYCLES(1_000_000)) u_db_r1 (
        .clk(clk), .rst_n(rst_sync_n), .btn_in(JA1),
        .btn_state_ff(r1_clean), .rising_pulse_ff(), .falling_pulse_ff()
    );
    debounce #(.DEBOUNCE_CYCLES(1_000_000)) u_db_r2 (
        .clk(clk), .rst_n(rst_sync_n), .btn_in(JA8),
        .btn_state_ff(r2_clean), .rising_pulse_ff(), .falling_pulse_ff()
    );
    debounce #(.DEBOUNCE_CYCLES(1_000_000)) u_db_r3 (
        .clk(clk), .rst_n(rst_sync_n), .btn_in(JA2),
        .btn_state_ff(r3_clean), .rising_pulse_ff(), .falling_pulse_ff()
    );

    // Row reader — decodes which button is pressed from debounced rows + columns
    row_reader u_row_rdr (
        .clk            (clk),
        .rst            (~rst_sync_n),
        .row_0          (r0_clean),
        .row_1          (r1_clean),
        .row_2          (r2_clean),
        .row_3          (r3_clean),
        .c_0_ff         (JA9),
        .c_1_ff         (JA3),
        .c_2_ff         (JA10),
        .c_3_ff         (JA4),
        .button_ff      (kp_button),
        .button_valid_ff(kp_button_valid),
        .freeze_out     (kp_freeze)
    );

    wire [2:0] screen_id_ff;
    wire [1:0] nav_mode_sel;
    wire       nav_go;

    keypad_nav u_keypad_nav (
        .clk          (clk),
        .rst          (~rst_sync_n),
        .button       (kp_button),
        .button_valid (kp_button_valid),
        .mode_done    (done),
        .screen_id_ff (screen_id_ff),
        .mode_sel_ff  (nav_mode_sel),
        .go_ff        (nav_go)
    );

    // =======================================================================
    // PLL: 100 MHz -> 25 MHz (clk_vga), 200 MHz (clk_mem)
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
    // Reset synchronizer (clk_vga domain)
    // =======================================================================
    reg vga_rst_meta, vga_rst_sync;
    always @(posedge clk_vga) begin
        vga_rst_meta <= ~pll_locked;
        vga_rst_sync <= vga_rst_meta;
    end
    wire vga_rst = vga_rst_sync;

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
    // mode_fsm <-> engine wires
    // =======================================================================
    wire             eng_plus_start, eng_plus_done, eng_plus_is_prime, eng_plus_busy;
    wire [WIDTH-1:0] eng_plus_candidate;
    wire             eng_minus_start, eng_minus_done, eng_minus_is_prime, eng_minus_busy;
    wire [WIDTH-1:0] eng_minus_candidate;

    // =======================================================================
    // mode_fsm <-> accumulator wires
    // =======================================================================
    wire acc_plus_valid, acc_plus_is_prime, acc_plus_flush, acc_plus_flush_done, acc_plus_fifo_full;
    wire acc_minus_valid, acc_minus_is_prime, acc_minus_flush, acc_minus_flush_done, acc_minus_fifo_full;

    // =======================================================================
    // elapsed_timer wires
    // =======================================================================
    wire        timer_freeze;
    wire [31:0] seconds, cycle_count;

    // =======================================================================
    // mode_fsm status wires
    // =======================================================================
    wire        done, is_prime_result;
    wire [3:0]  state_out;

    // =======================================================================
    // FIFO read wires (accumulators -> arbiter, ui_clk domain)
    // =======================================================================
    wire [127:0] acc_plus_rd_data,  acc_minus_rd_data;
    wire         acc_plus_fifo_empty, acc_minus_fifo_empty;
    wire [31:0]  prime_count_plus, prime_count_minus;

    // =======================================================================
    // mode_fsm
    // =======================================================================
    mode_fsm #(.WIDTH(WIDTH)) u_fsm (
        .clk                    (clk),
        .rst_n                  (rst_sync_n),
        .mode_sel               (nav_mode_sel),
        .n_limit                (n_limit),
        .t_limit                (t_limit),
        .check_candidate        (check_candidate),
        .go                     (nav_go),
        .eng_plus_start_ff      (eng_plus_start),
        .eng_plus_candidate_ff  (eng_plus_candidate),
        .eng_plus_done          (eng_plus_done),
        .eng_plus_is_prime      (eng_plus_is_prime),
        .eng_plus_busy          (eng_plus_busy),
        .eng_minus_start_ff     (eng_minus_start),
        .eng_minus_candidate_ff (eng_minus_candidate),
        .eng_minus_done         (eng_minus_done),
        .eng_minus_is_prime     (eng_minus_is_prime),
        .eng_minus_busy         (eng_minus_busy),
        .acc_plus_valid_ff      (acc_plus_valid),
        .acc_plus_is_prime_ff   (acc_plus_is_prime),
        .acc_plus_flush_ff      (acc_plus_flush),
        .acc_plus_flush_done    (acc_plus_flush_done),
        .acc_plus_fifo_full     (acc_plus_fifo_full),
        .acc_minus_valid_ff     (acc_minus_valid),
        .acc_minus_is_prime_ff  (acc_minus_is_prime),
        .acc_minus_flush_ff     (acc_minus_flush),
        .acc_minus_flush_done   (acc_minus_flush_done),
        .acc_minus_fifo_full    (acc_minus_fifo_full),
        .timer_freeze_ff        (timer_freeze),
        .seconds_ff             (seconds),
        .cycle_count_ff         (cycle_count),
        .done_ff                (done),
        .is_prime_result_ff     (is_prime_result),
        .state_out_ff           (state_out)
    );

    // =======================================================================
    // prime_engine instances (clk domain)
    // =======================================================================
    prime_engine #(.WIDTH(WIDTH)) u_eng_plus (
        .clk(clk), .rst_n(rst_sync_n),
        .start(eng_plus_start), .candidate(eng_plus_candidate),
        .done_ff(eng_plus_done), .is_prime_ff(eng_plus_is_prime), .busy_ff(eng_plus_busy)
    );
    prime_engine #(.WIDTH(WIDTH)) u_eng_minus (
        .clk(clk), .rst_n(rst_sync_n),
        .start(eng_minus_start), .candidate(eng_minus_candidate),
        .done_ff(eng_minus_done), .is_prime_ff(eng_minus_is_prime), .busy_ff(eng_minus_busy)
    );

    // =======================================================================
    // prime_accumulator instances (write: clk, read: ui_clk)
    // =======================================================================
    wire arb_rd_en_plus, arb_rd_en_minus;

    prime_accumulator u_acc_plus (
        .clk(clk), .rst_n(rst_sync_n), .rd_clk(ui_clk),
        .prime_valid(acc_plus_valid), .is_prime(acc_plus_is_prime),
        .flush(acc_plus_flush), .flush_done_ff(acc_plus_flush_done),
        .prime_fifo_rd_en(arb_rd_en_plus), .prime_fifo_rd_data(acc_plus_rd_data),
        .prime_fifo_empty(acc_plus_fifo_empty), .prime_fifo_full(acc_plus_fifo_full),
        .prime_count_ff(prime_count_plus)
    );
    prime_accumulator u_acc_minus (
        .clk(clk), .rst_n(rst_sync_n), .rd_clk(ui_clk),
        .prime_valid(acc_minus_valid), .is_prime(acc_minus_is_prime),
        .flush(acc_minus_flush), .flush_done_ff(acc_minus_flush_done),
        .prime_fifo_rd_en(arb_rd_en_minus), .prime_fifo_rd_data(acc_minus_rd_data),
        .prime_fifo_empty(acc_minus_fifo_empty), .prime_fifo_full(acc_minus_fifo_full),
        .prime_count_ff(prime_count_minus)
    );

    // =======================================================================
    // elapsed_timer (clk domain)
    // =======================================================================
    elapsed_timer #(.TICK_PERIOD(100_000_000)) u_timer (
        .clk(clk), .rst_n(rst_sync_n), .freeze(timer_freeze),
        .cycle_count_ff(cycle_count), .seconds_ff(seconds), .second_tick_ff()
    );

    // =======================================================================
    // Frame renderer (ui_clk domain)
    // Renders text from screen_text_rom via font_rom into DDR2 frame buffer.
    // Writes to the back buffer (~fb_display_ff).
    // screen_id from keypad_nav.
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
        .render_buf          (~fb_display_ff),
        .wr_req_ff           (fr_wr_req),
        .wr_addr_ff          (fr_wr_addr),
        .wr_data_ff          (fr_wr_data),
        .wr_grant            (fr_wr_grant),
        .render_done_ff      (render_done)
    );

    // =======================================================================
    // mem_arbiter (ui_clk domain)
    // All four ports active.
    // =======================================================================
    wire        vga_rd_req;
    wire [26:0] vga_rd_addr;
    wire        vga_rd_grant;
    wire [127:0] arb_rd_data;
    wire         arb_rd_data_valid;

    mem_arbiter u_arb (
        .ui_clk               (ui_clk),
        .rst_n                (arb_rst_n),
        .init_calib_complete  (init_calib_complete),

        // Port 0: VGA read (highest priority)
        .vga_rd_req           (vga_rd_req),
        .vga_rd_addr          (vga_rd_addr),
        .vga_rd_grant_ff      (vga_rd_grant),

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
    // VGA Controller (clk_vga domain)
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
    // Pixel FIFO (128-bit write @ ui_clk, 16-bit read @ clk_vga, FWFT)
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
    // fb_display_ff selects which buffer the VGA reader reads from.
    // The renderer writes to ~fb_display_ff (the back buffer).
    // Swap only on vsync rising edge AFTER render_done rises — never show
    // a partially-rendered frame.
    // =======================================================================
    reg        fb_display_ff;       // 0 = FB_A, 1 = FB_B
    reg        swap_pending_ff;     // back buffer ready, waiting for vsync
    reg        rd_prev_ff;          // previous render_done for edge detect
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
            // Rising edge of render_done -> back buffer has valid content
            if (render_done && !rd_prev_ff)
                swap_pending_ff <= 1'b1;
            // Swap on vsync rising edge when a completed render is pending
            if (vs_sync_top && !vs_prev_top && swap_pending_ff) begin
                fb_display_ff   <= ~fb_display_ff;
                swap_pending_ff <= 1'b0;
            end
        end
    end

    // VGA reader enable: latches high after first render completes.
    // Stays high during re-renders so the display buffer keeps being read.
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
        .enable              (vga_enable_ff),

        .fb_select           (fb_display_ff),
        .vsync_vga           (vsync),

        .vga_rd_req_ff       (vga_rd_req),
        .vga_rd_addr_ff      (vga_rd_addr),
        .vga_rd_grant        (vga_rd_grant),

        .rd_data             (arb_rd_data),
        .rd_data_valid       (arb_rd_data_valid),

        .fifo_din            (fifo_din),
        .fifo_wr_en          (fifo_wr_en),
        .fifo_full           (fifo_full),
        .fifo_wr_rst_busy    (fifo_wr_rst_busy)
    );

    // =======================================================================
    // Sprite Animator (clk_vga domain) — bouncing "PRIME FINDER" on screen 0
    // =======================================================================
    wire [9:0] sprite_x, sprite_y;
    wire [7:0] sprite_color;

    sprite_animator u_sprite_anim (
        .clk_vga        (clk_vga),
        .rst            (vga_rst),
        .vsync          (vsync),
        .enable         (sprite_enable),
        .sprite_x_ff    (sprite_x),
        .sprite_y_ff    (sprite_y),
        .sprite_color_ff(sprite_color)
    );

    // =======================================================================
    // VGA Driver (clk_vga domain)
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
        .sprite_en    (sprite_enable),
        .sprite_x     (sprite_x),
        .sprite_y     (sprite_y),
        .sprite_color (sprite_color),
        .vga_r_ff     (VGA_R),
        .vga_g_ff     (VGA_G),
        .vga_b_ff     (VGA_B),
        .vga_hs_ff    (VGA_HS),
        .vga_vs_ff    (VGA_VS)
    );

    // =======================================================================
    // SSD display (clk domain) — same pages as test_top_logic
    // =======================================================================
    reg [1:0] ssd_page_ff;
    always @(posedge clk) begin
        if (!rst_sync_n)     ssd_page_ff <= 2'd0;
        else if (btnr_pulse) ssd_page_ff <= ssd_page_ff + 2'd1;
    end

    reg [31:0] ssd_value;
    always @(*) begin
        case (ssd_page_ff)
            2'd0: ssd_value = wr_count_plus_ff;
            2'd1: ssd_value = wr_count_minus_ff;
            2'd2: ssd_value = prime_count_plus;
            2'd3: ssd_value = prime_count_minus;
        endcase
    end

    wire [7:0] ssd_dp_en = 8'h10 << ssd_page_ff;

    ssd #(
        .CLK_FREQ_HZ (100_000_000),
        .REFRESH_RATE (500)
    ) u_ssd (
        .clk  (clk),
        .rst_n(rst_sync_n),
        .value(ssd_value),
        .dp_en(ssd_dp_en),
        .SEG  (SEG),
        .AN   (AN),
        .DP_n (DP_n)
    );

    // =======================================================================
    // Activity toggles (ui_clk domain)
    // =======================================================================
    reg render_wr_toggle_ff;   // flips on each render write grant
    reg vga_rd_toggle_ff;      // flips on each VGA read grant

    always @(posedge ui_clk) begin
        if (ui_clk_sync_rst) begin
            render_wr_toggle_ff <= 1'b0;
            vga_rd_toggle_ff    <= 1'b0;
        end else begin
            if (fr_wr_grant)
                render_wr_toggle_ff <= ~render_wr_toggle_ff;
            if (vga_rd_grant)
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
    // LED status — focused on VGA / frame renderer debugging
    // =======================================================================
    // Startup & health
    assign LED[0]  = init_calib_complete;        // DDR2 calibrated
    assign LED[1]  = pll_locked;                 // clocks stable
    // Renderer state
    assign LED[2]  = render_done;                // latest render complete
    assign LED[3]  = vga_enable_ff;              // VGA reader enabled (latched)
    // Double-buffer state
    assign LED[4]  = swap_pending_ff;            // back buffer ready, awaiting vsync
    assign LED[5]  = fb_display_ff;              // which buffer displayed (0=A, 1=B)
    // Activity toggles (blink = healthy traffic)
    assign LED[6]  = render_wr_toggle_ff;        // render write activity
    assign LED[7]  = vga_rd_toggle_ff;           // VGA read activity
    // Pixel FIFO health
    assign LED[8]  = fifo_empty;                 // empty = potential underrun
    assign LED[9]  = fifo_full;                  // full = potential overflow
    // Arbiter handshake (stuck ON = stalled requestor)
    assign LED[10] = fr_wr_req;                  // renderer requesting write
    assign LED[11] = vga_rd_req;                 // VGA reader requesting read
    // VGA timing (informal CDC, fine for LEDs)
    assign LED[12] = vs_sync_top;                // vsync (CDC'd to ui_clk)
    assign LED[13] = video_on;                   // active display area
    // Heartbeats (blink ~3 Hz = clock alive)
    assign LED[14] = ui_heartbeat_ff[23];        // ui_clk heartbeat
    assign LED[15] = vga_heartbeat_ff[23];       // clk_vga heartbeat

endmodule
