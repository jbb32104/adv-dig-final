// prime_engine.v
// 6k+/-1 trial division FSM for prime number testing.
// 7 states: IDLE, CHECK_2_3, WAIT_DIV3, INIT_K, TEST_KM1, TEST_KP1, DONE.
// Instantiates divider.v as u_div for multi-cycle remainder computation.
// CSEE 4280 compliant: two always blocks, _ff suffix on all FFs, no for loops.

module prime_engine #(
    parameter WIDTH = 27
) (
    input  wire             clk,
    input  wire             rst,
    input  wire             start,
    input  wire [WIDTH-1:0] candidate,
    output wire             done_ff,
    output wire             is_prime_ff,
    output wire             busy_ff
);

    // -----------------------------------------------------------------------
    // State encoding (3-bit, 7 states)
    // -----------------------------------------------------------------------
    localparam [2:0]
        IDLE      = 3'd0,
        CHECK_2_3 = 3'd1,
        WAIT_DIV3 = 3'd2,
        INIT_K    = 3'd3,
        TEST_KM1  = 3'd4,
        TEST_KP1  = 3'd5,
        DONE      = 3'd6;

    // -----------------------------------------------------------------------
    // Internal flip-flop registers (all _ff suffix, driven in posedge block)
    // -----------------------------------------------------------------------
    reg [2:0]       state_ff;
    reg [WIDTH-1:0] candidate_ff;
    reg [WIDTH-1:0] d_ff;
    reg [WIDTH-1:0] k_ff;
    reg             is_prime_result_ff;
    reg             done_out_ff;
    reg             div_start_ff;

    // -----------------------------------------------------------------------
    // Combinational signals (no _ff suffix, driven in always @(*) block)
    // -----------------------------------------------------------------------
    reg [2:0]       next_state;
    reg [WIDTH-1:0] next_candidate;
    reg [WIDTH-1:0] next_d;
    reg [WIDTH-1:0] next_k;
    reg             next_is_prime_result;
    reg             next_done_out;
    reg             div_start;

    // -----------------------------------------------------------------------
    // Bound check: d*d > candidate (uses DSP48 inference)
    // -----------------------------------------------------------------------
    wire [2*WIDTH-1:0] d_squared;
    assign d_squared = d_ff * d_ff;
    wire bound_exceeded;
    assign bound_exceeded = (d_squared > {{WIDTH{1'b0}}, candidate_ff});

    // -----------------------------------------------------------------------
    // Divider instance
    // -----------------------------------------------------------------------
    wire             div_done;
    wire [WIDTH-1:0] div_remainder;
    wire             div_busy;

    divider #(.WIDTH(WIDTH)) u_div (
        .clk         (clk),
        .rst         (rst),
        .start       (div_start),      // combinational -- divider sees start on same cycle
        .dividend    (candidate_ff),
        .divisor     (next_d),         // next_d: combinational, so divider latches updated d on same cycle as div_start
        .busy_ff     (div_busy),
        .done_ff     (div_done),
        .dbz_ff      (),               // unused: divisor is never 0 in our usage
        .quotient_ff (),               // unused: only remainder needed
        .remainder_ff(div_remainder)
    );

    // -----------------------------------------------------------------------
    // Sequential block: non-blocking assignments only (INFRA-04)
    // Reset is synchronous (checked inside posedge block per INFRA-06)
    // -----------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            state_ff           <= IDLE;
            candidate_ff       <= {WIDTH{1'b0}};
            d_ff               <= {WIDTH{1'b0}};
            k_ff               <= {WIDTH{1'b0}};
            is_prime_result_ff <= 1'b0;
            done_out_ff        <= 1'b0;
            div_start_ff       <= 1'b0;
        end else begin
            state_ff           <= next_state;
            candidate_ff       <= next_candidate;
            d_ff               <= next_d;
            k_ff               <= next_k;
            is_prime_result_ff <= next_is_prime_result;
            done_out_ff        <= next_done_out;
            div_start_ff       <= div_start;
        end
    end

    // -----------------------------------------------------------------------
    // Combinational block: blocking assignments only (INFRA-04)
    // All next_* signals defaulted at top to avoid latches (INFRA-07)
    // -----------------------------------------------------------------------
    always @(*) begin
        // Defaults: hold current registered values
        next_state           = state_ff;
        next_candidate       = candidate_ff;
        next_d               = d_ff;
        next_k               = k_ff;
        next_is_prime_result = is_prime_result_ff;
        next_done_out        = 1'b0;   // done pulses one cycle; default off
        div_start            = 1'b0;

        case (state_ff)

            IDLE: begin
                if (start) begin
                    next_state     = CHECK_2_3;
                    next_candidate = candidate;
                end else begin
                    next_state = IDLE;
                end
            end

            CHECK_2_3: begin
                if (candidate_ff <= {{WIDTH-1{1'b0}}, 1'b1}) begin
                    // 0 or 1: not prime
                    next_is_prime_result = 1'b0;
                    next_state           = DONE;
                end else if (candidate_ff == {{WIDTH-2{1'b0}}, 2'd2}) begin
                    // candidate == 2: prime
                    next_is_prime_result = 1'b1;
                    next_state           = DONE;
                end else if (candidate_ff == {{WIDTH-2{1'b0}}, 2'd3}) begin
                    // candidate == 3: prime
                    next_is_prime_result = 1'b1;
                    next_state           = DONE;
                end else if (candidate_ff[0] == 1'b0) begin
                    // even and > 2: not prime
                    next_is_prime_result = 1'b0;
                    next_state           = DONE;
                end else begin
                    // Odd candidate > 3: check divisibility by 3 via divider
                    next_d     = {{WIDTH-2{1'b0}}, 2'd3};
                    div_start  = 1'b1;
                    next_state = WAIT_DIV3;
                end
            end

            WAIT_DIV3: begin
                if (div_done) begin
                    if (div_remainder == {WIDTH{1'b0}}) begin
                        // Divisible by 3: not prime (unless candidate==3, already handled)
                        next_is_prime_result = 1'b0;
                        next_state           = DONE;
                    end else begin
                        // Not divisible by 3: proceed to 6k+/-1 loop
                        next_k     = {{WIDTH-1{1'b0}}, 1'b1};  // k = 1
                        next_d     = {{WIDTH-3{1'b0}}, 3'd5};  // d = 6*1 - 1 = 5
                        next_state = INIT_K;
                    end
                end else begin
                    next_state = WAIT_DIV3;
                end
            end

            INIT_K: begin
                if (bound_exceeded) begin
                    // d*d > candidate: no more divisors to check, candidate is prime
                    next_is_prime_result = 1'b1;
                    next_state           = DONE;
                end else begin
                    // Start division: candidate / d (where d = 6k-1)
                    div_start  = 1'b1;
                    next_state = TEST_KM1;
                end
            end

            TEST_KM1: begin
                if (div_done) begin
                    if (div_remainder == {WIDTH{1'b0}}) begin
                        // Divisible by 6k-1: not prime
                        next_is_prime_result = 1'b0;
                        next_state           = DONE;
                    end else begin
                        // Switch to 6k+1 = d + 2
                        next_d     = d_ff + {{WIDTH-2{1'b0}}, 2'd2};
                        div_start  = 1'b1;
                        next_state = TEST_KP1;
                    end
                end else begin
                    next_state = TEST_KM1;
                end
            end

            TEST_KP1: begin
                if (div_done) begin
                    if (div_remainder == {WIDTH{1'b0}}) begin
                        // Divisible by 6k+1: not prime
                        next_is_prime_result = 1'b0;
                        next_state           = DONE;
                    end else begin
                        // Advance to next pair: k = k+1, d = 6k+1 + 4 = next 6(k+1)-1
                        next_k     = k_ff + {{WIDTH-1{1'b0}}, 1'b1};
                        next_d     = d_ff + {{WIDTH-3{1'b0}}, 3'd4};
                        next_state = INIT_K;
                    end
                end else begin
                    next_state = TEST_KP1;
                end
            end

            DONE: begin
                // done_out_ff was set when we transitioned here; pulse it
                next_done_out = 1'b1;
                next_state    = IDLE;
            end

            default: begin
                // Unreachable: return to IDLE safely (INFRA-07)
                next_state = IDLE;
            end

        endcase
    end

    // -----------------------------------------------------------------------
    // Output assignments
    // -----------------------------------------------------------------------
    assign done_ff     = done_out_ff;
    assign is_prime_ff = is_prime_result_ff;
    assign busy_ff     = (state_ff != IDLE) && (state_ff != DONE);

endmodule
