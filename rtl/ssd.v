`timescale 1ns / 1ps

// Seven-segment display controller for Nexys A7 (8-digit, active-low).
// Accepts a 32-bit value and displays it as 8 hex digits.
// Multiplexes all 8 digits using a refresh counter.
// All outputs are active-low (SEG, AN, DP_n).
//
// REFRESH_RATE: anode scan frequency per digit in Hz.
// At 100 MHz with REFRESH_RATE=500, each digit is on for 1/500 s = 2 ms.
// Full 8-digit scan period = 16 ms (62.5 Hz flicker-free).
//
// dp_en[7:0]: per-digit decimal point enable (1 = DP on for that digit).
//             dp_en[0] controls the rightmost digit (digit 0).

module ssd #(
    parameter CLK_FREQ_HZ = 100_000_000,
    parameter REFRESH_RATE = 500            // Hz per digit
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [31:0] value,               // 32-bit hex value to display
    input  wire [7:0]  dp_en,               // decimal point enable per digit
    output reg  [6:0]  SEG,                 // segment outputs (active-low)
    output reg  [7:0]  AN,                  // anode select (active-low)
    output reg         DP_n                 // decimal point (active-low)
);

    // -----------------------------------------------------------------------
    // Refresh counter: divides clk down to per-digit scan rate
    // -----------------------------------------------------------------------
    localparam REFRESH_COUNT = CLK_FREQ_HZ / REFRESH_RATE;  // cycles per digit slot
    localparam CTR_W         = $clog2(REFRESH_COUNT);

    reg [CTR_W-1:0] refresh_ctr_ff;
    reg [2:0]       digit_idx_ff;           // 0..7: which digit is active

    reg [CTR_W-1:0] next_refresh_ctr;
    reg [2:0]       next_digit_idx;

    always @(*) begin
        next_refresh_ctr = refresh_ctr_ff;
        next_digit_idx   = digit_idx_ff;

        if (!rst_n) begin
            next_refresh_ctr = {CTR_W{1'b0}};
            next_digit_idx   = 3'd0;
        end else begin
            if (refresh_ctr_ff == REFRESH_COUNT - 1) begin
                next_refresh_ctr = {CTR_W{1'b0}};
                next_digit_idx   = digit_idx_ff + 3'd1;  // wraps 7→0 naturally
            end else begin
                next_refresh_ctr = refresh_ctr_ff + {{CTR_W-1{1'b0}}, 1'b1};
            end
        end
    end

    always @(posedge clk) begin
        refresh_ctr_ff <= next_refresh_ctr;
        digit_idx_ff   <= next_digit_idx;
    end

    // -----------------------------------------------------------------------
    // Digit mux: extract the active 4-bit nibble from value
    // digit_idx 0 = rightmost digit (bits 3:0), 7 = leftmost (bits 31:28)
    // -----------------------------------------------------------------------
    reg [3:0] nibble;
    reg       dp_active;

    always @(*) begin
        case (digit_idx_ff)
            3'd0: nibble = value[3:0];
            3'd1: nibble = value[7:4];
            3'd2: nibble = value[11:8];
            3'd3: nibble = value[15:12];
            3'd4: nibble = value[19:16];
            3'd5: nibble = value[23:20];
            3'd6: nibble = value[27:24];
            3'd7: nibble = value[31:28];
            default: nibble = 4'h0;
        endcase
        dp_active = dp_en[digit_idx_ff];
    end

    // -----------------------------------------------------------------------
    // Hex to 7-segment decoder
    // Segment order: SEG[6:0] = {g, f, e, d, c, b, a} (active-low output)
    //
    //   aaa
    //  f   b
    //  f   b
    //   ggg
    //  e   c
    //  e   c
    //   ddd   dp
    //
    // -----------------------------------------------------------------------
    reg [6:0] seg_active_high;  // intermediate: 1 = segment ON

    always @(*) begin
        case (nibble)
            //                    gfedcba
            4'h0: seg_active_high = 7'b0111111;
            4'h1: seg_active_high = 7'b0000110;
            4'h2: seg_active_high = 7'b1011011;
            4'h3: seg_active_high = 7'b1001111;
            4'h4: seg_active_high = 7'b1100110;
            4'h5: seg_active_high = 7'b1101101;
            4'h6: seg_active_high = 7'b1111101;
            4'h7: seg_active_high = 7'b0000111;
            4'h8: seg_active_high = 7'b1111111;
            4'h9: seg_active_high = 7'b1101111;
            4'hA: seg_active_high = 7'b1110111;
            4'hB: seg_active_high = 7'b1111100;
            4'hC: seg_active_high = 7'b0111001;
            4'hD: seg_active_high = 7'b1011110;
            4'hE: seg_active_high = 7'b1111001;
            4'hF: seg_active_high = 7'b1110001;
            default: seg_active_high = 7'b0000000;
        endcase
    end

    // -----------------------------------------------------------------------
    // Anode decoder: assert the active digit (active-low)
    // -----------------------------------------------------------------------
    reg [7:0] an_active_low;

    always @(*) begin
        an_active_low = 8'hFF;                          // all off by default
        an_active_low[digit_idx_ff] = 1'b0;             // enable active digit
    end

    // -----------------------------------------------------------------------
    // Output registers (flop to avoid glitchy transitions on SEG/AN)
    // -----------------------------------------------------------------------
    reg [6:0] next_seg;
    reg [7:0] next_an;
    reg       next_dp_n;

    always @(*) begin
        if (!rst_n) begin
            next_seg  = 7'h7F;
            next_an   = 8'hFF;
            next_dp_n = 1'b1;
        end else begin
            next_seg  = ~seg_active_high;
            next_an   = an_active_low;
            next_dp_n = ~dp_active;
        end
    end

    always @(posedge clk) begin
        SEG  <= next_seg;
        AN   <= next_an;
        DP_n <= next_dp_n;
    end

endmodule
