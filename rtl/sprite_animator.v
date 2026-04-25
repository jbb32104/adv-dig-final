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
    parameter [9:0] INIT_X   = 10'd224,   // horizontally centered
    parameter [9:0] INIT_Y   = 10'd224    // vertically centered
) (
    input  wire        clk_vga,
    input  wire        rst,
    input  wire        vsync,        // from VGA controller (clk_vga domain)
    input  wire        enable,       // high on screen 0 only

    output reg  [9:0]  sprite_x_ff,
    output reg  [9:0]  sprite_y_ff,
    output reg  [7:0]  sprite_color_ff
);

    // -----------------------------------------------------------------------
    // Vsync rising-edge detect
    // -----------------------------------------------------------------------
    reg vs_prev_ff;
    wire vs_rising = vsync && !vs_prev_ff;

    always @(posedge clk_vga) begin
        if (rst) vs_prev_ff <= 1'b0;
        else     vs_prev_ff <= vsync;
    end

    // -----------------------------------------------------------------------
    // Movement bounds and speeds
    // -----------------------------------------------------------------------
    localparam [9:0] X_MAX   = SCREEN_W - SPRITE_W;  // 448
    localparam [9:0] Y_MAX   = SCREEN_H - SPRITE_H;  // 448
    localparam [9:0] SPEED_X = 10'd2;  // 2 px/frame horizontal
    localparam [9:0] SPEED_Y = 10'd1;  // 1 px/frame vertical

    // Direction flags: 0 = positive (right / down), 1 = negative (left / up)
    reg dir_x_ff;
    reg dir_y_ff;

    // Next position and direction (combinational, with boundary clamping)
    reg [9:0] next_x, next_y;
    reg       next_dir_x, next_dir_y;

    always @(*) begin
        next_dir_x = dir_x_ff;
        next_dir_y = dir_y_ff;

        // --- X axis ---
        if (dir_x_ff) begin
            // Moving left
            if (sprite_x_ff <= SPEED_X) begin
                next_x     = 10'd0;
                next_dir_x = 1'b0;       // reverse: go right
            end else begin
                next_x = sprite_x_ff - SPEED_X;
            end
        end else begin
            // Moving right
            if (sprite_x_ff >= X_MAX - SPEED_X) begin
                next_x     = X_MAX;
                next_dir_x = 1'b1;       // reverse: go left
            end else begin
                next_x = sprite_x_ff + SPEED_X;
            end
        end

        // --- Y axis ---
        if (dir_y_ff) begin
            // Moving up
            if (sprite_y_ff <= SPEED_Y) begin
                next_y     = 10'd0;
                next_dir_y = 1'b0;       // reverse: go down
            end else begin
                next_y = sprite_y_ff - SPEED_Y;
            end
        end else begin
            // Moving down
            if (sprite_y_ff >= Y_MAX - SPEED_Y) begin
                next_y     = Y_MAX;
                next_dir_y = 1'b1;       // reverse: go up
            end else begin
                next_y = sprite_y_ff + SPEED_Y;
            end
        end
    end

    // -----------------------------------------------------------------------
    // Rainbow color — 6-sector HSV at full saturation / value
    //   192 steps total  (32 per sector)
    //   R,G: 3-bit (0-7),  B: 2-bit (0-3)
    // -----------------------------------------------------------------------
    reg [7:0] hue_ff;           // 0-191, wrapping

    wire [4:0] hue_step = hue_ff[4:0];   // 0-31 within current sector

    reg [2:0] color_r;
    reg [2:0] color_g;
    reg [1:0] color_b;

    always @(*) begin
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
    // Sequential update — once per frame
    // -----------------------------------------------------------------------
    always @(posedge clk_vga) begin
        if (rst) begin
            sprite_x_ff     <= INIT_X;
            sprite_y_ff     <= INIT_Y;
            dir_x_ff        <= 1'b1;           // initial: left
            dir_y_ff        <= 1'b1;           // initial: up
            hue_ff          <= 8'd0;
            sprite_color_ff <= 8'hE0;          // start red
        end else if (vs_rising && enable) begin
            // --- Position & direction ---
            sprite_x_ff <= next_x;
            sprite_y_ff <= next_y;
            dir_x_ff    <= next_dir_x;
            dir_y_ff    <= next_dir_y;

            // --- Color ---
            hue_ff <= (hue_ff == 8'd191) ? 8'd0 : hue_ff + 8'd1;
            sprite_color_ff <= {color_r, color_g, color_b};
        end
    end

endmodule
