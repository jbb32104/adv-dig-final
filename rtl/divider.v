// divider.v
// Parameterized restoring binary division sub-module.
// Takes exactly WIDTH clock cycles to complete one division (after start is sampled).
// done_ff pulses HIGH for exactly one clock cycle when result is ready.
// CSEE 4280 compliant: _ff suffix on all FFs, no for loops, no blocking in posedge block.

module divider #(
    parameter WIDTH = 27
) (
    input  wire             clk,
    input  wire             rst,
    input  wire             start,
    input  wire [WIDTH-1:0] dividend,
    input  wire [WIDTH-1:0] divisor,
    output reg              busy_ff,
    output reg              done_ff,
    output reg              dbz_ff,
    output reg  [WIDTH-1:0] quotient_ff,
    output reg  [WIDTH-1:0] remainder_ff
);

    // Internal registers (all with _ff suffix per INFRA-03)
    reg [WIDTH-1:0] dividend_copy_ff;
    reg [WIDTH-1:0] divisor_copy_ff;
    reg [WIDTH-1:0] acc_ff;
    reg [WIDTH-1:0] quo_ff;
    reg       [4:0] iter_ff;  // 5 bits sufficient for WIDTH up to 27

    // Combinational trial-subtraction wire:
    // Shift accumulator left by 1, bring in MSB of dividend_copy_ff, subtract divisor.
    // WIDTH+1 bits wide to capture borrow in MSB.
    wire [WIDTH:0] acc_next;
    assign acc_next = {acc_ff[WIDTH-2:0], dividend_copy_ff[WIDTH-1]} - {1'b0, divisor_copy_ff};

    // Sequential block -- non-blocking assignments only (INFRA-04)
    always @(posedge clk) begin
        if (rst) begin
            busy_ff          <= 1'b0;
            done_ff          <= 1'b0;
            dbz_ff           <= 1'b0;
            quotient_ff      <= {WIDTH{1'b0}};
            remainder_ff     <= {WIDTH{1'b0}};
            dividend_copy_ff <= {WIDTH{1'b0}};
            divisor_copy_ff  <= {WIDTH{1'b0}};
            acc_ff           <= {WIDTH{1'b0}};
            quo_ff           <= {WIDTH{1'b0}};
            iter_ff          <= 5'b0;
        end else begin
            // Default done_ff to 0; overridden on completion/dbz cycles below
            done_ff <= 1'b0;

            if (busy_ff) begin
                // Iteration step
                if (iter_ff == WIDTH - 1) begin
                    // Final iteration: compute last bit, then assert outputs
                    if (acc_next[WIDTH] == 1'b0) begin
                        // Subtraction succeeded (no borrow)
                        quotient_ff  <= {quo_ff[WIDTH-2:0], 1'b1};
                        remainder_ff <= acc_next[WIDTH-1:0];
                    end else begin
                        // Subtraction failed (restore)
                        quotient_ff  <= {quo_ff[WIDTH-2:0], 1'b0};
                        remainder_ff <= {acc_ff[WIDTH-2:0], dividend_copy_ff[WIDTH-1]};
                    end
                    // Advance dividend shift even on final cycle (consistent with mid-iter)
                    dividend_copy_ff <= {dividend_copy_ff[WIDTH-2:0], 1'b0};
                    busy_ff  <= 1'b0;
                    done_ff  <= 1'b1;
                    iter_ff  <= 5'b0;
                end else begin
                    // Mid-iteration step
                    if (acc_next[WIDTH] == 1'b0) begin
                        // Subtraction succeeded
                        acc_ff  <= acc_next[WIDTH-1:0];
                        quo_ff  <= {quo_ff[WIDTH-2:0], 1'b1};
                    end else begin
                        // Subtraction failed (restore)
                        acc_ff  <= {acc_ff[WIDTH-2:0], dividend_copy_ff[WIDTH-1]};
                        quo_ff  <= {quo_ff[WIDTH-2:0], 1'b0};
                    end
                    dividend_copy_ff <= {dividend_copy_ff[WIDTH-2:0], 1'b0};
                    iter_ff          <= iter_ff + 5'd1;
                end
            end else if (start) begin
                // Start a new division
                if (divisor == {WIDTH{1'b0}}) begin
                    // Divide-by-zero
                    dbz_ff  <= 1'b1;
                    done_ff <= 1'b1;
                end else begin
                    dbz_ff           <= 1'b0;
                    dividend_copy_ff <= dividend;
                    divisor_copy_ff  <= divisor;
                    acc_ff           <= {WIDTH{1'b0}};
                    quo_ff           <= {WIDTH{1'b0}};
                    iter_ff          <= 5'b0;
                    busy_ff          <= 1'b1;
                end
            end else begin
                // Idle -- do nothing (satisfies INFRA-07 final-else requirement)
                busy_ff <= busy_ff;
            end
        end
    end

endmodule
