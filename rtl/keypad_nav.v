`timescale 1ns / 1ps

// Keypad navigation controller — translates keypad button presses into
// screen_id transitions and mode_fsm control signals.
//
// Screen map:
//   0: HOME       "PRIME FINDER" + "SEL MODE - A B C D"
//   1: MODE A     "MODE - N MAX"       (mode_sel = 1)
//   2: MODE B     "MODE - TIME LIMIT"  (mode_sel = 2)
//   3: MODE C     "MODE - SINGLE NUM"  (mode_sel = 3)
//   4: MODE D     "MODE - TEST"        (mode_sel = 0)
//   5: LOADING    "LOADING PRIMES"
//   6: RESULTS    "RESULTS"
//
// Keypad actions:
//   0-9      — on mode screens 1-3, digit entry (digit_press pulse)
//   A/B/C/D  — from any non-loading screen, navigate to mode screen
//   *  (0xE) — from mode screens 1-4, start prime finder (go pulse)
//   #  (0xF) — from any non-loading screen, return to HOME
//
// After mode_fsm reports done while on LOADING, auto-transition to RESULTS.
//
// Clock domain: clk (100 MHz, same as mode_fsm).

module keypad_nav #(
    parameter COOLDOWN_CYCLES = 25_000_000  // 250 ms at 100 MHz
) (
    input  wire        clk,
    input  wire        rst,

    // Keypad input (from row_reader, clk domain)
    input  wire [3:0]  button,
    input  wire        button_valid,

    // mode_fsm status (clk domain)
    input  wire        mode_done,

    // Outputs (clk domain)
    output reg  [2:0]  screen_id_ff,
    output reg  [1:0]  mode_sel_ff,
    output reg         go_ff,

    // Digit entry outputs (for digit_entry module)
    output reg         digit_press_ff,  // 1-cycle pulse on 0-9 press
    output reg  [3:0]  digit_value_ff   // which digit (0-9)
);

    // Screen IDs
    localparam [2:0]
        SCR_HOME    = 3'd0,
        SCR_NMAX    = 3'd1,
        SCR_TIME    = 3'd2,
        SCR_SINGLE  = 3'd3,
        SCR_TEST    = 3'd4,
        SCR_LOADING = 3'd5,
        SCR_RESULTS = 3'd6,
        SCR_TLOAD   = 3'd7;   // time-mode loading (countdown display)

    // Button codes (from row_reader encoding)
    localparam [3:0]
        BTN_A    = 4'hA,
        BTN_B    = 4'hB,
        BTN_C    = 4'hC,
        BTN_D    = 4'hD,
        BTN_STAR = 4'hE,
        BTN_HASH = 4'hF;

    // -----------------------------------------------------------------------
    // Registered state
    // -----------------------------------------------------------------------
    reg        bv_prev_ff;
    reg [24:0] cooldown_ff;   // press cooldown counter

    // -----------------------------------------------------------------------
    // Combinational next-state signals
    // -----------------------------------------------------------------------
    reg [2:0]  screen_id_next;
    reg [1:0]  mode_sel_next;
    reg        go_next;
    reg        bv_prev_next;
    reg        bv_rising;
    reg        digit_press_next;
    reg [3:0]  digit_value_next;
    reg [24:0] cooldown_next;

    // -----------------------------------------------------------------------
    // Combinational next-state logic (including reset)
    // -----------------------------------------------------------------------
    always @(*) begin
        // Rising edge of button_valid, suppressed during cooldown
        bv_rising = button_valid && !bv_prev_ff && (cooldown_ff == 25'd0);

        if (rst) begin
            screen_id_next   = SCR_HOME;
            mode_sel_next    = 2'd0;
            go_next          = 1'b0;
            bv_prev_next     = 1'b0;
            digit_press_next = 1'b0;
            digit_value_next = 4'd0;
            cooldown_next    = 25'd0;
        end else begin
            // Defaults: hold
            screen_id_next   = screen_id_ff;
            mode_sel_next    = mode_sel_ff;
            go_next          = 1'b0;
            bv_prev_next     = button_valid;
            digit_press_next = 1'b0;
            digit_value_next = 4'd0;

            // Cooldown: count down to 0
            if (cooldown_ff != 25'd0)
                cooldown_next = cooldown_ff - 25'd1;
            else
                cooldown_next = 25'd0;

            // Auto-transition: LOADING/TLOAD -> RESULTS when mode_fsm is done
            if ((screen_id_ff == SCR_LOADING || screen_id_ff == SCR_TLOAD) && mode_done) begin
                screen_id_next = SCR_RESULTS;
            end

            // Keypad press handling (rising edge of button_valid only)
            // LOADING screens ignore all input — wait for mode_done.
            if (bv_rising && screen_id_ff != SCR_LOADING && screen_id_ff != SCR_TLOAD) begin

                // 0-9 digit entry on mode screens with numeric input
                if (button <= 4'h9 &&
                    (screen_id_ff == SCR_NMAX  ||
                     screen_id_ff == SCR_TIME  ||
                     screen_id_ff == SCR_SINGLE)) begin
                    digit_press_next = 1'b1;
                    digit_value_next = button;
                end

                // A/B/C/D — navigate between modes from any non-loading screen
                case (button)
                    BTN_A: screen_id_next = SCR_NMAX;
                    BTN_B: screen_id_next = SCR_TIME;
                    BTN_C: screen_id_next = SCR_SINGLE;
                    BTN_D: screen_id_next = SCR_TEST;
                    default: ;
                endcase

                // * and # — screen-specific actions
                case (screen_id_ff)

                    SCR_NMAX, SCR_TIME, SCR_SINGLE, SCR_TEST: begin
                        if (button == BTN_HASH) begin
                            screen_id_next = SCR_HOME;
                        end else if (button == BTN_STAR) begin
                            screen_id_next = (screen_id_ff == SCR_TIME) ? SCR_TLOAD : SCR_LOADING;
                            go_next        = 1'b1;
                            case (screen_id_ff)
                                SCR_NMAX:   mode_sel_next = 2'd1;
                                SCR_TIME:   mode_sel_next = 2'd2;
                                SCR_SINGLE: mode_sel_next = 2'd3;
                                default:    mode_sel_next = 2'd0;
                            endcase
                        end
                    end

                    SCR_RESULTS: begin
                        if (button == BTN_HASH) begin
                            screen_id_next = SCR_HOME;
                            go_next        = 1'b1;
                        end
                    end

                    default: ;

                endcase

                // Start cooldown after any accepted press
                cooldown_next = COOLDOWN_CYCLES[24:0];
            end
        end
    end

    // -----------------------------------------------------------------------
    // Sequential block — flops only
    // -----------------------------------------------------------------------
    always @(posedge clk) begin
        screen_id_ff   <= screen_id_next;
        mode_sel_ff    <= mode_sel_next;
        go_ff          <= go_next;
        bv_prev_ff     <= bv_prev_next;
        digit_press_ff <= digit_press_next;
        digit_value_ff <= digit_value_next;
        cooldown_ff    <= cooldown_next;
    end

endmodule
