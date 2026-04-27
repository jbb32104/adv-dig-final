`timescale 1ns / 1ps

// TEST mode: for each prime from the SD card, verifies its bit is set
// in the DDR2 6k+/-1 bitmaps via direct lookup (no sequential scan).
//
// Primes 2 and 3 are hardcoded (not in bitmap) -- verified directly.
// For P > 3: computes k and family (6k+/-1) using a constant multiplier
// (division by 6), reads the corresponding DDR2 bitmap word, and
// checks the specific bit.
//
// Caches the last-read bitmap word per family to avoid redundant DDR2
// reads for consecutive primes in the same 128-bit word.
//
// DDR2 data endianness: Vivado async FIFO (32->128) packs MSW-first.
// Read data is word-swapped so bit 0 = k=1.
//
// Results:
//   pass        -- all SD primes found in bitmap
//   fail        -- first mismatch captured (expected_ff = SD prime)
//   match_count -- how many primes verified before done/mismatch

module test_prime_checker #(
    parameter WIDTH = 27
) (
    input  wire        clk,        // ui_clk domain (same as mem_arbiter)
    input  wire        rst_n,
    input  wire        init_calib_complete,

    // Control
    input  wire        start,      // pulse: begin test
    input  wire [WIDTH-1:0] check_limit, // highest candidate the engine computed
    output reg         done_ff,
    output reg         pass_ff,    // 1 = all matched, 0 = mismatch found
    output reg  [13:0] match_count_ff,   // 0..9999+
    output reg  [WIDTH-1:0] expected_ff, // SD prime that failed
    output reg  [WIDTH-1:0] got_ff,      // 0 = bit was not set in bitmap

    // SD prime handshake (ui_clk domain, from sd_prime_bridge)
    input  wire [31:0] sd_prime_data,
    input  wire        sd_prime_valid,
    output reg         sd_prime_consume_ff,
    input  wire        sd_prime_eof,

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

    // Division by 6 constant: ceil(2^32 / 6) = 715827883
    localparam [31:0] RECIP_6 = 32'd715827883;

    // -----------------------------------------------------------------------
    // FSM states
    // -----------------------------------------------------------------------
    localparam [3:0]
        S_IDLE        = 4'd0,
        S_WAIT_PRIME  = 4'd1,   // wait for SD prime data (or EOF)
        S_CLASSIFY    = 4'd2,   // determine family (6k+/-1) and k
        S_RD_BITMAP   = 4'd3,   // issue DDR2 read for bitmap word
        S_WAIT_BITMAP = 4'd4,   // wait for rd_data_valid
        S_CHECK_BIT   = 4'd5,   // verify the bitmap bit
        S_CONSUME     = 4'd6,   // signal bridge: prime consumed, fetch next
        S_PASS        = 4'd7,
        S_FAIL        = 4'd8;

    // -----------------------------------------------------------------------
    // State registers
    // -----------------------------------------------------------------------
    reg [3:0]        state_ff;
    reg [WIDTH-1:0]  cur_prime_ff;       // current SD prime being verified
    reg              is_minus_ff;        // 1 = 6k-1 family, 0 = 6k+1
    reg [6:0]        bit_pos_ff;         // bit position within 128-bit word
    reg [19:0]       word_idx_ff;        // which 128-bit DDR2 word

    // Bitmap cache (one entry, tagged by word_idx + family)
    reg [127:0]      cached_bm_ff;
    reg [19:0]       cached_word_idx_ff;
    reg              cached_is_minus_ff;
    reg              cache_valid_ff;



    // -----------------------------------------------------------------------
    // Division by 6: floor(P/6) = (P * RECIP_6) >> 32
    // Uses one DSP48 multiply in Vivado.
    // -----------------------------------------------------------------------
    wire [58:0] div6_prod = cur_prime_ff * RECIP_6;
    wire [26:0] div6_q    = div6_prod[58:32];           // floor(P/6)
    wire [26:0] six_q     = (div6_q << 2) + (div6_q << 1); // q * 6
    wire [26:0] div6_r    = cur_prime_ff - six_q;        // P mod 6

    // -----------------------------------------------------------------------
    // Family classification (combinational, from cur_prime_ff)
    // P = 6q + r.  r==5 -> minus family (6k-1), k = q+1
    //              r==1 -> plus family  (6k+1), k = q
    // -----------------------------------------------------------------------
    wire        classify_minus = (div6_r == 27'd5);
    wire [26:0] k_comb         = classify_minus ? (div6_q + 27'd1) : div6_q;
    wire [26:0] bit_index      = k_comb - 27'd1;        // 0-based bit position
    wire [19:0] word_idx_comb  = bit_index[26:7];        // which 128-bit word
    wire [6:0]  bit_pos_comb   = bit_index[6:0];         // bit within word

    // Cache hit check
    wire cache_hit = cache_valid_ff &&
                     (cached_word_idx_ff == word_idx_comb) &&
                     (cached_is_minus_ff == classify_minus);

    // DDR2 address for bitmap read
    wire [26:0] bitmap_base = classify_minus ? BASE_MINUS : BASE_PLUS;
    wire [26:0] bitmap_addr = bitmap_base + {3'd0, word_idx_comb, 4'b0000};

    // Bitmap bit extraction from cached word
    wire bitmap_bit = cached_bm_ff[bit_pos_ff];

    // -----------------------------------------------------------------------
    // Next-state signals
    // -----------------------------------------------------------------------
    reg [3:0]        next_state;
    reg [WIDTH-1:0]  next_cur_prime;
    reg              next_is_minus;
    reg [6:0]        next_bit_pos;
    reg [19:0]       next_word_idx;
    reg [127:0]      next_cached_bm;
    reg [19:0]       next_cached_word_idx;
    reg              next_cached_is_minus;
    reg              next_cache_valid;
    reg              next_done;
    reg              next_pass;
    reg [13:0]       next_match_count;
    reg [WIDTH-1:0]  next_expected;
    reg [WIDTH-1:0]  next_got;
    reg              next_consume;
    reg              next_rd_req;
    reg [26:0]       next_rd_addr;

    // -----------------------------------------------------------------------
    // Combinational logic
    // -----------------------------------------------------------------------
    always @(*) begin
        // Defaults: hold
        next_state           = state_ff;
        next_cur_prime       = cur_prime_ff;
        next_is_minus        = is_minus_ff;
        next_bit_pos         = bit_pos_ff;
        next_word_idx        = word_idx_ff;
        next_cached_bm       = cached_bm_ff;
        next_cached_word_idx = cached_word_idx_ff;
        next_cached_is_minus = cached_is_minus_ff;
        next_cache_valid     = cache_valid_ff;
        next_done            = done_ff;
        next_pass            = pass_ff;
        next_match_count     = match_count_ff;
        next_expected        = expected_ff;
        next_got             = got_ff;
        // Pulse signals default to 0
        next_consume         = 1'b0;
        next_rd_req          = 1'b0;
        next_rd_addr         = rd_addr_ff;

        if (!rst_n) begin
            next_state           = S_IDLE;
            next_cur_prime       = {WIDTH{1'b0}};
            next_is_minus        = 1'b0;
            next_bit_pos         = 7'd0;
            next_word_idx        = 20'd0;
            next_cached_bm       = 128'd0;
            next_cached_word_idx = 20'd0;
            next_cached_is_minus = 1'b0;
            next_cache_valid     = 1'b0;
            next_done            = 1'b0;
            next_pass            = 1'b0;
            next_match_count     = 14'd0;
            next_expected        = {WIDTH{1'b0}};
            next_got             = {WIDTH{1'b0}};
            next_rd_addr         = 27'd0;
        end else begin
            case (state_ff)

                S_IDLE: begin
                    if (start && init_calib_complete) begin
                        next_done         = 1'b0;
                        next_pass         = 1'b0;
                        next_match_count  = 14'd0;
                        next_expected     = {WIDTH{1'b0}};
                        next_got          = {WIDTH{1'b0}};
                        next_cache_valid  = 1'b0;
                        next_state        = S_WAIT_PRIME;
                    end
                end

                // ---- Wait for next SD prime (or EOF -> PASS) ----
                S_WAIT_PRIME: begin
                    if (sd_prime_eof) begin
                        next_state = S_PASS;
                    end else if (sd_prime_valid) begin
                        next_cur_prime = sd_prime_data[WIDTH-1:0];
                        next_state     = S_CLASSIFY;
                    end
                end

                // ---- Classify: primes 2,3 are hardcoded; others get bitmap lookup ----
                // If prime exceeds the engine's computed range, stop with PASS.
                S_CLASSIFY: begin
                    if (cur_prime_ff > check_limit) begin
                        // Beyond engine's range -- all in-range primes verified
                        next_state = S_PASS;
                    end else if (cur_prime_ff <= {{WIDTH-2{1'b0}}, 2'd3}) begin
                        // Primes 2 and 3: not in bitmap, always match
                        next_match_count = match_count_ff + 14'd1;
                        next_consume     = 1'b1;
                        next_state       = S_CONSUME;
                    end else if (div6_r != 27'd1 && div6_r != 27'd5) begin
                        // Not of the form 6k+/-1 — divisible by 2 or 3,
                        // so it can't be prime. Fail immediately.
                        next_expected = cur_prime_ff;
                        next_got      = {WIDTH{1'b0}};
                        next_state    = S_FAIL;
                    end else begin
                        // Register classification results for subsequent states
                        next_is_minus = classify_minus;
                        next_bit_pos  = bit_pos_comb;
                        next_word_idx = word_idx_comb;

                        if (cache_hit) begin
                            // Cache hit -- skip DDR2 read
                            next_state = S_CHECK_BIT;
                        end else begin
                            // Cache miss -- read from DDR2
                            next_rd_req  = 1'b1;
                            next_rd_addr = bitmap_addr;
                            next_state   = S_RD_BITMAP;
                        end
                    end
                end

                // ---- Issue DDR2 read, hold until grant ----
                S_RD_BITMAP: begin
                    next_rd_req  = 1'b1;
                    next_rd_addr = rd_addr_ff;
                    if (rd_grant) begin
                        next_rd_req = 1'b0;
                        next_state  = S_WAIT_BITMAP;
                    end
                end

                // ---- Wait for DDR2 data, update cache ----
                S_WAIT_BITMAP: begin
                    if (rd_data_valid) begin
                        // Endianness swap: MSW-first -> LSW-first
                        // so bit 0 = k=1 (first candidate in word)
                        next_cached_bm       = {rd_data[31:0], rd_data[63:32],
                                                 rd_data[95:64], rd_data[127:96]};
                        next_cached_word_idx = word_idx_ff;
                        next_cached_is_minus = is_minus_ff;
                        next_cache_valid     = 1'b1;
                        next_state           = S_CHECK_BIT;
                    end
                end

                // ---- Check the specific bit in the cached bitmap word ----
                S_CHECK_BIT: begin
                    if (bitmap_bit) begin
                        // Bit set -- prime verified in bitmap
                        next_match_count = match_count_ff + 14'd1;
                        next_consume     = 1'b1;
                        next_state       = S_CONSUME;
                    end else begin
                        // Bit not set -- SD says prime, DDR2 says not
                        next_expected = cur_prime_ff;
                        next_got      = {WIDTH{1'b0}};
                        next_state    = S_FAIL;
                    end
                end

                // ---- Consume pulse was registered; wait for bridge to fetch next ----
                S_CONSUME: begin
                    next_state = S_WAIT_PRIME;
                end

                S_PASS: begin
                    next_done  = 1'b1;
                    next_pass  = 1'b1;
                    next_state = S_IDLE;   // return to idle so next start is accepted
                end

                S_FAIL: begin
                    next_done  = 1'b1;
                    next_pass  = 1'b0;
                    next_state = S_IDLE;   // return to idle so next start is accepted
                end

                default: next_state = S_IDLE;

            endcase
        end
    end

    // -----------------------------------------------------------------------
    // Sequential block
    // -----------------------------------------------------------------------
    always @(posedge clk) begin
        state_ff             <= next_state;
        cur_prime_ff         <= next_cur_prime;
        is_minus_ff          <= next_is_minus;
        bit_pos_ff           <= next_bit_pos;
        word_idx_ff          <= next_word_idx;
        cached_bm_ff         <= next_cached_bm;
        cached_word_idx_ff   <= next_cached_word_idx;
        cached_is_minus_ff   <= next_cached_is_minus;
        cache_valid_ff       <= next_cache_valid;
        done_ff              <= next_done;
        pass_ff              <= next_pass;
        match_count_ff       <= next_match_count;
        expected_ff          <= next_expected;
        got_ff               <= next_got;
        sd_prime_consume_ff  <= next_consume;
        rd_req_ff            <= next_rd_req;
        rd_addr_ff           <= next_rd_addr;
    end

endmodule
