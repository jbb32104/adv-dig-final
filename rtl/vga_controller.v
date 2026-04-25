module vga_controller (
    input  wire clk_25MHz, // The pixel clock
    input  wire rst,       // Synchronous reset
    
    output reg hsync_ff,     // Horizontal sync pulse to the VGA port
    output reg vsync_ff,     // Vertical sync pulse to the VGA port
    output reg video_on_ff,   // High when in the 640x480 active region
    output reg [9:0] x_ff,   // Current pixel coordinate (0 to 639) same as h_count_ff
    output reg [9:0] y_ff    // Current line coordinate (0 to 479) same as v_count_ff
);

    //==================//
    //    PARAMETERS    //
    //==================//
    // Horizontal
    parameter H_VISIBLE = 640; 
    parameter H_FRONT   = 16;  
    parameter H_SYNC    = 96;  
    parameter H_BACK    = 48;  
    parameter H_TOTAL   = 800; 

    // Vertical
    parameter V_VISIBLE = 480;
    parameter V_FRONT   = 10;
    parameter V_SYNC    = 2;
    parameter V_BACK    = 33;
    parameter V_TOTAL   = 525;

    //==================//
    // INTERNAL SIGNALS //
    //==================//
    // Notice the consistent use of _next for comb logic and _ff for flops
    reg [9:0] h_count_next, h_count_ff;
    reg       hsync_next;
    reg       video_h_next, video_h_ff;

    reg [9:0] v_count_next, v_count_ff;
    reg       vsync_next;
    reg       video_v_next, video_v_ff;

    reg       video_on_next;    
    // ==========================================================================
    // Top of major always: Combinational Block
    // Description: Calculates all next-state logic and handles synchronous reset
    // ==========================================================================
    always @(*) begin
        // 1. Default assignments to prevent latches
        h_count_next  = h_count_ff;
        hsync_next    = 1'b0;
        video_h_next  = video_h_ff;

        v_count_next  = v_count_ff;
        vsync_next    = 1'b0;
        video_v_next  = video_v_ff;

        video_on_next = 1'b0;

        // 2. Reset Handler
        if (rst) begin
            // All combinational next-state variables go to 0 on reset
            h_count_next  = 10'd0;
            hsync_next    = 1'b0;
            video_h_next  = 1'b0;

            v_count_next  = 10'd0;
            vsync_next    = 1'b0;
            video_v_next  = 1'b0;

            video_on_next = 1'b0;
        end else begin
            // 3. Normal Operating Logic

            // --- HORIZONTAL JOURNEY ---
            if (h_count_ff == (H_TOTAL - 1)) begin 
                h_count_next = 10'd0; 
            end else begin
                h_count_next = h_count_ff + 10'd1; 
            end

            if ((h_count_ff >= H_VISIBLE + H_FRONT) && (h_count_ff < H_VISIBLE + H_FRONT + H_SYNC)) begin
                hsync_next = 1'b1;
            end else begin
                hsync_next = 1'b0;
            end

            if (h_count_ff < H_VISIBLE) begin
                video_h_next = 1'b1;
            end else begin
                video_h_next = 1'b0; 
            end

            // --- VERTICAL JOURNEY ---
            // Only increment vertical when horizontal is wrapping around
            if (h_count_ff == (H_TOTAL - 1)) begin 
               if (v_count_ff == (V_TOTAL - 1)) begin
                   v_count_next = 10'd0; 
               end else begin
                   // Fixed: Increment the flop value (_ff), not the combinational value
                   v_count_next = v_count_ff + 10'd1; 
               end
            end else begin
                v_count_next = v_count_ff; 
            end

            // Fixed: changed <= to >= so it triggers at the correct start point
            if ((v_count_ff >= V_VISIBLE + V_FRONT) && (v_count_ff < V_VISIBLE + V_FRONT + V_SYNC)) begin
                vsync_next = 1'b1; 
            end else begin 
                vsync_next = 1'b0;
            end

            if (v_count_ff < V_VISIBLE) begin
                video_v_next = 1'b1; 
            end else begin
                video_v_next = 1'b0; 
            end

            // --- VIDEO ON ---
            // Active video is only when both horizontal and vertical are in the visible region
            if (video_h_next && video_v_next) begin
                video_on_next = 1'b1;
            end else begin
                video_on_next = 1'b0;
            end
        end
    end

    // ==========================================================================
    // Top of major always: Sequential Block
    // Description: ONLY flop updates allowed. No combinational logic.
    // ==========================================================================
    always @(posedge clk_25MHz) begin
        // Horizontal updates
        h_count_ff  <= h_count_next;
        hsync_ff    <= hsync_next;    
        video_h_ff  <= video_h_next; //I don't think we need this flop actually

        // Vertical updates
        v_count_ff  <= v_count_next;
        vsync_ff    <= vsync_next;
        video_v_ff  <= video_v_next; //I don't think we need this flop either actually

        // Output update
        video_on_ff <= video_on_next;
        x_ff        <= h_count_ff;
        y_ff        <= v_count_ff;
    end

endmodule