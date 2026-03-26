---
phase: 01-prime-engine-core
verified: 2026-03-25T18:30:00Z
status: passed
score: 5/5 must-haves verified
re_verification: false
---

# Phase 1: Prime Engine Core — Verification Report

**Phase Goal:** Deliver a synthesizable, CSEE 4280-compliant prime engine (6k±1 algorithm) with a self-checking testbench that sweeps 2–10007 and reports PASS.
**Verified:** 2026-03-25
**Status:** PASSED
**Re-verification:** No — initial verification

---

## Goal Achievement

### Observable Truths (from ROADMAP.md Success Criteria)

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | Simulation confirms engine correctly classifies known primes and composites up to at least 10,000 | VERIFIED | `vvp sim/prime_engine_tb.vvp` output: "PASS: all 10006 tests passed" — 10006 candidates swept (2..10007), zero errors |
| 2 | Engine FSM reaches DONE state and asserts valid `is_prime` output for every tested candidate without hanging | VERIFIED | No TIMEOUT or FAIL lines in simulation output; 200000-cycle timeout guard was never tripped across any of the 10006 candidates |
| 3 | No `for` loops in any synthesis file; blocking and non-blocking assignments in strictly separate `always` blocks | VERIFIED | `grep "for\s*(" rtl/divider.v rtl/prime_engine.v` returns empty; divider.v has 1 posedge block (all `<=`), 0 `@(*)` blocks; prime_engine.v has 1 posedge block (all `<=`), 1 `@(*)` block (all `=`) |
| 4 | Every flip-flop signal carries the `_ff` suffix; every active-low signal carries the `_n` suffix | VERIFIED | 53 `_ff` hits in divider.v, 52 in prime_engine.v; no active-low signals exist in either file; all `reg` driven by `<=` in posedge block confirmed to carry `_ff` suffix |
| 5 | A self-checking testbench exists for `prime_engine.v` and passes with zero assertion failures in iVerilog | VERIFIED | `tb/prime_engine_tb.v` exists, compiles clean, simulation output ends with "PASS: all 10006 tests passed" |

**Score:** 5/5 truths verified

---

## Required Artifacts

### Plan 01-01 Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `rtl/divider.v` | Restoring binary division sub-module (WIDTH=27 cycles per call) | VERIFIED | 107 lines; `module divider` present; `parameter WIDTH = 27`; 1 `always @(posedge clk)` block; `done_ff`, `remainder_ff`, `busy_ff` outputs all present; no for loops |
| `rtl/prime_engine.v` | 6k+/-1 trial division FSM with 7 states | VERIFIED | 239 lines; `module prime_engine` present; all 7 states present (IDLE, CHECK_2_3, WAIT_DIV3, INIT_K, TEST_KM1, TEST_KP1, DONE); 1 posedge block, 1 `@(*)` block; `d_squared` bound check present; divider instantiated as `u_div` |

### Plan 01-02 Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `scripts/gen_golden_primes.py` | Python script generating golden_primes.mem | VERIFIED | 63 lines; `def is_prime` present; writes one line per index 0..10007; uses 6k±1 algorithm for generation |
| `tb/golden_primes.mem` | Binary memory file: 1=prime, 0=composite for indices 0..10007 | VERIFIED | 10008 lines confirmed (`wc -l`); index 2 = `1` (prime), index 3 = `1` (prime), index 4 = `0` (composite), index 25 = `0` (25=5×5 composite); 1230 primes marked (10007 is prime; plan doc stated 1229 which is off-by-one — the script and .mem file are correct) |
| `tb/prime_engine_tb.v` | Self-checking testbench sweeping 2..10007 | VERIFIED | 154 lines; `module prime_engine_tb`; `$readmemb` present; golden[2] load guard present with FATAL message; `prime_engine.*dut` instantiation present; PASS/FAIL/TIMEOUT reporting all present |

### Plan 01-03 Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `rtl/divider.v` (audit-clean) | Zero INFRA violations | VERIFIED | No changes needed; already compliant from Plan 01-01 |
| `rtl/prime_engine.v` (audit-clean) | Zero INFRA violations | VERIFIED | No changes needed; already compliant from Plans 01-01 and 01-02 |

---

## Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `rtl/prime_engine.v` | `rtl/divider.v` | Module instantiation `u_div` | VERIFIED | Line 68: `divider #(.WIDTH(WIDTH)) u_div (...)` — divider wired with `.start(div_start)`, `.divisor(next_d)`, `.remainder_ff(div_remainder)`; `div_done` and `div_remainder` used in FSM state logic |
| `tb/prime_engine_tb.v` | `rtl/prime_engine.v` | DUT instantiation | VERIFIED | Line 62: `prime_engine #(.WIDTH(WIDTH)) dut (...)` — all ports connected by name; matches exact port interface |
| `tb/prime_engine_tb.v` | `tb/golden_primes.mem` | `$readmemb` with load guard | VERIFIED | Line 40: `$readmemb("tb/golden_primes.mem", golden)`; lines 45–48: guard checks `golden[2] !== 1'b1` and calls `$finish` with FATAL message |

---

## Data-Flow Trace (Level 4)

Level 4 data-flow trace is not applicable to this phase. All artifacts are synthesizable RTL modules and testbench infrastructure — there are no dynamic data rendering components. The "data flow" is the physical simulation execution path, which was verified directly by running the testbench to completion.

---

## Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| Testbench sweeps 2..10007 and reports PASS | `vvp sim/prime_engine_tb.vvp` | "PASS: all 10006 tests passed" — output includes 10 INFO progress lines, no FAIL or TIMEOUT lines | PASS |
| Testbench compiles with zero errors | `iverilog -g2001 -o sim/prime_engine_tb.vvp rtl/divider.v rtl/prime_engine.v tb/prime_engine_tb.v` | No output (zero errors, zero warnings) | PASS |
| divider.v compiles standalone | `iverilog -g2001 rtl/divider.v` | Zero errors | PASS |

---

## Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|-------------|-------------|--------|---------|
| PRIME-01 | 01-01 | 6k±1 trial division engine as synthesizable FSM | SATISFIED | `rtl/prime_engine.v` implements 7-state 6k±1 FSM; no for loops; blocking/non-blocking separated; testbench passes across 2..10007 |
| INFRA-03 | 01-01, 01-03 | All module flip-flops use `_ff` suffix; active-low signals use `_n` suffix | SATISFIED | 53 `_ff` references in divider.v, 52 in prime_engine.v; no active-low signals present; every `reg` driven by `<=` in posedge block carries `_ff` suffix |
| INFRA-04 | 01-01, 01-03 | Blocking and non-blocking in strictly separate `always` blocks | SATISFIED | divider.v: 1 posedge block (`<=` only); prime_engine.v: 1 posedge block (`<=` only) + 1 `@(*)` block (`=` only); no mixed blocks |
| INFRA-05 | 01-01, 01-03 | No `for` loops in any synthesis file | SATISFIED | `grep "for\s*(" rtl/divider.v rtl/prime_engine.v` returns empty; for loops exist only in `tb/prime_engine_tb.v` (permitted per rule) |
| INFRA-06 | 01-01, 01-03 | All combinational logic in `always @(*)`; only `always @(posedge clk)` for flip-flops | SATISFIED | prime_engine.v: combinational block (`always @(*)`) drives all `next_*` signals; posedge block registers all `_ff` outputs; divider.v: all sequential, `acc_next` is a plain `assign` wire (not an always block), which is compliant |
| INFRA-07 | 01-01, 01-03 | `default:` in all `case` statements; final `else` in all `if-else` chains | SATISFIED | prime_engine.v: 1 `case` statement, 1 `default:` branch; divider.v: 0 case statements (if-else only); all else-if chains verified to have trailing `else`: divider.v line 84 chain closes at line 99, prime_engine.v CHECK_2_3 chain closes at line 147 |
| INFRA-08 | 01-02 | Self-checking Vivado testbench for every module | SATISFIED | `tb/prime_engine_tb.v` sweeps 2..10007 against Python-generated golden list; per-candidate timeout; load guard; PASS/FAIL reporting; simulation passes in iVerilog |

**Orphaned requirements check:** All 7 requirements assigned to Phase 1 in REQUIREMENTS.md (PRIME-01, INFRA-03 through INFRA-08) are claimed by plans 01-01, 01-02, 01-03. No orphans found.

---

## Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| `rtl/prime_engine.v` | 40, 93, 101 | `div_start_ff` is declared, driven in posedge block (non-blocking), but never used as input or output anywhere else in the file | Info | Dead register; synthesis will optimize away; not a violation (has correct `_ff` suffix, non-blocking assignment, synchronous reset); correct `div_start` (combinational) is properly wired to divider |

No blockers. No warnings. One informational note only.

**Stub scan result:** No return-null, return-empty, hardcoded placeholder, or TODO/FIXME patterns found in any synthesis file. All state machine transitions are implemented and functional (verified by simulation).

---

## Human Verification Required

None. All success criteria were verifiable programmatically:

- Functional correctness: confirmed by running the testbench to completion
- Coding standard compliance: confirmed by grep-based structural checks
- Wiring: confirmed by reading actual port connections in source files
- Commits: all 6 claimed commits confirmed in git log

---

## Gaps Summary

No gaps. All 5 observable truths verified, all 7 artifacts substantive and wired, all 7 requirements satisfied, simulation passes with zero failures.

One documentation discrepancy was found and is self-documented: the plan stated "1229 primes in range 2..10007" but the correct count is 1230 (10007 is prime). The Python script and `.mem` file are correct; the plan spec had the off-by-one error. This was caught and documented by the implementation agent in the 01-02 SUMMARY.

---

## Notes on Divider Architecture

The divider.v module uses an if-else structure (no case statement) in its single `always @(posedge clk)` block. This is fully INFRA-06 and INFRA-07 compliant: every `if` with an `else if` has a closing `else`. The absence of `always @(*)` in divider.v is intentional — the module is purely sequential with one combinational `assign` wire (`acc_next`), which is the correct pattern when there is no next-state combinational logic to separate.

---

_Verified: 2026-03-25_
_Verifier: Claude (gsd-verifier)_
