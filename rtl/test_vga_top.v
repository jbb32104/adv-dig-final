// test_vga_top.v — Combined VGA + prime engine test top for Nexys A7.
//
// Exercises all four arbiter ports simultaneously:
//   Port 0: VGA reader     — DDR2 reads into pixel_fifo (highest priority)
//   Port 1: FB test writer — one-shot fill of frame buffer with white pixels
//   Port 2: Prime plus     — 6k+1 bitmap writes from accumulator FIFO
//   Port 3: Prime minus    — 6k-1 bitmap writes from accumulator FIFO
//
// The test goal: confirm VGA stays solid (no magenta underrun) while
// prime engines are generating heavy write traffic on ports 2-3.
//
// Clock domains:
//   clk      (100 MHz) — engines, accumulators (write side), mode_fsm, SSD
//   clk_vga  (25 MHz)  — VGA controller, VGA driver, pixel_fifo read side
//   clk_mem  (200 MHz) — MIG reference clock
//   ui_clk   (~75 MHz) — arbiter, accumulators (read side), DDR2, VGA reader
//
// LED debug:
//   LED[0]  init_calib_complete    LED[8]  wr activity 6k+1 (toggle)
//   LED[1]  fb_ready               LED[9]  wr activity 6k-1 (toggle)
//   LED[2]  pixel_fifo empty       LED[10] mode_fsm running
//   LED[3]  pixel_fifo full        LED[11] PLL locked
//   LED[4]  eng_plus busy          LED[12] (unused)
//   LED[5]  eng_minus busy         LED[13] (unused)
//   LED[6]  plus FIFO empty        LED[14] ui_clk heartbeat
//   LED[7]  minus FIFO empty       LED[15] clk_vga heartbeat

module test_vga_top #(
    parameter WIDTH = 27
) (
    input  wire        clk,        // 100 MHz board clock
    input  wire        cpu_rst_n,  // active-low CPU_RESETN button
    input  wire [15:0] SW,
    input  wire        BTNC,
    input  wire        BTNR,
    input  wire        BTNL,

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
    // Input interpretation (from switches)
    // =======================================================================
    wire [1:0]       mode_sel        = SW[1:0];
    wire [WIDTH-1:0] n_limit         = {SW[15:2], {(WIDTH-14){1'b0}}};
    wire [31:0]      t_limit         = {18'd0, SW[15:2]};
    wire [WIDTH-1:0] check_candidate = {SW[15:2], {(WIDTH-14){1'b0}}};

    // =======================================================================
    // Debounced button pulses (clk domain)
    // =======================================================================
    wire go_pulse, btnr_pulse, btnl_pulse;

    debounce #(.DEBOUNCE_CYCLES(500_000)) u_dbnc_btnc (
        .clk(clk), .rst_n(rst_sync_n), .btn_in(BTNC),
        .btn_state_ff(), .rising_pulse_ff(go_pulse), .falling_pulse_ff()
    );
    debounce #(.DEBOUNCE_CYCLES(500_000)) u_dbnc_btnr (
        .clk(clk), .rst_n(rst_sync_n), .btn_in(BTNR),
        .btn_state_ff(), .rising_pulse_ff(btnr_pulse), .falling_pulse_ff()
    );
    debounce #(.DEBOUNCE_CYCLES(500_000)) u_dbnc_btnl (
        .clk(clk), .rst_n(rst_sync_n), .btn_in(BTNL),
        .btn_state_ff(), .rising_pulse_ff(btnl_pulse), .falling_pulse_ff()
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
        .mode_sel               (mode_sel),
        .n_limit                (n_limit),
        .t_limit                (t_limit),
        .check_candidate        (check_candidate),
        .go                     (go_pulse),
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
    // FB test writer (ui_clk domain)
    // One-shot: fills frame buffer with all-white pixels after calibration.
    // =======================================================================
    wire         fb_wr_req;
    wire [26:0]  fb_wr_addr;
    wire [127:0] fb_wr_data;
    wire         fb_wr_grant;
    wire         fb_ready;

    fb_test_writer u_fb_writer (
        .ui_clk              (ui_clk),
        .rst_n               (arb_rst_n),
        .init_calib_complete (init_calib_complete),
        .wr_req_ff           (fb_wr_req),
        .wr_addr_ff          (fb_wr_addr),
        .wr_data             (fb_wr_data),
        .wr_grant            (fb_wr_grant),
        .done_ff             (fb_ready)
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

        // Port 1: FB test writer
        .render_wr_req        (fb_wr_req),
        .render_wr_addr       (fb_wr_addr),
        .render_wr_data       (fb_wr_data),
        .render_wr_grant_ff   (fb_wr_grant),

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
    // VGA Reader (ui_clk domain)
    // =======================================================================
    vga_reader u_vga_reader (
        .ui_clk              (ui_clk),
        .rst_n               (arb_rst_n),
        .init_calib_complete (init_calib_complete),
        .enable              (fb_ready),

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
    // LED status
    // =======================================================================
    assign LED[0]  = init_calib_complete;
    assign LED[1]  = fb_ready;
    assign LED[2]  = fifo_empty;
    assign LED[3]  = fifo_full;
    assign LED[4]  = eng_plus_busy;
    assign LED[5]  = eng_minus_busy;
    assign LED[6]  = acc_plus_fifo_empty;
    assign LED[7]  = acc_minus_fifo_empty;
    assign LED[8]  = wr_toggle_plus_ff;
    assign LED[9]  = wr_toggle_minus_ff;
    assign LED[10] = |state_out;
    assign LED[11] = pll_locked;
    assign LED[12] = 1'b0;
    assign LED[13] = 1'b0;
    assign LED[14] = ui_heartbeat_ff[23];
    assign LED[15] = vga_heartbeat_ff[23];

endmodule
