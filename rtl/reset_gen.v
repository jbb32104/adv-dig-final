`timescale 1ns / 1ps

// reset_gen — derives composite reset signals from individual sources.
//
//   sys_rst_n : rst_sync_n AND pll_locked — used by SD card, VGA reset sync
//   arb_rst_n : inverted MIG ui_clk_sync_rst — used by all ui_clk-domain modules
//
// Purely combinational, no clock domain.

module reset_gen (
    input  wire rst_sync_n,
    input  wire pll_locked,
    input  wire ui_clk_sync_rst,
    output reg  sys_rst_n,
    output reg  arb_rst_n
);

    always @(*) begin
        sys_rst_n = rst_sync_n & pll_locked;
        arb_rst_n = ~ui_clk_sync_rst;
    end

endmodule
