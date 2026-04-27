`timescale 1ns / 1ps

// Binary-to-BCD converter — 9 BCD digits (36 bits).
//
// Converts a 27-bit binary value to 9 BCD digits using iterative
// double-dabble (shift-add-3) algorithm.
//
// Latency: 29 clock cycles (1 latch + 27 iterations + 1 output).
//
// Max input: 27'd134_217_727 (full 27-bit range).
// Output: bcd_out_ff[35:0] = {d8, d7, d6, d5, d4, d3, d2, d1, d0}
//         d8 = bcd_out_ff[35:32], d0 = bcd_out_ff[3:0]

module bin_to_bcd9 (
    input  wire        clk,
    input  wire        rst_n,

    input  wire [26:0] bin_in,
    input  wire        start,          // pulse to begin conversion

    output reg  [35:0] bcd_out_ff,     // 9 BCD digits
    output reg         valid_ff        // 1-cycle pulse when result is ready
);

    // -----------------------------------------------------------------------
    // Add-3 correction for one BCD digit
    // -----------------------------------------------------------------------
    function [3:0] adj;
        input [3:0] d;
        adj = (d >= 4'd5) ? d + 4'd3 : d;
    endfunction

    // -----------------------------------------------------------------------
    // FSM states
    // -----------------------------------------------------------------------
    localparam [1:0]
        S_IDLE = 2'd0,
        S_CALC = 2'd1,
        S_DONE = 2'd2;

    // -----------------------------------------------------------------------
    // Registered state
    // -----------------------------------------------------------------------
    reg [1:0]  state_ff;
    reg [62:0] shift_ff;   // {bcd[35:0], bin[26:0]}
    reg [4:0]  cnt_ff;     // iteration counter (0-26)

    // -----------------------------------------------------------------------
    // Combinational: add-3 correction on all 9 BCD digits, then shift left
    // -----------------------------------------------------------------------
    wire [35:0] bcd_cur = shift_ff[62:27];
    wire [35:0] bcd_adj = {adj(bcd_cur[35:32]),
                           adj(bcd_cur[31:28]), adj(bcd_cur[27:24]),
                           adj(bcd_cur[23:20]), adj(bcd_cur[19:16]),
                           adj(bcd_cur[15:12]), adj(bcd_cur[11:8]),
                           adj(bcd_cur[7:4]),   adj(bcd_cur[3:0])};
    wire [62:0] shifted = {bcd_adj[34:0], shift_ff[26:0], 1'b0};

    // -----------------------------------------------------------------------
    // Next-state signals
    // -----------------------------------------------------------------------
    reg [1:0]  state_next;
    reg [62:0] shift_next;
    reg [4:0]  cnt_next;
    reg [35:0] bcd_out_next;
    reg        valid_next;

    // -----------------------------------------------------------------------
    // Combinational next-state logic
    // -----------------------------------------------------------------------
    always @(*) begin
        if (!rst_n) begin
            state_next   = S_IDLE;
            shift_next   = 63'd0;
            cnt_next     = 5'd0;
            bcd_out_next = 36'd0;
            valid_next   = 1'b0;
        end else begin
            // Defaults: hold
            state_next   = state_ff;
            shift_next   = shift_ff;
            cnt_next     = cnt_ff;
            bcd_out_next = bcd_out_ff;
            valid_next   = 1'b0;

            case (state_ff)

                S_IDLE: begin
                    if (start) begin
                        shift_next = {36'd0, bin_in};
                        cnt_next   = 5'd0;
                        state_next = S_CALC;
                    end
                end

                S_CALC: begin
                    shift_next = shifted;
                    if (cnt_ff == 5'd26) begin
                        state_next = S_DONE;
                    end else begin
                        cnt_next = cnt_ff + 5'd1;
                    end
                end

                S_DONE: begin
                    bcd_out_next = shift_ff[62:27];
                    valid_next   = 1'b1;
                    state_next   = S_IDLE;
                end

                default: state_next = S_IDLE;

            endcase
        end
    end

    // -----------------------------------------------------------------------
    // Sequential block — flops only
    // -----------------------------------------------------------------------
    always @(posedge clk) begin
        state_ff   <= state_next;
        shift_ff   <= shift_next;
        cnt_ff     <= cnt_next;
        bcd_out_ff <= bcd_out_next;
        valid_ff   <= valid_next;
    end

endmodule
