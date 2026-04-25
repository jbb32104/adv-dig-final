`timescale 1ns / 1ps

// One-shot test-pattern writer for the VGA frame buffer.
// After init_calib_complete, writes WORD_COUNT 128-bit words of all-white
// pixels (0xFF = RGB332 white) to DDR2 starting at FB_BASE, using the
// arbiter's render write port (port 1).
// Fills both double-buffer regions (FB_A and FB_B are contiguous).
// Asserts done_ff when finished — gate vga_reader on this signal.
//
// Clock domain: ui_clk (same as arbiter).

module fb_test_writer #(
    parameter [26:0] FB_BASE    = 27'h050_0000,
    parameter [12:0] WORD_COUNT = 13'd5120       // 2 buffers x (32+16+16) lines x 40 words
) (
    input  wire        ui_clk,
    input  wire        rst_n,
    input  wire        init_calib_complete,

    // Arbiter render-write port (port 1)
    output reg         wr_req_ff,
    output reg  [26:0] wr_addr_ff,
    output wire [127:0] wr_data,
    input  wire        wr_grant,

    output reg         done_ff
);

    // All-white test pattern (RGB332 0xFF per pixel, 16 pixels per word)
    assign wr_data = {128{1'b1}};

    reg [12:0] cnt_ff;
    reg        state_ff;

    localparam S_IDLE = 1'b0,
               S_REQ  = 1'b1;

    always @(posedge ui_clk) begin
        if (!rst_n) begin
            state_ff   <= S_IDLE;
            cnt_ff     <= 13'd0;
            wr_req_ff  <= 1'b0;
            wr_addr_ff <= FB_BASE;
            done_ff    <= 1'b0;
        end else if (!done_ff && init_calib_complete) begin
            case (state_ff)
                S_IDLE: begin
                    if (cnt_ff < WORD_COUNT) begin
                        wr_req_ff  <= 1'b1;
                        wr_addr_ff <= FB_BASE + {cnt_ff, 4'b0000}; // cnt * 16
                        state_ff   <= S_REQ;
                    end else begin
                        done_ff <= 1'b1;
                    end
                end
                S_REQ: begin
                    if (wr_grant) begin
                        wr_req_ff <= 1'b0;
                        cnt_ff    <= cnt_ff + 13'd1;
                        state_ff  <= S_IDLE;
                    end
                end
            endcase
        end
    end

endmodule
