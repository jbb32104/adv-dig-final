`timescale 1ns / 1ps
// Behavioral simulation stub for Vivado FIFO Generator IP (prime_fifo_ip).
// Asymmetric: Write=32 bits, Read=128 bits (4:1 packing).
// Write depth=128, Read depth=32. For simulation only.
// Models independent clocks: writes on wr_clk, reads on rd_clk.
// Replace with the generated Vivado IP (.xci) for synthesis.

module prime_fifo_ip (
    input  wire          wr_clk,
    input  wire          rd_clk,
    input  wire          rst,
    input  wire [31:0]   din,
    input  wire          wr_en,
    output wire          full,
    output wire [127:0]  dout,
    input  wire          rd_en,
    output wire          empty,
    output wire          wr_rst_busy,
    output wire          rd_rst_busy
);
    // Internal storage in 32-bit granularity
    localparam WR_DEPTH = 128;
    localparam WR_ADDR  = 7;   // log2(128)

    reg [31:0] mem [0:WR_DEPTH-1];
    reg [WR_ADDR:0] wr_count;  // 0..WR_DEPTH (extra bit for full flag)
    reg [WR_ADDR-1:0] wr_ptr;
    reg [WR_ADDR-1:0] rd_ptr;  // increments by 4 on each 128-bit read
    reg [127:0] dout_reg;

    integer i;

    // Full when wr_count == WR_DEPTH; empty when fewer than 4 words available
    assign full  = (wr_count == WR_DEPTH);
    assign empty = (wr_count < 4);
    assign dout  = dout_reg;

    // rst_busy: deasserted after reset (simplified for sim)
    assign wr_rst_busy = 1'b0;
    assign rd_rst_busy = 1'b0;

    // Write side
    always @(posedge wr_clk) begin
        if (rst) begin
            wr_count <= 0;
            wr_ptr   <= 0;
            for (i = 0; i < WR_DEPTH; i = i + 1)
                mem[i] <= 32'd0;
        end else begin
            if (wr_en && !full) begin
                mem[wr_ptr] <= din;
                wr_ptr      <= wr_ptr + 1;
                wr_count    <= wr_count + 1;
            end
        end
    end

    // Read side (128-bit: packs 4 consecutive 32-bit words)
    always @(posedge rd_clk) begin
        if (rst) begin
            rd_ptr   <= 0;
            dout_reg <= 128'd0;
        end else begin
            if (rd_en && !empty) begin
                dout_reg <= {mem[rd_ptr+3], mem[rd_ptr+2], mem[rd_ptr+1], mem[rd_ptr]};
                rd_ptr   <= rd_ptr + 4;
            end
        end
    end

    // Adjust count on reads (cross-clock — simplified for simulation)
    always @(posedge rd_clk) begin
        if (!rst && rd_en && !empty) begin
            wr_count <= wr_count - 4;
        end
    end

endmodule
