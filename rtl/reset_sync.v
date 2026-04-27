`timescale 1ns / 1ps

// Reset synchronizer — 2-FF chain for asynchronous active-low reset.
//
// Outputs both polarities (active-high and active-low) so downstream
// modules and Xilinx IP cores can use whichever convention they need.
//
// Usage:
//   reset_sync u_rst_sync (
//       .clk    (clk),
//       .rst_n  (cpu_rst_n),  // async active-low input
//       .rst_ff (rst),        // synchronized active-high output
//       .rst_n_ff (rst_n)     // synchronized active-low output
//   );

module reset_sync (
    input  wire clk,
    input  wire rst_n,       // asynchronous active-low reset input
    output reg  rst_ff,      // synchronized active-high reset
    output reg  rst_n_ff     // synchronized active-low reset
);

    // -----------------------------------------------------------------------
    // Registered state
    // -----------------------------------------------------------------------
    reg meta_ff;

    // -----------------------------------------------------------------------
    // Combinational next-state signals
    // -----------------------------------------------------------------------
    reg meta_next;
    reg rst_next;
    reg rst_n_next;

    // -----------------------------------------------------------------------
    // Combinational logic
    // -----------------------------------------------------------------------
    always @(*) begin
        meta_next  = rst_n;       // first stage samples async input
        rst_n_next = meta_ff;     // second stage outputs clean signal
        rst_next   = ~meta_ff;    // inverted for active-high consumers
    end

    // -----------------------------------------------------------------------
    // Sequential block — flops only
    // -----------------------------------------------------------------------
    always @(posedge clk) begin
        meta_ff  <= meta_next;
        rst_ff   <= rst_next;
        rst_n_ff <= rst_n_next;
    end

endmodule
