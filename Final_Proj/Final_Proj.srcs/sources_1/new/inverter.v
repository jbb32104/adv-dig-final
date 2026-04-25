//`timescale 1ns / 1ps

module inverter (
    input  wire in,
    output reg out
);

    always @(*) begin
	   out = ~in;
    end
endmodule