`timescale 1ns / 1ps

// Row reader for 4x4 matrix keypad.
// Decodes which button is pressed from debounced row inputs and column
// driver state. Outputs a 4-bit button code and a 1-cycle valid pulse.
//
// Simultaneous presses are treated as invalid (button_valid stays low).
//
// Clock domain: clk (100 MHz).

module row_reader (
    input  wire       clk,
    input  wire       rst_n,

    input  wire       row_0,
    input  wire       row_1,
    input  wire       row_2,
    input  wire       row_3,

    input  wire       c_0_ff,
    input  wire       c_1_ff,
    input  wire       c_2_ff,
    input  wire       c_3_ff,

    output reg  [3:0] button_ff,
    output reg        button_valid_ff,
    output reg        freeze_out
);

    // -----------------------------------------------------------------------
    // Combinational bundles (replacing assign wires)
    // -----------------------------------------------------------------------
    reg [3:0] rows;
    reg [3:0] columns;

    always @(*) begin
        rows    = {row_0, row_1, row_2, row_3};
        columns = {c_0_ff, c_1_ff, c_2_ff, c_3_ff};
    end

    // -----------------------------------------------------------------------
    // Combinational next-state signals
    // -----------------------------------------------------------------------
    reg [3:0] button_next;
    reg       button_valid_next;
    reg       freeze_next;

    // -----------------------------------------------------------------------
    // Combinational logic
    // -----------------------------------------------------------------------
    always @(*) begin
        // Defaults
        button_next       = button_ff;
        button_valid_next = 1'b0;
        freeze_next       = row_0 | row_1 | row_2 | row_3;

        if (!rst_n) begin
            button_next       = 4'b0;
            button_valid_next = 1'b0;
            freeze_next       = 1'b0;
        end else begin
            case (rows)
                4'b1000: begin
                    button_valid_next = 1'b1;
                    case (columns)
                        4'b1000: button_next = 4'h1;
                        4'b0100: button_next = 4'h2;
                        4'b0010: button_next = 4'h3;
                        4'b0001: button_next = 4'hA;
                        default: button_valid_next = 1'b0;
                    endcase
                end

                4'b0100: begin
                    button_valid_next = 1'b1;
                    case (columns)
                        4'b1000: button_next = 4'h4;
                        4'b0100: button_next = 4'h5;
                        4'b0010: button_next = 4'h6;
                        4'b0001: button_next = 4'hB;
                        default: button_valid_next = 1'b0;
                    endcase
                end

                4'b0010: begin
                    button_valid_next = 1'b1;
                    case (columns)
                        4'b1000: button_next = 4'h7;
                        4'b0100: button_next = 4'h8;
                        4'b0010: button_next = 4'h9;
                        4'b0001: button_next = 4'hC;
                        default: button_valid_next = 1'b0;
                    endcase
                end

                4'b0001: begin
                    button_valid_next = 1'b1;
                    case (columns)
                        4'b1000: button_next = 4'hE;
                        4'b0100: button_next = 4'h0;
                        4'b0010: button_next = 4'hF;
                        4'b0001: button_next = 4'hD;
                        default: button_valid_next = 1'b0;
                    endcase
                end

                default: button_valid_next = 1'b0;
            endcase
        end
    end

    // -----------------------------------------------------------------------
    // Sequential block — flops only
    // -----------------------------------------------------------------------
    always @(posedge clk) begin
        button_ff       <= button_next;
        button_valid_ff <= button_valid_next;
        freeze_out      <= freeze_next;
    end

endmodule
