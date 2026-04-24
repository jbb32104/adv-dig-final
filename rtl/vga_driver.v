module vga_driver (
    input  wire        clk_vga,      // 25 MHz pixel clock
    input  wire        rst,          // synchronous reset

    // From vga_controller (all registered, 1-cycle latency)
    input  wire        hsync_in,
    input  wire        vsync_in,
    input  wire        video_on_in,
    input  wire [9:0]  x_in,
    input  wire [9:0]  y_in,

    // pixel_fifo read port (FWFT, 16-bit, no pipeline registers)
    input  wire [15:0] fifo_dout,
    input  wire        fifo_empty,
    output wire        fifo_rd_en,   // combinational — not registered

    // VGA output
    output reg  [3:0]  vga_r_ff,
    output reg  [3:0]  vga_g_ff,
    output reg  [3:0]  vga_b_ff,
    output reg         vga_hs_ff,
    output reg         vga_vs_ff
);

    //==================//
    //    PARAMETERS    //
    //==================//
    // Text line y-positions (fixed for now, will be CDC'd registers later)
    localparam LINE0_Y_START  = 10'd64;   // 4 char heights from top
    localparam LINE0_HEIGHT   = 10'd32;   // 2x height for title line
    localparam LINE1_Y_START  = 10'd288;  // 3 char heights above line 2
    localparam LINE2_Y_START  = 10'd352;  // 22 char heights from top
    localparam LINE12_HEIGHT  = 10'd16;   // normal height for lines 1-2

    // Background color (8-bit RGB332)
    localparam [7:0] BG_COLOR = 8'h00;

    //==================//
    // INTERNAL SIGNALS //
    //==================//
    reg        pixel_sel_ff, pixel_sel_next;
    reg  [3:0] vga_r_next, vga_g_next, vga_b_next;
    reg        vga_hs_next, vga_vs_next;

    // Text line detection
    wire in_line0 = (y_in >= LINE0_Y_START) && (y_in < LINE0_Y_START + LINE0_HEIGHT);
    wire in_line1 = (y_in >= LINE1_Y_START) && (y_in < LINE1_Y_START + LINE12_HEIGHT);
    wire in_line2 = (y_in >= LINE2_Y_START) && (y_in < LINE2_Y_START + LINE12_HEIGHT);
    wire in_text_line  = in_line0 || in_line1 || in_line2;
    wire in_text_pixel = video_on_in && in_text_line;

    // FIFO read enable: pop on second pixel of each 16-bit pair
    // Combinational so FIFO sees rd_en at the same posedge and advances dout by next cycle
    assign fifo_rd_en = in_text_pixel && !fifo_empty && pixel_sel_ff;

    // Pixel selection from 16-bit FIFO word
    // pixel_sel_ff=0: first pixel (high byte), pixel_sel_ff=1: second pixel (low byte)
    wire [7:0] pixel_byte = pixel_sel_ff ? fifo_dout[7:0] : fifo_dout[15:8];

    // 8-bit RGB332 to 12-bit RGB444 expansion
    wire [3:0] pixel_r = {pixel_byte[7:5], pixel_byte[7]};
    wire [3:0] pixel_g = {pixel_byte[4:2], pixel_byte[4]};
    wire [3:0] pixel_b = {pixel_byte[1:0], pixel_byte[1:0]};

    // Background color expansion (constant)
    wire [3:0] bg_r = {BG_COLOR[7:5], BG_COLOR[7]};
    wire [3:0] bg_g = {BG_COLOR[4:2], BG_COLOR[4]};
    wire [3:0] bg_b = {BG_COLOR[1:0], BG_COLOR[1:0]};

    // ==========================================================================
    // Combinational Block
    // ==========================================================================
    always @(*) begin
        // Defaults
        vga_hs_next    = hsync_in;
        vga_vs_next    = vsync_in;
        vga_r_next     = 4'd0;
        vga_g_next     = 4'd0;
        vga_b_next     = 4'd0;
        pixel_sel_next = 1'b0;

        if (rst) begin
            vga_hs_next    = 1'b0;
            vga_vs_next    = 1'b0;
        end else if (!video_on_in) begin
            // Blanking region: black, reset pixel_sel for next scanline
            pixel_sel_next = 1'b0;
        end else if (in_text_line) begin
            if (fifo_empty) begin
                // FIFO underrun: magenta (visible debug indicator)
                vga_r_next = 4'hF;
                vga_g_next = 4'h0;
                vga_b_next = 4'hF;
            end else begin
                // Text pixel from FIFO
                vga_r_next     = pixel_r;
                vga_g_next     = pixel_g;
                vga_b_next     = pixel_b;
                pixel_sel_next = ~pixel_sel_ff;
            end
        end else begin
            // Non-text visible region: background color
            vga_r_next = bg_r;
            vga_g_next = bg_g;
            vga_b_next = bg_b;
        end
    end

    // ==========================================================================
    // Sequential Block
    // ==========================================================================
    always @(posedge clk_vga) begin
        vga_r_ff     <= vga_r_next;
        vga_g_ff     <= vga_g_next;
        vga_b_ff     <= vga_b_next;
        vga_hs_ff    <= vga_hs_next;
        vga_vs_ff    <= vga_vs_next;
        pixel_sel_ff <= pixel_sel_next;
    end

endmodule
