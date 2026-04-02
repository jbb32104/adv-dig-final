`timescale 1ns / 1ps

// Mode dispatcher FSM for Prime Modes FSM project.
// 10 states: IDLE, MODE_SELECT, NUMBER_ENTRY, TIME_ENTRY, PRIME_RUN,
//            PRIME_FLUSH, PRIME_DONE, ISPRIME_ENTRY, ISPRIME_RUN, ISPRIME_DONE.
//
// Two independent prime_engine instances:
//   eng_plus  : tests 6k+1 candidates starting at k=1 (candidate=7), step +6 per k
//   eng_minus : tests 6k-1 candidates starting at k=1 (candidate=5), step +6 per k
//
// Candidates 2 and 3 are skipped in the bitmap (hardcoded prime at output layer).
// Each engine has a dedicated prime_accumulator fed via acc_plus_*/acc_minus_* ports.
// Engines run fully independently with per-engine FIFO-full stall.
//
// Mode 1: both engines run until candidate > n_limit, then flush both accumulators.
// Mode 2: both engines run until seconds >= t_limit, then flush both accumulators.
// Mode 3: eng_plus tests a single candidate; accumulators not used.
//
// Two-block FSM pattern: one always @(*) comb block + one always @(posedge clk) flop block.

module mode_fsm #(
    parameter WIDTH = 27
) (
    input  wire             clk,
    input  wire             rst,
    // User interface
    input  wire [1:0]       mode_sel,
    input  wire [WIDTH-1:0] n_limit,
    input  wire [31:0]      t_limit,
    input  wire [WIDTH-1:0] check_candidate,
    input  wire             go,
    // 6k+1 prime_engine interface
    output reg              eng_plus_start_ff,
    output reg  [WIDTH-1:0] eng_plus_candidate_ff,
    input  wire             eng_plus_done,
    input  wire             eng_plus_is_prime,
    input  wire             eng_plus_busy,
    // 6k-1 prime_engine interface
    output reg              eng_minus_start_ff,
    output reg  [WIDTH-1:0] eng_minus_candidate_ff,
    input  wire             eng_minus_done,
    input  wire             eng_minus_is_prime,
    input  wire             eng_minus_busy,
    // 6k+1 prime_accumulator interface
    output reg              acc_plus_valid_ff,
    output reg              acc_plus_is_prime_ff,
    output reg              acc_plus_flush_ff,
    input  wire             acc_plus_flush_done,
    input  wire             acc_plus_fifo_full,
    // 6k-1 prime_accumulator interface
    output reg              acc_minus_valid_ff,
    output reg              acc_minus_is_prime_ff,
    output reg              acc_minus_flush_ff,
    input  wire             acc_minus_flush_done,
    input  wire             acc_minus_fifo_full,
    // elapsed_timer interface
    output reg              timer_freeze_ff,
    input  wire [31:0]      seconds_ff,
    input  wire [31:0]      cycle_count_ff,
    // Status outputs
    output reg              done_ff,
    output reg              is_prime_result_ff,
    output reg  [3:0]       state_out_ff
);

    // State encoding (4-bit, 10 states)
    localparam [3:0]
        IDLE          = 4'd0,
        MODE_SELECT   = 4'd1,
        NUMBER_ENTRY  = 4'd2,
        TIME_ENTRY    = 4'd3,
        PRIME_RUN     = 4'd4,
        PRIME_FLUSH   = 4'd5,
        PRIME_DONE    = 4'd6,
        ISPRIME_ENTRY = 4'd7,
        ISPRIME_RUN   = 4'd8,
        ISPRIME_DONE  = 4'd9;

    // Internal flip-flop registers (_ff suffix per INFRA-03)
    reg [3:0]       state_ff;
    reg [1:0]       mode_sel_ff;
    reg [WIDTH-1:0] n_limit_ff;
    reg [31:0]      t_limit_ff;

    // Per-engine candidate tracking (Modes 1/2)
    reg [WIDTH-1:0] cand_plus_ff;       // current 6k+1 candidate
    reg [WIDTH-1:0] cand_minus_ff;      // current 6k-1 candidate
    reg             waiting_plus_ff;    // 1 while eng_plus is running
    reg             waiting_minus_ff;   // 1 while eng_minus is running
    reg             plus_exhausted_ff;  // Mode 1: plus engine will issue no more candidates
    reg             minus_exhausted_ff; // Mode 1: minus engine will issue no more candidates
    reg             timed_out_ff;       // Mode 2: time limit reached, no new starts

    // Mode 3
    reg [WIDTH-1:0] isprime_candidate_ff;
    reg             isprime_waiting_ff;

    // Flush tracking
    reg             flush_sent_ff;      // 1 after flush pulsed to both accumulators

    // Combinational next-state signals
    reg [3:0]       next_state;
    reg [1:0]       next_mode_sel;
    reg [WIDTH-1:0] next_n_limit;
    reg [31:0]      next_t_limit;
    reg [WIDTH-1:0] next_cand_plus;
    reg [WIDTH-1:0] next_cand_minus;
    reg             next_waiting_plus;
    reg             next_waiting_minus;
    reg             next_plus_exhausted;
    reg             next_minus_exhausted;
    reg             next_timed_out;
    reg [WIDTH-1:0] next_isprime_candidate;
    reg             next_isprime_waiting;
    reg             next_flush_sent;
    reg             next_eng_plus_start;
    reg [WIDTH-1:0] next_eng_plus_candidate;
    reg             next_eng_minus_start;
    reg [WIDTH-1:0] next_eng_minus_candidate;
    reg             next_acc_plus_valid;
    reg             next_acc_plus_is_prime;
    reg             next_acc_plus_flush;
    reg             next_acc_minus_valid;
    reg             next_acc_minus_is_prime;
    reg             next_acc_minus_flush;
    reg             next_timer_freeze;
    reg             next_done;
    reg             next_is_prime_result;
    reg [3:0]       next_state_out;


    //=====================================
    //========= COMBINATIONAL LOGIC =======
    //=====================================

    always @(*) begin
        // Defaults: hold current registered values
        next_state             = state_ff;
        next_mode_sel          = mode_sel_ff;
        next_n_limit           = n_limit_ff;
        next_t_limit           = t_limit_ff;
        next_cand_plus         = cand_plus_ff;
        next_cand_minus        = cand_minus_ff;
        next_waiting_plus      = waiting_plus_ff;
        next_waiting_minus     = waiting_minus_ff;
        next_plus_exhausted    = plus_exhausted_ff;
        next_minus_exhausted   = minus_exhausted_ff;
        next_timed_out         = timed_out_ff;
        next_isprime_candidate = isprime_candidate_ff;
        next_isprime_waiting   = isprime_waiting_ff;
        next_flush_sent        = flush_sent_ff;
        next_eng_plus_candidate  = eng_plus_candidate_ff;
        next_eng_minus_candidate = eng_minus_candidate_ff;
        next_timer_freeze      = timer_freeze_ff;
        next_done              = done_ff;
        next_is_prime_result   = is_prime_result_ff;
        // Pulse signals default to 0
        next_eng_plus_start    = 1'b0;
        next_eng_minus_start   = 1'b0;
        next_acc_plus_valid    = 1'b0;
        next_acc_plus_is_prime = 1'b0;
        next_acc_minus_valid   = 1'b0;
        next_acc_minus_is_prime = 1'b0;
        next_acc_plus_flush    = 1'b0;
        next_acc_minus_flush   = 1'b0;

        if (rst) begin
            next_state               = IDLE;
            next_mode_sel            = 2'b00;
            next_n_limit             = {WIDTH{1'b0}};
            next_t_limit             = 32'd0;
            next_cand_plus           = {WIDTH{1'b0}};
            next_cand_minus          = {WIDTH{1'b0}};
            next_waiting_plus        = 1'b0;
            next_waiting_minus       = 1'b0;
            next_plus_exhausted      = 1'b0;
            next_minus_exhausted     = 1'b0;
            next_timed_out           = 1'b0;
            next_isprime_candidate   = {WIDTH{1'b0}};
            next_isprime_waiting     = 1'b0;
            next_flush_sent          = 1'b0;
            next_eng_plus_candidate  = {WIDTH{1'b0}};
            next_eng_minus_candidate = {WIDTH{1'b0}};
            next_timer_freeze        = 1'b0;
            next_done                = 1'b0;
            next_is_prime_result     = 1'b0;
        end else begin
            case (state_ff)

                IDLE: begin
                    if (go) begin
                        next_mode_sel = mode_sel;
                        next_state    = MODE_SELECT;
                    end
                end

                MODE_SELECT: begin
                    case (mode_sel_ff)
                        2'd1: begin
                            next_n_limit = n_limit;
                            next_state   = NUMBER_ENTRY;
                        end
                        2'd2: begin
                            next_t_limit = t_limit;
                            next_state   = TIME_ENTRY;
                        end
                        2'd3: begin
                            next_isprime_candidate = check_candidate;
                            next_state             = ISPRIME_ENTRY;
                        end
                        default: next_state = IDLE;
                    endcase
                end

                NUMBER_ENTRY: begin
                    // 6k+1: k=1 → 6(1)+1 = 7   6k-1: k=1 → 6(1)-1 = 5
                    // Candidates 2 and 3 are skipped; hardcoded prime at output layer
                    next_cand_plus       = {{WIDTH-3{1'b0}}, 3'd7};
                    next_cand_minus      = {{WIDTH-3{1'b0}}, 3'd5};
                    next_waiting_plus    = 1'b0;
                    next_waiting_minus   = 1'b0;
                    next_plus_exhausted  = 1'b0;
                    next_minus_exhausted = 1'b0;
                    next_timed_out       = 1'b0;
                    next_flush_sent      = 1'b0;
                    next_done            = 1'b0;
                    next_timer_freeze    = 1'b0;
                    next_state           = PRIME_RUN;
                end

                TIME_ENTRY: begin
                    next_cand_plus       = {{WIDTH-3{1'b0}}, 3'd7};
                    next_cand_minus      = {{WIDTH-3{1'b0}}, 3'd5};
                    next_waiting_plus    = 1'b0;
                    next_waiting_minus   = 1'b0;
                    next_plus_exhausted  = 1'b0;
                    next_minus_exhausted = 1'b0;
                    next_timed_out       = 1'b0;
                    next_flush_sent      = 1'b0;
                    next_done            = 1'b0;
                    next_timer_freeze    = 1'b0;
                    next_state           = PRIME_RUN;
                end

                PRIME_RUN: begin

                    // ---- Mode 2 timeout check (sets next_timed_out for use below) ----
                    if (mode_sel_ff == 2'd2 && seconds_ff >= t_limit_ff)
                        next_timed_out = 1'b1;

                    // ---- 6k+1 engine ----
                    if (waiting_plus_ff) begin
                        if (eng_plus_done) begin
                            // Signal accumulator: one bit per completed candidate test
                            next_acc_plus_valid    = 1'b1;
                            next_acc_plus_is_prime = eng_plus_is_prime;
                            next_waiting_plus      = 1'b0;
                            // Advance to next k: candidate += 6
                            next_cand_plus = cand_plus_ff + {{WIDTH-3{1'b0}}, 3'd6};
                        end
                        // else: engine still running, hold
                    end else if (!plus_exhausted_ff && !acc_plus_fifo_full && !eng_plus_busy) begin
                        // Stop condition: Mode 1 limit exceeded or Mode 2 timed out
                        if ((mode_sel_ff == 2'd1 && cand_plus_ff > n_limit_ff) || next_timed_out) begin
                            next_plus_exhausted = 1'b1;
                        end else begin
                            next_eng_plus_start      = 1'b1;
                            next_eng_plus_candidate  = cand_plus_ff;
                            next_waiting_plus        = 1'b1;
                        end
                    end

                    // ---- 6k-1 engine (symmetric, independent of plus engine) ----
                    if (waiting_minus_ff) begin
                        if (eng_minus_done) begin
                            next_acc_minus_valid    = 1'b1;
                            next_acc_minus_is_prime = eng_minus_is_prime;
                            next_waiting_minus      = 1'b0;
                            next_cand_minus = cand_minus_ff + {{WIDTH-3{1'b0}}, 3'd6};
                        end
                    end else if (!minus_exhausted_ff && !acc_minus_fifo_full && !eng_minus_busy) begin
                        if ((mode_sel_ff == 2'd1 && cand_minus_ff > n_limit_ff) || next_timed_out) begin
                            next_minus_exhausted = 1'b1;
                        end else begin
                            next_eng_minus_start     = 1'b1;
                            next_eng_minus_candidate = cand_minus_ff;
                            next_waiting_minus       = 1'b1;
                        end
                    end

                    // ---- Termination check ----
                    // Uses next_ values: catches same-cycle exhaustion/timeout + done events.
                    // Mode 1: both engines exhausted and neither has an in-flight candidate.
                    // Mode 2: timeout fired and neither engine is still running.
                    if ((mode_sel_ff == 2'd1 &&
                         next_plus_exhausted && next_minus_exhausted &&
                         !next_waiting_plus  && !next_waiting_minus) ||
                        (mode_sel_ff == 2'd2 &&
                         next_timed_out &&
                         !next_waiting_plus && !next_waiting_minus)) begin
                        next_state        = PRIME_FLUSH;
                        next_timer_freeze = 1'b1;
                    end
                end

                PRIME_FLUSH: begin
                    if (!flush_sent_ff) begin
                        // Pulse flush to both accumulators simultaneously
                        next_acc_plus_flush  = 1'b1;
                        next_acc_minus_flush = 1'b1;
                        next_flush_sent      = 1'b1;
                    end else begin
                        // Wait for both flush_done acknowledgements (one cycle after flush arrives)
                        if (acc_plus_flush_done && acc_minus_flush_done) begin
                            next_state = PRIME_DONE;
                            next_done  = 1'b1;
                        end
                    end
                end

                PRIME_DONE: begin
                    next_done         = 1'b1;
                    next_timer_freeze = 1'b1;
                    if (go) begin
                        next_state        = IDLE;
                        next_done         = 1'b0;
                        next_timer_freeze = 1'b0;
                    end
                end

                ISPRIME_ENTRY: begin
                    next_isprime_waiting = 1'b0;
                    next_done            = 1'b0;
                    next_timer_freeze    = 1'b0;
                    next_state           = ISPRIME_RUN;
                end

                ISPRIME_RUN: begin
                    // eng_plus tests the single candidate; accumulators not involved
                    if (isprime_waiting_ff) begin
                        if (eng_plus_done) begin
                            next_is_prime_result = eng_plus_is_prime;
                            next_isprime_waiting = 1'b0;
                            next_state           = ISPRIME_DONE;
                            next_timer_freeze    = 1'b1;
                            next_done            = 1'b1;
                        end
                        // else: still waiting for engine
                    end else if (!eng_plus_busy) begin
                        next_eng_plus_start     = 1'b1;
                        next_eng_plus_candidate = isprime_candidate_ff;
                        next_isprime_waiting    = 1'b1;
                    end
                end

                ISPRIME_DONE: begin
                    next_done         = 1'b1;
                    next_timer_freeze = 1'b1;
                    if (go) begin
                        next_state        = IDLE;
                        next_done         = 1'b0;
                        next_timer_freeze = 1'b0;
                    end
                end

                default: next_state = IDLE;

            endcase

            next_state_out = next_state;
        end
    end


    //=====================================
    //========= FLOP REGISTERS ============
    //=====================================

    always @(posedge clk) begin
        state_ff               <= next_state;
        mode_sel_ff            <= next_mode_sel;
        n_limit_ff             <= next_n_limit;
        t_limit_ff             <= next_t_limit;
        cand_plus_ff           <= next_cand_plus;
        cand_minus_ff          <= next_cand_minus;
        waiting_plus_ff        <= next_waiting_plus;
        waiting_minus_ff       <= next_waiting_minus;
        plus_exhausted_ff      <= next_plus_exhausted;
        minus_exhausted_ff     <= next_minus_exhausted;
        timed_out_ff           <= next_timed_out;
        isprime_candidate_ff   <= next_isprime_candidate;
        isprime_waiting_ff     <= next_isprime_waiting;
        flush_sent_ff          <= next_flush_sent;
        eng_plus_start_ff      <= next_eng_plus_start;
        eng_plus_candidate_ff  <= next_eng_plus_candidate;
        eng_minus_start_ff     <= next_eng_minus_start;
        eng_minus_candidate_ff <= next_eng_minus_candidate;
        acc_plus_valid_ff      <= next_acc_plus_valid;
        acc_plus_is_prime_ff   <= next_acc_plus_is_prime;
        acc_plus_flush_ff      <= next_acc_plus_flush;
        acc_minus_valid_ff     <= next_acc_minus_valid;
        acc_minus_is_prime_ff  <= next_acc_minus_is_prime;
        acc_minus_flush_ff     <= next_acc_minus_flush;
        timer_freeze_ff        <= next_timer_freeze;
        done_ff                <= next_done;
        is_prime_result_ff     <= next_is_prime_result;
        state_out_ff           <= next_state_out;
    end

endmodule
