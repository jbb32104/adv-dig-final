`timescale 1ns / 1ps

// Prime engine + DDR2 integration test top.
// Generates primes via two engines (6k+1, 6k-1), packs results into
// bitmaps via accumulators, and writes the bitmaps to DDR2 through the
// mem_arbiter.
//
// Clock domains:
//   clk      (100 MHz) — engines, accumulators (write side), mode_fsm, SSD
//   ui_clk   (~75 MHz) — arbiter, accumulators (read side), DDR2
//   sys_clk_200 (200 MHz) — MIG reference clock (PLL output)
//
// Debug interface:
//   SSD shows one of four 32-bit values, cycled by BTNR:
//     Page 0: DDR2 writes completed (6k+1)
//     Page 1: DDR2 writes completed (6k-1)
//     Page 2: primes found (6k+1)
//     Page 3: primes found (6k-1)
//   A decimal point on one of the upper digits indicates the active page.
//
//   LED[0]     init_calib_complete    LED[8]     wr activity (6k+1 toggle)
//   LED[1]     mode_fsm done         LED[9]     wr activity (6k-1 toggle)
//   LED[2]     eng_plus busy         LED[10]    mode_fsm running (!IDLE)
//   LED[3]     eng_minus busy        LED[11]    ui_clk_sync_rst
//   LED[4]     plus FIFO empty       LED[12]    PLL locked
//   LED[5]     minus FIFO empty      LED[13]    is_prime_result (mode 3)
//   LED[6]     plus FIFO full        LED[14]    200 MHz heartbeat
//   LED[7]     minus FIFO full       LED[15]    ui_clk heartbeat

module test_top_logic #(
    parameter WIDTH = 27
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [15:0] SW,
    input  wire        BTNC,
    input  wire        BTNR,
    input  wire        BTNL,
    output wire [15:0] LED,
    output wire [6:0]  SEG,
    output wire [7:0]  AN,
    output wire        DP_n,

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
    // Reset synchronizer (clk domain)
    // Register rst_n immediately to prevent the IO pin from fanning out
    // directly to hundreds of FFs, which causes Vivado to infer a BUFG
    // on a non-clock-capable pin (Place 30-574).
    // Xilinx 7-series FFs initialize to 0, so rst_sync_n starts asserted.
    // =======================================================================
    reg rst_meta_ff, rst_sync_n;
    always @(posedge clk) begin
        rst_meta_ff <= rst_n;
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
    wire go_pulse;
    wire btnr_pulse;
    wire btnl_pulse;

    debounce #(.DEBOUNCE_CYCLES(500_000)) u_dbnc_btnc (
        .clk             (clk),
        .rst_n           (rst_sync_n),
        .btn_in          (BTNC),
        .btn_state_ff    (),
        .rising_pulse_ff (go_pulse),
        .falling_pulse_ff()
    );

    debounce #(.DEBOUNCE_CYCLES(500_000)) u_dbnc_btnr (
        .clk             (clk),
        .rst_n           (rst_sync_n),
        .btn_in          (BTNR),
        .btn_state_ff    (),
        .rising_pulse_ff (btnr_pulse),
        .falling_pulse_ff()
    );

    debounce #(.DEBOUNCE_CYCLES(500_000)) u_dbnc_btnl (
        .clk             (clk),
        .rst_n           (rst_sync_n),
        .btn_in          (BTNL),
        .btn_state_ff    (),
        .rising_pulse_ff (btnl_pulse),
        .falling_pulse_ff()
    );

    // =======================================================================
    // PLL: 100 MHz board clock -> 200 MHz for MIG sys_clk_i
    // =======================================================================
    wire sys_clk_200;
    wire mmcm_locked;

    pll u_pll (
        .clk_in  (clk),
        .resetn  (rst_sync_n),
        .clk_mem (sys_clk_200),
        .clk_vga (),
        .clk_sd  (),
        .locked  (mmcm_locked)
    );

    wire sys_rst_n = rst_sync_n & mmcm_locked;

    // =======================================================================
    // DDR2 wrapper (MIG pass-through)
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
        .sys_clk_i           (sys_clk_200),
        .sys_rst             (sys_rst_n)
    );

    // =======================================================================
    // mode_fsm <-> engine wires
    // =======================================================================
    wire             eng_plus_start;
    wire [WIDTH-1:0] eng_plus_candidate;
    wire             eng_plus_done;
    wire             eng_plus_is_prime;
    wire             eng_plus_busy;

    wire             eng_minus_start;
    wire [WIDTH-1:0] eng_minus_candidate;
    wire             eng_minus_done;
    wire             eng_minus_is_prime;
    wire             eng_minus_busy;

    // =======================================================================
    // mode_fsm <-> accumulator wires
    // =======================================================================
    wire             acc_plus_valid;
    wire             acc_plus_is_prime;
    wire             acc_plus_flush;
    wire             acc_plus_flush_done;
    wire             acc_plus_fifo_full;

    wire             acc_minus_valid;
    wire             acc_minus_is_prime;
    wire             acc_minus_flush;
    wire             acc_minus_flush_done;
    wire             acc_minus_fifo_full;

    // =======================================================================
    // elapsed_timer wires
    // =======================================================================
    wire        timer_freeze;
    wire [31:0] seconds;
    wire [31:0] cycle_count;

    // =======================================================================
    // mode_fsm status wires
    // =======================================================================
    wire        done;
    wire        is_prime_result;
    wire [3:0]  state_out;

    // =======================================================================
    // FIFO read wires (accumulators -> arbiter, ui_clk domain)
    // =======================================================================
    wire [127:0] acc_plus_rd_data;
    wire         acc_plus_fifo_empty;
    wire [127:0] acc_minus_rd_data;
    wire         acc_minus_fifo_empty;

    // =======================================================================
    // Prime count outputs (clk domain)
    // =======================================================================
    wire [31:0] prime_count_plus;
    wire [31:0] prime_count_minus;

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
    // prime_engine instances
    // =======================================================================
    prime_engine #(.WIDTH(WIDTH)) u_eng_plus (
        .clk        (clk),
        .rst_n      (rst_sync_n),
        .start      (eng_plus_start),
        .candidate  (eng_plus_candidate),
        .done_ff    (eng_plus_done),
        .is_prime_ff(eng_plus_is_prime),
        .busy_ff    (eng_plus_busy)
    );

    prime_engine #(.WIDTH(WIDTH)) u_eng_minus (
        .clk        (clk),
        .rst_n      (rst_sync_n),
        .start      (eng_minus_start),
        .candidate  (eng_minus_candidate),
        .done_ff    (eng_minus_done),
        .is_prime_ff(eng_minus_is_prime),
        .busy_ff    (eng_minus_busy)
    );

    // =======================================================================
    // prime_accumulator instances
    // Write side: clk (100 MHz)
    // Read side:  ui_clk (~75 MHz) — drives the arbiter
    // =======================================================================
    wire arb_rd_en_plus;
    wire arb_rd_en_minus;

    prime_accumulator u_acc_plus (
        .clk                  (clk),
        .rst_n                (rst_sync_n),
        .rd_clk               (ui_clk),
        .prime_valid          (acc_plus_valid),
        .is_prime             (acc_plus_is_prime),
        .flush                (acc_plus_flush),
        .flush_done_ff        (acc_plus_flush_done),
        .prime_fifo_rd_en     (arb_rd_en_plus),
        .prime_fifo_rd_data   (acc_plus_rd_data),
        .prime_fifo_empty     (acc_plus_fifo_empty),
        .prime_fifo_full      (acc_plus_fifo_full),
        .prime_count_ff       (prime_count_plus)
    );

    prime_accumulator u_acc_minus (
        .clk                  (clk),
        .rst_n                (rst_sync_n),
        .rd_clk               (ui_clk),
        .prime_valid          (acc_minus_valid),
        .is_prime             (acc_minus_is_prime),
        .flush                (acc_minus_flush),
        .flush_done_ff        (acc_minus_flush_done),
        .prime_fifo_rd_en     (arb_rd_en_minus),
        .prime_fifo_rd_data   (acc_minus_rd_data),
        .prime_fifo_empty     (acc_minus_fifo_empty),
        .prime_fifo_full      (acc_minus_fifo_full),
        .prime_count_ff       (prime_count_minus)
    );

    // =======================================================================
    // elapsed_timer
    // =======================================================================
    elapsed_timer #(.TICK_PERIOD(100_000_000)) u_timer (
        .clk           (clk),
        .rst_n         (rst_sync_n),
        .freeze        (timer_freeze),
        .cycle_count_ff(cycle_count),
        .seconds_ff    (seconds),
        .second_tick_ff()
    );

    // =======================================================================
    // mem_arbiter (ui_clk domain)
    // VGA read and renderer write ports stubbed for now — will be connected
    // when vga_reader and frame_renderer are implemented.
    // =======================================================================
    wire [127:0] arb_rd_data;
    wire         arb_rd_data_valid;

    mem_arbiter u_arb (
        .ui_clk               (ui_clk),
        .rst_n                (arb_rst_n),
        .init_calib_complete  (init_calib_complete),

        // Port 0: VGA read (stubbed — no requestor yet)
        .vga_rd_req           (1'b0),
        .vga_rd_addr          (27'd0),
        .vga_rd_grant_ff      (),

        // Port 1: Frame renderer write (stubbed — no requestor yet)
        .render_wr_req        (1'b0),
        .render_wr_addr       (27'd0),
        .render_wr_data       (128'd0),
        .render_wr_grant_ff   (),

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
    // DDR2 write counters (ui_clk domain)
    // One increment per completed write transaction (= one FIFO pop).
    // Read by the clk-domain SSD without formal CDC — acceptable for a
    // human-readable debug display.
    // =======================================================================
    reg [31:0] wr_count_plus_ff;
    reg [31:0] wr_count_minus_ff;
    reg        wr_toggle_plus_ff;       // toggles on each write (LED activity)
    reg        wr_toggle_minus_ff;

    always @(posedge ui_clk) begin
        if (ui_clk_sync_rst) begin
            wr_count_plus_ff  <= 32'd0;
            wr_count_minus_ff <= 32'd0;
            wr_toggle_plus_ff <= 1'b0;
            wr_toggle_minus_ff <= 1'b0;
        end else begin
            if (arb_rd_en_plus) begin
                wr_count_plus_ff  <= wr_count_plus_ff  + 32'd1;
                wr_toggle_plus_ff <= ~wr_toggle_plus_ff;
            end
            if (arb_rd_en_minus) begin
                wr_count_minus_ff <= wr_count_minus_ff + 32'd1;
                wr_toggle_minus_ff <= ~wr_toggle_minus_ff;
            end
        end
    end

    // =======================================================================
    // SSD display page selector (clk domain)
    // BTNR cycles through pages 0-3.
    // =======================================================================
    reg [1:0] ssd_page_ff;

    always @(posedge clk) begin
        if (!rst_sync_n)
            ssd_page_ff <= 2'd0;
        else if (btnr_pulse)
            ssd_page_ff <= ssd_page_ff + 2'd1;
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

    // Decimal point on one of the upper four digits indicates the page.
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
    reg [24:0] mem_heartbeat_ff;
    reg rst_sync_200_0, rst_sync_200_1;
    always @(posedge sys_clk_200) begin
        rst_sync_200_0 <= rst_sync_n;
        rst_sync_200_1 <= rst_sync_200_0;
    end
    always @(posedge sys_clk_200) begin
        if (!rst_sync_200_1) mem_heartbeat_ff <= 25'd0;
        else                 mem_heartbeat_ff <= mem_heartbeat_ff + 25'd1;
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
    assign LED[1]  = done;
    assign LED[2]  = eng_plus_busy;
    assign LED[3]  = eng_minus_busy;
    assign LED[4]  = acc_plus_fifo_empty;
    assign LED[5]  = acc_minus_fifo_empty;
    assign LED[6]  = acc_plus_fifo_full;
    assign LED[7]  = acc_minus_fifo_full;
    assign LED[8]  = wr_toggle_plus_ff;
    assign LED[9]  = wr_toggle_minus_ff;
    assign LED[10] = |state_out;            // 1 when mode_fsm is not IDLE
    assign LED[11] = ui_clk_sync_rst;       // should be 0 in steady state
    assign LED[12] = mmcm_locked;
    assign LED[13] = is_prime_result;
    assign LED[14] = mem_heartbeat_ff[24];  // 200 MHz alive (~3 Hz blink)
    assign LED[15] = ui_heartbeat_ff[23];   // ui_clk alive (~4 Hz blink)

endmodule
