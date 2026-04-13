`timescale 1ns / 1ps

// Parameterized restoring binary division sub-module.
// Takes exactly WIDTH clock cycles per division after start is sampled.
// done_ff pulses HIGH for exactly one clock cycle when result is ready.

module divider #(
    parameter WIDTH = 27
) (
    input  wire             clk,
    input  wire             rst_n,
    input  wire             start,
    input  wire [WIDTH-1:0] dividend,
    input  wire [WIDTH-1:0] divisor,
    output reg              busy_ff,
    output reg              done_ff,
    output reg              dbz_ff,
    output reg  [WIDTH-1:0] quotient_ff,
    output reg  [WIDTH-1:0] remainder_ff
);

    // Internal flip-flop registers
    reg [WIDTH-1:0] dividend_copy_ff;
    reg [WIDTH-1:0] divisor_copy_ff;
    reg [WIDTH-1:0] acc_ff;
    reg [WIDTH-1:0] quo_ff;
    reg       [4:0] iter_ff;  // 5 bits covers WIDTH up to 31

    // Combinational next-state signals
    reg             next_busy;
    reg             next_done;
    reg             next_dbz;
    reg [WIDTH-1:0] next_quotient;
    reg [WIDTH-1:0] next_remainder;
    reg [WIDTH-1:0] next_dividend_copy;
    reg [WIDTH-1:0] next_divisor_copy;
    reg [WIDTH-1:0] next_acc;
    reg [WIDTH-1:0] next_quo;
    reg       [4:0] next_iter;

    // Trial-subtraction wire: shift accumulator left, bring in MSB of dividend_copy,
    // subtract divisor. WIDTH+1 bits to capture borrow in MSB.
    wire [WIDTH:0] acc_next;
    assign acc_next = {acc_ff[WIDTH-2:0], dividend_copy_ff[WIDTH-1]} - {1'b0, divisor_copy_ff};


    //=====================================
    //========= DIVIDER LOGIC =============
    //=====================================

    always @(*) begin
        // Defaults: hold current registered values
        next_busy          = busy_ff;
        next_done          = 1'b0;      // done pulses one cycle; default off
        next_dbz           = dbz_ff;
        next_quotient      = quotient_ff;
        next_remainder     = remainder_ff;
        next_dividend_copy = dividend_copy_ff;
        next_divisor_copy  = divisor_copy_ff;
        next_acc           = acc_ff;
        next_quo           = quo_ff;
        next_iter          = iter_ff;

        if (!rst_n) begin
            next_busy          = 1'b0;
            next_done          = 1'b0;
            next_dbz           = 1'b0;
            next_quotient      = {WIDTH{1'b0}};
            next_remainder     = {WIDTH{1'b0}};
            next_dividend_copy = {WIDTH{1'b0}};
            next_divisor_copy  = {WIDTH{1'b0}};
            next_acc           = {WIDTH{1'b0}};
            next_quo           = {WIDTH{1'b0}};
            next_iter          = 5'b0;
        end else if (busy_ff) begin
            if (iter_ff == WIDTH - 1) begin
                // Final iteration: latch quotient and remainder outputs
                if (acc_next[WIDTH] == 1'b0) begin
                    next_quotient  = {quo_ff[WIDTH-2:0], 1'b1};
                    next_remainder = acc_next[WIDTH-1:0];
                end else begin
                    next_quotient  = {quo_ff[WIDTH-2:0], 1'b0};
                    next_remainder = {acc_ff[WIDTH-2:0], dividend_copy_ff[WIDTH-1]};
                end
                next_dividend_copy = {dividend_copy_ff[WIDTH-2:0], 1'b0};
                next_busy          = 1'b0;
                next_done          = 1'b1;
                next_iter          = 5'b0;
            end else begin
                // Mid-iteration step
                if (acc_next[WIDTH] == 1'b0) begin
                    next_acc = acc_next[WIDTH-1:0];
                    next_quo = {quo_ff[WIDTH-2:0], 1'b1};
                end else begin
                    next_acc = {acc_ff[WIDTH-2:0], dividend_copy_ff[WIDTH-1]};
                    next_quo = {quo_ff[WIDTH-2:0], 1'b0};
                end
                next_dividend_copy = {dividend_copy_ff[WIDTH-2:0], 1'b0};
                next_iter          = iter_ff + 5'd1;
            end
        end else if (start) begin
            if (divisor == {WIDTH{1'b0}}) begin
                next_dbz  = 1'b1;
                next_done = 1'b1;
            end else begin
                next_dbz           = 1'b0;
                next_dividend_copy = dividend;
                next_divisor_copy  = divisor;
                next_acc           = {WIDTH{1'b0}};
                next_quo           = {WIDTH{1'b0}};
                next_iter          = 5'b0;
                next_busy          = 1'b1;
            end
        end else begin
            next_busy = busy_ff;  // idle: hold
        end
    end


    //=====================================
    //========= FLOP REGISTERS ============
    //=====================================

    always @(posedge clk) begin
        busy_ff          <= next_busy;
        done_ff          <= next_done;
        dbz_ff           <= next_dbz;
        quotient_ff      <= next_quotient;
        remainder_ff     <= next_remainder;
        dividend_copy_ff <= next_dividend_copy;
        divisor_copy_ff  <= next_divisor_copy;
        acc_ff           <= next_acc;
        quo_ff           <= next_quo;
        iter_ff          <= next_iter;
    end

endmodule
