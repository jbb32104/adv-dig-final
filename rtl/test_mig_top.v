`timescale 1ns / 1ps

// MIG bring-up exerciser (step 3 of rtl/NEXT_STEPS.md).
// Proves the Clocking Wizard -> MIG -> DDR2 path works end-to-end before
// any arbiter logic is added.
//
// Behavior:
//   1. Wait for init_calib_complete.
//   2. Write a known 128-bit pattern to a few sequential DDR2 addresses.
//   3. Read those addresses back, compare against the expected pattern.
//   4. Drive LEDs with coarse status:
//        LED[0] = init_calib_complete
//        LED[1] = write phase done
//        LED[2] = read phase done
//        LED[3] = all data matched (PASS)
//        LED[4] = any mismatch seen    (FAIL, latched)
//        LED[5] = ui_clk_sync_rst (should be 0 in steady state)
//        LED[15] = heartbeat from ui_clk (visible blink)
//
// Clocking:
//   Board clock `clk` is 100 MHz (Nexys A7, pin E3).
//   PLL IP `pll`:
//     - Input:  clk_in  (100 MHz board clock)
//     - Output: clk_mem (200 MHz, sys_clk_i for MIG)
//               clk_vga (pixel clock, unused in this bring-up)
//               clk_sd  (SD card clock, unused in this bring-up)
//     - Output: locked  (assumed; if your PLL doesn't expose it, tie
//                        mmcm_locked = 1'b1 and rely on cpu_rst_n only)
//
// Reset:
//   Board CPU reset `cpu_rst_n` is active-low. Combined with !locked to
//   form the MIG's active-low sys_rst.

module test_mig_top (
    input  wire        clk,          // 100 MHz board clock (E3)
    input  wire        cpu_rst_n,    // active-low reset button
    output reg  [15:0] LED,

    // DDR2 pins (routed out to the board)
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

    // -----------------------------------------------------------------------
    // Clocking Wizard: 100 MHz -> 200 MHz for MIG sys_clk_i
    // -----------------------------------------------------------------------
    wire sys_clk_200;
    wire clk_vga;
    wire clk_sd;
    wire mmcm_locked;

    pll u_pll (
        .clk_in  (clk),
        .resetn  (cpu_rst_n),
        .clk_mem (sys_clk_200),
        .clk_vga (clk_vga),
        .clk_sd  (clk_sd),
        .locked  (mmcm_locked)
    );

    // MIG sys_rst is active-low; hold in reset until MMCM locks and button released
    wire sys_rst_n = cpu_rst_n & mmcm_locked;

    // -----------------------------------------------------------------------
    // DDR2 wrapper (MIG pass-through)
    // -----------------------------------------------------------------------
    wire         ui_clk;
    wire         ui_clk_sync_rst;
    wire         init_calib_complete;

    reg  [26:0]  app_addr_ff;
    reg  [2:0]   app_cmd_ff;
    reg          app_en_ff;
    reg  [127:0] app_wdf_data_ff;
    reg          app_wdf_end_ff;
    reg  [15:0]  app_wdf_mask_ff;
    reg          app_wdf_wren_ff;

    wire [127:0] app_rd_data;
    wire         app_rd_data_end;
    wire         app_rd_data_valid;
    wire         app_rdy;
    wire         app_wdf_rdy;

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

        .app_addr            (app_addr_ff),
        .app_cmd             (app_cmd_ff),
        .app_en              (app_en_ff),
        .app_wdf_data        (app_wdf_data_ff),
        .app_wdf_end         (app_wdf_end_ff),
        .app_wdf_mask        (app_wdf_mask_ff),
        .app_wdf_wren        (app_wdf_wren_ff),
        .app_rd_data         (app_rd_data),
        .app_rd_data_end     (app_rd_data_end),
        .app_rd_data_valid   (app_rd_data_valid),
        .app_rdy             (app_rdy),
        .app_wdf_rdy         (app_wdf_rdy),
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

    // -----------------------------------------------------------------------
    // Exerciser FSM (ui_clk domain)
    //
    // Writes NUM_WORDS 128-bit words starting at BASE_ADDR, then reads them
    // back and checks for mismatches. One outstanding transaction at a time
    // keeps the logic simple — this is bring-up, not a throughput test.
    // -----------------------------------------------------------------------
    localparam [26:0] BASE_ADDR = 27'h000_0000;
    localparam [3:0]  NUM_WORDS = 4'd8;       // 8 x 128-bit words
    localparam [2:0]  CMD_WRITE = 3'b000;
    localparam [2:0]  CMD_READ  = 3'b001;

    localparam [3:0] S_WAIT_CAL  = 4'd0,
                     S_WR_ISSUE  = 4'd1,
                     S_WR_NEXT   = 4'd2,
                     S_WR_DONE   = 4'd3,
                     S_RD_ISSUE  = 4'd4,
                     S_RD_WAIT   = 4'd5,
                     S_RD_DONE   = 4'd6,
                     S_PASS      = 4'd7,
                     S_FAIL      = 4'd8;

    reg  [3:0]  state_ff,   next_state;
    reg  [3:0]  word_idx_ff, next_word_idx;
    reg  [3:0]  rd_idx_ff,   next_rd_idx;
    reg         wr_data_sent_ff, next_wr_data_sent;
    reg         wr_cmd_sent_ff,  next_wr_cmd_sent;
    reg         fail_ff,     next_fail;
    reg  [23:0] heartbeat_ff;

    // Expected pattern — unique per word so mismatches point at which one failed
    function [127:0] pattern;
        input [3:0] idx;
        begin
            pattern = {idx, 28'hA5A5A5A, idx, 28'h5A5A5A5,
                       idx, 28'hDEADBEE, idx, 28'hCAFEBABE};
        end
    endfunction

    wire [26:0] addr_for_idx = BASE_ADDR + ({23'd0, word_idx_ff} <<< 4); // +16 bytes/word
    wire [26:0] rd_addr_for_idx = BASE_ADDR + ({23'd0, rd_idx_ff}   <<< 4);

    always @(*) begin
        // defaults
        next_state        = state_ff;
        next_word_idx     = word_idx_ff;
        next_rd_idx       = rd_idx_ff;
        next_wr_data_sent = wr_data_sent_ff;
        next_wr_cmd_sent  = wr_cmd_sent_ff;
        next_fail         = fail_ff;

        app_addr_ff      = 27'd0;
        app_cmd_ff       = 3'b000;
        app_en_ff        = 1'b0;
        app_wdf_data_ff  = 128'd0;
        app_wdf_end_ff   = 1'b0;
        app_wdf_mask_ff  = 16'd0;   // write all bytes
        app_wdf_wren_ff  = 1'b0;

        if (ui_clk_sync_rst) begin
            next_state        = S_WAIT_CAL;
            next_word_idx     = 4'd0;
            next_rd_idx       = 4'd0;
            next_wr_data_sent = 1'b0;
            next_wr_cmd_sent  = 1'b0;
            next_fail         = 1'b0;
        end else begin
            case (state_ff)
                S_WAIT_CAL: begin
                    if (init_calib_complete) next_state = S_WR_ISSUE;
                end

                S_WR_ISSUE: begin
                    // Push write data (may go before, with, or after command;
                    // MIG accepts wdf wren whenever app_wdf_rdy is high).
                    app_wdf_data_ff = pattern(word_idx_ff);
                    app_wdf_end_ff  = 1'b1;   // single 128-bit beat per write
                    app_wdf_wren_ff = ~wr_data_sent_ff;
                    if (~wr_data_sent_ff && app_wdf_rdy) next_wr_data_sent = 1'b1;

                    // Issue the write command
                    app_addr_ff = addr_for_idx;
                    app_cmd_ff  = CMD_WRITE;
                    app_en_ff   = ~wr_cmd_sent_ff;
                    if (~wr_cmd_sent_ff && app_rdy) next_wr_cmd_sent = 1'b1;

                    if ((wr_data_sent_ff || (~wr_data_sent_ff && app_wdf_rdy)) &&
                        (wr_cmd_sent_ff  || (~wr_cmd_sent_ff  && app_rdy))) begin
                        next_state        = S_WR_NEXT;
                        next_wr_data_sent = 1'b0;
                        next_wr_cmd_sent  = 1'b0;
                    end
                end

                S_WR_NEXT: begin
                    if (word_idx_ff == NUM_WORDS - 1) begin
                        next_state    = S_WR_DONE;
                        next_word_idx = 4'd0;
                    end else begin
                        next_word_idx = word_idx_ff + 4'd1;
                        next_state    = S_WR_ISSUE;
                    end
                end

                S_WR_DONE: next_state = S_RD_ISSUE;

                S_RD_ISSUE: begin
                    app_addr_ff = rd_addr_for_idx;
                    app_cmd_ff  = CMD_READ;
                    app_en_ff   = 1'b1;
                    if (app_rdy) next_state = S_RD_WAIT;
                end

                S_RD_WAIT: begin
                    if (app_rd_data_valid) begin
                        if (app_rd_data !== pattern(rd_idx_ff)) next_fail = 1'b1;
                        if (rd_idx_ff == NUM_WORDS - 1) begin
                            next_state = S_RD_DONE;
                        end else begin
                            next_rd_idx = rd_idx_ff + 4'd1;
                            next_state  = S_RD_ISSUE;
                        end
                    end
                end

                S_RD_DONE: next_state = fail_ff ? S_FAIL : S_PASS;

                S_PASS: /* stay */;
                S_FAIL: /* stay */;

                default: next_state = S_WAIT_CAL;
            endcase
        end
    end

    always @(posedge ui_clk) begin
        state_ff        <= next_state;
        word_idx_ff     <= next_word_idx;
        rd_idx_ff       <= next_rd_idx;
        wr_data_sent_ff <= next_wr_data_sent;
        wr_cmd_sent_ff  <= next_wr_cmd_sent;
        fail_ff         <= next_fail;
        heartbeat_ff    <= heartbeat_ff + 24'd1;
    end

    // Diagnostic heartbeat off the 200 MHz PLL output — proves clk_mem is
    // actually toggling independent of the MIG.
    reg [24:0] mem_heartbeat_ff;
    always @(posedge sys_clk_200 or negedge cpu_rst_n) begin
        if (!cpu_rst_n) mem_heartbeat_ff <= 25'd0;
        else            mem_heartbeat_ff <= mem_heartbeat_ff + 25'd1;
    end

    // LEDs (combinational; LED is a reg only for the always @* assignment)
    always @(*) begin
        LED = 16'd0;
        LED[0]  = init_calib_complete;
        LED[1]  = (state_ff == S_WR_DONE) || (state_ff >= S_RD_ISSUE);
        LED[2]  = (state_ff == S_RD_DONE) || (state_ff == S_PASS) || (state_ff == S_FAIL);
        LED[3]  = (state_ff == S_PASS);
        LED[4]  = fail_ff;
        LED[5]  = ui_clk_sync_rst;
        LED[13] = mmcm_locked;            // PLL locked?
        LED[14] = mem_heartbeat_ff[24];   // clk_mem (200 MHz) alive? ~3 Hz blink
        LED[15] = heartbeat_ff[23];       // ui_clk (~75 MHz) alive? ~4 Hz blink
    end

endmodule
