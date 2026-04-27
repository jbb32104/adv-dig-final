`timescale 1ns / 1ps

// sprite_enable_cdc — CDC screen_id from clk to clk_vga domain,
// then decode to produce sprite_enable (high when on home screen 0).
//
// Clock domain: clk_vga (25 MHz).

module sprite_enable_cdc (
    input  wire       clk_vga,
    input  wire [2:0] screen_id,     // clk domain, slow-changing
    output reg        sprite_enable
);

    // 2-FF synchroniser (safe for slow-changing multi-bit bus)
    reg [2:0] meta_ff, sync_ff;
    reg [2:0] meta_next, sync_next;

    always @(*) begin
        meta_next = screen_id;
        sync_next = meta_ff;
    end

    always @(posedge clk_vga) begin
        meta_ff <= meta_next;
        sync_ff <= sync_next;
    end

    // Sprite shows on home screen (screen 0) only
    always @(*) begin
        sprite_enable = (sync_ff == 3'd0);
    end

endmodule
