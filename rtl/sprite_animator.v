`timescale 1ns / 1ps

// Sprite animator — drives position and color for the bouncing "PRIME FINDER"
// title on screen 0.
//
// Position updates once per frame (vsync rising edge).  Direction reverses
// when the sprite's bounding box touches a screen edge.
//
// X and Y speeds differ (2:1) so the bounce pattern covers the full screen
// instead of tracing a single diagonal.
//
// Color cycles through a 192-step HSV rainbow (6 sectors x 32 steps) mapped
// to RGB332.
//
// Clock domain: clk_vga (25 MHz).

module sprite_animator #(
    parameter [9:0] SPRITE_W = 10'd192,   // 12 chars x 16 px (2x scale)
    parameter [9:0] SPRITE_H = 10'd32,    // 16 font rows x 2  (2x scale)
    parameter [9:0] SCREEN_W = 10'd640,
    parameter [9:0] SCREEN_H = 10'd480,
    parameter [9:0] INIT_X   = 10'd200,   // off-diagonal for path coverage
    parameter [9:0] INIT_Y   = 10'd300
) (
    input  wire        clk_vga,
    input  wire        rst_n,
    input  wire        vsync,        // from VGA controller (clk_vga domain)
    input  wire        enable,       // high on screen 0 only

    output reg  [9:0]  sprite_x_ff,
    output reg  [9:0]  sprite_y_ff,
    output reg  [7:0]  sprite_color_ff
);

    // -----------------------------------------------------------------------
    // Movement bounds
    // -----------------------------------------------------------------------
    // Expanded bounding box: sprite + 1 px border on each side
    localparam [9:0] BOX_W   = SPRITE_W + 10'd2;     // 194
    localparam [9:0] BOX_H   = SPRITE_H + 10'd2;     // 34
    localparam [9:0] X_MAX   = SCREEN_W - BOX_W - 10'd3; // 443 (prime — breaks 446=446 symmetry)
    localparam [9:0] Y_MAX   = SCREEN_H - BOX_H;     // 446

    // -----------------------------------------------------------------------
    // Registered state
    // -----------------------------------------------------------------------
    reg        vs_prev_ff;
    reg        dir_x_ff;
    reg        dir_y_ff;
    reg [7:0]  hue_ff;

    // -----------------------------------------------------------------------
    // Combinational next-state signals
    // -----------------------------------------------------------------------
    reg        vs_prev_next;
    reg        vs_rising;
    reg [9:0]  sprite_x_next;
    reg [9:0]  sprite_y_next;
    reg        dir_x_next;
    reg        dir_y_next;
    reg [7:0]  hue_next;
    reg [7:0]  sprite_color_next;

    // -----------------------------------------------------------------------
    // Rainbow color — 6-sector HSV at full saturation / value
    //   192 steps total  (32 per sector)
    //   R,G: 3-bit (0-7),  B: 2-bit (0-3)
    // -----------------------------------------------------------------------
    reg [4:0] hue_step;
    reg [2:0] color_r;
    reg [2:0] color_g;
    reg [1:0] color_b;

    always @(*) begin
        hue_step = hue_ff[4:0];

        if (hue_ff < 8'd32) begin              // Sector 0: Red -> Yellow
            color_r = 3'd7;
            color_g = hue_step[4:2];
            color_b = 2'd0;
        end else if (hue_ff < 8'd64) begin     // Sector 1: Yellow -> Green
            color_r = 3'd7 - hue_step[4:2];
            color_g = 3'd7;
            color_b = 2'd0;
        end else if (hue_ff < 8'd96) begin     // Sector 2: Green -> Cyan
            color_r = 3'd0;
            color_g = 3'd7;
            color_b = hue_step[4:3];
        end else if (hue_ff < 8'd128) begin    // Sector 3: Cyan -> Blue
            color_r = 3'd0;
            color_g = 3'd7 - hue_step[4:2];
            color_b = 2'd3;
        end else if (hue_ff < 8'd160) begin    // Sector 4: Blue -> Magenta
            color_r = hue_step[4:2];
            color_g = 3'd0;
            color_b = 2'd3;
        end else begin                          // Sector 5: Magenta -> Red
            color_r = 3'd7;
            color_g = 3'd0;
            color_b = 2'd3 - hue_step[4:3];
        end
    end

    // -----------------------------------------------------------------------
    // Combinational next-state logic (including reset)
    // -----------------------------------------------------------------------
    always @(*) begin
        if (!rst_n) begin
            vs_prev_next      = 1'b0;
            sprite_x_next     = INIT_X;
            sprite_y_next     = INIT_Y;
            dir_x_next        = 1'b1;           // initial: left
            dir_y_next        = 1'b1;           // initial: up
            hue_next          = 8'd0;
            sprite_color_next = 8'hE0;          // start red
        end else begin
            // Vsync rising-edge detect
            vs_rising = vsync && !vs_prev_ff;
            vs_prev_next = vsync;

            // Default: hold all registers
            sprite_x_next     = sprite_x_ff;
            sprite_y_next     = sprite_y_ff;
            dir_x_next        = dir_x_ff;
            dir_y_next        = dir_y_ff;
            hue_next          = hue_ff;
            sprite_color_next = sprite_color_ff;

            if (vs_rising && enable) begin
                // --- X axis ---
                dir_x_next = dir_x_ff;
                if (dir_x_ff) begin
                    if (sprite_x_ff == 10'd0) begin
                        sprite_x_next = 10'd1;
                        dir_x_next    = 1'b0;
                    end else begin
                        sprite_x_next = sprite_x_ff - 10'd1;
                    end
                end else begin
                    if (sprite_x_ff == X_MAX) begin
                        sprite_x_next = X_MAX - 10'd1;
                        dir_x_next    = 1'b1;
                    end else begin
                        sprite_x_next = sprite_x_ff + 10'd1;
                    end
                end

                // --- Y axis ---
                dir_y_next = dir_y_ff;
                if (dir_y_ff) begin
                    if (sprite_y_ff == 10'd0) begin
                        sprite_y_next = 10'd1;
                        dir_y_next    = 1'b0;
                    end else begin
                        sprite_y_next = sprite_y_ff - 10'd1;
                    end
                end else begin
                    if (sprite_y_ff == Y_MAX) begin
                        sprite_y_next = Y_MAX - 10'd1;
                        dir_y_next    = 1'b1;
                    end else begin
                        sprite_y_next = sprite_y_ff + 10'd1;
                    end
                end

                // --- Color ---
                hue_next          = (hue_ff == 8'd191) ? 8'd0 : hue_ff + 8'd1;
                sprite_color_next = {color_r, color_g, color_b};
            end
        end
    end

    // -----------------------------------------------------------------------
    // Sequential block — flops only
    // -----------------------------------------------------------------------
    always @(posedge clk_vga) begin
        vs_prev_ff      <= vs_prev_next;
        sprite_x_ff     <= sprite_x_next;
        sprite_y_ff     <= sprite_y_next;
        dir_x_ff        <= dir_x_next;
        dir_y_ff        <= dir_y_next;
        hue_ff          <= hue_next;
        sprite_color_ff <= sprite_color_next;
    end

endmodule
