`timescale 1ns / 1ps
// Behavioral simulation stub for Vivado FIFO Generator IP (pixel_fifo_ip).
// Asymmetric: Write=128 bits (ui_clk), Read=16 bits (clk_vga).
// 8:1 ratio. Write depth=64, Read depth=512. FWFT mode.
// For simulation only — replace with generated Vivado IP (.xci) for synthesis.
//
// Byte ordering: DDR2 word [127:0] is read out as 16-bit chunks
// from MSB to LSB: [127:112], [111:96], ..., [15:0].
// Each 16-bit chunk holds 2 pixels: {pixel_high[15:8], pixel_low[7:0]}.
// vga_driver unpacks each 16-bit pop into 2 sequential 8-bit pixels.

module pixel_fifo_ip (
    input  wire          wr_clk,
    input  wire          rd_clk,
    input  wire          rst,
    input  wire [127:0]  din,
    input  wire          wr_en,
    output wire          full,
    output wire [15:0]   dout,
    input  wire          rd_en,
    output wire          empty,
    output wire          wr_rst_busy,
    output wire          rd_rst_busy
);

    // Internal storage in 16-bit granularity
    localparam RD_DEPTH = 512;
    localparam RD_ADDR  = 9;   // log2(512)

    reg [15:0] mem [0:RD_DEPTH-1];
    reg [RD_ADDR:0] count;     // 0..RD_DEPTH (extra bit for full flag)
    reg [RD_ADDR-1:0] wr_ptr;  // increments by 8 on each 128-bit write
    reg [RD_ADDR-1:0] rd_ptr;

    reg [15:0] dout_reg;

    // Full when count >= RD_DEPTH; empty when count == 0
    assign full  = (count >= RD_DEPTH);
    assign empty = (count == 0);
    assign dout  = dout_reg;

    // rst_busy: deasserted after reset (simplified for sim)
    assign wr_rst_busy = 1'b0;
    assign rd_rst_busy = 1'b0;

    // Write side (128-bit: unpacks into 8 consecutive 16-bit words, MSB first)
    always @(posedge wr_clk) begin
        if (rst) begin
            wr_ptr <= 0;
            count  <= 0;
        end else begin
            if (wr_en && !full) begin
                mem[wr_ptr]     <= din[127:112];
                mem[wr_ptr + 1] <= din[111:96];
                mem[wr_ptr + 2] <= din[95:80];
                mem[wr_ptr + 3] <= din[79:64];
                mem[wr_ptr + 4] <= din[63:48];
                mem[wr_ptr + 5] <= din[47:32];
                mem[wr_ptr + 6] <= din[31:16];
                mem[wr_ptr + 7] <= din[15:0];
                wr_ptr <= wr_ptr + 8;
                count  <= count + 8;
            end
        end
    end

    // Read side (16-bit, FWFT behavior)
    always @(posedge rd_clk) begin
        if (rst) begin
            rd_ptr   <= 0;
            dout_reg <= 16'd0;
        end else begin
            if (rd_en && !empty) begin
                rd_ptr <= rd_ptr + 1;
            end
        end
    end

    // FWFT: dout always shows the next word
    always @(*) begin
        dout_reg = mem[rd_ptr];
    end

    // Adjust count on reads (cross-clock — simplified for simulation)
    always @(posedge rd_clk) begin
        if (!rst && rd_en && !empty) begin
            count <= count - 1;
        end
    end

endmodule
