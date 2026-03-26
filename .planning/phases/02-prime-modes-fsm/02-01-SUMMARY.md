---
phase: 02-prime-modes-fsm
plan: "01"
subsystem: rtl
tags: [elapsed-timer, prime-accumulator, fifo, ring-buffer, verilog, fsm]
dependency_graph:
  requires: [rtl/prime_engine.v, rtl/divider.v]
  provides: [rtl/elapsed_timer.v, rtl/prime_accumulator.v]
  affects: [rtl/mode_fsm.v (future)]
tech_stack:
  added: []
  patterns:
    - Two-block FSM (always @(*) comb + always @(posedge clk) flop)
    - BRAM-inferred FIFO via synchronous dual-port read/write
    - Ring buffer with explicit pointer wrap (no modulo, no for loop)
    - Individual output ports for array values (Verilog-2001 compat)
key_files:
  created:
    - rtl/elapsed_timer.v
    - rtl/prime_accumulator.v
  modified: []
decisions:
  - elapsed_timer uses plain integer comparison (tick_cnt_ff == TICK_PERIOD - 1) instead of sized-cast syntax -- iverilog does not support TICK_BITS'(...) parameterized bit-width casts
  - prime_accumulator last20 uses 20 individual output reg ports rather than array port -- Verilog-2001 disallows array port declarations
  - fifo_count_ff is PTR_W+1 bits wide (6 bits for depth 32) to unambiguously distinguish full (count==32) from empty (count==0)
metrics:
  duration_seconds: 81
  completed_date: "2026-03-25"
  tasks_completed: 2
  files_created: 2
---

# Phase 02 Plan 01: Supporting Sub-Modules (elapsed_timer + prime_accumulator) Summary

**One-liner:** 32-bit elapsed timer with freeze and TICK_PERIOD parameter plus BRAM FIFO accumulator with prime_count and last-20 ring buffer, both following the two-block FSM coding standard.

## Objective

Create the two supporting RTL sub-modules for Phase 2: `elapsed_timer.v` (cycle/seconds counter with freeze) and `prime_accumulator.v` (FIFO + count + last-20 ring buffer). These are prerequisites for `mode_fsm.v` (Plan 02) and the testbenches (Plans 03-04).

## What Was Built

### Task 1: elapsed_timer.v

`rtl/elapsed_timer.v` — a parameterized elapsed timer with:

- `TICK_PERIOD` parameter (default 100,000,000 for 100 MHz) enabling fast simulation by overriding to a small value
- 27-bit internal `tick_cnt_ff` counting 0 to TICK_PERIOD-1
- 32-bit `cycle_count_ff` incrementing every clock cycle
- 32-bit `seconds_ff` incrementing on each TICK_PERIOD rollover
- `second_tick_ff` one-cycle pulse on each second
- `freeze` input with highest priority after reset (halts all counters)
- Plain integer comparison `tick_cnt_ff == TICK_PERIOD - 1` (iverilog compatible)

### Task 2: prime_accumulator.v

`rtl/prime_accumulator.v` — a prime result accumulator with:

- BRAM-inferred FIFO (depth 32, width WIDTH=27): synchronous write and registered read ports
- `fifo_count_ff` (6 bits, one wider than PTR_W) to unambiguously distinguish full (32) from empty (0)
- `prime_fifo_full_ff` / `prime_fifo_empty_ff` flags derived from `next_fifo_count` after computing simultaneous read+write effects
- `prime_count_ff` 32-bit running total of found primes
- 20-entry last-20 ring buffer with explicit wrap logic (`if (ring_wr_ptr_ff == 5'd19)`)
- 20 individual `output reg` ports (last20_0_ff through last20_19_ff) for Verilog-2001 port compatibility
- Explicit reset of all 20 ring buffer entries without for loops

## Verification

Both modules compiled cleanly with iverilog -g2001 (exit 0, no warnings or errors):

```
/c/iverilog/bin/iverilog -g2001 -o sim/elapsed_timer_check.vvp rtl/elapsed_timer.v
/c/iverilog/bin/iverilog -g2001 -o sim/prime_accumulator_check.vvp rtl/prime_accumulator.v
```

## Deviations from Plan

### Auto-fixed Issues

None — plan executed exactly as written with two minor implementation clarifications tracked as decisions.

### Decisions Made

1. **Plain integer comparison for TICK_PERIOD:** The RESEARCH.md skeleton used `TICK_BITS'(TICK_PERIOD - 1)` but the plan explicitly noted this is not valid in iverilog. Used `tick_cnt_ff == TICK_PERIOD - 1` per plan instruction.

2. **Individual output ports for last20:** Used 20 individual `output reg [WIDTH-1:0]` ports (last20_0_ff..last20_19_ff) with an internal `last20_ff[0:19]` reg array, copying to output ports in a dedicated flop block. Verilog-2001 does not allow array port declarations.

3. **fifo_count_ff width:** Used PTR_W+1 = 6 bits so that `count == FIFO_DEPTH` (= 32) and `count == 0` are unambiguous distinguishing conditions for full and empty.

## Commits

| Task | Commit | Description |
|------|--------|-------------|
| 1 | 441d0f1 | feat(02-01): create elapsed_timer.v |
| 2 | 62f09f4 | feat(02-01): create prime_accumulator.v |

## Known Stubs

None — both modules are fully implemented with no placeholder logic.

## Self-Check: PASSED
