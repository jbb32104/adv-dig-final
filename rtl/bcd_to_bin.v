`timescale 1ns / 1ps

// BCD-to-binary converter using 7 DSP multipliers + looping accumulator.
//
// Converts 8 BCD digits to a 27-bit binary value:
//   value = d0 + d1*10 + d2*100 + d3*1000 + d4*10000
//         + d5*100000 + d6*1000000 + d7*10000000
//
// All 7 multiplications execute in parallel using DSP48E1 slices
// (one registered multiply each). The looping accumulator adds one
// product per clock cycle over 8 cycles.
//
// Latency: 10 clock cycles from start pulse to valid output.
// Max input:  99,999,999 (8 digits of 9)
// Max output: 27'd99_999_999 = 27'h5F5E0FF (fits in 27 bits)
//
// Clock domain: clk (100 MHz).

module bcd_to_bin (
    input  wire        clk,
    input  wire        rst_n,

    input  wire [31:0] bcd_digits,    // 8 BCD digits: d7[31:28] .. d0[3:0]
    input  wire        start,          // pulse to begin conversion

    output reg  [26:0] bin_value_ff,   // binary result (held until next conversion)
    output reg         valid_ff        // 1-cycle pulse when result is ready
);

    // -----------------------------------------------------------------------
    // Latched digit copies (captured on start)
    // -----------------------------------------------------------------------
    reg [3:0] d0_ff, d1_ff, d2_ff, d3_ff, d4_ff, d5_ff, d6_ff, d7_ff;

    // -----------------------------------------------------------------------
    // DSP multiply outputs — registered pipeline stage.
    // (* use_dsp = "yes" *) encourages Vivado to map these to DSP48E1.
    // Each multiplies a 4-bit digit by a constant power of 10.
    // -----------------------------------------------------------------------
    (* use_dsp = "yes" *) reg [27:0] p1_ff;
    (* use_dsp = "yes" *) reg [27:0] p2_ff;
    (* use_dsp = "yes" *) reg [27:0] p3_ff;
    (* use_dsp = "yes" *) reg [27:0] p4_ff;
    (* use_dsp = "yes" *) reg [27:0] p5_ff;
    (* use_dsp = "yes" *) reg [27:0] p6_ff;
    (* use_dsp = "yes" *) reg [27:0] p7_ff;

    // -----------------------------------------------------------------------
    // Accumulator FSM
    //   step 0:  IDLE — wait for start
    //   step 1:  MULT — one cycle for DSP pipeline to register products
    //   step 2:  acc = d0
    //   step 3:  acc += p1 (d1*10)
    //   step 4:  acc += p2 (d2*100)
    //   step 5:  acc += p3 (d3*1000)
    //   step 6:  acc += p4 (d4*10000)
    //   step 7:  acc += p5 (d5*100000)
    //   step 8:  acc += p6 (d6*1000000)
    //   step 9:  acc += p7 (d7*10000000)
    //   step 10: DONE — output result
    // -----------------------------------------------------------------------
    reg [3:0]  step_ff;
    reg [26:0] acc_ff;

    // -----------------------------------------------------------------------
    // Next-state signals
    // -----------------------------------------------------------------------
    reg [3:0]  d0_next, d1_next, d2_next, d3_next;
    reg [3:0]  d4_next, d5_next, d6_next, d7_next;
    reg [27:0] p1_next, p2_next, p3_next, p4_next;
    reg [27:0] p5_next, p6_next, p7_next;
    reg [3:0]  step_next;
    reg [26:0] acc_next;
    reg [26:0] bin_value_next;
    reg        valid_next;

    always @(*) begin
        if (!rst_n) begin
            d0_next = 4'd0; d1_next = 4'd0; d2_next = 4'd0; d3_next = 4'd0;
            d4_next = 4'd0; d5_next = 4'd0; d6_next = 4'd0; d7_next = 4'd0;
            p1_next = 28'd0; p2_next = 28'd0; p3_next = 28'd0; p4_next = 28'd0;
            p5_next = 28'd0; p6_next = 28'd0; p7_next = 28'd0;
            step_next      = 4'd0;
            acc_next       = 27'd0;
            bin_value_next = 27'd0;
            valid_next     = 1'b0;
        end else begin
            // Defaults: hold
            d0_next = d0_ff; d1_next = d1_ff; d2_next = d2_ff; d3_next = d3_ff;
            d4_next = d4_ff; d5_next = d5_ff; d6_next = d6_ff; d7_next = d7_ff;
            p1_next = p1_ff; p2_next = p2_ff; p3_next = p3_ff; p4_next = p4_ff;
            p5_next = p5_ff; p6_next = p6_ff; p7_next = p7_ff;
            step_next      = step_ff;
            acc_next       = acc_ff;
            bin_value_next = bin_value_ff;
            valid_next     = 1'b0;

            case (step_ff)

                4'd0: begin // IDLE
                    if (start) begin
                        // Latch digits
                        d0_next = bcd_digits[3:0];
                        d1_next = bcd_digits[7:4];
                        d2_next = bcd_digits[11:8];
                        d3_next = bcd_digits[15:12];
                        d4_next = bcd_digits[19:16];
                        d5_next = bcd_digits[23:20];
                        d6_next = bcd_digits[27:24];
                        d7_next = bcd_digits[31:28];
                        // Kick off DSP multiplies (products registered next cycle)
                        p1_next = bcd_digits[7:4]   * 28'd10;
                        p2_next = bcd_digits[11:8]  * 28'd100;
                        p3_next = bcd_digits[15:12] * 28'd1000;
                        p4_next = bcd_digits[19:16] * 28'd10000;
                        p5_next = bcd_digits[23:20] * 28'd100000;
                        p6_next = bcd_digits[27:24] * 28'd1000000;
                        p7_next = bcd_digits[31:28] * 28'd10000000;
                        step_next = 4'd1;
                    end
                end

                4'd1: begin // MULT — products now registered, start accumulating
                    acc_next  = {23'd0, d0_ff};
                    step_next = 4'd2;
                end

                4'd2:  begin acc_next = acc_ff + p1_ff[26:0]; step_next = 4'd3;  end
                4'd3:  begin acc_next = acc_ff + p2_ff[26:0]; step_next = 4'd4;  end
                4'd4:  begin acc_next = acc_ff + p3_ff[26:0]; step_next = 4'd5;  end
                4'd5:  begin acc_next = acc_ff + p4_ff[26:0]; step_next = 4'd6;  end
                4'd6:  begin acc_next = acc_ff + p5_ff[26:0]; step_next = 4'd7;  end
                4'd7:  begin acc_next = acc_ff + p6_ff[26:0]; step_next = 4'd8;  end
                4'd8:  begin acc_next = acc_ff + p7_ff[26:0]; step_next = 4'd9;  end

                4'd9: begin // DONE
                    bin_value_next = acc_ff;
                    valid_next     = 1'b1;
                    step_next      = 4'd0;
                end

                default: step_next = 4'd0;

            endcase
        end
    end

    // -----------------------------------------------------------------------
    // Sequential block
    // -----------------------------------------------------------------------
    always @(posedge clk) begin
        d0_ff <= d0_next; d1_ff <= d1_next; d2_ff <= d2_next; d3_ff <= d3_next;
        d4_ff <= d4_next; d5_ff <= d5_next; d6_ff <= d6_next; d7_ff <= d7_next;
        p1_ff <= p1_next; p2_ff <= p2_next; p3_ff <= p3_next; p4_ff <= p4_next;
        p5_ff <= p5_next; p6_ff <= p6_next; p7_ff <= p7_next;
        step_ff      <= step_next;
        acc_ff       <= acc_next;
        bin_value_ff <= bin_value_next;
        valid_ff     <= valid_next;
    end

endmodule
