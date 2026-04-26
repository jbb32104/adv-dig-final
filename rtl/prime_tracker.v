`timescale 1ns / 1ps

// Prime tracker — circular buffer that stores the last DEPTH prime
// candidate values found by both engines during N-max / time-limit modes.
//
// DEPTH is 64 (power of 2) so that even when one engine lags behind the
// other significantly, the buffer still contains all top primes from both.
// results_bcd reads all entries, sorts, and picks the top 20 for display.
//
// Handles dual writes: both engines can report a prime on the same cycle.
//
// Primes 2 and 3 are NOT tracked here (they're hardcoded, never tested
// by the engines). The display logic appends them if count < 20 and
// n_limit >= 2 or 3.
//
// Clock domain: clk (100 MHz, same as mode_fsm).

module prime_tracker #(
    parameter WIDTH = 27,
    parameter DEPTH = 64,
    parameter PTR_W = 6          // log2(DEPTH)
) (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               clear,           // pulse: reset on new computation

    // Engine prime inputs (active during PRIME_RUN)
    input  wire               plus_found,      // pulse: 6k+1 candidate was prime
    input  wire [WIDTH-1:0]   plus_value,      // the 6k+1 candidate value
    input  wire               minus_found,     // pulse: 6k-1 candidate was prime
    input  wire [WIDTH-1:0]   minus_value,     // the 6k-1 candidate value

    // Read port (stable after computation completes)
    input  wire [PTR_W-1:0]   read_idx,        // 0 = most recent (largest)
    output reg  [WIDTH-1:0]   read_data_ff,    // registered prime value

    // Status
    output reg  [PTR_W:0]     count_ff         // engine primes stored (0-DEPTH)
);

    // -----------------------------------------------------------------------
    // Storage: register array (64 x WIDTH bits)
    // -----------------------------------------------------------------------
    (* ram_style = "register" *) reg [WIDTH-1:0] mem [0:DEPTH-1];

    // Write pointer: next position to write (wraps via bit masking)
    reg [PTR_W-1:0] wr_ptr_ff;

    // -----------------------------------------------------------------------
    // Combinational next-state signals
    // -----------------------------------------------------------------------
    reg [PTR_W-1:0] next_wr_ptr;
    reg [PTR_W:0]   next_count;
    reg             wr_en_0, wr_en_1;
    reg [PTR_W-1:0] wr_addr_0, wr_addr_1;
    reg [WIDTH-1:0] wr_data_0, wr_data_1;

    // Read address: read_idx 0 = most recent = wr_ptr - 1
    // Power-of-2 depth: wrap is just truncation
    wire [PTR_W-1:0] rd_addr = wr_ptr_ff - {{(PTR_W-1){1'b0}}, 1'b1} - read_idx;

    always @(*) begin
        next_wr_ptr = wr_ptr_ff;
        next_count  = count_ff;
        wr_en_0     = 1'b0;
        wr_en_1     = 1'b0;
        wr_addr_0   = {PTR_W{1'b0}};
        wr_addr_1   = {PTR_W{1'b0}};
        wr_data_0   = {WIDTH{1'b0}};
        wr_data_1   = {WIDTH{1'b0}};

        if (!rst_n || clear) begin
            next_wr_ptr = {PTR_W{1'b0}};
            next_count  = {(PTR_W+1){1'b0}};
        end else begin
            if (plus_found && minus_found) begin
                // Both engines found a prime on the same cycle.
                // Write minus first (smaller), then plus (larger).
                wr_en_0   = 1'b1;
                wr_addr_0 = wr_ptr_ff;
                wr_data_0 = minus_value;

                wr_en_1   = 1'b1;
                wr_addr_1 = wr_ptr_ff + {{(PTR_W-1){1'b0}}, 1'b1};
                wr_data_1 = plus_value;

                // Advance write pointer by 2 (wraps naturally)
                next_wr_ptr = wr_ptr_ff + {{(PTR_W-2){1'b0}}, 2'd2};

                // Increment count (saturate at DEPTH)
                if (count_ff <= DEPTH[PTR_W:0] - 2)
                    next_count = count_ff + {{PTR_W{1'b0}}, 1'b1} + {{PTR_W{1'b0}}, 1'b1};
                else if (count_ff == DEPTH[PTR_W:0] - 1)
                    next_count = DEPTH[PTR_W:0];

            end else if (plus_found) begin
                wr_en_0   = 1'b1;
                wr_addr_0 = wr_ptr_ff;
                wr_data_0 = plus_value;

                next_wr_ptr = wr_ptr_ff + {{(PTR_W-1){1'b0}}, 1'b1};
                if (count_ff < DEPTH[PTR_W:0])
                    next_count = count_ff + {{PTR_W{1'b0}}, 1'b1};

            end else if (minus_found) begin
                wr_en_0   = 1'b1;
                wr_addr_0 = wr_ptr_ff;
                wr_data_0 = minus_value;

                next_wr_ptr = wr_ptr_ff + {{(PTR_W-1){1'b0}}, 1'b1};
                if (count_ff < DEPTH[PTR_W:0])
                    next_count = count_ff + {{PTR_W{1'b0}}, 1'b1};
            end
        end
    end

    // -----------------------------------------------------------------------
    // Sequential block — flops + memory writes
    // -----------------------------------------------------------------------
    integer i;
    always @(posedge clk) begin
        wr_ptr_ff <= next_wr_ptr;
        count_ff  <= next_count;

        if (!rst_n || clear) begin
            for (i = 0; i < DEPTH; i = i + 1)
                mem[i] <= {WIDTH{1'b0}};
        end else begin
            if (wr_en_0)
                mem[wr_addr_0] <= wr_data_0;
            if (wr_en_1)
                mem[wr_addr_1] <= wr_data_1;
        end

        // Registered read port
        read_data_ff <= mem[rd_addr];
    end

endmodule
