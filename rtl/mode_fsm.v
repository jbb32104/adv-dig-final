`timescale 1ns / 1ps

// Mode dispatcher FSM for Prime Modes FSM project.
// 9 states: IDLE, MODE_SELECT, NUMBER_ENTRY, TIME_ENTRY, PRIME_RUN, PRIME_DONE,
//           ISPRIME_ENTRY, ISPRIME_RUN, ISPRIME_DONE.
// Orchestrates Modes 1 (enumerate primes up to N), 2 (enumerate primes within T seconds),
// and 3 (single primality check). Drives prime_engine, prime_accumulator, elapsed_timer.
// 6k+/-1 candidate enumeration: 2, 3, then 5, 7, 11, 13, ... via step_toggle_ff.
// Two-block FSM pattern: one always @(*) comb block + one always @(posedge clk) flop block.

module mode_fsm #(
    parameter WIDTH = 27
) (
    input  wire             clk,
    input  wire             rst,
    // User interface (directly driven by testbench in Phase 2; joystick/7SD in Phase 4)
    input  wire [1:0]       mode_sel,        // 2'd1=Mode1, 2'd2=Mode2, 2'd3=Mode3
    input  wire [WIDTH-1:0] n_limit,         // Mode 1: find primes <= N
    input  wire [31:0]      t_limit,         // Mode 2: run for T seconds
    input  wire [WIDTH-1:0] check_candidate, // Mode 3: single number to test
    input  wire             go,              // pulse to start selected mode
    // prime_engine interface
    output reg              eng_start_ff,
    output reg  [WIDTH-1:0] eng_candidate_ff,
    input  wire             eng_done_ff,
    input  wire             eng_is_prime_ff,
    input  wire             eng_busy_ff,
    // prime_accumulator interface
    output reg              prime_valid_ff,
    output reg  [WIDTH-1:0] prime_data_ff,
    input  wire             prime_fifo_full_ff,
    // elapsed_timer interface
    output reg              timer_freeze_ff,
    input  wire [31:0]      seconds_ff,
    input  wire [31:0]      cycle_count_ff,
    // Status outputs
    output reg              done_ff,
    output reg              is_prime_result_ff,
    output reg  [3:0]       state_out_ff     // expose FSM state for debug/testbench
);

    // State encoding (4-bit binary, 9 states)
    localparam [3:0]
        IDLE          = 4'd0,
        MODE_SELECT   = 4'd1,
        NUMBER_ENTRY  = 4'd2,
        TIME_ENTRY    = 4'd3,
        PRIME_RUN     = 4'd4,
        PRIME_DONE    = 4'd5,
        ISPRIME_ENTRY = 4'd6,
        ISPRIME_RUN   = 4'd7,
        ISPRIME_DONE  = 4'd8;

    // Internal flip-flop registers (_ff suffix per INFRA-03)
    reg [3:0]       state_ff;
    reg [1:0]       mode_sel_ff;      // latched mode selection
    reg [WIDTH-1:0] n_limit_ff;       // latched N limit for Mode 1
    reg [31:0]      t_limit_ff;       // latched T limit for Mode 2 (per D-13)
    reg [WIDTH-1:0] candidate_ff;     // current candidate being fed to prime_engine
    reg             step_toggle_ff;   // 0 = next step +2, 1 = next step +4 (per D-01)
    reg [1:0]       init_phase_ff;    // 2'b10=feed 2, 2'b01=feed 3, 2'b00=main loop
    reg             waiting_result_ff; // 1 when prime_engine is running and we wait for done_ff

    // Combinational next-state signals (blocking = only)
    reg [3:0]       next_state;
    reg [1:0]       next_mode_sel;
    reg [WIDTH-1:0] next_n_limit;
    reg [31:0]      next_t_limit;
    reg [WIDTH-1:0] next_candidate;
    reg             next_step_toggle;
    reg [1:0]       next_init_phase;
    reg             next_waiting_result;
    reg             next_eng_start;
    reg [WIDTH-1:0] next_eng_candidate;
    reg             next_prime_valid;
    reg [WIDTH-1:0] next_prime_data;
    reg             next_timer_freeze;
    reg             next_done;
    reg             next_is_prime_result;
    reg [3:0]       next_state_out;


    //=====================================
    //========= COMBINATIONAL LOGIC =======
    //=====================================

    always @(*) begin
        // Defaults: hold current registered values
        next_state           = state_ff;
        next_mode_sel        = mode_sel_ff;
        next_n_limit         = n_limit_ff;
        next_t_limit         = t_limit_ff;
        next_candidate       = candidate_ff;
        next_step_toggle     = step_toggle_ff;
        next_init_phase      = init_phase_ff;
        next_waiting_result  = waiting_result_ff;
        next_eng_candidate   = eng_candidate_ff;
        next_prime_data      = prime_data_ff;
        next_timer_freeze    = timer_freeze_ff;
        next_done            = done_ff;
        next_is_prime_result = is_prime_result_ff;
        // Pulse signals default to 0
        next_eng_start  = 1'b0;
        next_prime_valid = 1'b0;

        if (rst) begin
            next_state           = IDLE;
            next_mode_sel        = 2'b00;
            next_n_limit         = {WIDTH{1'b0}};
            next_t_limit         = 32'd0;
            next_candidate       = {WIDTH{1'b0}};
            next_step_toggle     = 1'b0;
            next_init_phase      = 2'b00;
            next_waiting_result  = 1'b0;
            next_eng_start       = 1'b0;
            next_eng_candidate   = {WIDTH{1'b0}};
            next_prime_valid     = 1'b0;
            next_prime_data      = {WIDTH{1'b0}};
            next_timer_freeze    = 1'b0;
            next_done            = 1'b0;
            next_is_prime_result = 1'b0;
        end else begin
            case (state_ff)

                IDLE: begin
                    if (go) begin
                        next_mode_sel = mode_sel;
                        next_state    = MODE_SELECT;
                    end else begin
                        next_state = IDLE;
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
                            next_candidate = check_candidate;
                            next_state     = ISPRIME_ENTRY;
                        end
                        default: begin
                            next_state = IDLE;
                        end
                    endcase
                end

                NUMBER_ENTRY: begin
                    // Initialize for Mode 1 candidate enumeration
                    next_init_phase      = 2'b10;                        // start with candidate 2
                    next_candidate       = {{WIDTH-2{1'b0}}, 2'd2};      // candidate = 2
                    next_step_toggle     = 1'b0;
                    next_waiting_result  = 1'b0;
                    next_done            = 1'b0;
                    next_timer_freeze    = 1'b0;
                    next_state           = PRIME_RUN;
                end

                TIME_ENTRY: begin
                    // Initialize for Mode 2 candidate enumeration (same as Mode 1 init)
                    next_init_phase      = 2'b10;                        // start with candidate 2
                    next_candidate       = {{WIDTH-2{1'b0}}, 2'd2};      // candidate = 2
                    next_step_toggle     = 1'b0;
                    next_waiting_result  = 1'b0;
                    next_done            = 1'b0;
                    next_timer_freeze    = 1'b0;
                    next_state           = PRIME_RUN;
                end

                PRIME_RUN: begin
                    // Priority order per RESEARCH Mode 2 Termination / D-12:

                    // a. Mode 2 timeout check (HIGHEST PRIORITY per D-12):
                    //    Terminates immediately even if engine is mid-computation
                    if (mode_sel_ff == 2'd2 && seconds_ff >= t_limit_ff) begin
                        next_state        = PRIME_DONE;
                        next_timer_freeze = 1'b1;
                        next_done         = 1'b1;
                    // b. Mode 1 completion check:
                    //    Only when not waiting for a result and candidate exceeds n_limit
                    end else if (mode_sel_ff == 2'd1 && !waiting_result_ff &&
                                 candidate_ff > n_limit_ff) begin
                        next_state        = PRIME_DONE;
                        next_timer_freeze = 1'b1;
                        next_done         = 1'b1;
                    // c. Waiting for prime_engine result:
                    end else if (waiting_result_ff) begin
                        if (eng_done_ff) begin
                            next_waiting_result = 1'b0;
                            // Store prime if found and FIFO not full (per D-06)
                            if (eng_is_prime_ff && !prime_fifo_full_ff) begin
                                next_prime_valid = 1'b1;
                                next_prime_data  = candidate_ff;
                            end
                            // Advance candidate per D-01/D-02 (6k+/-1 enumeration)
                            if (init_phase_ff == 2'b10) begin
                                // Just tested 2; next is 3
                                next_init_phase = 2'b01;
                                next_candidate  = {{WIDTH-2{1'b0}}, 2'd3};
                            end else if (init_phase_ff == 2'b01) begin
                                // Just tested 3; next is 5 (start of main 6k+/-1 loop)
                                next_init_phase  = 2'b00;
                                next_candidate   = {{WIDTH-3{1'b0}}, 3'd5};
                                next_step_toggle = 1'b0; // +2 first
                            end else begin
                                // Main 6k+/-1 loop: alternate +2/+4
                                if (step_toggle_ff == 1'b0) begin
                                    next_candidate   = candidate_ff + {{WIDTH-2{1'b0}}, 2'd2};
                                    next_step_toggle = 1'b1;
                                end else begin
                                    next_candidate   = candidate_ff + {{WIDTH-3{1'b0}}, 3'd4};
                                    next_step_toggle = 1'b0;
                                end
                            end
                        end else begin
                            // Still waiting for engine to complete
                            next_state = PRIME_RUN;
                        end
                    // d. FIFO full stall (per D-06): do not start engine when FIFO is full
                    end else if (prime_fifo_full_ff) begin
                        next_eng_start = 1'b0;
                        next_state     = PRIME_RUN;
                    // e. Ready to start next candidate (gate on ~eng_busy_ff per Pitfall 1)
                    end else if (!eng_busy_ff) begin
                        next_eng_start       = 1'b1;
                        next_eng_candidate   = candidate_ff;
                        next_waiting_result  = 1'b1;
                    // f. Engine busy, not done yet — hold
                    end else begin
                        next_state = PRIME_RUN;
                    end
                end

                PRIME_DONE: begin
                    // Hold done and freeze; allow re-run on go pulse
                    next_done         = 1'b1;
                    next_timer_freeze = 1'b1;
                    if (go) begin
                        next_state        = IDLE;
                        next_done         = 1'b0;
                        next_timer_freeze = 1'b0;
                    end else begin
                        next_state = PRIME_DONE;
                    end
                end

                ISPRIME_ENTRY: begin
                    // Initialize for Mode 3 (candidate already latched in MODE_SELECT)
                    next_waiting_result  = 1'b0;
                    next_done            = 1'b0;
                    next_timer_freeze    = 1'b0;
                    next_state           = ISPRIME_RUN;
                end

                ISPRIME_RUN: begin
                    // Single prime_engine invocation for Mode 3
                    if (waiting_result_ff && eng_done_ff) begin
                        next_is_prime_result = eng_is_prime_ff;
                        // Store prime result in accumulator if prime and FIFO not full
                        if (eng_is_prime_ff && !prime_fifo_full_ff) begin
                            next_prime_valid = 1'b1;
                            next_prime_data  = candidate_ff;
                        end
                        next_state        = ISPRIME_DONE;
                        next_timer_freeze = 1'b1;
                        next_done         = 1'b1;
                    end else if (waiting_result_ff && !eng_done_ff) begin
                        // Still waiting
                        next_state = ISPRIME_RUN;
                    end else if (!eng_busy_ff) begin
                        // Start the engine (gate on ~eng_busy_ff per Pitfall 1)
                        next_eng_start      = 1'b1;
                        next_eng_candidate  = candidate_ff;
                        next_waiting_result = 1'b1;
                    end else begin
                        next_state = ISPRIME_RUN;
                    end
                end

                ISPRIME_DONE: begin
                    // Hold done and freeze; allow re-run on go pulse
                    next_done            = 1'b1;
                    next_timer_freeze    = 1'b1;
                    if (go) begin
                        next_state        = IDLE;
                        next_done         = 1'b0;
                        next_timer_freeze = 1'b0;
                    end else begin
                        next_state = ISPRIME_DONE;
                    end
                end

                default: begin
                    next_state = IDLE;
                end

            endcase

            // Expose FSM next-state for debug/testbench
            next_state_out = next_state;
        end
    end


    //=====================================
    //========= FLOP REGISTERS ============
    //=====================================

    always @(posedge clk) begin
        state_ff           <= next_state;
        mode_sel_ff        <= next_mode_sel;
        n_limit_ff         <= next_n_limit;
        t_limit_ff         <= next_t_limit;
        candidate_ff       <= next_candidate;
        step_toggle_ff     <= next_step_toggle;
        init_phase_ff      <= next_init_phase;
        waiting_result_ff  <= next_waiting_result;
        eng_start_ff       <= next_eng_start;
        eng_candidate_ff   <= next_eng_candidate;
        prime_valid_ff     <= next_prime_valid;
        prime_data_ff      <= next_prime_data;
        timer_freeze_ff    <= next_timer_freeze;
        done_ff            <= next_done;
        is_prime_result_ff <= next_is_prime_result;
        state_out_ff       <= next_state_out;
    end

endmodule
