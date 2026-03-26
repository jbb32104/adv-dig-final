---
phase: 2
slug: prime-modes-fsm
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-03-25
---

# Phase 2 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | iVerilog behavioral sim + Vivado sim |
| **Config file** | none — testbenches are standalone `.v` files |
| **Quick run command** | `iverilog -o sim/mode_fsm_tb tb/mode_fsm_tb.v rtl/mode_fsm.v rtl/prime_engine.v rtl/divider.v rtl/elapsed_timer.v rtl/prime_accumulator.v && vvp sim/mode_fsm_tb` |
| **Accumulator run command** | `iverilog -o sim/accumulator_tb tb/accumulator_tb.v rtl/prime_accumulator.v && vvp sim/accumulator_tb` |
| **Estimated runtime** | ~5 seconds |

---

## Sampling Rate

- **After every task commit:** Run quick run command for the module just implemented
- **After every plan wave:** Run both testbenches to zero failures
- **Before `/gsd:verify-work`:** Both testbenches must exit with `ALL TESTS PASSED` and zero assertion failures
- **Max feedback latency:** ~5 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | Status |
|---------|------|------|-------------|-----------|-------------------|--------|
| 02-01 mode_fsm.v | 02-01 | 1 | PRIME-02, PRIME-03, PRIME-04 | unit/integration | `vvp sim/mode_fsm_tb` | ⬜ pending |
| 02-02 elapsed_timer.v | 02-02 | 1 | PRIME-06 | unit | `vvp sim/mode_fsm_tb` (timer instantiated inside) | ⬜ pending |
| 02-03 prime_accumulator.v | 02-03 | 1 | PRIME-05 | unit | `vvp sim/accumulator_tb` | ⬜ pending |
| 02-04 testbenches | 02-04 | 2 | PRIME-02..06 | self-check | both commands above | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `tb/mode_fsm_tb.v` — self-checking testbench for mode_fsm + elapsed_timer + prime_accumulator integrated
- [ ] `tb/accumulator_tb.v` — isolated unit test for prime_accumulator FIFO and ring buffer

*Wave 0 produces the testbench stubs; Wave 1 fills in the RTL under test.*

---

## Key Simulation Constraints

| Constraint | Detail |
|-----------|--------|
| `TICK_PERIOD` parameter | elapsed_timer must expose a `TICK_PERIOD` parameter (default 100_000_000; override to 100 in testbench) so Mode 2 sim completes in < 1000 cycles |
| No `$display` only — use `$fatal` / assertions | Self-checking: testbench must call `$fatal` or `$error` on mismatch, not just print |
| Prime sweep correctness | Mode 1 sim with N=100 must produce exactly 25 primes; testbench cross-checks against hardcoded golden list |
| Ring buffer wrap | last-20 ring buffer testbench must feed > 20 primes and verify correct overwrite behavior |
| Freeze semantics | Verify `cycle_count_ff` stops incrementing on the exact cycle `freeze` is asserted |

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Vivado synthesis with no critical warnings | INFRA-03..08 | Synthesis requires Vivado project | Open Vivado, add all Phase 2 RTL, run Synthesis, check messages |

---

## Validation Sign-Off

- [ ] All tasks have automated verify commands
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 testbench stubs created before RTL implementation
- [ ] No watch-mode flags
- [ ] Feedback latency < 10s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
