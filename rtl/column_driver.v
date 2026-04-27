`timescale 1ns / 1ps

// Column driver for 4x4 matrix keypad scanning.
// Drives one column high for ~2M clock cycles, then advances to the next.
// freeze input holds the current column steady (used during row read).
//
// Clock domain: clk (100 MHz).

module column_driver (
    input  wire clk,
    input  wire rst_n,
    input  wire freeze,
    output reg  c_0,
    output reg  c_1,
    output reg  c_2,
    output reg  c_3
);

    // -----------------------------------------------------------------------
    // Registered state
    // -----------------------------------------------------------------------
    reg [1:0]  col_ff;
    reg [20:0] count_ff;

    // -----------------------------------------------------------------------
    // Combinational next-state signals
    // -----------------------------------------------------------------------
    reg        c_0_next, c_1_next, c_2_next, c_3_next;
    reg [1:0]  col_next;
    reg [20:0] count_next;

    // -----------------------------------------------------------------------
    // Combinational logic
    // -----------------------------------------------------------------------
    always @(*) begin
        // Defaults
        c_0_next   = 1'b0;
        c_1_next   = 1'b0;
        c_2_next   = 1'b0;
        c_3_next   = 1'b0;
        count_next = count_ff;
        col_next   = col_ff;

        if (!rst_n) begin
            c_0_next   = 1'b0;
            c_1_next   = 1'b0;
            c_2_next   = 1'b0;
            c_3_next   = 1'b0;
            count_next = 21'd2000000;
            col_next   = 2'd3;
        end else if (freeze) begin
            count_next = count_ff;
            col_next   = col_ff;
        end else begin
            if (count_ff == 21'd2000000) begin
                count_next = 21'd0;
                col_next   = col_ff + 2'd1;
            end else begin
                count_next = count_ff + 21'd1;
                col_next   = col_ff;
            end
        end

        // Column decode (active regardless of reset/freeze for clean defaults)
        if (!rst_n) begin
            // already zeroed above
        end else begin
            case (col_next)
                2'd0: c_0_next = 1'b1;
                2'd1: c_1_next = 1'b1;
                2'd2: c_2_next = 1'b1;
                2'd3: c_3_next = 1'b1;
                default: ;
            endcase
        end
    end

    // -----------------------------------------------------------------------
    // Sequential block — flops only
    // -----------------------------------------------------------------------
    always @(posedge clk) begin
        c_0      <= c_0_next;
        c_1      <= c_1_next;
        c_2      <= c_2_next;
        c_3      <= c_3_next;
        count_ff <= count_next;
        col_ff   <= col_next;
    end

endmodule
