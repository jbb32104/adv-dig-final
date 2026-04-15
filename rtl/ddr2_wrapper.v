`timescale 1ns / 1ps

// Thin pass-through wrapper around the Vivado MIG 7-series IP (`mig`).
// Exposes every port of the generated MIG so higher-level code does not
// instantiate the IP directly. Logic/arbitration belongs in mem_arbiter,
// not here.
//
// MIG generation settings (mirrored in rtl/NEXT_STEPS.md):
//   - DDR2, MT47H64M16HR-25E, 16-bit DQ, BL8, CL=5
//   - Native interface, 128-bit app data, 4:1 PHY ratio (~75 MHz ui_clk)
//   - System Clock Type: No Buffer (sys_clk_i must be a buffered 200 MHz clock)
//   - Reference Clock Type: Use System Clock (no separate clk_ref_i port)
//   - XADC instantiation in MIG: Enabled (no device_temp_i port)
//   - Internal Vref: Enabled
//   - Ordering: Normal
//   - sys_rst: active-low

module ddr2_wrapper (
    // ---- DDR2 device pins (to SDRAM) --------------------------------------
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
    output wire [0:0]  ddr2_odt,

    // ---- User application interface (ui_clk domain) -----------------------
    input  wire [26:0] app_addr,
    input  wire [2:0]  app_cmd,
    input  wire        app_en,
    input  wire [127:0] app_wdf_data,
    input  wire        app_wdf_end,
    input  wire [15:0] app_wdf_mask,
    input  wire        app_wdf_wren,
    output wire [127:0] app_rd_data,
    output wire        app_rd_data_end,
    output wire        app_rd_data_valid,
    output wire        app_rdy,
    output wire        app_wdf_rdy,
    input  wire        app_sr_req,
    input  wire        app_ref_req,
    input  wire        app_zq_req,
    output wire        app_sr_active,
    output wire        app_ref_ack,
    output wire        app_zq_ack,

    // ---- Clocks / status / reset ------------------------------------------
    output wire        ui_clk,
    output wire        ui_clk_sync_rst,
    output wire        init_calib_complete,
    input  wire        sys_clk_i,     // 200 MHz, buffered (No Buffer mode)
    input  wire        sys_rst        // active-low
);

    mig u_mig (
        // DDR2 pins
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
        // App
        .app_addr            (app_addr),
        .app_cmd             (app_cmd),
        .app_en              (app_en),
        .app_wdf_data        (app_wdf_data),
        .app_wdf_end         (app_wdf_end),
        .app_wdf_mask        (app_wdf_mask),
        .app_wdf_wren        (app_wdf_wren),
        .app_rd_data         (app_rd_data),
        .app_rd_data_end     (app_rd_data_end),
        .app_rd_data_valid   (app_rd_data_valid),
        .app_rdy             (app_rdy),
        .app_wdf_rdy         (app_wdf_rdy),
        .app_sr_req          (app_sr_req),
        .app_ref_req         (app_ref_req),
        .app_zq_req          (app_zq_req),
        .app_sr_active       (app_sr_active),
        .app_ref_ack         (app_ref_ack),
        .app_zq_ack          (app_zq_ack),
        // Clocks / reset / status
        .ui_clk              (ui_clk),
        .ui_clk_sync_rst     (ui_clk_sync_rst),
        .init_calib_complete (init_calib_complete),
        .sys_clk_i           (sys_clk_i),
        .sys_rst             (sys_rst)
    );

endmodule
