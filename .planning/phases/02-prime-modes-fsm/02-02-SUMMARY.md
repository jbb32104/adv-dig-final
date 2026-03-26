---
phase: 02-prime-modes-fsm
plan: "02"
subsystem: rtl/mode_fsm
tags: [fsm, mode-dispatcher, prime-modes, candidate-enumeration, orchestration]
dependency_graph:
  requires: ["02-01"]
  provides: ["rtl/mode_fsm.v"]
  affects: ["02-03", "02-04"]
tech_stack:
  added: []
  patterns:
    - "Two-block FSM: always @(*) comb + always @(posedge clk) flop"
    - "6k+/-1 candidate enumeration via step_toggle_ff and init_phase_ff"
    - "Mode 2 immediate termination on seconds_ff >= t_limit_ff"
    - "FIFO back-pressure stall on prime_fifo_full_ff"
key_files:
  created:
    - rtl/mode_fsm.v
    - rtl/elapsed_timer.v
    - rtl/prime_accumulator.v
  modified: []
decisions:
  - "Copied elapsed_timer.v and prime_accumulator.v from sibling worktree (02-01) to enable compilation verification — these files will merge from that worktree's changes"
  - "step_toggle_ff=0 means +2 next, step_toggle_ff=1 means +4 next (5→7 is +2, 7→11 is +4)"
  - "init_phase_ff tracks special-case 2/3 seeding before main 6k+/-1 loop enters"
  - "Mode 2 timeout fires even mid-computation per D-12 — engine result is discarded"
metrics:
  duration: "2 minutes"
  completed: "2026-03-26"
  tasks_completed: 1
  files_changed: 3
---

# Phase 2 Plan 2: mode_fsm.v — 9-state Mode Dispatcher FSM — Summary

**One-liner:** 9-state mode dispatcher FSM orchestrating Modes 1/2/3 via 6k+/-1 candidate enumeration with step_toggle_ff, immediate Mode 2 termination, FIFO back-pressure, and prime_engine handshake.

## What Was Built

`rtl/mode_fsm.v` — the central orchestration module for Phase 2. It drives `prime_engine`, `prime_accumulator`, and `elapsed_timer` across all three computation modes:

- **Mode 1** (NUMBER_ENTRY → PRIME_RUN → PRIME_DONE): enumerates 6k±1 candidates up to N, feeds each to prime_engine, stores results via prime_valid pulse.
- **Mode 2** (TIME_ENTRY → PRIME_RUN → PRIME_DONE): same enumeration but terminates immediately when `seconds_ff >= t_limit_ff`, per D-12.
- **Mode 3** (ISPRIME_ENTRY → ISPRIME_RUN → ISPRIME_DONE): single candidate test, stores is_prime_result_ff, freezes timer on completion.

### Key Implementation Details

**Candidate Enumeration (D-01/D-02):**
- `init_phase_ff = 2'b10`: feed candidate 2 first
- `init_phase_ff = 2'b01`: feed candidate 3 next
- `init_phase_ff = 2'b00`: main loop — alternate +2 and +4 via `step_toggle_ff`
- Sequence: 2, 3, 5, 7, 11, 13, 17, 19 ... (all primes > 3 are of form 6k±1)

**PRIME_RUN Priority Order:**
1. Mode 2 timeout (`seconds_ff >= t_limit_ff`) — immediate, per D-12
2. Mode 1 done (`candidate_ff > n_limit_ff && !waiting_result_ff`)
3. Waiting for engine result (`waiting_result_ff`)
4. FIFO full stall (`prime_fifo_full_ff`) — per D-06
5. Start next candidate (`!eng_busy_ff`) — per Pitfall 1
6. Default hold

**Timing Correctness:**
- `eng_start_ff` gated on `!eng_busy_ff`, NOT on `eng_done_ff` (Pitfall 1)
- Candidate advance happens when `eng_done_ff` fires; start fires next cycle with new candidate (Pitfall 2)
- Mode 2 timeout transitions immediately to PRIME_DONE even mid-computation (Pitfall 3)

## Tasks Completed

| Task | Description | Commit | Files |
|------|-------------|--------|-------|
| 1 | Create mode_fsm.v — 9-state mode dispatcher | 26ffdc0 | rtl/mode_fsm.v, rtl/elapsed_timer.v, rtl/prime_accumulator.v |

## Verification Results

```
iverilog -g2001 -o sim/mode_fsm_check.vvp \
  rtl/divider.v rtl/prime_engine.v rtl/elapsed_timer.v \
  rtl/prime_accumulator.v rtl/mode_fsm.v
EXIT: 0
```

All 9 states present, all required signals implemented, clean compilation.

## Deviations from Plan

### Auto-handled Setup

**1. [Rule 3 - Blocking Issue] Copied 02-01 sub-module files to this worktree for compilation**
- **Found during:** Task 1 verification
- **Issue:** `elapsed_timer.v` and `prime_accumulator.v` (created by plan 02-01 in a sibling worktree) were not present in this worktree, causing compile to fail without them
- **Fix:** Copied the files from sibling worktree `agent-a30cfbc1` to enable full compile verification. These files are not modified — they are the exact outputs of plan 02-01.
- **Files modified:** rtl/elapsed_timer.v, rtl/prime_accumulator.v (copied, not modified)
- **Commit:** 26ffdc0 (same commit as mode_fsm.v)

None — all plan logic executed exactly as specified.

## Known Stubs

None — mode_fsm.v wires all signals to sub-module interfaces. The FIFO read-side (`prime_fifo_rd_en`) is tied low by the testbench (per D-05), which is the intended Phase 2 behavior documented in the plan.

## Self-Check: PASSED

- [x] `rtl/mode_fsm.v` exists: FOUND
- [x] Commit 26ffdc0 exists: FOUND
- [x] iverilog compile exits 0: VERIFIED
- [x] All 9 state localparams present: VERIFIED
- [x] step_toggle_ff, init_phase_ff, waiting_result_ff present: VERIFIED
- [x] seconds_ff >= t_limit_ff comparison present: VERIFIED
- [x] candidate_ff > n_limit_ff comparison present: VERIFIED
- [x] prime_fifo_full_ff stall check present: VERIFIED
- [x] !eng_busy_ff gate for eng_start present: VERIFIED
- [x] Exactly 1 always @(*) block, 1 always @(posedge clk) block: VERIFIED
- [x] if (rst) synchronous reset in comb block: VERIFIED
- [x] default: in state case: VERIFIED
- [x] No for loops: VERIFIED (all "for" occurrences are in comments)
