module debouncer (
    input  wire ui_clk,        // The 100 MHz memory clock
    input  wire rst,           // The MIG's synchronous reset
    input  wire button_raw,    // The physical pin from the board
    output reg  button_clean_ff // The stable, filtered output
);

    // 100 MHz clock = 10ns period.
    // 10 ms debounce = 1,000,000 clock cycles.
    localparam MAX_COUNT = 20'd1000000;

    // Combinational Variables
    reg [19:0] counter_next;
    reg        button_clean_next;
    reg        sync_0_next;
    reg        sync_1_next;

    // Sequential Variables
    reg [19:0] counter_ff;
    reg        sync_0_ff;
    reg        sync_1_ff;

    // ==========================================================================
    // Combinational Block
    // ==========================================================================
    always @(*) begin
        // 1. Defaults
        counter_next      = counter_ff;
        button_clean_next = button_clean_ff;
        
        // The double-flop synchronizer logic
        sync_0_next       = button_raw;
        sync_1_next       = sync_0_ff;

        // 2. Reset
        if (rst) begin
            counter_next      = 20'd0;
            button_clean_next = 1'b0;
            sync_0_next       = 1'b0;
            sync_1_next       = 1'b0;
        end else begin
            
            // 3. Debounce Logic
            // If the incoming synchronized signal does not match our current official output...
            if (sync_1_ff !== button_clean_ff) begin
                
                // Have we waited the full 10 milliseconds?
                if (counter_ff == MAX_COUNT) begin
                    button_clean_next = sync_1_ff; // Lock in the new state
                    counter_next      = 20'd0;     // Reset the timer
                end else begin
                    counter_next      = counter_ff + 20'd1; // Keep counting
                    button_clean_next = button_clean_ff;    // Hold the old state
                end
                
            end else begin
                // Class Standard: Catch-all else
                // If the signal matches, reset the counter to stay ready for the next press
                counter_next      = 20'd0;
                button_clean_next = button_clean_ff;
            end
        end
    end

    // ==========================================================================
    // Sequential Block
    // ==========================================================================
    always @(posedge ui_clk) begin
        sync_0_ff       <= sync_0_next;
        sync_1_ff       <= sync_1_next;
        counter_ff      <= counter_next;
        button_clean_ff <= button_clean_next;
    end

endmodule