# Phase 1: Prime Engine Core - Research

**Researched:** 2026-03-25
**Domain:** Synthesizable FSM design in Verilog — 6k±1 trial division, integer division/modulo hardware, sqrt bounding, class coding rules
**Confidence:** HIGH (core patterns from authoritative sources; algorithm math is deterministic)

---

## Summary

Phase 1 delivers a synthesizable Verilog FSM that implements the 6k±1 primality trial-division algorithm and a self-checking testbench that sweeps candidates 2–10,007 against a golden list. The two hardest sub-problems are: (1) avoiding hardware division/modulo while still checking divisibility, and (2) bounding the divisor loop at sqrt(candidate) without calling a behavioral sqrt() function.

The canonical solution to both problems is to track the current trial divisor `d` in a register and compare `d * d` against the candidate. When `d * d > candidate`, the loop terminates — this is a synthesizable multiply-and-compare with no division needed for the bound check. Divisibility itself (n mod d == 0) requires a multi-cycle restoring or non-restoring binary division sub-FSM, or can be computed with a sequential subtraction loop. The restoring binary division approach is the most standard on Xilinx — it takes exactly WIDTH cycles for a WIDTH-bit dividend and maps cleanly to an inner-FSM or sub-module pattern.

The class coding rules (INFRA-03 through INFRA-08) are strict and must be enforced from the very first line of RTL. The two-always-block FSM style (one `always @(posedge clk)` for FF registers, one `always @(*)` for next-state/output combinational logic) is the exact pattern required by the rules and is also the synthesis-friendly style endorsed by Xilinx documentation.

**Primary recommendation:** Implement the prime engine as a main FSM with an embedded divider sub-FSM (or dedicated `divider.v` module). Use `d * d > candidate` for the sqrt bound instead of computing sqrt. Implement modulo as restoring binary division (N cycles for N-bit numbers). Keep the divider as a separate instantiation to isolate the multi-cycle wait from the outer 6k±1 state machine.

---

## Project Constraints (from CLAUDE.md / PROJECT.md)

No CLAUDE.md exists. Project rules are drawn from PROJECT.md (confirmed authoritative).

### Mandatory Class Rules (CSEE 4280) — violations cause 0.0 multiplier on functional grade

| Rule | What it means for this phase |
|------|------------------------------|
| ANSI module port declarations | Use `module foo #(...) (input wire ..., output reg ...)` style, not old-style port lists |
| No combinational logic at top level | N/A for Phase 1 (no top-level module yet), but prime_engine.v must be clean |
| `_n` suffix for active-low signals | Any active-low enables, resets, etc. must have `_n` name |
| `_ff` suffix for flip-flop registers | Every `reg` driven by `always @(posedge clk)` carries `_ff` suffix |
| Blocking (`=`) and non-blocking (`<=`) in separate `always` blocks | Never mix in the same block |
| No `for` loops in synthesis files | The 6k±1 iteration must be an FSM state, not a for loop |
| `always @(posedge clk)` for FFs only | No sensitivity list additions (no negedge, no async reset in posedge block) |
| Synchronous reset decoded in `always @(*)` | Reset is a combinational input to next-state logic, not a posedge-clock sensitivity item |
| `default:` in all `case` statements | Required even if all enum values are covered |
| Final `else` in all `if-else` chains | Required even if logically unreachable |
| Self-checking testbench for every module | prime_engine_tb.v must assert and auto-report pass/fail |

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| PRIME-01 | 6k±1 trial division engine as synthesizable FSM (no for loops, no blocking/non-blocking mixing) | Section: 6k±1 FSM Design, Integer Division Sub-FSM, Don't Hand-Roll |
| INFRA-03 | All module flip-flops use `_ff` suffix; active-low signals use `_n` suffix | Section: Class-Compliant FSM Structure, Code Examples |
| INFRA-04 | Blocking (`=`) and non-blocking (`<=`) in strictly separate `always` blocks | Section: Class-Compliant FSM Structure, Code Examples |
| INFRA-05 | No `for` loops in any synthesis file | Section: 6k±1 FSM Design, Common Pitfalls |
| INFRA-06 | All combinational logic (including synchronous reset decode) in `always @(*)`; only `always @(posedge clk)` for flip-flops | Section: Class-Compliant FSM Structure, Code Examples |
| INFRA-07 | `default:` in all `case` statements; final `else` in all `if-else` chains | Section: Common Pitfalls, Code Examples |
| INFRA-08 | Self-checking Vivado testbench for every module; iVerilog for rapid iteration | Section: Testbench Strategy, Validation Architecture |
</phase_requirements>

---

## Standard Stack

### Core
| Tool/Library | Version | Purpose | Why Standard |
|---|---|---|---|
| iVerilog (Icarus Verilog) | 12.0 (installed: `/opt/homebrew/bin/iverilog`) | Behavioral simulation, rapid iteration, self-checking TB runs | Fast compile, free, available on dev machine right now |
| vvp | bundled with iVerilog 12.0 | Execute compiled iVerilog simulations | Inseparable from iVerilog |
| Vivado | Target (not in PATH on dev machine) | Synthesis, implementation, Vivado sim for final TB check | Class requirement; produces bitstream |
| Verilog-2001 | Language standard | Synthesis target language | Class requirement (Verilog only, not SV) |

### Supporting
| Tool | Purpose | When to Use |
|------|---------|-------------|
| Python 3 (system) | Generate golden prime list as a Verilog `$readmemh` hex file or include file | Use when building the testbench golden list — Python's primality is trivially correct |
| `$dumpvars` / `$dumpfile` | VCD waveform dump for debugging FSM states | Use during development when FSM hangs or produces wrong output |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Restoring binary division sub-FSM | Xilinx Divider IP (LUT/DSP) | IP is simpler but requires IP wizard setup; sub-FSM is portable, zero IP overhead, controllable latency |
| `d*d > candidate` bound check | Non-restoring sqrt sub-FSM | sqrt sub-FSM is cleaner conceptually but adds another multi-cycle module; multiply-compare is simpler and uses DSP48 inference |
| Separate `divider.v` module | Inline div states in prime_engine.v | Inline is fewer files but makes the FSM harder to read/test; separate module is cleaner |

**Installation:** iVerilog already installed. No `npm install` equivalent needed.

---

## 6k±1 Algorithm — FSM Design

### Mathematical Basis (HIGH confidence — number theory)

For any integer n > 3:
- If n is divisible by 2 or 3, n is not prime.
- All remaining prime candidates must be of the form 6k±1 (i.e., 6k-1 or 6k+1 for k = 1, 2, 3, ...).
- Trial division only needs to check divisors of form 6k-1 and 6k+1.
- The loop terminates when the current divisor d satisfies d * d > n (equivalent to d > sqrt(n)).

This reduces trial divisors by approximately 2/3 compared to naive trial division.

### FSM State Map

The planned states from the roadmap are correct and complete:

| State | Action | Next State |
|-------|--------|------------|
| `IDLE` | Wait for `start` pulse; latch `candidate` | `CHECK_2_3` |
| `CHECK_2_3` | Check if candidate == 2 or == 3 (primes); check if divisible by 2 or 3 (composites); initialize k=1, d=5 | `DONE` (if trivially resolved) or `INIT_K` |
| `INIT_K` | Compute d = 6k-1 = 6*k - 1 (first divisor in this k-pair); start divider sub-FSM | `TEST_KM1` |
| `TEST_KM1` | Wait for divider done; if remainder==0, composite; else check bound (d*d > candidate?) | `DONE` (composite or d*d>n) or `TEST_KP1` |
| `TEST_KP1` | d = 6k+1 = d + 2; start divider sub-FSM for new d | (wait for divider) then check remainder and bound |
| (after TEST_KP1 passes) | k = k + 1; back to INIT_K | `INIT_K` |
| `DONE` | Assert `is_prime` output; assert `done` | `IDLE` (on next start or explicit clear) |

**Key insight on state count:** TEST_KM1 and TEST_KP1 each require waiting for the divider sub-FSM. The outer FSM transitions to a "waiting" sub-state while the divider runs, OR the divider is a separate module and the outer FSM simply holds in TEST_KM1/TEST_KP1 until a `div_done` signal goes high.

### Sqrt Bound Without sqrt() — CRITICAL

Do NOT compute sqrt(candidate). Instead, maintain a register `d_ff` (the current trial divisor) and compute:

```verilog
// In combinational block:
// bound_exceeded = (d_ff * d_ff > candidate_ff)
// This uses one DSP48 multiplier, inferred automatically by Vivado
wire [53:0] d_squared; // d is at most 27 bits for candidate up to 99,999,999
assign d_squared = d_ff * d_ff;
wire bound_exceeded = (d_squared > candidate_ff);
```

For candidate up to 99,999,999 (< 2^27), d ranges up to ~10,000 (< 2^14). So `d*d` fits in 28 bits. No overflow concern.

**Width calculation for Phase 1 (up to 10,007):**
- candidate: 14 bits sufficient (2^14 = 16384 > 10007)
- For the full spec (up to 99,999,999): candidate needs 27 bits, d needs 14 bits, d*d fits in 28 bits.
- Use 27-bit candidate width from the start to avoid a later refactor.

---

## Integer Division Sub-FSM (MEDIUM-HIGH confidence)

### Why Not the `%` Operator

Vivado synthesis supports the `%` (modulo) operator **only when the divisor is a constant power of 2**. For variable divisors (which is exactly the case here — d changes each iteration), the `%` operator will either fail synthesis or infer a very large combinational divider that may not meet timing at 100 MHz.

Source: AMD Adaptive Support KBA; confirmed by edaboard forum discussions.

### Restoring Binary Division Algorithm

The standard synthesizable approach is restoring (or non-restoring) binary long division:

- For an N-bit dividend and M-bit divisor, the algorithm takes N clock cycles.
- Each cycle: shift accumulator left 1 bit, shift in one bit of dividend; if accumulator >= divisor, subtract divisor and set quotient bit; else keep accumulator.
- Result: quotient and remainder available after N cycles.

For Phase 1 (candidate up to 10,007, divisors up to ~100):
- Dividend (candidate) = 14 bits → 14 cycles per division
- Full spec (candidate up to 99,999,999) = 27 bits → 27 cycles per division

**Latency estimate for primality check of n near 10,000:**
- Number of 6k±1 divisors to check up to sqrt(10000) ≈ 100 → ~17 pairs (d = 5, 7, 11, 13, ... up to ~97)
- Each pair requires 2 divisions × 14 cycles = 28 cycles
- Plus FSM overhead: ~5 cycles per pair
- Total: ~17 × 33 ≈ 561 cycles at 100 MHz = 5.6 µs per candidate

For candidate near 99,999,999 (full spec):
- sqrt ≈ 10,000 → ~1,667 pairs
- Each pair: 2 × 27 = 54 cycles + overhead
- Total: ~1,667 × 60 ≈ 100,000 cycles at 100 MHz = 1 ms per candidate (worst case, large primes)

### Divider Interface Pattern (Project F style)
Source: projectf.io/posts/division-in-verilog/ — HIGH confidence (official open-source RTL reference)

```verilog
// divider.v interface (synthesizable, no for loops)
module divider #(
    parameter WIDTH = 27
) (
    input  wire             clk,
    input  wire             rst,        // synchronous reset
    input  wire             start,      // pulse to begin
    input  wire [WIDTH-1:0] dividend,
    input  wire [WIDTH-1:0] divisor,
    output reg              busy_ff,
    output reg              done_ff,    // pulses high one cycle when complete
    output reg              dbz_ff,     // divide-by-zero flag
    output reg [WIDTH-1:0]  quotient_ff,
    output reg [WIDTH-1:0]  remainder_ff
);
```

The divider module uses:
- One `always @(posedge clk)` block for all FFs (WIDTH-bit shift registers, counter)
- One `always @(*)` block for combinational subtraction logic
- No for loops
- `done_ff` pulses for exactly one cycle when result is ready

### Alternative: Subtraction-Based Modulo (Simpler, Slower)

For Phase 1 only (small divisors), a simpler approach works:
- To test if `candidate % d == 0`: initialize accumulator to `candidate`, subtract `d` repeatedly until accumulator < d.
- If accumulator == 0, divisible. Otherwise not.
- Worst case cycles = candidate / d. For candidate=10007 and d=5: 2001 cycles. Too slow for large candidates.
- **Do not use this for the main implementation.** Use restoring binary division.

---

## Architecture Patterns

### Recommended File Structure

```
rtl/
├── prime_engine.v       # Main 6k±1 FSM (outer)
├── divider.v            # Restoring binary division sub-module
sim/
├── prime_engine_tb.v    # Self-checking testbench
├── golden_primes.vh     # `include file with localparam golden list OR
├── golden_primes.hex    # $readmemh file for testbench memory
scripts/
└── gen_golden_primes.py # Python script to generate golden list
```

### Class-Compliant Two-Always-Block FSM Pattern

This is the exact pattern required by INFRA-04 and INFRA-06. The key discipline: the `always @(posedge clk)` block contains ONLY non-blocking assignments to `_ff` registers. The `always @(*)` block contains ONLY blocking assignments and determines next-state values.

```verilog
// Source: CSEE 4280 class rules + chipverify.com FSM guide

// --- State register (FF block) ---
// ALL signals driven here must have _ff suffix
always @(posedge clk) begin
    if (rst) begin              // rst is synchronous — decoded here, NOT in sensitivity list
        state_ff    <= IDLE;
        // ... other _ff resets
    end else begin
        state_ff    <= next_state;  // non-blocking only
        // ... other _ff updates
    end
end

// --- Next-state / output logic (combinational block) ---
// ALL assignments here are blocking (=)
// rst checked here as a combinational input
always @(*) begin
    // Default all outputs to avoid latches (INFRA-07)
    next_state  = state_ff;
    done        = 1'b0;
    is_prime    = 1'b0;
    div_start   = 1'b0;
    // ... all other outputs defaulted

    case (state_ff)
        IDLE: begin
            if (start) begin
                next_state = CHECK_2_3;
            end
            // No else needed because default handles it — but add anyway per INFRA-07
            else begin
                next_state = IDLE;
            end
        end
        // ... other states
        default: begin          // INFRA-07: required even if all states covered
            next_state = IDLE;
        end
    endcase
end
```

**Critical detail on synchronous reset:** The class rule states reset is decoded in `always @(*)`, not as a posedge sensitivity item. This means the `always @(posedge clk)` block checks `if (rst)` inside the clocked block — which IS synchronous reset. This is correct and standard. Do NOT write `always @(posedge clk or posedge rst)` — that is asynchronous reset, which the class rules forbid.

### Module Port Declaration (ANSI Style — INFRA-01 prep)

```verilog
// Source: Verilog-2001 ANSI port style, required by class rules
module prime_engine #(
    parameter WIDTH = 27
) (
    input  wire             clk,
    input  wire             rst,
    input  wire             start,
    input  wire [WIDTH-1:0] candidate,
    output reg              done_ff,
    output reg              is_prime_ff
);
```

### Anti-Patterns to Avoid

- **Async reset in posedge block:** `always @(posedge clk or posedge rst)` — forbidden by class rules. Use synchronous only.
- **Mixing blocking and non-blocking in one always block:** Causes simulation-synthesis mismatch. Vivado will warn; behavior is undefined.
- **For loop to iterate divisors:** Even if loop count is compile-time constant, class rules prohibit for loops in synthesis files entirely.
- **Using `%` with variable divisor:** Will fail Vivado synthesis or produce a massive slow combinational tree.
- **Behavioral `$sqrt()` in synthesis file:** Not synthesizable. Use `d*d > candidate` comparison instead.
- **Incomplete case without default:** Causes Vivado to infer latches and issue `[Synth 8-327]` warning.
- **Forgetting to default outputs at top of always @(*):** Without defaults, any output not assigned in every branch infers a latch.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Integer division/modulo | Subtraction loop | Restoring binary division FSM (N cycles for N bits) | Subtraction loop cycles scale with quotient magnitude (O(n/d)); restoring division is O(N bits) — far better for large candidates |
| sqrt bound | Non-restoring sqrt FSM | `d*d > candidate` compare | Fewer states, no extra module, uses DSP48 inference, mathematically equivalent |
| Golden prime list | Verilog procedural loop in TB | Python script generating hex/include file | Python primality is trivially verified; Verilog generation is error-prone |
| Waveform debug | printf-style $display spam | `$dumpvars` + VCD viewer (GTKWave) | VCD shows state transitions visually; essential for debugging multi-cycle FSM hangs |

**Key insight:** The division sub-FSM is the most reusable piece in this project — it will be called thousands of times per second in Modes 1/2. Getting it correct and clean in Phase 1 pays dividends through all later phases.

---

## Common Pitfalls

### Pitfall 1: Latch Inference from Missing Defaults
**What goes wrong:** Vivado emits `[Synth 8-327] inferring latch for variable X_ff` and simulation shows X_ff holding stale values when it shouldn't.
**Why it happens:** If any output of an `always @(*)` block is not assigned under ALL possible code paths, synthesis infers a latch to "remember" the value.
**How to avoid:** Begin EVERY `always @(*)` block with default assignments for ALL signals the block drives. Then override in the case/if branches.
**Warning signs:** Vivado synthesis warning `[Synth 8-327]`; simulation shows output that never changes even when it should.

### Pitfall 2: FSM Hangs (Never Reaches DONE)
**What goes wrong:** Testbench timeout — done_ff never asserts for some candidates.
**Why it happens:** (a) `d*d > candidate` overflow if d or candidate widths are too narrow; (b) divider's `done_ff` pulse is one cycle wide but the outer FSM misses it (reads the signal a cycle late); (c) initial k value wrong (should start k=1, d=5 for the 6k±1 sequence).
**How to avoid:** (a) Size registers to WIDTH=27 from the start; (b) sample `div_done_ff` in the clocked block and use a registered copy; (c) verify by hand: k=1 → d=5 (6*1-1), then d=7 (6*1+1), k=2 → d=11, d=13, etc.
**Warning signs:** Testbench reports timeout rather than assertion failure; waveform shows FSM stuck in TEST_KM1 or TEST_KP1.

### Pitfall 3: Off-by-One in 6k±1 Sequence
**What goes wrong:** Engine reports 25 as prime (it is not: 25 = 5×5).
**Why it happens:** The bound check `d*d > candidate` must use strict greater-than. If using `>=`, the engine exits before testing d=5 against candidate=25. If using `>` it correctly tests d=5 (5*5=25, not > 25, so test proceeds; 25%5==0, composite).
**How to avoid:** Bound condition is `d*d > candidate` (strict >). Loop continues as long as `d*d <= candidate`.
**Warning signs:** 25, 49 (7²), 121 (11²), etc. incorrectly classified as prime.

### Pitfall 4: Mixing Blocking/Non-Blocking
**What goes wrong:** Simulation and synthesis disagree on output values; Vivado warns about assignment type mixing.
**Why it happens:** Using `<=` in an `always @(*)` block, or `=` in `always @(posedge clk)`.
**How to avoid:** Hard rule: `=` lives exclusively in `always @(*)`; `<=` lives exclusively in `always @(posedge clk)`. Review every always block before committing.
**Warning signs:** Vivado `[Synth 8-91]` warning about blocking assignment to register; simulation output differs from synthesized behavior.

### Pitfall 5: Candidate Width Too Narrow
**What goes wrong:** Engine gives wrong answers for candidates > 2^WIDTH without any error indication.
**Why it happens:** Register truncation is silent in Verilog.
**How to avoid:** Use WIDTH=27 (covers 99,999,999 < 2^27 = 134,217,728) from the start. Phase 1 only tests up to 10,007 but the register width should be set for the full spec.
**Warning signs:** Wrong answers for candidates that are multiples of 2^WIDTH ± small numbers.

### Pitfall 6: iVerilog vs Vivado Simulation Discrepancy
**What goes wrong:** Self-checking TB passes in iVerilog but fails in Vivado behavioral sim, or vice versa.
**Why it happens:** iVerilog is more permissive with `integer` types and some non-standard Verilog; Vivado sim is stricter. Also, `$error` is a SystemVerilog construct — iVerilog 12.0 supports it but Vivado sim requires the file to be added as SystemVerilog if using `$error`.
**How to avoid:** Use `$display` + `$finish` for errors rather than `$error` in testbench, OR consistently invoke iVerilog with `-g2012`. For Vivado, add TB as Verilog (not SV) source.
**Warning signs:** Compile errors in one tool that the other ignores.

---

## Code Examples

### Outer FSM Skeleton (class-compliant)

```verilog
// Source: CSEE 4280 class rules + two-always-block pattern
// prime_engine.v — skeleton

module prime_engine #(
    parameter WIDTH = 27
) (
    input  wire             clk,
    input  wire             rst,         // synchronous active-high reset
    input  wire             start,
    input  wire [WIDTH-1:0] candidate,
    output reg              done_ff,
    output reg              is_prime_ff
);

    // State encoding
    localparam [2:0]
        IDLE      = 3'd0,
        CHECK_2_3 = 3'd1,
        INIT_K    = 3'd2,
        TEST_KM1  = 3'd3,
        TEST_KP1  = 3'd4,
        DONE      = 3'd5;

    // Flip-flop signals (_ff suffix required by INFRA-03)
    reg [2:0]       state_ff;
    reg [WIDTH-1:0] candidate_ff;
    reg [WIDTH-1:0] d_ff;            // current trial divisor
    reg [WIDTH-1:0] k_ff;            // current k in 6k±1

    // Combinational / next-state signals
    reg [2:0]       next_state;
    reg             div_start;
    wire            div_done;
    wire [WIDTH-1:0] div_remainder;

    // Bound check — synthesizes to DSP48 multiply + compare
    wire [2*WIDTH-1:0] d_squared;
    assign d_squared = d_ff * d_ff;
    wire bound_exceeded = (d_squared > {1'b0, candidate_ff}); // strictly greater-than

    // Divider instance
    divider #(.WIDTH(WIDTH)) u_div (
        .clk        (clk),
        .rst        (rst),
        .start      (div_start),
        .dividend   (candidate_ff),
        .divisor    (d_ff),
        .done_ff    (div_done),
        .remainder_ff(div_remainder)
        // .quotient_ff, .busy_ff, .dbz_ff unused here
    );

    // --- Sequential block: FF updates only, non-blocking only ---
    always @(posedge clk) begin
        if (rst) begin
            state_ff     <= IDLE;
            candidate_ff <= {WIDTH{1'b0}};
            d_ff         <= {WIDTH{1'b0}};
            k_ff         <= {WIDTH{1'b0}};
            done_ff      <= 1'b0;
            is_prime_ff  <= 1'b0;
        end else begin
            state_ff <= next_state;
            // latch candidate on start
            if (start && state_ff == IDLE) begin
                candidate_ff <= candidate;
            end
            // update d and k as directed by combinational logic
            // (use registered copies of combinational signals as needed)
            done_ff     <= (next_state == DONE) ? 1'b1 : 1'b0;
        end
    end

    // --- Combinational block: next-state logic, blocking only ---
    always @(*) begin
        // Defaults (INFRA-07: prevents latch inference)
        next_state = state_ff;
        div_start  = 1'b0;
        is_prime_ff = is_prime_ff; // hold (driven from clocked block)

        case (state_ff)
            IDLE: begin
                if (start) next_state = CHECK_2_3;
                else       next_state = IDLE;
            end
            CHECK_2_3: begin
                if (candidate_ff == 27'd2 || candidate_ff == 27'd3)
                    next_state = DONE; // is_prime set in clocked block
                else if (candidate_ff[0] == 1'b0 || /* divisible by 3 check */ 1'b0)
                    next_state = DONE; // not prime
                else
                    next_state = INIT_K;
            end
            // ... (INIT_K, TEST_KM1, TEST_KP1, DONE)
            default: next_state = IDLE;
        endcase
    end

endmodule
```

### Restoring Binary Divider Skeleton

```verilog
// Source: projectf.io division-in-verilog pattern, adapted to class rules
// divider.v

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
    output reg [WIDTH-1:0]  quotient_ff,
    output reg [WIDTH-1:0]  remainder_ff
);
    reg [WIDTH-1:0] dividend_copy_ff;
    reg [WIDTH-1:0] divisor_copy_ff;
    reg [WIDTH-1:0] acc_ff;       // accumulator
    reg [WIDTH-1:0] quo_ff;       // quotient being built
    reg [$clog2(WIDTH)-1:0] iter_ff; // iteration counter

    // Combinational subtraction
    wire [WIDTH:0] acc_sub;
    assign acc_sub = {acc_ff[WIDTH-2:0], dividend_copy_ff[WIDTH-1]} - divisor_copy_ff;

    always @(posedge clk) begin
        done_ff <= 1'b0; // default: not done
        if (rst) begin
            busy_ff        <= 1'b0;
            done_ff        <= 1'b0;
            dbz_ff         <= 1'b0;
            quotient_ff    <= {WIDTH{1'b0}};
            remainder_ff   <= {WIDTH{1'b0}};
            iter_ff        <= {$clog2(WIDTH){1'b0}};
        end else if (start) begin
            if (divisor == {WIDTH{1'b0}}) begin
                dbz_ff  <= 1'b1;
                done_ff <= 1'b1;
            end else begin
                busy_ff         <= 1'b1;
                dbz_ff          <= 1'b0;
                dividend_copy_ff <= dividend;
                divisor_copy_ff  <= divisor;
                acc_ff          <= {WIDTH{1'b0}};
                quo_ff          <= {WIDTH{1'b0}};
                iter_ff         <= {$clog2(WIDTH){1'b0}};
            end
        end else if (busy_ff) begin
            if (acc_sub[WIDTH] == 1'b0) begin
                // subtraction did not borrow: quotient bit = 1
                acc_ff <= acc_sub[WIDTH-1:0];
                quo_ff <= {quo_ff[WIDTH-2:0], 1'b1};
            end else begin
                // subtraction borrowed: quotient bit = 0
                acc_ff <= {acc_ff[WIDTH-2:0], dividend_copy_ff[WIDTH-1]};
                quo_ff <= {quo_ff[WIDTH-2:0], 1'b0};
            end
            dividend_copy_ff <= {dividend_copy_ff[WIDTH-2:0], 1'b0}; // shift out
            iter_ff <= iter_ff + 1'b1;
            if (iter_ff == WIDTH - 1) begin
                busy_ff      <= 1'b0;
                done_ff      <= 1'b1;
                quotient_ff  <= quo_ff;
                remainder_ff <= acc_ff;
            end
        end
    end
endmodule
```

### Testbench Self-Checking Pattern (iVerilog-compatible)

```verilog
// Source: chipverify.com self-checking testbench pattern, adapted for iVerilog compatibility
// prime_engine_tb.v — no SystemVerilog constructs

`timescale 1ns/1ps
module prime_engine_tb;

    // Parameters
    parameter WIDTH   = 27;
    parameter CLK_PERIOD = 10; // 100 MHz

    // DUT signals
    reg             clk, rst, start;
    reg [WIDTH-1:0] candidate;
    wire            done_ff, is_prime_ff;

    // Test tracking
    integer errors;
    integer test_num;

    // Golden list storage (loaded from file or hardcoded as include)
    // For 2..10007: 1229 primes
    // Use $readmemb or a localparam array (Verilog-2001 supports parameter arrays)

    // DUT instantiation
    prime_engine #(.WIDTH(WIDTH)) dut (
        .clk       (clk),
        .rst       (rst),
        .start     (start),
        .candidate (candidate),
        .done_ff   (done_ff),
        .is_prime_ff(is_prime_ff)
    );

    // Clock generation
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // Task: apply one candidate and check result
    task apply_and_check;
        input [WIDTH-1:0] cand;
        input             expected_prime;
        begin
            candidate = cand;
            start = 1'b1;
            @(posedge clk);
            start = 1'b0;
            // Wait for done with timeout
            fork
                begin : wait_done
                    wait (done_ff == 1'b1);
                    @(posedge clk); // sample stable output
                    disable timeout_watch;
                end
                begin : timeout_watch
                    repeat(200000) @(posedge clk);
                    $display("TIMEOUT: candidate=%0d never asserted done", cand);
                    errors = errors + 1;
                    disable wait_done;
                end
            join
            if (is_prime_ff !== expected_prime) begin
                $display("FAIL: candidate=%0d expected is_prime=%0b got %0b",
                         cand, expected_prime, is_prime_ff);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        errors   = 0;
        rst      = 1'b1;
        start    = 1'b0;
        candidate = {WIDTH{1'b0}};
        repeat(4) @(posedge clk);
        rst = 1'b0;
        @(posedge clk);

        // Test known primes and composites
        apply_and_check(2,     1'b1);
        apply_and_check(3,     1'b1);
        apply_and_check(4,     1'b0);
        apply_and_check(5,     1'b1);
        apply_and_check(25,    1'b0); // 5*5 — catches off-by-one in bound
        apply_and_check(97,    1'b1);
        apply_and_check(100,   1'b0);
        // ... sweep 2..10007 using golden list

        if (errors == 0)
            $display("PASS: all tests passed");
        else
            $display("FAIL: %0d errors detected", errors);

        $finish;
    end

endmodule
```

### Divisibility by 3 Without Division

The CHECK_2_3 state needs to check if candidate is divisible by 3. Since a hardware divider would be overhead for a single check, use the subtraction loop or a simple combinational check. For small constant divisors (2 and 3), synthesizers handle these efficiently:

```verilog
// Divisibility by 2: check LSB
wire div_by_2 = ~candidate_ff[0]; // even number

// Divisibility by 3: subtract 3 repeatedly — too slow for large n
// Better: use the property that (n % 3 == 0) iff sum of digits % 3 == 0 in base-3
// In hardware: instantiate the divider with divisor=3 and check remainder
// OR: special-case in CHECK_2_3 state — fire the divider with divisor=3'd3 once.
// This adds 27 cycles but only runs once per candidate.
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Async reset in posedge sensitivity list | Synchronous reset: `if (rst)` inside `always @(posedge clk)` | CSEE 4280 class rule | Cleaner synthesis; no reset glitch paths |
| Three-always-block FSM (separate output always) | Two-always-block (next-state + output combined in one `always @(*)`) | Ongoing best practice | Fewer files, easier latch prevention |
| Behavioral `%` operator with variable divisor | Explicit multi-cycle divider sub-module | Required for synthesis | Predictable timing, synthesizable on all tools |
| Computing sqrt() for divisor bound | `d*d > candidate` comparison | Standard FPGA practice | Single multiplier, no extra module, exact |

**Deprecated / avoid:**
- `integer` type in synthesis files (use `reg [N:0]` with explicit width)
- `always @(posedge clk or posedge rst)` — async reset, forbidden by class rules
- `$sqrt()`, `$ceil()` — simulation-only, not synthesizable

---

## Open Questions

1. **Divisibility-by-3 in CHECK_2_3 state**
   - What we know: Can use the restoring divider with divisor=3, costs 27 cycles once per candidate.
   - What's unclear: Whether the class PDF specifies any particular approach; PDF is unreadable in this environment.
   - Recommendation: Use the restoring divider for consistency; add a localparam `DIV3 = 27'd3` and start the divider at entry to CHECK_2_3.

2. **Register width for Phase 1 vs full spec**
   - What we know: Phase 1 only tests up to 10,007; full spec is 99,999,999 (27 bits).
   - What's unclear: Whether the planner wants WIDTH=14 (Phase 1 minimal) or WIDTH=27 (full spec ready).
   - Recommendation: Use WIDTH=27 as a parameter default from the start. Avoids a refactor at Phase 2 when the mode FSM drives candidates up to 99,999,999.

3. **Vivado testbench compatibility**
   - What we know: Vivado is not in the dev machine PATH. iVerilog 12.0 is available.
   - What's unclear: Whether the course provides a Vivado project template or the student sets it up from scratch.
   - Recommendation: Plan 01-02 and 01-03 should note that Vivado TB verification may be manual (run in Vivado GUI). iVerilog is the primary development loop.

---

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|-------------|-----------|---------|----------|
| iVerilog | Behavioral simulation, TB rapid iteration | Yes | 12.0 (`/opt/homebrew/bin/iverilog`) | — |
| vvp | Execute iVerilog compiled sims | Yes | bundled with iVerilog 12.0 | — |
| Vivado | Synthesis, implementation, final TB check | Not in PATH | Unknown | iVerilog covers behavioral verification; Vivado must be opened via GUI separately |
| Python 3 | Generate golden prime list | Yes (system Python) | Check with `python3 --version` | Hardcode primes in Verilog include file manually |
| GTKWave | VCD waveform viewing | Not checked | — | Use `$dumpvars` + `$dumpfile` and open VCD in GTKWave if installed; or add more `$display` statements |

**Missing dependencies with no fallback:**
- Vivado (not in PATH) — synthesis and final INFRA-08 Vivado-sim check must be done via Vivado GUI. Plans should include a manual step: "Open Vivado project, add sources, run behavioral simulation, confirm zero assertion failures."

**Missing dependencies with fallback:**
- GTKWave: iVerilog generates VCD; if GTKWave unavailable, `$display` debugging is sufficient for Phase 1.

---

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | iVerilog 12.0 (behavioral) + Vivado behavioral sim (manual) |
| Config file | None — iVerilog invoked directly from command line |
| Quick run command | `iverilog -o sim/prime_engine_tb.vvp -g2001 rtl/prime_engine.v rtl/divider.v sim/prime_engine_tb.v && vvp sim/prime_engine_tb.vvp` |
| Full suite command | Same as above (Phase 1 has one testbench) |

### Phase Requirements to Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|--------------|
| PRIME-01 | 6k±1 FSM correctly classifies primes and composites 2–10,007 | Functional simulation | `vvp sim/prime_engine_tb.vvp` | No — Wave 0 |
| PRIME-01 | FSM reaches DONE for every candidate (no hangs) | Timeout check in TB | `vvp sim/prime_engine_tb.vvp` | No — Wave 0 |
| INFRA-03 | `_ff` / `_n` naming convention | Code review / lint | Manual audit (Plan 01-03) | No — Wave 0 |
| INFRA-04 | No mixed blocking/non-blocking | Code review | Manual audit (Plan 01-03) + Vivado warning check | No — Wave 0 |
| INFRA-05 | No for loops in synthesis files | Code review / grep | `grep -rn "for\s*(.*)" rtl/` | No — Wave 0 |
| INFRA-06 | Combinational logic in `always @(*)`; FFs in `always @(posedge clk)` | Code review | Manual audit (Plan 01-03) | No — Wave 0 |
| INFRA-07 | `default:` in all case; `else` in all if-else | Code review | Manual audit (Plan 01-03) + Vivado `[Synth 8-327]` absence | No — Wave 0 |
| INFRA-08 | Self-checking TB passes zero assertions in iVerilog | Automated simulation | `vvp sim/prime_engine_tb.vvp` | No — Wave 0 |
| INFRA-08 | Self-checking TB passes in Vivado behavioral sim | Manual simulation | Open Vivado, run TB, confirm PASS | No — Wave 0 |

### Sampling Rate

- **Per task commit:** `iverilog -o sim/prime_engine_tb.vvp -g2001 rtl/prime_engine.v rtl/divider.v sim/prime_engine_tb.v && vvp sim/prime_engine_tb.vvp`
- **Per wave merge:** Same command + manual Vivado behavioral sim run
- **Phase gate:** Full iVerilog sweep of 2–10,007 green, Vivado sim green, audit checklist complete

### Wave 0 Gaps

- [ ] `rtl/prime_engine.v` — main FSM; covers PRIME-01, INFRA-03 through INFRA-07
- [ ] `rtl/divider.v` — binary restoring division sub-module; used by prime_engine
- [ ] `sim/prime_engine_tb.v` — self-checking testbench; covers INFRA-08
- [ ] `sim/golden_primes.vh` OR `scripts/gen_golden_primes.py` — golden list for 2–10,007
- [ ] `sim/` directory — does not exist yet
- [ ] `rtl/` directory — does not exist yet

---

## Sources

### Primary (HIGH confidence)
- [Project F — Division in Verilog](https://projectf.io/posts/division-in-verilog/) — restoring binary division algorithm, cycle counts, signal interface
- [Project F — Square Root in Verilog](https://projectf.io/posts/square-root-in-verilog/) — non-restoring sqrt algorithm (verified that `d*d` comparison is the simpler alternative)
- [chipverify.com — Verilog FSM](https://www.chipverify.com/verilog/verilog-fsm) — two-always-block FSM structure
- [chipverify.com — Self-Checking Testbench](https://www.chipverify.com/verification/self-checking-testbench) — TB patterns, `$error`, `$finish`
- CSEE 4280 class rules (PROJECT.md / Lecture 2b PDF — PDF unreadable without poppler, rules extracted from PROJECT.md which summarizes them authoritatively)

### Secondary (MEDIUM confidence)
- [Verilog Coding Tips — Clocked Square Root](https://verilogcodes.blogspot.com/2020/12/synthesizable-clocked-square-root.html) — non-restoring sqrt; confirms N/2 cycle approach
- [edaboard — Modulus synthesizable or not](https://www.edaboard.com/threads/synthesizable-modulo-operator.382729/) — community confirmation that `%` with variable divisor fails Vivado synthesis
- [AMD Adaptive Support — Modulus operator](https://adaptivesupport.amd.com/s/question/0D52E00006hpcLESAY/modulus-synthesizable-or-nonsynthesizable) — official Xilinx position on `%` operator limitations

### Tertiary (LOW confidence — informational only)
- [arXiv 2407.12541](https://arxiv.org/html/2407.12541v2) — FSM-based modulus for FPGA using add/subtract/shift only; supports the restoring division approach direction

---

## Metadata

**Confidence breakdown:**
- 6k±1 algorithm correctness: HIGH — pure mathematics, deterministic
- Standard stack (iVerilog, divider pattern): HIGH — iVerilog confirmed installed; Project F patterns well-documented
- Synthesis rules (no `%`, class coding style): HIGH — sourced from PROJECT.md class rules + AMD docs
- FSM structure: HIGH — two-always-block pattern is consensus-standard
- Cycle-count estimates: MEDIUM — derived from formula, not measured on actual synthesis
- Vivado compatibility: MEDIUM — Vivado not in PATH; cannot verify synthesis locally before hardware phase

**Research date:** 2026-03-25
**Valid until:** 2026-06-25 (stable domain — Verilog synthesis rules and iVerilog version unlikely to change)
