`timescale 1ns / 1ps

// pulse_cdc — reusable toggle-based CDC for single-cycle pulses.
//
// Converts a pulse in the source clock domain to a pulse in the
// destination clock domain using a toggle + 2-FF synchroniser +
// edge detect.  Latency is 2-3 destination clock cycles.
//
// Clock domains: src_clk (source), dst_clk (destination).

module pulse_cdc (
    input  wire src_clk,
    input  wire src_rst_n,
    input  wire src_pulse,
    input  wire dst_clk,
    input  wire dst_rst_n,
    output reg  dst_pulse
);

    // -------------------------------------------------------------------
    // Source domain: pulse -> toggle
    // -------------------------------------------------------------------
    reg toggle_ff;
    reg toggle_next;

    always @(*) begin
        toggle_next = toggle_ff;
        if (src_pulse)
            toggle_next = ~toggle_ff;
        if (!src_rst_n)
            toggle_next = 1'b0;
    end

    always @(posedge src_clk) begin
        toggle_ff <= toggle_next;
    end

    // -------------------------------------------------------------------
    // Destination domain: 2-FF sync + edge detect
    // -------------------------------------------------------------------
    reg sync0_ff, sync1_ff, sync2_ff;
    reg sync0_next, sync1_next, sync2_next;

    always @(*) begin
        sync0_next = toggle_ff;
        sync1_next = sync0_ff;
        sync2_next = sync1_ff;
        if (!dst_rst_n) begin
            sync0_next = 1'b0;
            sync1_next = 1'b0;
            sync2_next = 1'b0;
        end
    end

    always @(posedge dst_clk) begin
        sync0_ff <= sync0_next;
        sync1_ff <= sync1_next;
        sync2_ff <= sync2_next;
    end

    // Edge detect: pulse on toggle transition
    always @(*) begin
        dst_pulse = sync2_ff ^ sync1_ff;
    end

endmodule
