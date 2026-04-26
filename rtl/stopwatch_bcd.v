`timescale 1ns / 1ps

// BCD stopwatch for seven-segment display.
// Counts up in ten-thousandths of a second using cascading BCD digits.
// No binary-to-BCD conversion needed — output is natively BCD.
//
// Format: bcd_ff = {d7, d6, d5, d4, d3, d2, d1, d0}
//   d7..d4 = seconds (0000–9999)
//   d3..d0 = fractional ten-thousandths (0000–9999)
//
// Display on SSD as SSSS.FFFF with decimal point at digit 4.
//
// PRESCALE = clock cycles per ten-thousandth of a second.
//   100 MHz → 10,000 cycles per 0.1 ms.

module stopwatch_bcd #(
    parameter PRESCALE = 10_000   // 10,000 @ 100 MHz = 0.0001 s
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        restart,   // pulse: reset to 0 and start counting
    input  wire        freeze,    // hold value
    output reg  [31:0] bcd_ff     // 8 packed BCD digits
);

    localparam PRE_W = $clog2(PRESCALE);

    reg [PRE_W-1:0] pre_ff;

    // Combinational next-state
    reg [31:0]      next_bcd;
    reg [PRE_W-1:0] next_pre;

    // -----------------------------------------------------------------------
    // BCD increment with carry — pure combinational
    // -----------------------------------------------------------------------
    function [31:0] bcd_inc;
        input [31:0] val;
        reg [3:0] d [0:7];
        reg       carry;
        integer   i;
        begin
            // Unpack
            for (i = 0; i < 8; i = i + 1)
                d[i] = val[i*4 +: 4];

            // Ripple-carry BCD add-1
            carry = 1'b1;  // incoming +1
            for (i = 0; i < 8; i = i + 1) begin
                if (carry) begin
                    if (d[i] == 4'd9) begin
                        d[i]  = 4'd0;
                        carry = 1'b1;
                    end else begin
                        d[i]  = d[i] + 4'd1;
                        carry = 1'b0;
                    end
                end
            end

            // Repack
            bcd_inc = {d[7], d[6], d[5], d[4], d[3], d[2], d[1], d[0]};
        end
    endfunction

    // -----------------------------------------------------------------------
    // Combinational logic
    // -----------------------------------------------------------------------
    always @(*) begin
        next_bcd = bcd_ff;
        next_pre = pre_ff;

        if (!rst_n || restart) begin
            next_bcd = 32'd0;
            next_pre = {PRE_W{1'b0}};
        end else if (!freeze) begin
            if (pre_ff == PRESCALE[PRE_W-1:0] - 1) begin
                next_pre = {PRE_W{1'b0}};
                next_bcd = bcd_inc(bcd_ff);
            end else begin
                next_pre = pre_ff + {{PRE_W-1{1'b0}}, 1'b1};
            end
        end
    end

    // -----------------------------------------------------------------------
    // Sequential block — flops only
    // -----------------------------------------------------------------------
    always @(posedge clk) begin
        bcd_ff <= next_bcd;
        pre_ff <= next_pre;
    end

endmodule
