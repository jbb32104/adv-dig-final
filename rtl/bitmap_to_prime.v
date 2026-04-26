`timescale 1ns / 1ps

// Bitmap-to-prime converter.
// Scans a 128-bit DDR2 bitmap word one bit per cycle.
// For each set bit, outputs the corresponding prime number.
//
// Mapping:
//   bitmap_type = 0 (6k-1): prime = 6*k - 1
//   bitmap_type = 1 (6k+1): prime = 6*k + 1
//
// k = base_k + bit_position, where base_k is the k value for bit 0
// of the loaded word. For the first DDR2 word base_k = 1, for the
// second base_k = 129, etc.
//
// Interface:
//   load + bitmap_data: load a new 128-bit word to scan
//   prime_out / prime_valid: outputs one prime per cycle for each set bit
//   word_done: pulses when all 128 bits have been scanned
//   busy: high while scanning

module bitmap_to_prime #(
    parameter WIDTH = 27
) (
    input  wire              clk,
    input  wire              rst_n,
    // Control
    input  wire              load,          // pulse: latch bitmap_data and begin scan
    input  wire [127:0]      bitmap_data,   // 128-bit word from DDR2
    input  wire [WIDTH-1:0]  base_k,        // k value for bit 0 of this word
    input  wire              bitmap_type,   // 0 = 6k-1, 1 = 6k+1
    // Output
    output reg  [WIDTH-1:0]  prime_out_ff,  // prime number value
    output reg               prime_valid_ff,// pulse: prime_out_ff is valid this cycle
    output reg               word_done_ff,  // pulse: finished scanning all 128 bits
    output reg               busy_ff        // high while scanning
);

    // -----------------------------------------------------------------------
    // State
    // -----------------------------------------------------------------------
    localparam [1:0] S_IDLE = 2'd0,
                     S_SCAN = 2'd1,
                     S_DONE = 2'd2;

    reg [1:0]        state_ff;
    reg [127:0]      shift_reg_ff;    // bitmap being scanned (shifts right)
    reg [6:0]        bit_idx_ff;      // 0..127: current bit position
    reg [WIDTH-1:0]  cur_k_ff;        // k value for current bit
    reg              type_ff;         // latched bitmap_type

    // Next-state
    reg [1:0]        next_state;
    reg [127:0]      next_shift_reg;
    reg [6:0]        next_bit_idx;
    reg [WIDTH-1:0]  next_cur_k;
    reg              next_type;
    reg [WIDTH-1:0]  next_prime_out;
    reg              next_prime_valid;
    reg              next_word_done;
    reg              next_busy;

    // -----------------------------------------------------------------------
    // k-to-prime conversion: 6*k +/- 1
    // 6*k = (k << 2) + (k << 1)  — no multiplier needed
    // -----------------------------------------------------------------------
    wire [WIDTH-1:0] six_k = (cur_k_ff << 2) + (cur_k_ff << 1);

    // -----------------------------------------------------------------------
    // Combinational logic
    // -----------------------------------------------------------------------
    always @(*) begin
        next_state       = state_ff;
        next_shift_reg   = shift_reg_ff;
        next_bit_idx     = bit_idx_ff;
        next_cur_k       = cur_k_ff;
        next_type        = type_ff;
        next_prime_out   = prime_out_ff;
        next_prime_valid = 1'b0;
        next_word_done   = 1'b0;
        next_busy        = 1'b0;

        if (!rst_n) begin
            next_state     = S_IDLE;
            next_shift_reg = 128'd0;
            next_bit_idx   = 7'd0;
            next_cur_k     = {WIDTH{1'b0}};
            next_type      = 1'b0;
            next_prime_out = {WIDTH{1'b0}};
        end else begin
            case (state_ff)

                S_IDLE: begin
                    if (load) begin
                        next_shift_reg = bitmap_data;
                        next_cur_k     = base_k;
                        next_bit_idx   = 7'd0;
                        next_type      = bitmap_type;
                        next_state     = S_SCAN;
                        next_busy      = 1'b1;
                    end
                end

                S_SCAN: begin
                    next_busy = 1'b1;

                    // Check LSB of shift register
                    if (shift_reg_ff[0]) begin
                        // This k is prime — output the value
                        if (type_ff)
                            next_prime_out = six_k + {{WIDTH-1{1'b0}}, 1'b1};  // 6k+1
                        else
                            next_prime_out = six_k - {{WIDTH-1{1'b0}}, 1'b1};  // 6k-1
                        next_prime_valid = 1'b1;
                    end

                    // Advance to next bit
                    if (bit_idx_ff == 7'd127) begin
                        // Last bit — done with this word
                        next_state = S_DONE;
                    end else begin
                        next_shift_reg = {1'b0, shift_reg_ff[127:1]};
                        next_bit_idx   = bit_idx_ff + 7'd1;
                        next_cur_k     = cur_k_ff + {{WIDTH-1{1'b0}}, 1'b1};
                    end
                end

                S_DONE: begin
                    next_word_done = 1'b1;
                    next_state     = S_IDLE;
                end

                default: next_state = S_IDLE;

            endcase
        end
    end

    // -----------------------------------------------------------------------
    // Flop registers
    // -----------------------------------------------------------------------
    always @(posedge clk) begin
        state_ff       <= next_state;
        shift_reg_ff   <= next_shift_reg;
        bit_idx_ff     <= next_bit_idx;
        cur_k_ff       <= next_cur_k;
        type_ff        <= next_type;
        prime_out_ff   <= next_prime_out;
        prime_valid_ff <= next_prime_valid;
        word_done_ff   <= next_word_done;
        busy_ff        <= next_busy;
    end

endmodule
