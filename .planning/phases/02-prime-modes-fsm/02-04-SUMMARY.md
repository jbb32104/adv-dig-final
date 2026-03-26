---
phase: 02-prime-modes-fsm
plan: 04
subsystem: testing
tags: [iverilog, verilog, mode_fsm, prime_accumulator, elapsed_timer, integration-test, simulation]

# Dependency graph
requires:
  - phase: 02-prime-modes-fsm/02-01
    provides: elapsed_timer.v and prime_accumulator.v RTL
  - phase: 02-prime-modes-fsm/02-02
    provides: mode_fsm.v 9-state FSM RTL
  - phase: 02-prime-modes-fsm/02-03
    provides: accumulator_tb unit test pattern (write_prime/read_prime tasks, idle-posedge protocol)
  - phase: 01-prime-engine-core/01-01
    provides: prime_engine.v and divider.v verified RTL
provides:
  - tb/mode_fsm_tb.v — integration testbench for full Mode 1/2/3 stack
  - Phase 2 gate validation: all PRIME-02..PRIME-06 requirements verified in simulation
affects: [03-ddr2-interface, 04-vga-display, 05-sd-card-test]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Integration testbench wires all four sub-modules together mirroring future top-level"
    - "wait_done task with timeout parameter prevents infinite simulation loops"
    - "TICK_PERIOD=100 shrinks elapsed_timer 1-second period to 100 cycles for feasible Mode 2 sim"
    - "idle posedges after do_reset before pulse_go for clean state transitions"

key-files:
  created:
    - tb/mode_fsm_tb.v
  modified:
    - rtl/elapsed_timer.v (extracted from 02-01 worktree branch)
    - rtl/mode_fsm.v (extracted from 02-02 worktree branch)
    - rtl/prime_accumulator.v (extracted from 02-01 worktree branch)

key-decisions:
  - "Access u_acc.prime_count_ff via direct hierarchical reference (assign prime_count_w = u_acc.prime_count_ff) rather than exposing as output port — avoids modifying prime_accumulator interface"
  - "TICK_PERIOD=100 yields Mode 2 T=3 termination in 300 cycles — feasible simulation with 1000-cycle timeout guard"
  - "do_reset task uses 5 cycles of rst=1 then 2 idle cycles — ensures all module state cleared before each test"

patterns-established:
  - "Integration TB pattern: instantiate all sub-modules as peer instances, wire via combinational wire declarations"
  - "wait_done(max_cycles) task: spin on done_w with cycle counter, $fatal on timeout"
  - "Freeze verification: save cycle_count/seconds value, wait 10 cycles, assert unchanged"

requirements-completed: [PRIME-02, PRIME-03, PRIME-04, PRIME-05, PRIME-06]

# Metrics
duration: 15min
completed: 2026-03-26
---

# Phase 02 Plan 04: mode_fsm_tb Integration Testbench Summary

**Phase 2 gate testbench: verifies all three modes (find-to-N, timed, primality-check) through the full 4-module stack, confirming 25 primes for N=100, timed termination at T=3, and correct is_prime results for 97/99/2.**

## Performance

- **Duration:** ~15 min
- **Started:** 2026-03-26T03:37:00Z
- **Completed:** 2026-03-26T03:52:46Z
- **Tasks:** 1 of 1
- **Files modified:** 4 (1 created, 3 extracted from other worktree branches)

## Accomplishments

- Created `tb/mode_fsm_tb.v` — self-checking integration testbench exercising the full sub-module stack
- Test 1 (Mode 1, N=100): confirmed exactly 25 primes, prime_count=25, 97 in last20 ring buffer, cycle_count freezes on done
- Test 2 (Mode 2, T=3 sim-seconds): confirmed timed termination with seconds_w=3, prime_count=9 primes found, timer freezes
- Test 3 (Mode 3, candidate=97): confirmed is_prime_result=1
- Test 4 (Mode 3, candidate=99): confirmed is_prime_result=0 (composite 9×11)
- Test 5 (Mode 3, edge case candidate=2): confirmed is_prime_result=1
- Full Phase 2 suite (accumulator_tb + mode_fsm_tb) both print ALL TESTS PASSED

## Commits

| Hash | Description |
|------|-------------|
| fe90b0f | feat(02-04): create mode_fsm_tb.v integration testbench |

## Verification

```
iverilog -g2001 -o sim/accumulator_tb.vvp rtl/elapsed_timer.v rtl/prime_accumulator.v tb/accumulator_tb.v
vvp sim/accumulator_tb.vvp
# → ALL TESTS PASSED

iverilog -g2001 -o sim/mode_fsm_tb.vvp rtl/divider.v rtl/prime_engine.v rtl/elapsed_timer.v rtl/prime_accumulator.v rtl/mode_fsm.v tb/mode_fsm_tb.v
vvp sim/mode_fsm_tb.vvp
# → ALL TESTS PASSED
```

## Deviations from Plan

### Auto-handled Setup

**RTL files not in worktree branch:** The plan references rtl/mode_fsm.v, rtl/elapsed_timer.v, rtl/prime_accumulator.v which were created in parallel worktree branches (worktree-agent-a6bac804 and 02-01/02-02 agents). These were extracted from the appropriate git branches (`git show worktree-agent-a6bac804:rtl/...`) and committed to this worktree. This is expected parallel-execution behavior, not a deviation.

**prime_count_w via hierarchical reference:** The plan specified connecting prime_count_ff as an accumulator output wire, but prime_accumulator exposes it as `prime_count_ff` output. Rather than leaving it disconnected, added `wire [31:0] prime_count_w; assign prime_count_w = u_acc.prime_count_ff;` for clean testbench access without modifying the accumulator's port list.

None — plan executed exactly as written with the above setup notes.

## Known Stubs

None. All test checks are wired to live simulation outputs. The FIFO read side is intentionally tied off (1'b0) per the plan's D-05 note that DDR2 writer is Phase 3 work.

## Self-Check

- [x] tb/mode_fsm_tb.v exists
- [x] Commit fe90b0f exists
- [x] iverilog compile: exit 0
- [x] vvp simulation: ALL TESTS PASSED
- [x] Mode 1: prime_count=25
- [x] Mode 2: seconds_w=3, prime_count=9
- [x] Mode 3: 97→prime, 99→composite, 2→prime
