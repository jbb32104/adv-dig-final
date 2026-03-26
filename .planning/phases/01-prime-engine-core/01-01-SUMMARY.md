---
phase: 01-prime-engine-core
plan: 01
subsystem: prime-engine
tags: [rtl, verilog, divider, fsm, 6k-plus-minus-1, synthesis]
dependency_graph:
  requires: []
  provides: [rtl/divider.v, rtl/prime_engine.v]
  affects: [02-testbench, 03-ddr2-integration]
tech_stack:
  added: [iVerilog-g2001]
  patterns: [two-always-block-FSM, restoring-binary-division, DSP48-bound-check]
key_files:
  created:
    - rtl/divider.v
    - rtl/prime_engine.v
    - sim/.gitignore
  modified: []
decisions:
  - "Use combinational div_start wired directly to divider (not through FF) to avoid one-cycle start delay"
  - "WAIT_DIV3 state added for divisibility-by-3 check; essential to correctly classify composites like 9, 15, 21"
  - "d*d > candidate (strict >) for sqrt bound — ensures d=5 for candidate=25 is not skipped prematurely"
metrics:
  duration: 2 minutes
  completed: 2026-03-26
  tasks_completed: 2
  files_changed: 3
---

# Phase 1 Plan 1: Prime Engine RTL Summary

**One-liner:** WIDTH=27 restoring binary divider and 7-state 6k+/-1 prime engine FSM, fully CSEE 4280 compliant, iVerilog clean.

## What Was Built

### Task 1: rtl/divider.v

A parameterized (WIDTH=27) restoring binary integer divider. Accepts a dividend and divisor and computes quotient and remainder in exactly WIDTH clock cycles after `start` is asserted. Key properties:

- Single `always @(posedge clk)` block with non-blocking assignments only
- `done_ff` pulses HIGH for exactly one clock cycle upon completion
- Divide-by-zero guard: asserts `dbz_ff` and `done_ff` immediately if divisor is zero
- All internal registers carry `_ff` suffix: `dividend_copy_ff`, `divisor_copy_ff`, `acc_ff`, `quo_ff`, `iter_ff`
- Trial subtraction is a combinational `assign` wire (`acc_next`), not in any always block
- No `for` loops; `iter_ff` counts from 0 to WIDTH-1 using non-blocking increment

### Task 2: rtl/prime_engine.v

A 7-state FSM implementing the 6k+/-1 primality algorithm. Instantiates `divider.v` as `u_div`. States:

| State | Purpose |
|-------|---------|
| IDLE | Wait for start; latch candidate |
| CHECK_2_3 | Handle trivial cases: 0/1 (not prime), 2/3 (prime), even>2 (not prime), else fire div-by-3 |
| WAIT_DIV3 | Wait for divider result; if remainder=0 → not prime; else advance to INIT_K with k=1, d=5 |
| INIT_K | Check bound (d*d > candidate); if exceeded → prime; else fire divider for 6k-1 divisor |
| TEST_KM1 | Wait for divider; if remainder=0 → not prime; else advance d by 2, fire divider for 6k+1 |
| TEST_KP1 | Wait for divider; if remainder=0 → not prime; else advance k, d by 4, back to INIT_K |
| DONE | Assert done_out_ff=1 for one cycle; return to IDLE |

Output wires: `assign done_ff = done_out_ff`, `assign is_prime_ff = is_prime_result_ff`, `assign busy_ff = (state_ff != IDLE) && (state_ff != DONE)`.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed redundant/confusing candidate==2 check expression**
- **Found during:** Task 2 post-write review
- **Issue:** CHECK_2_3 state had expression `(candidate_ff == {{WIDTH-1{1'b0}}, 1'b0} | 1'b0)` which evaluates to checking if candidate==0 (already caught by the <=1 branch), plus an OR with the correct check for candidate==2. The expression was logically correct but confusingly written.
- **Fix:** Simplified to a single `candidate_ff == {{WIDTH-2{1'b0}}, 2'd2}` comparison.
- **Files modified:** rtl/prime_engine.v
- **Commit:** 817960b

## Known Stubs

None. Both modules are fully wired RTL with no placeholder values or hardcoded empty results.

## Self-Check: PASSED

Files exist:
- rtl/divider.v: FOUND
- rtl/prime_engine.v: FOUND
- sim/.gitignore: FOUND

Commits exist:
- 2113031 (feat(01-01): create restoring binary divider sub-module): FOUND
- 817960b (feat(01-01): create 6k+/-1 prime engine FSM): FOUND
- b5ad558 (chore(01-01): add sim/.gitignore): FOUND

Verification: `iverilog -g2001 rtl/divider.v rtl/prime_engine.v` → Zero errors.
