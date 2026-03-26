# Phase 2: Prime Modes FSM - Context

**Gathered:** 2026-03-25
**Status:** Ready for planning

<domain>
## Phase Boundary

Wrap the Phase 1 prime engine in a mode dispatcher FSM and supporting modules that implement Modes 1, 2, and 3 in simulation. No display hardware, no real joystick, no DDR2 — this phase is sim-only. The testbench drives N and T directly as wire inputs. Phase 3 will connect the DDR2 write side; Phase 4 will connect joystick and 7SD.

Modules to produce: `mode_fsm.v`, `elapsed_timer.v`, `prime_accumulator.v`, `mode_fsm_tb.v`, `accumulator_tb.v`.

</domain>

<decisions>
## Implementation Decisions

### Candidate enumeration (Modes 1 and 2)
- **D-01:** mode_fsm feeds prime_engine the 6k±1 candidate sequence: 2, then 3, then candidates starting at 5 alternating +2/+4 (5, 7, 11, 13, 17, 19 …). Controlled by a single toggle flip-flop (`step_toggle_ff`) in mode_fsm.
- **D-02:** No multiplication in the iteration loop — only addition (+2 or +4). The step toggle does not require a counter or multiplier.
- **D-03:** Rationale: ~1/3 the prime_engine invocations vs. testing every integer. Execution time is the stated optimization target. All primes > 3 are of the form 6k±1, so no prime is missed.

### Prime accumulator and DDR2 stub (FIFO architecture)
- **D-04:** prime_accumulator.v instantiates an internal BRAM-based FIFO to buffer found primes. Phase 3 connects to the FIFO read-side without changing prime_accumulator's port list.
- **D-05:** FIFO read-side ports exposed on prime_accumulator: `prime_fifo_rd_en` (input), `prime_fifo_rd_data_ff [WIDTH-1:0]` (output), `prime_fifo_empty_ff` (output). In Phase 2 sim, tie `prime_fifo_rd_en = 0` — FIFO fills but is never read.
- **D-06:** FIFO full → stall mode_fsm. mode_fsm checks `prime_fifo_full_ff` before starting the next prime_engine run; if full, it waits in PRIME_RUN state without asserting `start`. Elapsed timer keeps running during the stall.
- **D-07:** prime_accumulator also maintains: `prime_count_ff` (32-bit running count of primes found), `last20` ring buffer (20 entries × WIDTH bits, overwrite oldest on each new prime).

### Elapsed timer
- **D-08:** elapsed_timer.v runs entirely on the 100 MHz system clock. No PLL or separate clock domain — avoids CDC complexity and conserves MMCM resources for MIG (Phase 3) and pixel clock (Phase 4).
- **D-09:** Internal 27-bit cycle counter counts to 100,000,000 then resets, asserting a one-cycle `second_tick` pulse (100 MHz / 100,000,000 = exactly 1 Hz).
- **D-10:** Outputs: `cycle_count_ff` (32-bit, increments every clock), `seconds_ff` (32-bit, increments on each `second_tick`).
- **D-11:** `freeze` input (driven by mode_fsm when done is asserted) halts both counters. Both registers hold their last value when frozen.

### Mode 2 termination
- **D-12:** mode_fsm checks `seconds_ff >= t_limit_ff` every clock cycle in the combinational block. Terminates immediately on the first cycle the condition is true — no overshoot waiting for a prime test to finish.
- **D-13:** T is held in `t_limit_ff` (32-bit), loaded from the `t_limit` input when mode_fsm transitions into TIME_ENTRY.

### FSM partitioning
- **D-14:** One flat `mode_fsm.v` with all 9 states: IDLE, MODE_SELECT, NUMBER_ENTRY, TIME_ENTRY, PRIME_RUN, PRIME_DONE, ISPRIME_ENTRY, ISPRIME_RUN, ISPRIME_DONE. Single `always @(*)` comb block + single `always @(posedge clk)` flop block per class rules.
- **D-15:** No sub-FSMs or dispatcher hierarchy. Keeps module count low and testbench coverage straightforward.

### Claude's Discretion
- FIFO depth (suggest 32 or 64 entries — enough to absorb a burst before DDR2 writer catches up in Phase 3)
- Internal state encoding (binary vs. one-hot; binary preferred for resource efficiency)
- Exact testbench stimulus values (N and T for each test case, beyond the roadmap success-criteria minimums)

</decisions>

<specifics>
## Specific Ideas

- "We only need to check numbers of the form 6k±1 as candidates" — user confirmed the 6k±1 candidate filter, not just the divisor filter inside prime_engine
- "Feed found primes into a FIFO that feeds into memory — BRAM FIFO is much quicker and we can keep looking at full speed" — FIFO-buffered write path is the explicit architecture
- Timer on system clock, not PLL-derived — user agreed after clarification on MMCM resource budget and CDC risk

</specifics>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Existing RTL (Phase 1 interface contracts)
- `rtl/prime_engine.v` — prime engine module: WIDTH=27 parameter, `start`/`busy_ff`/`done_ff`/`is_prime_ff`/`candidate` port interface; two-block FSM pattern to follow
- `rtl/divider.v` — divider sub-module instantiated by prime_engine; reference for multi-cycle sub-module patterns

### Phase requirements and roadmap
- `.planning/ROADMAP.md` — Phase 2 goal, success criteria (5 items), and plan list (02-01 through 02-04)
- `.planning/REQUIREMENTS.md` — PRIME-02, PRIME-03, PRIME-04, PRIME-05, PRIME-06 (full acceptance criteria)

### Prior phase research (coding patterns)
- `.planning/phases/01-prime-engine-core/01-RESEARCH.md` — Two-block FSM coding standard, _ff/_n naming, synchronous reset in always @(*), no-for-loops rule; all patterns MUST be replicated in Phase 2 modules

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `prime_engine.v` (WIDTH=27): drives directly from mode_fsm via `start`/`candidate` → wait `busy_ff` low or `done_ff` high → read `is_prime_ff`. No changes needed.
- `divider.v`: reference pattern for multi-cycle sub-module with start/done_ff handshake — same pattern prime_accumulator's FIFO controller should follow.

### Established Patterns
- Two-block FSM: `always @(*)` for all combinational logic (next-state, next-outputs, reset decode) + `always @(posedge clk)` for all flip-flop registers only. No exceptions.
- All flip-flop signals carry `_ff` suffix; active-low signals carry `_n` suffix.
- Synchronous reset: handled in the `always @(*)` comb block (`if (rst) begin … end else begin … end`), not as a sensitivity list event.
- `default:` in every `case`; final `else` in every `if-else` chain.
- ANSI module port declarations throughout.

### Integration Points
- mode_fsm drives prime_engine: `start` pulse + `candidate` — must wait for `busy_ff` to deassert before pulsing `start` again
- mode_fsm drives elapsed_timer: `freeze` input goes high when mode_fsm enters a DONE state
- mode_fsm drives prime_accumulator: `prime_valid` pulse + `prime_data` on each `is_prime_ff` assertion
- prime_accumulator exposes `prime_fifo_full_ff` back to mode_fsm for back-pressure

</code_context>

<deferred>
## Deferred Ideas

- None — discussion stayed within phase scope. DDR2 write controller (read side of FIFO) is explicitly Phase 3.

</deferred>

---

*Phase: 02-prime-modes-fsm*
*Context gathered: 2026-03-25*
