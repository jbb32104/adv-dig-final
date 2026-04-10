`timescale 1ns / 1ps

// Debounce module for mechanical pushbuttons.
// Two-stage synchronizer eliminates metastability, then a counter-based
// filter holds the output stable for DEBOUNCE_CYCLES consecutive same-level
// samples before changing state.
// rising_pulse and falling_pulse are single-cycle strobes on the debounced edge.
//
// Default DEBOUNCE_CYCLES=500000 gives 5 ms filter at 100 MHz.
// Use a smaller value in simulation (e.g. 10).

module debounce #(
    parameter DEBOUNCE_CYCLES = 500_000
) (
    input  wire clk,
    input  wire rst,
    input  wire btn_in,
    output reg  btn_state_ff,
    output reg  rising_pulse_ff,
    output reg  falling_pulse_ff
);

    localparam CTR_W = $clog2(DEBOUNCE_CYCLES + 1);

    // -----------------------------------------------------------------------
    // Flip-flop registers
    // -----------------------------------------------------------------------
    reg              sync0_ff, sync1_ff;
    reg [CTR_W-1:0]  ctr_ff;
    reg              filtered_ff;
    reg              prev_ff;

    // -----------------------------------------------------------------------
    // Combinational next-state signals
    // -----------------------------------------------------------------------
    reg              next_sync0;
    reg              next_sync1;
    reg [CTR_W-1:0]  next_ctr;
    reg              next_filtered;
    reg              next_prev;
    reg              next_btn_state;
    reg              next_rising_pulse;
    reg              next_falling_pulse;

    // -----------------------------------------------------------------------
    // Combinational logic
    // -----------------------------------------------------------------------
    always @(*) begin
        // Defaults: hold current values
        next_sync0         = btn_in;        // synchronizer always samples input
        next_sync1         = sync0_ff;
        next_ctr           = ctr_ff;
        next_filtered      = filtered_ff;
        next_prev          = filtered_ff;   // prev always tracks filtered one cycle behind
        next_btn_state     = filtered_ff;
        next_rising_pulse  = 1'b0;
        next_falling_pulse = 1'b0;

        if (rst) begin
            next_sync0         = 1'b0;
            next_sync1         = 1'b0;
            next_ctr           = {CTR_W{1'b0}};
            next_filtered      = 1'b0;
            next_prev          = 1'b0;
            next_btn_state     = 1'b0;
            next_rising_pulse  = 1'b0;
            next_falling_pulse = 1'b0;
        end else begin
            // --- Counter filter ---
            if (sync1_ff == filtered_ff) begin
                // Input matches stable state: reset counter
                next_ctr = {CTR_W{1'b0}};
            end else begin
                next_ctr = ctr_ff + {{CTR_W-1{1'b0}}, 1'b1};
                if (ctr_ff == DEBOUNCE_CYCLES - 1) begin
                    next_filtered = sync1_ff;
                    next_ctr      = {CTR_W{1'b0}};
                end
            end

            // --- Edge detection (uses registered filtered_ff, not next_filtered) ---
            // Comparing filtered_ff to prev_ff gives exactly one pulse cycle:
            // prev_ff catches up to filtered_ff one cycle after filtered_ff changes.
            next_rising_pulse  = filtered_ff & ~prev_ff;
            next_falling_pulse = ~filtered_ff & prev_ff;
            next_btn_state     = filtered_ff;
        end
    end

    // -----------------------------------------------------------------------
    // Flop registers
    // -----------------------------------------------------------------------
    always @(posedge clk) begin
        sync0_ff         <= next_sync0;
        sync1_ff         <= next_sync1;
        ctr_ff           <= next_ctr;
        filtered_ff      <= next_filtered;
        prev_ff          <= next_prev;
        btn_state_ff     <= next_btn_state;
        rising_pulse_ff  <= next_rising_pulse;
        falling_pulse_ff <= next_falling_pulse;
    end

endmodule
