// ==============================================================================
// Module: seven_seg_decoder
// Description: Converts a 4-bit hex value into 7-segment display signals.
//              Hardcodes the anode (AN) to only activate the right-most digit.
// ==============================================================================

//`timescale 1ns / 1ps

module seven_seg_decoder (
    input  wire [3:0] hex_in,
    output reg        CA, CB, CC, CD, CE, CF, CG,
    output wire [7:0] AN
);

    // Turn on ONLY the right-most digit of the 7-segment display (Active Low)
    assign AN = 8'b1111_1110;

    always @(*) begin
        case(hex_in)
            4'h0: {CA,CB,CC,CD,CE,CF,CG} = 7'b0000001; 
            4'h1: {CA,CB,CC,CD,CE,CF,CG} = 7'b1001111; 
            4'h2: {CA,CB,CC,CD,CE,CF,CG} = 7'b0010010; 
            4'h3: {CA,CB,CC,CD,CE,CF,CG} = 7'b0000110; 
            4'h4: {CA,CB,CC,CD,CE,CF,CG} = 7'b1001100; 
            4'h5: {CA,CB,CC,CD,CE,CF,CG} = 7'b0100100; 
            4'h6: {CA,CB,CC,CD,CE,CF,CG} = 7'b0100000; 
            4'h7: {CA,CB,CC,CD,CE,CF,CG} = 7'b0001111; 
            4'h8: {CA,CB,CC,CD,CE,CF,CG} = 7'b0000000; 
            4'h9: {CA,CB,CC,CD,CE,CF,CG} = 7'b0000100; 
            4'hA: {CA,CB,CC,CD,CE,CF,CG} = 7'b0001000; 
            4'hB: {CA,CB,CC,CD,CE,CF,CG} = 7'b1100000; 
            4'hC: {CA,CB,CC,CD,CE,CF,CG} = 7'b0110001; 
            4'hD: {CA,CB,CC,CD,CE,CF,CG} = 7'b1000010; 
            4'hE: {CA,CB,CC,CD,CE,CF,CG} = 7'b0110000; 
            4'hF: {CA,CB,CC,CD,CE,CF,CG} = 7'b0111000; 
            default: {CA,CB,CC,CD,CE,CF,CG} = 7'b1111111; // All OFF
        endcase
    end
endmodule