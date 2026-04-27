`timescale 1ns / 1ps

// prime_count_calc — computes the total prime count and effective N-limit.
//
// effective_n_limit:
//   For time mode (latched_mode == 2), all primes are relevant so
//   effective_n_limit = max (all 1s).  Otherwise, use latched_n_limit.
//
// prime_total:
//   Sum of both engine counts plus an adjustment for hardcoded
//   primes 2 and 3 that the 6k±1 engines cannot discover:
//     effective_n_limit >= 3 → +2 (primes 2 and 3)
//     effective_n_limit >= 2 → +1 (prime 2 only)
//     otherwise              → +0
//
// Purely combinational, no clock domain.

module prime_count_calc #(
    parameter WIDTH = 27
) (
    input  wire [1:0]       latched_mode,
    input  wire [WIDTH-1:0] latched_n_limit,
    input  wire [31:0]      prime_count_plus,
    input  wire [31:0]      prime_count_minus,
    output reg  [WIDTH-1:0] effective_n_limit,
    output reg  [31:0]      prime_total
);

    reg [1:0] adj;

    always @(*) begin
        // Effective N-limit
        if (latched_mode == 2'd2)
            effective_n_limit = {WIDTH{1'b1}};
        else
            effective_n_limit = latched_n_limit;

        // Hardcoded prime adjustment for 2 and 3
        if (effective_n_limit >= {{(WIDTH-2){1'b0}}, 2'd3})
            adj = 2'd2;
        else if (effective_n_limit >= {{(WIDTH-2){1'b0}}, 2'd2})
            adj = 2'd1;
        else
            adj = 2'd0;

        // Total
        prime_total = prime_count_plus + prime_count_minus + {30'd0, adj};
    end

endmodule
