`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// sd_line_parser.v
//
// Parses a stream of ASCII decimal bytes (from sd_file_reader) into
// binary values. Each line ends with '\n' (0x0A) or '\r' (0x0D).
//
// On each newline, the accumulated decimal value is presented on `value`
// and `valid` pulses high for one cycle.
//
// Handles up to 32-bit values (max ~4 billion, more than enough for
// primes up to 99991).
//
// Ignores carriage returns and non-digit characters at line boundaries.
//////////////////////////////////////////////////////////////////////////////

module sd_line_parser (
    input  wire        clk,
    input  wire        rst_n,

    // Byte stream from sd_file_reader
    input  wire        byte_en,
    input  wire [7:0]  byte_data,

    // Parsed output
    output reg  [31:0] value,
    output reg         valid
);

    reg [31:0] accum;
    reg        has_digits;  // at least one digit seen on this line

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            accum      <= 32'd0;
            has_digits <= 1'b0;
            value      <= 32'd0;
            valid      <= 1'b0;
        end else begin
            valid <= 1'b0;

            if (byte_en) begin
                if (byte_data >= 8'h30 && byte_data <= 8'h39) begin
                    // ASCII '0'-'9': accumulate decimal
                    accum      <= accum * 10 + (byte_data - 8'h30);
                    has_digits <= 1'b1;
                end else if (byte_data == 8'h0A) begin
                    // '\n': emit value if we had digits
                    if (has_digits) begin
                        value <= accum;
                        valid <= 1'b1;
                    end
                    accum      <= 32'd0;
                    has_digits <= 1'b0;
                end else if (byte_data == 8'h0D) begin
                    // '\r': ignore (CR before LF)
                end else begin
                    // Any other char (e.g. 'A' at end of file): emit if pending
                    if (has_digits) begin
                        value <= accum;
                        valid <= 1'b1;
                    end
                    accum      <= 32'd0;
                    has_digits <= 1'b0;
                end
            end
        end
    end

endmodule
