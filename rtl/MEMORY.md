This file is for showing how the memory should work, and how we should find the primes and store them.

## From the top level...
We will instantiate two prime_engine modules (one for 6k + 1 and one for 6k - 1). Each prime_engine module has the following I/O:
```Verilog
    input  wire             clk, // clock
    input  wire             rst, // reset
    input  wire             start, // start prime algorithm signal
    input  wire [WIDTH-1:0] candidate, // candidate to check
    output reg              done_ff, // prime algo done signal
    output reg              is_prime_ff, // prime algo result
    output reg              busy_ff // prime being calculated
```

## prime_engine --> FIFO --> DDR2 Pipeline
Each prime_engine has a dedicated FIFO (Queue data structure) that buffers the output between BRAM and DDR2.
- Each FIFO is 16KB with 32-bit write and 128-bit read ports
- The pattern of the data in each fifo is bitmapped for compression

Ex.
1. 6k + 1 and 6k - 1 FIFO: initially empty
2. Both modules compute primes for k = 1 (they may finish in different # of clocks)
3. Each FIFO has a dedicated register meant for holding primes
- 6k + 1 reg is 0...00 then concludes 7 is prime at k = 1
- reg value becomes 0...01 where the LSB corresponds with k = 1 -- 6(1) + 1 = 7
- 6k - 1 reg goes from 0...00 to 0...01 after completion with k = 1 -- 6(1) - 1 = 5
- note: this isn't exact since the first few iterations will have 2 and 3 as the first primes.
4. This pattern will repeat until the 32-bits are full with an accurate prime bitmap
- It writes each 32-bit pattern to the corresponding FIFO buffer
which feeds to memory as fast as it can (handled by memory manager)

## Constraints with this method
This method primarily relies on the fact that over a long enough time, the 6k + 1 and the 6k - 1 concurrent sequential paths will take about the same amount of time. Likely, one path will have k lead, so like the 6k + 1 is at k = 40,000 and the 6k - 1 path is at k = 39,400. This is really only an issue in terms of what we display to the user, and in the testing mode. We must consider when we display the "largest prime" to the user, we have to pick the lowest of the two k values to display the primality of.