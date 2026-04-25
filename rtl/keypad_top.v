`timescale 1ns / 1ps

// Standalone keypad test top — wires column_driver + debounce + row_reader
// to a simple 7-segment decoder so you can verify each button press shows
// the correct hex value on the rightmost SSD digit.
//
// PMOD JA pin mapping (matches working reference):
//   Columns (outputs): c_0→JA9, c_1→JA3, c_2→JA10, c_3→JA4
//   Rows    (inputs):  row_0←JA7, row_1←JA1, row_2←JA8, row_3←JA2

module keypad_top (
    input  wire        clk,
    input  wire        cpu_rst_n,

    // PMOD JA
    input  wire        JA1,
    input  wire        JA2,
    output wire        JA3,
    output wire        JA4,
    input  wire        JA7,
    input  wire        JA8,
    output wire        JA9,
    output wire        JA10,

    // 7-segment display
    output reg  [6:0]  SEG,
    output wire [7:0]  AN,
    output wire        DP_n
);

    // =====================================================================
    // Reset synchronizer — keeps cpu_rst_n off the clock network
    // =====================================================================
    (* ASYNC_REG = "TRUE" *) reg rst_meta_ff, rst_sync_n;
    (* dont_touch = "true" *)  wire rst_pin = cpu_rst_n;
    always @(posedge clk) begin
        rst_meta_ff <= rst_pin;
        rst_sync_n  <= rst_meta_ff;
    end
    wire rst = ~rst_sync_n;

    // =====================================================================
    // Column driver
    // =====================================================================
    wire freeze;

    column_driver u_col_drv (
        .clk    (clk),
        .rst    (rst),
        .freeze (freeze),
        .c_0    (JA9),
        .c_1    (JA3),
        .c_2    (JA10),
        .c_3    (JA4)
    );

    // =====================================================================
    // Row debouncers
    // =====================================================================
    wire r0_clean, r1_clean, r2_clean, r3_clean;

    debounce #(.DEBOUNCE_CYCLES(1_000_000)) u_db_r0 (
        .clk(clk), .rst_n(rst_sync_n), .btn_in(JA7),
        .btn_state_ff(r0_clean), .rising_pulse_ff(), .falling_pulse_ff()
    );
    debounce #(.DEBOUNCE_CYCLES(1_000_000)) u_db_r1 (
        .clk(clk), .rst_n(rst_sync_n), .btn_in(JA1),
        .btn_state_ff(r1_clean), .rising_pulse_ff(), .falling_pulse_ff()
    );
    debounce #(.DEBOUNCE_CYCLES(1_000_000)) u_db_r2 (
        .clk(clk), .rst_n(rst_sync_n), .btn_in(JA8),
        .btn_state_ff(r2_clean), .rising_pulse_ff(), .falling_pulse_ff()
    );
    debounce #(.DEBOUNCE_CYCLES(1_000_000)) u_db_r3 (
        .clk(clk), .rst_n(rst_sync_n), .btn_in(JA2),
        .btn_state_ff(r3_clean), .rising_pulse_ff(), .falling_pulse_ff()
    );

    // =====================================================================
    // Row reader
    // =====================================================================
    wire [3:0] button;
    wire       button_valid;

    row_reader u_row_rdr (
        .clk             (clk),
        .rst             (rst),
        .row_0           (r0_clean),
        .row_1           (r1_clean),
        .row_2           (r2_clean),
        .row_3           (r3_clean),
        .c_0_ff          (JA9),
        .c_1_ff          (JA3),
        .c_2_ff          (JA10),
        .c_3_ff          (JA4),
        .button_ff       (button),
        .button_valid_ff (button_valid),
        .freeze_out      (freeze)
    );

    // =====================================================================
    // 7-segment decoder — rightmost digit only, active-low
    // Segment order matches XDC: SEG[6:0] = {g, f, e, d, c, b, a}
    // =====================================================================
    assign AN   = 8'b1111_1110;   // only digit 0 on
    assign DP_n = ~button_valid;  // DP lights when a valid press is detected

    always @(*) begin
        case (button)
            //                    gfedcba  (active-low)
            4'h0: SEG = 7'b1000000;
            4'h1: SEG = 7'b1111001;
            4'h2: SEG = 7'b0100100;
            4'h3: SEG = 7'b0110000;
            4'h4: SEG = 7'b0011001;
            4'h5: SEG = 7'b0010010;
            4'h6: SEG = 7'b0000010;
            4'h7: SEG = 7'b1111000;
            4'h8: SEG = 7'b0000000;
            4'h9: SEG = 7'b0010000;
            4'hA: SEG = 7'b0001000;
            4'hB: SEG = 7'b0000011;
            4'hC: SEG = 7'b1000110;
            4'hD: SEG = 7'b0100001;
            4'hE: SEG = 7'b0000110;
            4'hF: SEG = 7'b0001110;
            default: SEG = 7'b1111111;
        endcase
    end

endmodule
