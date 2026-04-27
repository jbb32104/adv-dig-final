`timescale 1ns / 1ps

// Keypad digit entry controller — captures decimal digits from keypad,
// manages cursor position, outputs BCD digits for display and conversion.
//
// Cursor starts at digit 0 (rightmost/ones). After each valid digit press
// (0-9), stores the digit and advances cursor one position to the left.
// Wraps back to digit 0 after reaching the MSB.
//
// Active digit counts per screen:
//   Screen 1 (N MAX):      8 digits  "00 000 000"  max cursor = 7
//   Screen 2 (TIME LIMIT): 4 digits  "0 000"       max cursor = 3
//   Screen 3 (SINGLE NUM): 8 digits  "00 000 000"  max cursor = 7
//
// Digits reset to 0 and cursor resets to 0 when navigating to a new screen.
//
// Clock domain: clk (100 MHz, same as keypad_nav).

module digit_entry (
    input  wire        clk,
    input  wire        rst_n,

    // Screen context (from keypad_nav)
    input  wire [2:0]  screen_id,

    // Digit input (from keypad_nav)
    input  wire        digit_press,    // 1-cycle pulse when 0-9 pressed
    input  wire [3:0]  digit_value,    // 0-9

    // Outputs
    output reg  [31:0] bcd_digits_ff,  // 8 BCD digits: d7[31:28] .. d0[3:0]
    output reg  [3:0]  cursor_pos_ff,  // current cursor (0 = ones, 7 = ten-millions)
    output reg         changed_ff,     // 1-cycle pulse on any digit/cursor update
    output reg         toggle_ff       // flips on each change (for CDC edge detect)
);

    // Screen IDs with digit entry
    localparam [2:0]
        SCR_NMAX   = 3'd1,
        SCR_TIME   = 3'd2,
        SCR_SINGLE = 3'd3;

    // -----------------------------------------------------------------------
    // Registered state
    // -----------------------------------------------------------------------
    reg [2:0] prev_sid_ff;

    // -----------------------------------------------------------------------
    // Max cursor position for current screen
    // -----------------------------------------------------------------------
    reg [3:0] max_cursor;
    always @(*) begin
        case (screen_id)
            SCR_NMAX:   max_cursor = 4'd7;
            SCR_TIME:   max_cursor = 4'd3;
            SCR_SINGLE: max_cursor = 4'd7;
            default:    max_cursor = 4'd0;
        endcase
    end

    // -----------------------------------------------------------------------
    // Is the current screen a digit-entry screen?
    // -----------------------------------------------------------------------
    reg is_entry_screen;
    always @(*) begin
        is_entry_screen = (screen_id == SCR_NMAX) ||
                          (screen_id == SCR_TIME) ||
                          (screen_id == SCR_SINGLE);
    end

    // -----------------------------------------------------------------------
    // Next-state signals
    // -----------------------------------------------------------------------
    reg [31:0] bcd_digits_next;
    reg [3:0]  cursor_pos_next;
    reg        changed_next;
    reg        toggle_next;
    reg [2:0]  prev_sid_next;

    always @(*) begin
        if (!rst_n) begin
            bcd_digits_next = 32'd0;
            cursor_pos_next = 4'd0;
            changed_next    = 1'b0;
            toggle_next     = 1'b0;
            prev_sid_next   = 3'd0;
        end else begin
            // Defaults: hold
            bcd_digits_next = bcd_digits_ff;
            cursor_pos_next = cursor_pos_ff;
            changed_next    = 1'b0;
            toggle_next     = toggle_ff;
            prev_sid_next   = screen_id;

            // Reset digits when navigating to a different screen
            if (screen_id != prev_sid_ff) begin
                bcd_digits_next = 32'd0;
                cursor_pos_next = 4'd0;
                changed_next    = 1'b1;
                toggle_next     = ~toggle_ff;
            end
            // Accept digit press on entry screens
            else if (digit_press && is_entry_screen) begin
                // Write digit at cursor position using case mux
                case (cursor_pos_ff)
                    4'd0: bcd_digits_next[3:0]   = digit_value;
                    4'd1: bcd_digits_next[7:4]   = digit_value;
                    4'd2: bcd_digits_next[11:8]  = digit_value;
                    4'd3: bcd_digits_next[15:12] = digit_value;
                    4'd4: bcd_digits_next[19:16] = digit_value;
                    4'd5: bcd_digits_next[23:20] = digit_value;
                    4'd6: bcd_digits_next[27:24] = digit_value;
                    4'd7: bcd_digits_next[31:28] = digit_value;
                    default: ;
                endcase

                changed_next = 1'b1;
                toggle_next  = ~toggle_ff;

                // Advance cursor left, wrap at max
                if (cursor_pos_ff >= max_cursor)
                    cursor_pos_next = 4'd0;
                else
                    cursor_pos_next = cursor_pos_ff + 4'd1;
            end
        end
    end

    // -----------------------------------------------------------------------
    // Sequential block — flops only
    // -----------------------------------------------------------------------
    always @(posedge clk) begin
        bcd_digits_ff <= bcd_digits_next;
        cursor_pos_ff <= cursor_pos_next;
        changed_ff    <= changed_next;
        toggle_ff     <= toggle_next;
        prev_sid_ff   <= prev_sid_next;
    end

endmodule
