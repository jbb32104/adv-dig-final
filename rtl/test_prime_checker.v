`timescale 1ns / 1ps

// TEST mode: reads 6k+1 and 6k-1 bitmaps from DDR2, extracts primes
// in ascending order, and compares against a ROM of the first 100 primes.
//
// Prime ordering: 2, 3, then for k=1,2,...: 6k-1 (if set), 6k+1 (if set).
// This naturally produces ascending order because 6k-1 < 6k+1 < 6(k+1)-1.
//
// DDR2 read interface follows the same protocol as vga_reader:
//   Hold rd_req + rd_addr until rd_grant pulses, then wait for rd_data_valid.
//
// For the first 100 primes (up to 541), only k=1..90 is needed,
// which fits in a single 128-bit DDR2 word per bitmap. The FSM
// generalises to multiple words for larger test sets.
//
// Results:
//   pass        — all ROM primes matched
//   fail        — at least one mismatch (first mismatch captured)
//   match_count — how many primes matched before done/mismatch

module test_prime_checker #(
    parameter WIDTH      = 27,
    parameter NUM_PRIMES = 100
) (
    input  wire        clk,        // ui_clk domain (same as mem_arbiter)
    input  wire        rst_n,
    input  wire        init_calib_complete,

    // Control
    input  wire        start,      // pulse: begin test
    output reg         done_ff,
    output reg         pass_ff,    // 1 = all matched, 0 = mismatch found
    output reg  [6:0]  match_count_ff,   // 0..100
    output reg  [WIDTH-1:0] expected_ff, // first mismatched expected value
    output reg  [WIDTH-1:0] got_ff,      // first mismatched actual value
    output wire [7:0] dbg_minus_b0,    // bm_minus[7:0]
    output wire [7:0] dbg_minus_b1,    // bm_minus[15:8]
    output wire [7:0] dbg_minus_b2,    // bm_minus[23:16]
    output wire [7:0] dbg_minus_b3,    // bm_minus[31:24]
    output wire [7:0] dbg_plus_b0,     // bm_plus[7:0]

    // DDR2 read interface (directly to mem_arbiter read port)
    output reg         rd_req_ff,
    output reg  [26:0] rd_addr_ff,
    input  wire        rd_grant,
    input  wire [127:0] rd_data,
    input  wire        rd_data_valid
);

    // -----------------------------------------------------------------------
    // DDR2 bitmap base addresses (must match mem_arbiter)
    // -----------------------------------------------------------------------
    localparam [26:0] BASE_PLUS  = 27'h000_0000;
    localparam [26:0] BASE_MINUS = 27'h028_0000;

    // -----------------------------------------------------------------------
    // ROM: first 100 primes loaded from .mem file
    // -----------------------------------------------------------------------
    reg [WIDTH-1:0] prime_rom [0:NUM_PRIMES-1];
    initial $readmemh("primes_100.mem", prime_rom);

    // -----------------------------------------------------------------------
    // FSM states
    // -----------------------------------------------------------------------
    localparam [3:0]
        S_IDLE       = 4'd0,
        S_RD_MINUS   = 4'd1,  // issue DDR2 read for minus bitmap word
        S_WAIT_MINUS = 4'd2,  // wait for rd_data_valid
        S_RD_PLUS    = 4'd3,  // issue DDR2 read for plus bitmap word
        S_WAIT_PLUS  = 4'd4,  // wait for rd_data_valid
        S_CHECK_2    = 4'd5,  // compare hardcoded prime 2
        S_CHECK_3    = 4'd6,  // compare hardcoded prime 3
        S_SCAN_MINUS = 4'd7,  // check 6k-1 bit for current k
        S_SCAN_PLUS  = 4'd8,  // check 6k+1 bit for current k
        S_ADVANCE_K  = 4'd9,  // increment k, possibly load next DDR2 word
        S_PASS       = 4'd10,
        S_FAIL       = 4'd11;

    // -----------------------------------------------------------------------
    // State registers
    // -----------------------------------------------------------------------
    reg [3:0]        state_ff;
    reg [127:0]      bm_minus_ff;       // current 128-bit minus bitmap word
    reg [127:0]      bm_plus_ff;        // current 128-bit plus bitmap word
    reg [6:0]        rom_idx_ff;        // index into prime_rom (0..99)
    reg [6:0]        bit_idx_ff;        // bit position within 128-bit word (0..127)
    reg [WIDTH-1:0]  cur_k_ff;          // current k value
    reg [26:0]       addr_minus_ff;     // next DDR2 read address for minus
    reg [26:0]       addr_plus_ff;      // next DDR2 read address for plus
    reg [WIDTH-1:0]  last_prime_ff;     // last successfully matched prime

    // -----------------------------------------------------------------------
    // Next-state signals
    // -----------------------------------------------------------------------
    reg [3:0]        next_state;
    reg [127:0]      next_bm_minus;
    reg [127:0]      next_bm_plus;
    reg [6:0]        next_rom_idx;
    reg [6:0]        next_bit_idx;
    reg [WIDTH-1:0]  next_cur_k;
    reg [26:0]       next_addr_minus;
    reg [26:0]       next_addr_plus;
    reg              next_done;
    reg              next_pass;
    reg [6:0]        next_match_count;
    reg [WIDTH-1:0]  next_expected;
    reg [WIDTH-1:0]  next_got;
    reg [WIDTH-1:0]  next_last_prime;
    reg              next_rd_req;
    reg [26:0]       next_rd_addr;

    // -----------------------------------------------------------------------
    // k-to-prime conversion (shift-add, no multiplier)
    // -----------------------------------------------------------------------
    wire [WIDTH-1:0] six_k     = (cur_k_ff << 2) + (cur_k_ff << 1);
    wire [WIDTH-1:0] prime_km1 = six_k - {{WIDTH-1{1'b0}}, 1'b1};  // 6k-1
    wire [WIDTH-1:0] prime_kp1 = six_k + {{WIDTH-1{1'b0}}, 1'b1};  // 6k+1

    // Current bitmap bits for position bit_idx
    wire minus_bit = bm_minus_ff[bit_idx_ff];
    wire plus_bit  = bm_plus_ff[bit_idx_ff];

    // ROM lookup
    wire [WIDTH-1:0] rom_expected = prime_rom[rom_idx_ff];

    // -----------------------------------------------------------------------
    // Combinational logic
    // -----------------------------------------------------------------------
    always @(*) begin
        // Defaults: hold
        next_state       = state_ff;
        next_bm_minus    = bm_minus_ff;
        next_bm_plus     = bm_plus_ff;
        next_rom_idx     = rom_idx_ff;
        next_bit_idx     = bit_idx_ff;
        next_cur_k       = cur_k_ff;
        next_addr_minus  = addr_minus_ff;
        next_addr_plus   = addr_plus_ff;
        next_done        = done_ff;
        next_pass        = pass_ff;
        next_match_count = match_count_ff;
        next_expected    = expected_ff;
        next_got         = got_ff;
        next_last_prime  = last_prime_ff;
        next_rd_req      = 1'b0;
        next_rd_addr     = rd_addr_ff;

        if (!rst_n) begin
            next_state       = S_IDLE;
            next_bm_minus    = 128'd0;
            next_bm_plus     = 128'd0;
            next_rom_idx     = 7'd0;
            next_bit_idx     = 7'd0;
            next_cur_k       = {WIDTH{1'b0}};
            next_addr_minus  = BASE_MINUS;
            next_addr_plus   = BASE_PLUS;
            next_done        = 1'b0;
            next_pass        = 1'b0;
            next_match_count = 7'd0;
            next_expected    = {WIDTH{1'b0}};
            next_got         = {WIDTH{1'b0}};
            next_last_prime  = {WIDTH{1'b0}};
            next_rd_addr     = 27'd0;
        end else begin
            case (state_ff)

                S_IDLE: begin
                    if (start && init_calib_complete) begin
                        next_rom_idx     = 7'd0;
                        next_bit_idx     = 7'd0;
                        next_cur_k       = {{WIDTH-1{1'b0}}, 1'b1};  // k=1
                        next_addr_minus  = BASE_MINUS;
                        next_addr_plus   = BASE_PLUS;
                        next_done        = 1'b0;
                        next_pass        = 1'b0;
                        next_match_count = 7'd0;
                        next_expected    = {WIDTH{1'b0}};
                        next_got         = {WIDTH{1'b0}};
                        next_last_prime  = {WIDTH{1'b0}};
                        // Start by reading the first minus bitmap word
                        next_rd_req      = 1'b1;
                        next_rd_addr     = BASE_MINUS;
                        next_state       = S_RD_MINUS;
                    end
                end

                // ---- Read minus bitmap word from DDR2 ----
                S_RD_MINUS: begin
                    next_rd_req  = 1'b1;
                    next_rd_addr = addr_minus_ff;
                    if (rd_grant) begin
                        next_rd_req = 1'b0;
                        next_state  = S_WAIT_MINUS;
                    end
                end

                S_WAIT_MINUS: begin
                    if (rd_data_valid) begin
                        // Vivado async FIFO (32→128) packs MSW-first:
                        //   W0→[127:96], W1→[95:64], W2→[63:32], W3→[31:0]
                        // Swap so bit 0 = k=1 (W0 bit 0) as the scanner expects.
                        next_bm_minus    = {rd_data[31:0], rd_data[63:32],
                                            rd_data[95:64], rd_data[127:96]};
                        next_addr_minus  = addr_minus_ff + 27'd16;
                        // Now read the plus bitmap word
                        next_rd_req      = 1'b1;
                        next_rd_addr     = addr_plus_ff;
                        next_state       = S_RD_PLUS;
                    end
                end

                // ---- Read plus bitmap word from DDR2 ----
                S_RD_PLUS: begin
                    next_rd_req  = 1'b1;
                    next_rd_addr = addr_plus_ff;
                    if (rd_grant) begin
                        next_rd_req = 1'b0;
                        next_state  = S_WAIT_PLUS;
                    end
                end

                S_WAIT_PLUS: begin
                    if (rd_data_valid) begin
                        // Same MSW-first swap as minus bitmap
                        next_bm_plus    = {rd_data[31:0], rd_data[63:32],
                                           rd_data[95:64], rd_data[127:96]};
                        next_addr_plus  = addr_plus_ff + 27'd16;
                        // Both words loaded — start checking
                        next_state      = S_CHECK_2;
                    end
                end

                // ---- Hardcoded primes 2 and 3 (not in bitmap) ----
                S_CHECK_2: begin
                    if (rom_expected == {{WIDTH-2{1'b0}}, 2'd2}) begin
                        next_match_count = match_count_ff + 7'd1;
                        next_rom_idx     = rom_idx_ff + 7'd1;
                        next_last_prime  = {{WIDTH-2{1'b0}}, 2'd2};
                        next_state       = S_CHECK_3;
                    end else begin
                        next_expected = rom_expected;
                        next_got      = {{WIDTH-2{1'b0}}, 2'd2};
                        next_state    = S_FAIL;
                    end
                end

                S_CHECK_3: begin
                    if (rom_expected == {{WIDTH-2{1'b0}}, 2'd3}) begin
                        next_match_count = match_count_ff + 7'd1;
                        next_rom_idx     = rom_idx_ff + 7'd1;
                        next_last_prime  = {{WIDTH-2{1'b0}}, 2'd3};
                        next_state       = S_SCAN_MINUS;
                    end else begin
                        next_expected = rom_expected;
                        next_got      = {{WIDTH-2{1'b0}}, 2'd3};
                        next_state    = S_FAIL;
                    end
                end

                // ---- Scan: check 6k-1 bit ----
                S_SCAN_MINUS: begin
                    if (minus_bit) begin
                        // This k has a prime in the 6k-1 family
                        if (rom_expected == prime_km1) begin
                            next_match_count = match_count_ff + 7'd1;
                            next_rom_idx     = rom_idx_ff + 7'd1;
                            next_last_prime  = prime_km1;
                            // Check if we've matched all ROM primes
                            if (rom_idx_ff == NUM_PRIMES - 1)
                                next_state = S_PASS;
                            else
                                next_state = S_SCAN_PLUS;
                        end else begin
                            next_expected = rom_expected;
                            next_got      = last_prime_ff;
                            next_state    = S_FAIL;
                        end
                    end else begin
                        // Bit not set — skip to plus
                        next_state = S_SCAN_PLUS;
                    end
                end

                // ---- Scan: check 6k+1 bit ----
                S_SCAN_PLUS: begin
                    if (plus_bit) begin
                        // This k has a prime in the 6k+1 family
                        if (rom_expected == prime_kp1) begin
                            next_match_count = match_count_ff + 7'd1;
                            next_rom_idx     = rom_idx_ff + 7'd1;
                            next_last_prime  = prime_kp1;
                            if (rom_idx_ff == NUM_PRIMES - 1)
                                next_state = S_PASS;
                            else
                                next_state = S_ADVANCE_K;
                        end else begin
                            next_expected = rom_expected;
                            next_got      = last_prime_ff;
                            next_state    = S_FAIL;
                        end
                    end else begin
                        // Bit not set — advance k
                        next_state = S_ADVANCE_K;
                    end
                end

                // ---- Advance to next k value ----
                S_ADVANCE_K: begin
                    if (bit_idx_ff == 7'd127) begin
                        // First 128-bit word covers k=1..128 (primes up to 769).
                        // All 100 ROM primes (up to 541) fit in this word.
                        // If we haven't matched all primes by now, fail.
                        next_expected = rom_expected;
                        next_got      = last_prime_ff;
                        next_state    = S_FAIL;
                    end else begin
                        next_bit_idx = bit_idx_ff + 7'd1;
                        next_cur_k   = cur_k_ff + {{WIDTH-1{1'b0}}, 1'b1};
                        next_state   = S_SCAN_MINUS;
                    end
                end

                S_PASS: begin
                    next_done = 1'b1;
                    next_pass = 1'b1;
                end

                S_FAIL: begin
                    next_done = 1'b1;
                    next_pass = 1'b0;
                end

                default: next_state = S_IDLE;

            endcase
        end
    end

    // -----------------------------------------------------------------------
    // Sequential block
    // -----------------------------------------------------------------------
    always @(posedge clk) begin
        state_ff       <= next_state;
        bm_minus_ff    <= next_bm_minus;
        bm_plus_ff     <= next_bm_plus;
        rom_idx_ff     <= next_rom_idx;
        bit_idx_ff     <= next_bit_idx;
        cur_k_ff       <= next_cur_k;
        addr_minus_ff  <= next_addr_minus;
        addr_plus_ff   <= next_addr_plus;
        done_ff        <= next_done;
        pass_ff        <= next_pass;
        match_count_ff <= next_match_count;
        expected_ff    <= next_expected;
        got_ff         <= next_got;
        last_prime_ff  <= next_last_prime;
        rd_req_ff      <= next_rd_req;
        rd_addr_ff     <= next_rd_addr;
    end

    // Debug: expose bitmap bytes
    assign dbg_minus_b0 = bm_minus_ff[7:0];
    assign dbg_minus_b1 = bm_minus_ff[15:8];
    assign dbg_minus_b2 = bm_minus_ff[23:16];
    assign dbg_minus_b3 = bm_minus_ff[31:24];
    assign dbg_plus_b0  = bm_plus_ff[7:0];

endmodule
