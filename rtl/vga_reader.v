`timescale 1ns / 1ps

// VGA frame-buffer reader — fetches pre-rendered pixel data from DDR2
// through the mem_arbiter VGA read port and pushes it into pixel_fifo.
//
// Double-buffered: fb_select chooses FB_A or FB_B. The select is latched
// on the vsync rising edge so the reader uses a consistent buffer for
// the entire frame.
//
// Clock domain: ui_clk (~75 MHz, same as arbiter).
// vsync from the VGA controller (clk_vga domain) is CDC'd internally.
//
// Frame buffer layout (contiguous 128-bit words starting at FB_A/FB_B):
//   Line 0: LINE0_HEIGHT scanlines x WORDS_PER_SCANLINE words
//   Line 1: LINE12_HEIGHT scanlines x WORDS_PER_SCANLINE words
//   Line 2: LINE12_HEIGHT scanlines x WORDS_PER_SCANLINE words
//
// Each 128-bit word holds 16 pixels (8-bit RGB332 each).
// 640 pixels per scanline = 40 words per scanline.
//
// Protocol with arbiter:
//   Hold vga_rd_req high with vga_rd_addr until vga_rd_grant pulses.
//   Read data returns later via rd_data / rd_data_valid (passthrough
//   from MIG — only one read requestor so no routing needed).
//   One read in flight at a time; wait for rd_data_valid before
//   issuing the next request.

module vga_reader #(
    parameter [26:0] FB_A              = 27'h050_0000,
    parameter [26:0] FB_B              = 27'h050_A000,
    parameter [5:0]  WORDS_PER_SCANLINE = 6'd40,     // 640 px / 16 px per word
    parameter [5:0]  LINE0_HEIGHT      = 6'd32,
    parameter [5:0]  LINE12_HEIGHT     = 6'd16
) (
    input  wire        ui_clk,
    input  wire        rst_n,
    input  wire        init_calib_complete,
    input  wire        enable,              // gate: wait for FB to be filled

    // Double-buffer select (ui_clk domain): 0 = FB_A, 1 = FB_B
    input  wire        fb_select,

    // vsync from VGA controller (clk_vga domain — CDC'd internally)
    input  wire        vsync_vga,

    // Arbiter VGA read port (ui_clk domain)
    output reg         vga_rd_req_ff,
    output reg  [26:0] vga_rd_addr_ff,
    input  wire        vga_rd_grant,

    // Read data return from arbiter (ui_clk domain)
    input  wire [127:0] rd_data,
    input  wire         rd_data_valid,

    // pixel_fifo write port (ui_clk domain)
    output wire [127:0] fifo_din,
    output wire         fifo_wr_en,
    input  wire         fifo_full,
    input  wire         fifo_wr_rst_busy
);

    // Total 128-bit words per frame
    localparam [12:0] WORDS_PER_FRAME =
        (LINE0_HEIGHT + LINE12_HEIGHT + LINE12_HEIGHT) * WORDS_PER_SCANLINE;

    // -----------------------------------------------------------------------
    // vsync CDC (clk_vga -> ui_clk): 2-FF synchronizer + edge detect
    // -----------------------------------------------------------------------
    reg vs_meta_ff, vs_sync_ff, vs_prev_ff;
    always @(posedge ui_clk) begin
        vs_meta_ff <= vsync_vga;
        vs_sync_ff <= vs_meta_ff;
        vs_prev_ff <= vs_sync_ff;
    end
    // Rising edge of vsync = entering vertical blanking = frame done.
    // We use this to reset the read pointer for the next frame.
    wire vs_rising = vs_sync_ff && !vs_prev_ff;

    // -----------------------------------------------------------------------
    // Latch fb_select on vsync so the buffer base is stable for the frame
    // -----------------------------------------------------------------------
    reg        fb_sel_latched_ff;
    wire [26:0] frame_base = fb_sel_latched_ff ? FB_B : FB_A;

    // -----------------------------------------------------------------------
    // FSM
    // -----------------------------------------------------------------------
    localparam [1:0] S_WAIT_VS = 2'd0,   // wait for vsync to reset pointer
                     S_IDLE    = 2'd1,   // wait for FIFO room
                     S_REQ     = 2'd2,   // read request in flight
                     S_DATA    = 2'd3;   // wait for rd_data_valid

    reg [1:0]  state_ff;
    reg [12:0] word_cnt_ff;   // words read this frame (0..WORDS_PER_FRAME-1)
    reg [26:0] rd_addr_ff;    // next DDR2 byte address to read

    // Read data from arbiter goes straight into pixel_fifo
    assign fifo_din   = rd_data;
    assign fifo_wr_en = rd_data_valid && !fifo_wr_rst_busy;

    // -----------------------------------------------------------------------
    // Sequential logic
    // -----------------------------------------------------------------------
    always @(posedge ui_clk) begin
        if (!rst_n) begin
            state_ff          <= S_WAIT_VS;
            word_cnt_ff       <= 13'd0;
            rd_addr_ff        <= FB_A;
            vga_rd_req_ff     <= 1'b0;
            vga_rd_addr_ff    <= FB_A;
            fb_sel_latched_ff <= 1'b0;
        end else begin
            case (state_ff)

                // ---- Wait for vsync rising edge to start a new frame ----
                S_WAIT_VS: begin
                    vga_rd_req_ff <= 1'b0;
                    if (vs_rising) begin
                        fb_sel_latched_ff <= fb_select;  // latch buffer choice
                        word_cnt_ff       <= 13'd0;
                        rd_addr_ff        <= fb_select ? FB_B : FB_A;
                        state_ff          <= S_IDLE;
                    end
                end

                // ---- Check if more data needed and FIFO has room ----
                S_IDLE: begin
                    if (word_cnt_ff >= WORDS_PER_FRAME) begin
                        // All words for this frame have been read
                        state_ff <= S_WAIT_VS;
                    end else if (!fifo_full && !fifo_wr_rst_busy && init_calib_complete && enable) begin
                        vga_rd_req_ff  <= 1'b1;
                        vga_rd_addr_ff <= rd_addr_ff;
                        state_ff       <= S_REQ;
                    end
                end

                // ---- Hold request until arbiter grants ----
                S_REQ: begin
                    if (vga_rd_grant) begin
                        vga_rd_req_ff <= 1'b0;
                        rd_addr_ff    <= rd_addr_ff + 27'd16; // next 128-bit word
                        word_cnt_ff   <= word_cnt_ff + 13'd1;
                        state_ff      <= S_DATA;
                    end
                end

                // ---- Wait for MIG to return read data ----
                S_DATA: begin
                    if (rd_data_valid) begin
                        state_ff <= S_IDLE;
                    end
                end

                default: state_ff <= S_WAIT_VS;

            endcase
        end
    end

endmodule
