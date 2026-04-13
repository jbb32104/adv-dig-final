`timescale 1ns / 1ps

// Bit-packing prime accumulator.
// Accepts one bit per completed candidate test (prime_valid + is_prime).
// Packs 32 bits into a word (LSB = first candidate received), then writes
// that word to the Vivado FIFO IP (prime_fifo_ip) for DDR2 transfer.
// flush zero-pads the current partial word and writes it at mode end.
//
// FIFO IP configuration (prime_fifo_ip):
//   Interface      : Native
//   Implementation : Independent clocks, Block RAM
//   Write width    : 32 bits,   Write depth : 16384
//   Read  width    : 128 bits,  Read  depth : 4096  (asymmetric)
//   Output register: enabled (1-cycle read latency)
//   Reset type     : Synchronous
//
// Two instances of this module are used: one for the 6k+1 engine,
// one for the 6k-1 engine. Each gets its own prime_fifo_ip instance.

module prime_accumulator (
    // Write-domain clock (logic clock, shared with prime_engine / mode_fsm)
    input  wire        clk,
    input  wire        rst_n,
    // Read-domain clock (MIG DDR2 ui_clk)
    input  wire        rd_clk,
    // Write interface: one pulse per engine done_ff
    input  wire        prime_valid,     // pulse on every completed candidate test
    input  wire        is_prime,        // 1 = candidate is prime, 0 = composite
    // Flush: zero-pads partial word and writes to FIFO at mode end
    input  wire        flush,           // pulse to flush partial shift register
    output reg         flush_done_ff,   // pulses one cycle after flush write completes
    // FIFO read interface (rd_clk domain — to DDR2 writer)
    // Read side is 128 bits: four 32-bit bitmap words packed per MIG transaction
    input  wire          prime_fifo_rd_en,
    output wire [127:0]  prime_fifo_rd_data,
    output wire          prime_fifo_empty,
    output wire          prime_fifo_full,
    // Status (clk domain)
    output reg  [31:0] prime_count_ff   // running count of primes found
);

    // -----------------------------------------------------------------------
    // Bit-packing shift register
    // -----------------------------------------------------------------------
    reg [31:0] shift_reg_ff;
    reg [4:0]  bit_count_ff;    // 0..31: position of next incoming bit

    // -----------------------------------------------------------------------
    // FIFO IP write controls (combinational)
    // -----------------------------------------------------------------------
    reg        do_fifo_write;
    reg [31:0] fifo_write_data;

    // -----------------------------------------------------------------------
    // FIFO IP instantiation
    // -----------------------------------------------------------------------
    wire wr_rst_busy, rd_rst_busy;

    prime_fifo_ip u_fifo (
        .wr_clk     (clk),
        .rd_clk     (rd_clk),
        .rst        (~rst_n),
        .din        (fifo_write_data),       // 32-bit write side
        .wr_en      (do_fifo_write & ~wr_rst_busy),
        .full       (prime_fifo_full),
        .dout       (prime_fifo_rd_data),    // 128-bit read side
        .rd_en      (prime_fifo_rd_en & ~rd_rst_busy),
        .empty      (prime_fifo_empty),
        .wr_rst_busy(wr_rst_busy),
        .rd_rst_busy(rd_rst_busy)
    );

    // -----------------------------------------------------------------------
    // Combinational: bit packing + flush logic
    // -----------------------------------------------------------------------
    reg [31:0] next_shift_reg;
    reg [4:0]  next_bit_count;
    reg [31:0] next_prime_count;
    reg        next_flush_done;

    always @(*) begin
        next_shift_reg   = shift_reg_ff;
        next_bit_count   = bit_count_ff;
        next_prime_count = prime_count_ff;
        next_flush_done  = 1'b0;
        do_fifo_write    = 1'b0;
        fifo_write_data  = 32'd0;

        if (!rst_n) begin
            next_shift_reg   = 32'd0;
            next_bit_count   = 5'd0;
            next_prime_count = 32'd0;
        end else begin

            // --- Bit packing ---
            // flush takes priority if both arrive simultaneously (not expected in practice)
            if (prime_valid && !flush) begin
                next_shift_reg = shift_reg_ff | ({31'b0, is_prime} << bit_count_ff);

                if (is_prime)
                    next_prime_count = prime_count_ff + 32'd1;

                if (bit_count_ff == 5'd31) begin
                    // Word complete: write to FIFO
                    // FIFO full: word dropped — mode_fsm stalls engines via prime_fifo_full
                    fifo_write_data = next_shift_reg;
                    do_fifo_write   = !prime_fifo_full;
                    next_shift_reg  = 32'd0;
                    next_bit_count  = 5'd0;
                end else begin
                    next_bit_count  = bit_count_ff + 5'd1;
                end
            end

            // --- Flush: zero-pad partial word and write ---
            if (flush) begin
                if (bit_count_ff != 5'd0) begin
                    fifo_write_data = shift_reg_ff;
                    do_fifo_write   = !prime_fifo_full;
                    next_shift_reg  = 32'd0;
                    next_bit_count  = 5'd0;
                end
                next_flush_done = 1'b1;     // pulse regardless — mode_fsm waits on this
            end
        end
    end

    // -----------------------------------------------------------------------
    // Flop registers (clk domain)
    // -----------------------------------------------------------------------
    always @(posedge clk) begin
        shift_reg_ff   <= next_shift_reg;
        bit_count_ff   <= next_bit_count;
        prime_count_ff <= next_prime_count;
        flush_done_ff  <= next_flush_done;
    end

endmodule
