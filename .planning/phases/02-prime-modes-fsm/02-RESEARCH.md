# Phase 2: Prime Modes FSM - Research

**Researched:** 2026-03-25
**Domain:** Synthesizable Verilog FSM orchestration — multi-module handshake, ring buffer, parameterized timer, BRAM FIFO inference
**Confidence:** HIGH (all critical patterns derived from existing Phase 1 RTL contracts and established coding rules; no external dependencies)

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**D-01:** mode_fsm feeds prime_engine the 6k±1 candidate sequence: 2, then 3, then candidates starting at 5 alternating +2/+4 (5, 7, 11, 13, 17, 19 ...). Controlled by a single toggle flip-flop (`step_toggle_ff`) in mode_fsm.

**D-02:** No multiplication in the iteration loop — only addition (+2 or +4). The step toggle does not require a counter or multiplier.

**D-03:** Rationale: ~1/3 the prime_engine invocations vs. testing every integer. All primes > 3 are of the form 6k±1, so no prime is missed.

**D-04:** prime_accumulator.v instantiates an internal BRAM-based FIFO to buffer found primes. Phase 3 connects to the FIFO read-side without changing prime_accumulator's port list.

**D-05:** FIFO read-side ports exposed on prime_accumulator: `prime_fifo_rd_en` (input), `prime_fifo_rd_data_ff [WIDTH-1:0]` (output), `prime_fifo_empty_ff` (output). In Phase 2 sim, tie `prime_fifo_rd_en = 0`.

**D-06:** FIFO full → stall mode_fsm. mode_fsm checks `prime_fifo_full_ff` before starting the next prime_engine run; if full, it waits in PRIME_RUN state without asserting `start`. Elapsed timer keeps running during the stall.

**D-07:** prime_accumulator also maintains: `prime_count_ff` (32-bit running count), `last20` ring buffer (20 entries × WIDTH bits, overwrite oldest on each new prime).

**D-08:** elapsed_timer.v runs entirely on the 100 MHz system clock. No PLL or separate clock domain.

**D-09:** Internal 27-bit cycle counter counts to 100,000,000 then resets, asserting a one-cycle `second_tick` pulse.

**D-10:** Outputs: `cycle_count_ff` (32-bit, increments every clock), `seconds_ff` (32-bit, increments on each `second_tick`).

**D-11:** `freeze` input (driven by mode_fsm when done is asserted) halts both counters.

**D-12:** mode_fsm checks `seconds_ff >= t_limit_ff` every clock cycle in the combinational block. Terminates immediately on the first cycle the condition is true — no overshoot waiting for a prime test to finish.

**D-13:** T is held in `t_limit_ff` (32-bit), loaded from the `t_limit` input when mode_fsm transitions into TIME_ENTRY.

**D-14:** One flat `mode_fsm.v` with all 9 states: IDLE, MODE_SELECT, NUMBER_ENTRY, TIME_ENTRY, PRIME_RUN, PRIME_DONE, ISPRIME_ENTRY, ISPRIME_RUN, ISPRIME_DONE. Single `always @(*)` comb block + single `always @(posedge clk)` flop block per class rules.

**D-15:** No sub-FSMs or dispatcher hierarchy.

### Claude's Discretion

- FIFO depth (suggest 32 or 64 entries)
- Internal state encoding (binary vs. one-hot; binary preferred)
- Exact testbench stimulus values (N and T for each test case, beyond roadmap minimums)

### Deferred Ideas (OUT OF SCOPE)

- None — DDR2 write controller (read side of FIFO) is explicitly Phase 3.
</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| PRIME-02 | Mode 1 — find all primes ≤ N; store all found primes in DDR2 (FIFO stub in Phase 2) | Section: mode_fsm Architecture, Candidate Enumeration, Integration Contracts |
| PRIME-03 | Mode 2 — find all primes within T seconds; store in DDR2 (FIFO stub) | Section: mode_fsm Architecture, Mode 2 Termination, Elapsed Timer Design |
| PRIME-04 | Mode 3 — determine if entered number is prime; show elapsed time; freeze display on completion | Section: mode_fsm Architecture (ISPRIME_RUN/DONE), Timer Freeze |
| PRIME-05 | Running prime count and last 20 primes updated live during Modes 1 and 2 | Section: prime_accumulator Design, Ring Buffer Without For Loops |
| PRIME-06 | Elapsed time counter runs during active computation; freezes on mode completion | Section: elapsed_timer Design |
</phase_requirements>

---

## Summary

Phase 2 wraps the already-verified `prime_engine.v` in three orchestration modules: a flat 9-state mode dispatcher FSM (`mode_fsm.v`), a 32-bit cycle/seconds counter (`elapsed_timer.v`), and a prime accumulator with BRAM FIFO stub and last-20 ring buffer (`prime_accumulator.v`). All hardware is simulation-only; no joystick, no 7SD, no real DDR2 writes occur this phase.

The central design challenge is the multi-signal handshake between mode_fsm, prime_engine, prime_accumulator, and elapsed_timer — four modules exchanging control signals across a single clock domain with specific ordering requirements. A second challenge is implementing the last-20 ring buffer and FIFO without for loops, using indexed register arrays and compare-based wrap logic instead. The third challenge is making the elapsed_timer parameterizable so its second-tick period can be shrunk to 100 or 1000 cycles for feasible simulation of Mode 2.

All three modules must follow the identical two-block coding pattern established in Phase 1 (one `always @(*)` comb block, one `always @(posedge clk)` flop block, synchronous reset decoded in comb, `_ff` on all registers). No exceptions — the class rules apply to every new synthesis file.

**Primary recommendation:** Implement elapsed_timer with a `TICK_PERIOD` parameter (default 100_000_000); testbench overrides to 100. Implement the ring buffer as an indexed reg array with a 5-bit write pointer that resets via an explicit compare (not `% 20`). Use inferred RTL FIFO (not Xilinx IP) inside prime_accumulator so the sim flow stays purely iVerilog-compatible.

---

## Project Constraints (from CSEE 4280 Class Rules)

No CLAUDE.md exists. All mandatory constraints come from the project's established coding standard (INFRA-03 through INFRA-08), fully enforced in Phase 1 RTL and carried forward unchanged.

| Rule | Phase 2 Impact |
|------|----------------|
| ANSI module port declarations | All four new modules use `module foo #(...) (input wire ..., output reg ...)` style |
| `_ff` suffix on all flip-flop registers | Every `reg` driven by `always @(posedge clk)` carries `_ff`; next-state wires do NOT |
| `_n` suffix on active-low signals | Any active-low signals (unlikely in this phase) must carry `_n` |
| Blocking (`=`) in comb only; non-blocking (`<=`) in flop only | Strictly separate always blocks — no mixing |
| No `for` loops in synthesis files | Ring buffer wrap uses compare-and-reset; FIFO pointers use the same pattern |
| `always @(*)` for all combinational logic | Synchronous reset decoded here, not in the posedge block |
| `default:` in all `case` statements | Required in mode_fsm state case and any case in accumulator |
| Final `else` in all `if-else` chains | Required in all combinational logic |
| Self-checking testbench for every module | mode_fsm_tb.v and accumulator_tb.v must auto-report PASS/FAIL |

---

## Standard Stack

### Core
| Tool | Version | Purpose | Why Standard |
|------|---------|---------|--------------|
| Icarus Verilog (iverilog) | 12.0 (installed: `/c/iverilog/bin/iverilog`) | Behavioral simulation, self-checking TB execution | Already installed, confirmed working from Phase 1 |
| vvp | bundled with iverilog 12.0 (installed: `/c/iverilog/bin/vvp`) | Execute compiled iverilog simulations | Inseparable from iverilog |
| Verilog-2001 | Language standard (`-g2001` flag) | Synthesis target; allows ANSI ports and reg arrays | Class requirement; used throughout Phase 1 |

### Supporting
| Tool | Purpose | When to Use |
|------|---------|-------------|
| `$dumpvars` / `$dumpfile` in testbench | VCD waveform dump for FSM state debug | Use when mode_fsm hangs or accumulator produces wrong count |
| `$display` / `$monitor` | Pass/fail printing; signal tracing during TB development | Standard tb pattern from Phase 1 |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Inferred RTL FIFO (plain Verilog) | Xilinx FIFO Generator IP (.xci) | IP requires Vivado IP flow; incompatible with iverilog sim. RTL FIFO is portable and synthesizes to BRAM via Vivado inference. |
| Inferred RTL FIFO | FIFO18E1/FIFO36E1 primitive instantiation | Primitive requires detailed attribute tuning; RTL inference is simpler and equally correct for this depth. |
| Binary state encoding | One-hot encoding | Binary uses fewer FFs (4 bits for 9 states vs 9 bits); preferred per D-14 discretion note. |

**Compile commands:**
```bash
# mode_fsm_tb (all modules)
iverilog -g2001 -o sim/mode_fsm_tb.vvp \
  rtl/divider.v rtl/prime_engine.v \
  rtl/elapsed_timer.v rtl/prime_accumulator.v rtl/mode_fsm.v \
  tb/mode_fsm_tb.v
vvp sim/mode_fsm_tb.vvp

# accumulator_tb (accumulator only)
iverilog -g2001 -o sim/accumulator_tb.vvp \
  rtl/prime_accumulator.v \
  tb/accumulator_tb.v
vvp sim/accumulator_tb.vvp
```

---

## Architecture Patterns

### Recommended File Structure

```
rtl/
├── divider.v            # Phase 1 — unchanged
├── prime_engine.v       # Phase 1 — unchanged
├── elapsed_timer.v      # Phase 2 NEW
├── prime_accumulator.v  # Phase 2 NEW
└── mode_fsm.v           # Phase 2 NEW
tb/
├── prime_engine_tb.v    # Phase 1 — unchanged
├── mode_fsm_tb.v        # Phase 2 NEW
└── accumulator_tb.v     # Phase 2 NEW
sim/
├── prime_engine_tb.vvp  # Phase 1 artifacts
├── mode_fsm_tb.vvp      # Phase 2 NEW (compiled output)
└── accumulator_tb.vvp   # Phase 2 NEW (compiled output)
scripts/
└── gen_golden_primes.py # Phase 1 — unchanged
```

### Pattern 1: Two-Block FSM (mandatory — same as Phase 1)

Every synthesis module in Phase 2 uses exactly this structure. No exceptions.

```verilog
// Source: established in Phase 1 (rtl/prime_engine.v, rtl/divider.v)
module my_module #(parameter WIDTH = 27) (
    input  wire       clk,
    input  wire       rst,
    // ... other ports as output reg
);
    // Flip-flop registers (_ff suffix)
    reg [3:0] state_ff;
    reg [3:0] next_state;  // combinational wire (no _ff)

    // ===== COMBINATIONAL BLOCK =====
    always @(*) begin
        // defaults: hold all registered values
        next_state = state_ff;
        // ... other next_ signals

        if (rst) begin
            next_state = IDLE;
            // ... reset all next_ signals
        end else begin
            case (state_ff)
                STATE_A: begin
                    // ...
                end
                default: next_state = IDLE;
            endcase
        end
    end

    // ===== FLOP BLOCK =====
    always @(posedge clk) begin
        state_ff <= next_state;
        // ... other _ff <= next_ assignments
    end

endmodule
```

### Pattern 2: prime_engine Handshake (HIGH confidence — derived from RTL)

Critical timing verified from `rtl/prime_engine.v`:

- `start` is sampled on the rising edge when `state_ff == IDLE`.
- `busy_ff` goes high the cycle AFTER start is sampled (cycle N+1, when state transitions to CHECK_2_3).
- `done_ff` pulses HIGH for exactly one cycle when the result is ready; the engine returns to IDLE the following cycle.
- `is_prime_ff` holds its value after `done_ff` deasserts, until the next `start`. It is safe to read on the `done_ff` cycle or the immediately following cycle.
- mode_fsm MUST NOT assert `start` while `busy_ff == 1`.

```verilog
// mode_fsm comb block: safe start condition
// Source: derived from prime_engine.v timing analysis
next_eng_start = 1'b0;
if (state_ff == PRIME_RUN) begin
    if (~eng_busy_ff && ~prime_fifo_full_ff && ~mode2_timeout) begin
        next_eng_start = 1'b1;   // pulse start only when safe
    end else begin
        next_eng_start = 1'b0;   // stall
    end
end else begin
    next_eng_start = 1'b0;
end
```

### Pattern 3: Candidate Enumeration Without Multiplication (HIGH confidence)

The 6k±1 sequence from mode_fsm: 2, 3, 5, 7, 11, 13, 17, 19, 23, ...

Use a 2-bit `init_phase_ff` register to handle the 2/3 special cases before entering the main toggle loop:

```verilog
// In PRIME_RUN comb logic:
// init_phase_ff: 2'b10 = feed 2, 2'b01 = feed 3, 2'b00 = main loop
// step_toggle_ff: 0 = next step is +2, 1 = next step is +4
if (init_phase_ff == 2'b10) begin
    next_candidate = 27'd2;
    // after prime_engine done: next_init_phase = 2'b01
end else if (init_phase_ff == 2'b01) begin
    next_candidate = 27'd3;
    // after prime_engine done: next_init_phase = 2'b00, next_candidate = 27'd5
end else begin
    // main loop: candidate_ff is current, step_toggle drives advance
    if (eng_done_ff) begin
        if (step_toggle_ff == 1'b0) begin
            next_candidate = candidate_ff + 27'd2;  // 6k-1 to 6k+1
            next_step_toggle = 1'b1;
        end else begin
            next_candidate = candidate_ff + 27'd4;  // 6k+1 to next 6k-1
            next_step_toggle = 1'b0;
        end
    end
end
```

### Pattern 4: Ring Buffer Without For Loops (HIGH confidence)

```verilog
// In prime_accumulator.v
// 20-entry ring buffer, 5-bit write pointer
reg [WIDTH-1:0] last20_ff [0:19];  // Verilog-2001 reg array — synthesizes correctly
reg [4:0]       wr_ptr_ff;          // 0..19

// Comb block: pointer wrap without modulo
if (prime_valid_in) begin
    // Indexed write: synthesizes as 20-entry mux in Vivado (no for loop)
    // ... update last20_ff[wr_ptr_ff] via non-blocking in flop block
    if (wr_ptr_ff == 5'd19) begin
        next_wr_ptr = 5'd0;
    end else begin
        next_wr_ptr = wr_ptr_ff + 5'd1;
    end
end else begin
    next_wr_ptr = wr_ptr_ff;
end
```

**Note:** Indexed assignment `last20_ff[wr_ptr_ff] <= prime_data` in the `always @(posedge clk)` block is valid Verilog-2001 and synthesizes correctly in Vivado as a write-enable mux — no for loop required or permitted.

### Pattern 5: Inferred BRAM FIFO (MEDIUM-HIGH confidence)

Synchronous dual-port RAM with registered read port causes Vivado to infer BRAM. Use separate write and read pointers; generate `full` and `empty` flags combinationally.

```verilog
// BRAM inference pattern (inside prime_accumulator.v)
// DEPTH must be power of 2 for pointer arithmetic without modulo
localparam DEPTH = 32;
localparam PTR_W = 5;  // log2(32)

reg [WIDTH-1:0] fifo_mem [0:DEPTH-1];
reg [PTR_W-1:0] wr_ptr_ff, rd_ptr_ff;
reg [PTR_W:0]   count_ff;  // one extra bit to distinguish full from empty

// Write port (synchronous)
always @(posedge clk) begin
    if (wr_en && ~full_ff) begin
        fifo_mem[wr_ptr_ff] <= wr_data;
    end
end

// Read port (registered — required for BRAM inference)
always @(posedge clk) begin
    if (rd_en && ~empty_ff) begin
        prime_fifo_rd_data_ff <= fifo_mem[rd_ptr_ff];
    end
end

// full/empty: derived from count_ff in comb block
// full_ff: count_ff == DEPTH; empty_ff: count_ff == 0
```

**DEPTH must be a power of 2** to allow natural binary pointer wrap (PTR_W-bit counter overflows cleanly at DEPTH). Depth 32 is recommended: 32 × 27 bits = 864 bits, well within a single 18Kb BRAM.

### Pattern 6: elapsed_timer with TICK_PERIOD Parameter

```verilog
module elapsed_timer #(
    parameter TICK_PERIOD = 100_000_000  // override in TB to 100 or 1000
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        freeze,
    output reg [31:0]  cycle_count_ff,
    output reg [31:0]  seconds_ff,
    output reg         second_tick_ff  // one-cycle pulse
);
    // Internal 27-bit tick counter (counts to TICK_PERIOD-1)
    reg [26:0] tick_cnt_ff;
    // ...
```

**Why TICK_PERIOD must be a parameter:** Mode 2 sim at production rate (T=3s = 300,000,000 cycles) would run for ~30 seconds of wall time at iverilog speeds. With `TICK_PERIOD=100`, T=3 seconds = 300 clock cycles — simulation completes in milliseconds.

### Anti-Patterns to Avoid

- **For loop for ring buffer:** Never `for (i=0; i<20; i=i+1)`. Use indexed assignment with write pointer.
- **For loop for FIFO drain:** Never iterate over FIFO entries. Use wr/rd pointer arithmetic.
- **Async reset in posedge block:** Never `always @(posedge clk or posedge rst)`. Reset is decoded in `always @(*)`.
- **Modulo operator for pointer wrap:** Never `wr_ptr_ff % 20`. Use `if (ptr == MAX) next_ptr = 0; else next_ptr = ptr + 1`.
- **Pulsing start while busy:** Never assert `start` to prime_engine when `busy_ff == 1`. mode_fsm must gate on `~busy_ff`.
- **Reading is_prime_ff before done_ff:** The value is only guaranteed correct when `done_ff == 1`. Latch it on that cycle or rely on the hold (it holds until the next start).
- **Hardcoded TICK_PERIOD in elapsed_timer:** Makes Mode 2 simulation impractical. Must be a Verilog parameter.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| FIFO full/empty detection | Custom count-based flags from scratch with blocking logic | Standard RTL FIFO pattern (count_ff or MSB-extended pointers) | Off-by-one errors in full/empty detection are a very common sim-passes-hardware-fails bug. Use the established pointer comparison or count approach. |
| sqrt bound check | sqrt() sub-FSM for mode_fsm termination | Already solved: `candidate_ff > n_limit_ff` for Mode 1; `seconds_ff >= t_limit_ff` for Mode 2 | Mode 1 terminates by value compare, not sqrt. Mode 2 by time compare. No sqrt needed anywhere in Phase 2. |
| Modulo 20 for ring buffer wrap | Division or subtraction loop | `if (ptr == 5'd19) next_ptr = 5'd0; else next_ptr = ptr + 5'd1` | Division is multi-cycle hardware; the explicit compare is one LUT. |
| Simulation speedup | Separate fast-clock testbench domain | TICK_PERIOD parameter on elapsed_timer | Clock domain crossing adds CDC risk; parameterizing the timer is simpler and zero-risk. |

**Key insight:** All of Phase 2's "hard" problems (FIFO, ring buffer, timer) have clean, established RTL patterns that require no custom algorithmic logic. The implementation risk is entirely in correctly wiring the handshake signals between the four modules.

---

## Common Pitfalls

### Pitfall 1: start Pulse While prime_engine is Transitioning

**What goes wrong:** mode_fsm sees `busy_ff == 0` AND `done_ff == 1` (the one cycle when prime_engine is in DONE state, about to return to IDLE). If mode_fsm pulses `start` on the same cycle that `done_ff` fires, the start may be presented while the engine's internal next_state is already IDLE but hasn't been flopped yet. The engine picks up the new start correctly if it's in IDLE next cycle — but the candidate value must be valid when start is asserted.

**Why it happens:** `done_ff` and `busy_ff` both low occurs for only one cycle. mode_fsm combinational logic must make an accurate decision in that cycle.

**How to avoid:** In PRIME_RUN, gate start on `~eng_busy_ff` only. Do NOT use `eng_done_ff` as the start trigger. This way, start is asserted on the cycle after done_ff, when the engine is definitely in IDLE.

**Warning signs:** Prime count off by 1 in simulation; first candidate silently skipped or double-counted.

---

### Pitfall 2: Candidate Advance Before done_ff is Latched

**What goes wrong:** mode_fsm advances `candidate_ff` and `step_toggle_ff` in the same cycle it pulses `start`. The prime_engine sees the NEW candidate on the `candidate` port, not the one whose result just came back.

**Why it happens:** `candidate` is a wire driven by `candidate_ff`. If mode_fsm's comb block updates `next_candidate` on the `done_ff` cycle, the flop block latches it at the rising edge — but `prime_engine.candidate` is driven combinationally by `candidate_ff` (the old value) until that edge. This is actually safe if start fires on the NEXT cycle (cycle after done_ff). But if start and candidate advance happen in the same comb evaluation, start sees the new candidate, which is correct.

**How to avoid:** Ensure the sequence is: (1) latch is_prime on done_ff cycle, (2) compute next_candidate, (3) assert start on the following cycle with the new candidate already in candidate_ff. One clean approach: in PRIME_RUN, when done_ff fires, transition to a one-cycle "ADVANCE" register update (inline via a sub-flag, not a new state) then pulse start.

**Warning signs:** Mode 1 finds only 24 primes instead of 25; or finds an extra composite classified as prime.

---

### Pitfall 3: Mode 2 Termination Missing In-Flight prime_engine Run

**What goes wrong:** Mode 2 terminates (seconds_ff >= t_limit_ff) mid-way through a prime_engine run. The prime being tested is partially computed. If mode_fsm transitions to PRIME_DONE while engine is busy, the in-flight result is discarded — acceptable per D-12. But if mode_fsm hard-transitions without allowing `start` to go low, the prime_engine is left busy.

**Why it happens:** mode_fsm checks `seconds_ff >= t_limit_ff` every cycle in PRIME_RUN. The engine may be in the middle of a 27-cycle division.

**How to avoid:** On Mode 2 timeout, transition to PRIME_DONE immediately (per D-12). Do NOT wait for the in-flight result. The prime_engine will finish on its own and assert done_ff, but mode_fsm will no longer be in PRIME_RUN to act on it. Ensure that the PRIME_DONE state does NOT pulse start or prime_valid — the engine output is ignored after timeout.

**Warning signs:** mode_fsm never exits PRIME_RUN after timeout; or prime_count increments once more after done_ff is asserted.

---

### Pitfall 4: FIFO Full/Empty Off-By-One

**What goes wrong:** FIFO reports `full` one entry early (depth-1 entries) or `empty` one entry late. The classic off-by-one in FIFO flag logic.

**Why it happens:** Using `wr_ptr == rd_ptr` for both full and empty detection is ambiguous. A count register (or MSB-extended pointer comparison) is unambiguous.

**How to avoid:** Use a `count_ff` register (width: log2(DEPTH)+1 bits). `empty_ff = (count_ff == 0)`, `full_ff = (count_ff == DEPTH)`. Increment on write, decrement on read, handle simultaneous read+write as no-change.

**Warning signs:** Accumulator testbench: FIFO claims full at 31 entries instead of 32; or mode_fsm stalls one write early.

---

### Pitfall 5: last20 Ring Buffer — Indexed Write Synthesis

**What goes wrong:** `last20_ff[wr_ptr_ff] <= prime_data` in the posedge block compiles in iverilog simulation but fails synthesis in Vivado when wr_ptr_ff is not a constant.

**Why it happens:** Some older Xilinx tool versions generate warnings about non-constant indices into reg arrays. Vivado 2022+ handles this correctly as distributed RAM or registers, not BRAM.

**How to avoid:** This is NOT a problem in Vivado 2022+ for register arrays of 20 entries (too small for BRAM inference — will be inferred as flip-flops or distributed RAM). If synthesis ever flags it, the workaround is a 20-way if-else mux. But for this project, indexed write is correct and synthesizable.

**Warning signs:** Synthesis warning "multi-driver" or "non-constant index" — investigate, but the warning is usually benign for this use case.

---

### Pitfall 6: elapsed_timer Freeze Races

**What goes wrong:** `freeze` is asserted by mode_fsm the same cycle it transitions to PRIME_DONE. If `second_tick` also fires on that cycle, the decision of whether to increment `seconds_ff` is ambiguous.

**Why it happens:** Both events are comb-evaluated in the same always @(*) block.

**How to avoid:** In elapsed_timer comb block, check `freeze` FIRST (highest priority). If `freeze == 1`, all `next_` signals hold their current values regardless of `second_tick`. This is deterministic and correct — the last seen value is what freezes.

**Warning signs:** Testbench: elapsed seconds one count too high after freeze; or cycle_count_ff increments one extra time after done.

---

## Code Examples

### Verified Pattern: prime_engine Port Interface
```verilog
// Source: rtl/prime_engine.v (Phase 1 — read directly)
// WIDTH = 27 parameter
// Ports:
//   input  wire             clk, rst, start
//   input  wire [WIDTH-1:0] candidate
//   output reg              done_ff    // one-cycle pulse
//   output reg              is_prime_ff // holds result until next start
//   output reg              busy_ff    // high while engine is running
```

### Verified Pattern: Synchronous Reset in Comb Block
```verilog
// Source: rtl/prime_engine.v lines 85-93 (Phase 1 RTL)
always @(*) begin
    next_state = state_ff;
    // ... other defaults

    if (rst) begin
        next_state = IDLE;
        // ... clear all next_ signals
    end else begin
        case (state_ff)
            // ... state logic
            default: next_state = IDLE;
        endcase
    end
end
```

### Verified Pattern: One-Cycle done_ff Pulse
```verilog
// Source: rtl/prime_engine.v lines 81, 192-194
// done_ff is a registered output that pulses for one cycle in DONE state
// Default in comb block: next_done_out = 1'b0
// In DONE state: next_done_out = 1'b1; next_state = IDLE;
// Result: done_ff is 1 for exactly one clock cycle
```

### Derived Pattern: Mode 2 Termination Check
```verilog
// In mode_fsm always @(*), inside PRIME_RUN case:
// Check termination FIRST (highest priority) in if-else chain
if (mode_sel_ff == 2'd2 && seconds_ff >= t_limit_ff) begin
    next_state = PRIME_DONE;
    next_freeze = 1'b1;
end else if (candidate_ff > n_limit_ff && mode_sel_ff == 2'd1) begin
    next_state = PRIME_DONE;
    next_freeze = 1'b1;
end else if (prime_fifo_full_ff) begin
    next_state = PRIME_RUN;  // stall: stay, no start
    next_eng_start = 1'b0;
end else if (~eng_busy_ff) begin
    next_eng_start = 1'b1;
    next_state = PRIME_RUN;
end else begin
    next_eng_start = 1'b0;
    next_state = PRIME_RUN;
end
```

### Derived Pattern: elapsed_timer Skeleton
```verilog
// Source: D-08 through D-11 (CONTEXT.md)
module elapsed_timer #(
    parameter TICK_PERIOD = 100_000_000
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        freeze,
    output reg [31:0]  cycle_count_ff,
    output reg [31:0]  seconds_ff,
    output reg         second_tick_ff
);
    localparam TICK_BITS = 27;  // 2^27 = 134,217,728 > 100,000,000
    reg [TICK_BITS-1:0] tick_cnt_ff;

    // next_ wires declared as reg (comb use only)
    reg [TICK_BITS-1:0] next_tick_cnt;
    reg [31:0]          next_cycle_count;
    reg [31:0]          next_seconds;
    reg                 next_second_tick;

    always @(*) begin
        // defaults: hold
        next_tick_cnt    = tick_cnt_ff;
        next_cycle_count = cycle_count_ff;
        next_seconds     = seconds_ff;
        next_second_tick = 1'b0;  // pulse default off

        if (rst) begin
            next_tick_cnt    = {TICK_BITS{1'b0}};
            next_cycle_count = 32'd0;
            next_seconds     = 32'd0;
            next_second_tick = 1'b0;
        end else if (freeze) begin
            // hold everything — highest priority
            next_tick_cnt    = tick_cnt_ff;
            next_cycle_count = cycle_count_ff;
            next_seconds     = seconds_ff;
        end else begin
            next_cycle_count = cycle_count_ff + 32'd1;
            if (tick_cnt_ff == TICK_BITS'(TICK_PERIOD - 1)) begin
                next_tick_cnt    = {TICK_BITS{1'b0}};
                next_seconds     = seconds_ff + 32'd1;
                next_second_tick = 1'b1;
            end else begin
                next_tick_cnt = tick_cnt_ff + {{TICK_BITS-1{1'b0}}, 1'b1};
            end
        end
    end

    always @(posedge clk) begin
        tick_cnt_ff    <= next_tick_cnt;
        cycle_count_ff <= next_cycle_count;
        seconds_ff     <= next_seconds;
        second_tick_ff <= next_second_tick;
    end
endmodule
```

---

## Key Numeric Constants

| Constant | Value | Derivation |
|----------|-------|-----------|
| WIDTH | 27 | prime_engine parameter; covers candidates up to 134,217,727 > 99,999,999 max N |
| TICK_PERIOD (production) | 100,000,000 | 100 MHz / 1 Hz = 1 second |
| TICK_BITS | 27 | ceil(log2(100,000,001)) = 27; 2^26 = 67,108,864 < 100,000,000 |
| TICK_PERIOD (testbench) | 100 | Shrinks 1 second to 100 clock cycles for feasible Mode 2 sim |
| FIFO_DEPTH | 32 | Power-of-2; 32 × 27-bit primes = 864 bits — fits in one 18Kb BRAM |
| RING_SIZE | 20 | Fixed by requirement PRIME-05; write pointer is 5-bit (0..19) |
| Mode 1 N=100 prime count | 25 | Primes: 2,3,5,7,11,13,17,19,23,29,31,37,41,43,47,53,59,61,67,71,73,79,83,89,97 |
| prime_engine cycles per run | ~27-200 | 27 cycles per division; candidates near 100 need ~2 divisor pairs = ~120 cycles |

---

## Integration Contracts (Signal-Level)

### mode_fsm → prime_engine
| Signal | Direction | Width | Notes |
|--------|-----------|-------|-------|
| `eng_start` | mode_fsm → prime_engine (`start`) | 1 | Pulse; must be 0 when `eng_busy_ff == 1` |
| `eng_candidate` | mode_fsm → prime_engine (`candidate`) | WIDTH | Valid and stable when `eng_start` pulses |
| `eng_done_ff` | prime_engine → mode_fsm (`done_ff`) | 1 | One-cycle pulse; mode_fsm latches `eng_is_prime_ff` this cycle |
| `eng_is_prime_ff` | prime_engine → mode_fsm (`is_prime_ff`) | 1 | Holds until next start |
| `eng_busy_ff` | prime_engine → mode_fsm (`busy_ff`) | 1 | High while engine computing |

### mode_fsm → prime_accumulator
| Signal | Direction | Width | Notes |
|--------|-----------|-------|-------|
| `prime_valid` | mode_fsm → prime_accumulator | 1 | One-cycle pulse when a prime is confirmed |
| `prime_data` | mode_fsm → prime_accumulator | WIDTH | The prime value; valid when `prime_valid` pulses |
| `prime_fifo_full_ff` | prime_accumulator → mode_fsm | 1 | Back-pressure; stall when high |

### mode_fsm → elapsed_timer
| Signal | Direction | Width | Notes |
|--------|-----------|-------|-------|
| `timer_freeze` | mode_fsm → elapsed_timer | 1 | Asserted when mode_fsm enters a DONE state |
| `seconds_ff` | elapsed_timer → mode_fsm | 32 | Read every cycle for Mode 2 termination check |
| `cycle_count_ff` | elapsed_timer → mode_fsm | 32 | Read in ISPRIME_DONE for elapsed-cycles display |

---

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| iverilog | All TB simulation | Yes | 12.0 (devel) at `/c/iverilog/bin/iverilog` | None needed |
| vvp | All TB execution | Yes | bundled with iverilog at `/c/iverilog/bin/vvp` | None needed |
| python / python3 | golden list generation (Phase 1) | No (not in PATH on Windows) | — | Phase 1 golden_primes.mem already generated; not needed for Phase 2 |
| Vivado | Synthesis verification | Not in PATH (developer machine) | — | iverilog covers all Phase 2 sim; Vivado check deferred to hardware phases |

**Missing dependencies with no fallback:** None — all Phase 2 simulation needs are met by iverilog + vvp.

---

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | iVerilog 12.0 (behavioral sim) |
| Config file | None — compile command is manual (see Standard Stack) |
| Quick run command | `iverilog -g2001 -o sim/accumulator_tb.vvp rtl/prime_accumulator.v tb/accumulator_tb.v && vvp sim/accumulator_tb.vvp` |
| Full suite command | `iverilog -g2001 -o sim/mode_fsm_tb.vvp rtl/divider.v rtl/prime_engine.v rtl/elapsed_timer.v rtl/prime_accumulator.v rtl/mode_fsm.v tb/mode_fsm_tb.v && vvp sim/mode_fsm_tb.vvp` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|--------------|
| PRIME-02 | Mode 1 N=100 finds exactly 25 primes, asserts done | integration | `vvp sim/mode_fsm_tb.vvp` | No — Wave 0 |
| PRIME-03 | Mode 2 T=3 (sim) terminates after T seconds_ff tick | integration | `vvp sim/mode_fsm_tb.vvp` | No — Wave 0 |
| PRIME-04 | Mode 3 candidate=97 returns is_prime=1; candidate=99 returns 0; cycle_count frozen | integration | `vvp sim/mode_fsm_tb.vvp` | No — Wave 0 |
| PRIME-05 | prime_count_ff increments on each prime; last20 holds correct 20 after 25 primes written | unit | `vvp sim/accumulator_tb.vvp` | No — Wave 0 |
| PRIME-06 | cycle_count_ff increments every clock; seconds_ff increments every TICK_PERIOD cycles; both freeze on freeze=1 | unit | `vvp sim/accumulator_tb.vvp` (elapsed_timer standalone or folded into accumulator_tb) | No — Wave 0 |

### Sampling Rate
- **Per task commit:** `vvp sim/accumulator_tb.vvp` (unit-level, fast)
- **Per wave merge:** Full suite — both accumulator_tb and mode_fsm_tb must pass
- **Phase gate:** Full suite green before `/gsd:verify-work`

### Wave 0 Gaps
- [ ] `tb/mode_fsm_tb.v` — integration test covering PRIME-02, PRIME-03, PRIME-04
- [ ] `tb/accumulator_tb.v` — unit test covering PRIME-05, PRIME-06 (includes elapsed_timer unit checks)
- [ ] `rtl/mode_fsm.v` — DUT for mode_fsm_tb
- [ ] `rtl/elapsed_timer.v` — DUT; must exist before either TB compiles
- [ ] `rtl/prime_accumulator.v` — DUT for accumulator_tb

---

## Open Questions

1. **mode_fsm input port for mode_sel and N/T**
   - What we know: MODE_SELECT state needs a `mode_sel` input; NUMBER_ENTRY needs a digit value; TIME_ENTRY needs a T value
   - What's unclear: Phase 2 is sim-only (no joystick/7SD). Should mode_fsm expose raw `n_limit [WIDTH-1:0]` and `t_limit [31:0]` and `mode_sel [1:0]` as direct wire inputs, with the testbench driving them?
   - Recommendation: Yes — expose `n_limit`, `t_limit`, `mode_sel`, and `go` (enter pulse) as top-level ports. Phase 4 will wrap mode_fsm with the joystick/7SD driver. This is already implied by the CONTEXT.md phase boundary statement.

2. **prime_fifo_rd_data_ff registered output**
   - What we know: D-05 specifies `prime_fifo_rd_data_ff` as a registered output (the `_ff` suffix)
   - What's unclear: With a registered read port, reading requires asserting `rd_en` one cycle before data is valid. The DDR2 controller (Phase 3) must account for this read latency.
   - Recommendation: Implement with registered read (required for BRAM inference); document the one-cycle read latency in the module header as a contract for Phase 3.

3. **mode_fsm done output — which states assert it**
   - What we know: PRIME_DONE and ISPRIME_DONE should signal completion; freeze goes high at this point
   - What's unclear: Does done_ff stay high while in the DONE state, or pulse once on entry?
   - Recommendation: Hold `done_ff` high for the duration of the DONE state (not a one-cycle pulse). This matches VGA display freeze requirements — the display must stay frozen until a new mode is selected. `freeze` (timer) can similarly be held high.

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Separate FSM for each mode | Single flat 9-state FSM (D-14) | Phase 2 decision | Fewer modules, simpler testbench coverage |
| Every integer as candidate | 6k±1 candidate filter in mode_fsm | Phase 2 decision | ~1/3 fewer prime_engine invocations |
| `% 20` for ring buffer wrap | Explicit compare-and-reset | Class rule (no division) | Synthesizable; no multi-cycle hardware needed |

---

## Sources

### Primary (HIGH confidence)
- `rtl/prime_engine.v` — verified Phase 1 RTL; prime_engine port interface and timing extracted directly
- `rtl/divider.v` — verified Phase 1 RTL; multi-cycle sub-module pattern reference
- `.planning/phases/02-prime-modes-fsm/02-CONTEXT.md` — locked design decisions D-01 through D-15
- `.planning/REQUIREMENTS.md` — PRIME-02 through PRIME-06 acceptance criteria

### Secondary (MEDIUM confidence)
- `.planning/phases/01-prime-engine-core/01-RESEARCH.md` — two-block FSM pattern, coding rules — matches Phase 1 RTL
- Numeric constant derivations (27-bit tick counter, 32-depth FIFO) — computed directly from spec values

### Tertiary (LOW confidence — for awareness only)
- None — all critical patterns verified from existing project RTL and locked decisions

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — iverilog confirmed installed; no new tools required
- Architecture: HIGH — all patterns derive from verified Phase 1 RTL contracts; no external dependencies
- Integration contracts: HIGH — extracted directly from prime_engine.v RTL analysis
- FIFO/ring buffer patterns: MEDIUM-HIGH — standard Verilog BRAM inference patterns; tested approaches in the community
- Pitfalls: HIGH — derived from handshake timing analysis of actual prime_engine.v code

**Research date:** 2026-03-25
**Valid until:** 2026-06-25 (stable; all patterns from fixed RTL, no external library versioning)
