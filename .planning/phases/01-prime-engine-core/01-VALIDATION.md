---
phase: 1
slug: prime-engine-core
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-03-25
---

# Phase 1 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | iVerilog (iverilog + vvp) for behavioral sim; Vivado sim for synthesis-level |
| **Config file** | none — Wave 0 creates testbench files |
| **Quick run command** | `iverilog -o sim/prime_engine_tb.vvp rtl/prime_engine.v tb/prime_engine_tb.v && vvp sim/prime_engine_tb.vvp` |
| **Full suite command** | Same (single testbench sweeps 2–10007) |
| **Estimated runtime** | ~2 seconds |

---

## Sampling Rate

- **After every task commit:** Run `iverilog -o sim/prime_engine_tb.vvp rtl/prime_engine.v tb/prime_engine_tb.v && vvp sim/prime_engine_tb.vvp`
- **After every plan wave:** Run full testbench sweep
- **Before `/gsd:verify-work`:** Full testbench must show `PASS: all N test cases passed`
- **Max feedback latency:** ~5 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 1-01-01 | 01-01 | 1 | PRIME-01 | unit (iVerilog) | `iverilog -o sim/prime_engine_tb.vvp rtl/prime_engine.v tb/prime_engine_tb.v && vvp sim/prime_engine_tb.vvp` | ❌ W0 | ⬜ pending |
| 1-01-02 | 01-01 | 1 | INFRA-06 | structural | `grep -n "always @(\*)" rtl/prime_engine.v` | ❌ W0 | ⬜ pending |
| 1-01-03 | 01-01 | 1 | INFRA-03 | structural | `grep -n "_ff" rtl/prime_engine.v` | ❌ W0 | ⬜ pending |
| 1-02-01 | 01-02 | 2 | INFRA-08 | unit (iVerilog) | `iverilog -o sim/prime_engine_tb.vvp rtl/prime_engine.v tb/prime_engine_tb.v && vvp sim/prime_engine_tb.vvp` | ❌ W0 | ⬜ pending |
| 1-03-01 | 01-03 | 3 | INFRA-04 | structural | `grep -rn "begin" rtl/ \| grep -v "//"` (manual review) | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `rtl/` directory created for synthesis RTL files
- [ ] `tb/` directory created for testbench files
- [ ] `sim/` directory created for simulation outputs
- [ ] `iverilog` confirmed available at `/opt/homebrew/bin/iverilog`

*Wave 0 is trivial (directory creation only) — iVerilog already installed.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Vivado synthesis passes with no errors | INFRA-08 | Vivado not in PATH; must run via GUI | Open Vivado project, add rtl/prime_engine.v, run Synthesis; confirm no errors in tcl console |
| No `for` loops in synthesis file | INFRA-05 | Static code review | `grep -n "for\s*(" rtl/prime_engine.v` must return empty |
| `default:` in all case statements | INFRA-07 | Static code review | `grep -n "default:" rtl/prime_engine.v` must match number of `case` statements |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 5s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
