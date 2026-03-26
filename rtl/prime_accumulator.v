`timescale 1ns / 1ps

// Prime accumulator sub-module for Prime Modes FSM.
// Maintains a BRAM-inferred FIFO (depth 32) for buffering found primes,
// a 32-bit running prime_count_ff, and a 20-entry last20 ring buffer.
// FIFO full stalls the mode_fsm via prime_fifo_full_ff output.
// FIFO read-side ports (prime_fifo_rd_en, prime_fifo_rd_data_ff,
// prime_fifo_empty_ff) are wired to the Phase 3 DDR2 writer.

module prime_accumulator #(
    parameter WIDTH      = 27,
    parameter FIFO_DEPTH = 32
) (
    input  wire             clk,
    input  wire             rst,
    // Write interface (from mode_fsm)
    input  wire             prime_valid,
    input  wire [WIDTH-1:0] prime_data,
    // FIFO read interface (for Phase 3 DDR2 writer)
    input  wire             prime_fifo_rd_en,
    output reg  [WIDTH-1:0] prime_fifo_rd_data_ff,
    output reg              prime_fifo_empty_ff,
    output reg              prime_fifo_full_ff,
    // Live status outputs
    output reg  [31:0]      prime_count_ff,
    // Last-20 ring buffer read interface (individual ports, Verilog-2001 compat)
    output reg  [WIDTH-1:0] last20_0_ff,  last20_1_ff,  last20_2_ff,  last20_3_ff,
    output reg  [WIDTH-1:0] last20_4_ff,  last20_5_ff,  last20_6_ff,  last20_7_ff,
    output reg  [WIDTH-1:0] last20_8_ff,  last20_9_ff,  last20_10_ff, last20_11_ff,
    output reg  [WIDTH-1:0] last20_12_ff, last20_13_ff, last20_14_ff, last20_15_ff,
    output reg  [WIDTH-1:0] last20_16_ff, last20_17_ff, last20_18_ff, last20_19_ff
);

    localparam PTR_W    = 5;   // log2(32) = 5
    localparam RING_SIZE = 20;

    // FIFO storage (BRAM inference via synchronous dual-port pattern)
    reg [WIDTH-1:0] fifo_mem [0:FIFO_DEPTH-1];

    // FIFO pointer and count registers (_ff suffix)
    reg [PTR_W-1:0] fifo_wr_ptr_ff;
    reg [PTR_W-1:0] fifo_rd_ptr_ff;
    reg [PTR_W:0]   fifo_count_ff;   // 6 bits: distinguishes full (32) from empty (0)

    // Ring buffer storage
    reg [WIDTH-1:0] last20_ff [0:19];
    reg [4:0]       ring_wr_ptr_ff;  // 0..19

    // Combinational next-state signals (blocking = only)
    reg [PTR_W-1:0] next_fifo_wr_ptr;
    reg [PTR_W-1:0] next_fifo_rd_ptr;
    reg [PTR_W:0]   next_fifo_count;
    reg [31:0]      next_prime_count;
    reg [4:0]       next_ring_wr_ptr;
    reg             next_fifo_empty;
    reg             next_fifo_full;


    //=====================================
    //========= COMBINATIONAL LOGIC =======
    //=====================================

    always @(*) begin
        // Defaults: hold current registered values
        next_fifo_wr_ptr  = fifo_wr_ptr_ff;
        next_fifo_rd_ptr  = fifo_rd_ptr_ff;
        next_fifo_count   = fifo_count_ff;
        next_prime_count  = prime_count_ff;
        next_ring_wr_ptr  = ring_wr_ptr_ff;
        next_fifo_empty   = prime_fifo_empty_ff;
        next_fifo_full    = prime_fifo_full_ff;

        if (rst) begin
            next_fifo_wr_ptr  = {PTR_W{1'b0}};
            next_fifo_rd_ptr  = {PTR_W{1'b0}};
            next_fifo_count   = {(PTR_W+1){1'b0}};
            next_prime_count  = 32'd0;
            next_ring_wr_ptr  = 5'd0;
            next_fifo_empty   = 1'b1;
            next_fifo_full    = 1'b0;
        end else begin
            // --- FIFO write ---
            if (prime_valid && !prime_fifo_full_ff) begin
                next_fifo_wr_ptr = fifo_wr_ptr_ff + {{PTR_W-1{1'b0}}, 1'b1};
                next_fifo_count  = fifo_count_ff  + {{PTR_W{1'b0}}, 1'b1};
            end

            // --- FIFO read ---
            if (prime_fifo_rd_en && !prime_fifo_empty_ff) begin
                next_fifo_rd_ptr = fifo_rd_ptr_ff + {{PTR_W-1{1'b0}}, 1'b1};
                next_fifo_count  = next_fifo_count - {{PTR_W{1'b0}}, 1'b1};
            end

            // --- FIFO full/empty flags (derived from next_fifo_count) ---
            next_fifo_empty = (next_fifo_count == {(PTR_W+1){1'b0}});
            next_fifo_full  = (next_fifo_count == FIFO_DEPTH[PTR_W:0]);

            // --- Prime count ---
            if (prime_valid && !prime_fifo_full_ff) begin
                next_prime_count = prime_count_ff + 32'd1;
            end

            // --- Ring buffer write pointer ---
            if (prime_valid && !prime_fifo_full_ff) begin
                if (ring_wr_ptr_ff == 5'd19) begin
                    next_ring_wr_ptr = 5'd0;
                end else begin
                    next_ring_wr_ptr = ring_wr_ptr_ff + 5'd1;
                end
            end
        end
    end


    //=====================================
    //========= FLOP REGISTERS ============
    //=====================================

    // Main pointer and count registers
    always @(posedge clk) begin
        fifo_wr_ptr_ff      <= next_fifo_wr_ptr;
        fifo_rd_ptr_ff      <= next_fifo_rd_ptr;
        fifo_count_ff       <= next_fifo_count;
        prime_count_ff      <= next_prime_count;
        ring_wr_ptr_ff      <= next_ring_wr_ptr;
        prime_fifo_empty_ff <= next_fifo_empty;
        prime_fifo_full_ff  <= next_fifo_full;
    end

    // FIFO write port (synchronous — required for BRAM inference)
    always @(posedge clk) begin
        if (prime_valid && !prime_fifo_full_ff) begin
            fifo_mem[fifo_wr_ptr_ff] <= prime_data;
        end
    end

    // FIFO read port (registered — required for BRAM inference)
    always @(posedge clk) begin
        if (prime_fifo_rd_en && !prime_fifo_empty_ff) begin
            prime_fifo_rd_data_ff <= fifo_mem[fifo_rd_ptr_ff];
        end
    end

    // Ring buffer write (explicit reset without for loop)
    always @(posedge clk) begin
        if (rst) begin
            last20_ff[0]  <= {WIDTH{1'b0}};
            last20_ff[1]  <= {WIDTH{1'b0}};
            last20_ff[2]  <= {WIDTH{1'b0}};
            last20_ff[3]  <= {WIDTH{1'b0}};
            last20_ff[4]  <= {WIDTH{1'b0}};
            last20_ff[5]  <= {WIDTH{1'b0}};
            last20_ff[6]  <= {WIDTH{1'b0}};
            last20_ff[7]  <= {WIDTH{1'b0}};
            last20_ff[8]  <= {WIDTH{1'b0}};
            last20_ff[9]  <= {WIDTH{1'b0}};
            last20_ff[10] <= {WIDTH{1'b0}};
            last20_ff[11] <= {WIDTH{1'b0}};
            last20_ff[12] <= {WIDTH{1'b0}};
            last20_ff[13] <= {WIDTH{1'b0}};
            last20_ff[14] <= {WIDTH{1'b0}};
            last20_ff[15] <= {WIDTH{1'b0}};
            last20_ff[16] <= {WIDTH{1'b0}};
            last20_ff[17] <= {WIDTH{1'b0}};
            last20_ff[18] <= {WIDTH{1'b0}};
            last20_ff[19] <= {WIDTH{1'b0}};
        end else if (prime_valid && !prime_fifo_full_ff) begin
            last20_ff[ring_wr_ptr_ff] <= prime_data;
        end
    end

    // Last-20 output copy (registered — updates output ports from internal array)
    always @(posedge clk) begin
        last20_0_ff  <= last20_ff[0];
        last20_1_ff  <= last20_ff[1];
        last20_2_ff  <= last20_ff[2];
        last20_3_ff  <= last20_ff[3];
        last20_4_ff  <= last20_ff[4];
        last20_5_ff  <= last20_ff[5];
        last20_6_ff  <= last20_ff[6];
        last20_7_ff  <= last20_ff[7];
        last20_8_ff  <= last20_ff[8];
        last20_9_ff  <= last20_ff[9];
        last20_10_ff <= last20_ff[10];
        last20_11_ff <= last20_ff[11];
        last20_12_ff <= last20_ff[12];
        last20_13_ff <= last20_ff[13];
        last20_14_ff <= last20_ff[14];
        last20_15_ff <= last20_ff[15];
        last20_16_ff <= last20_ff[16];
        last20_17_ff <= last20_ff[17];
        last20_18_ff <= last20_ff[18];
        last20_19_ff <= last20_ff[19];
    end

endmodule
