`timescale 1ns / 1ps
// Behavioral simulation stub for Vivado FIFO Generator IP (prime_fifo_ip).
// Width=32 bits, Depth=32 words. For simulation only.
// rd_clk is accepted but unused; all state clocks on wr_clk.
// Replace with the generated Vivado IP (.xci) for synthesis.

module prime_fifo_ip (
    input  wire        wr_clk,
    input  wire        rd_clk,  // accepted, ignored in stub
    input  wire        rst,
    input  wire [31:0] din,
    input  wire        wr_en,
    output wire        full,
    output wire [31:0] dout,
    input  wire        rd_en,
    output wire        empty
);
    localparam DEPTH = 32;

    reg [31:0] mem [0:DEPTH-1];
    reg [5:0]  count;           // 0..32 (6 bits to distinguish full=32 from empty=0)
    reg [4:0]  wr_ptr;
    reg [4:0]  rd_ptr;
    reg [31:0] dout_reg;

    integer i;

    // Flags are combinational from the registered count — one-cycle latency,
    // matching the real Vivado IP's registered-flag behavior.
    assign full  = (count[5]);          // count == 32
    assign empty = (count == 6'd0);
    assign dout  = dout_reg;

    always @(posedge wr_clk) begin
        if (rst) begin
            count   <= 6'd0;
            wr_ptr  <= 5'd0;
            rd_ptr  <= 5'd0;
            dout_reg <= 32'd0;
            for (i = 0; i < DEPTH; i = i + 1)
                mem[i] <= 32'd0;
        end else begin
            // Write port
            if (wr_en && !full) begin
                mem[wr_ptr] <= din;
                wr_ptr      <= wr_ptr + 5'd1;
            end
            // Read port
            if (rd_en && !empty) begin
                dout_reg <= mem[rd_ptr];
                rd_ptr   <= rd_ptr + 5'd1;
            end
            // Count: handle all four wr/rd combinations
            if ((wr_en && !full) && !(rd_en && !empty))
                count <= count + 6'd1;
            else if (!(wr_en && !full) && (rd_en && !empty))
                count <= count - 6'd1;
            // else: simultaneous r+w or neither — count unchanged
        end
    end

endmodule
