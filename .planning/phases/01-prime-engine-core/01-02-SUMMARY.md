---
phase: 01-prime-engine-core
plan: 02
subsystem: testing
tags: [verilog, testbench, simulation, iverilog, python, golden-list, prime-engine]

requires:
  - phase: 01-prime-engine-core/01-01
    provides: rtl/prime_engine.v, rtl/divider.v (DUT under test)
provides:
  - scripts/gen_golden_primes.py (Python golden list generator)
  - tb/golden_primes.mem (10008-line binary lookup, 1=prime 0=composite, indices 0..10007)
  - tb/prime_engine_tb.v (self-checking testbench, sweeps 2..10007)
affects: [02-ddr2-integration, any phase that re-tests prime_engine correctness]

tech-stack:
  added: [Python-3.14-6k-plus-minus-1-primality, iVerilog-g2001-simulation]
  patterns: [readmemb-golden-list-with-load-guard, while-loop-timeout-per-candidate, combinatorial-div_start-with-next_d]

key-files:
  created:
    - scripts/gen_golden_primes.py
    - tb/golden_primes.mem
    - tb/prime_engine_tb.v
  modified:
    - rtl/prime_engine.v

key-decisions:
  - "Use next_d (combinatorial) not d_ff (registered) as divider divisor: ensures correct divisor is latched on same cycle as div_start"
  - "prime count in 0..10007 is 1230 not 1229: 10007 is prime; plan had off-by-one in expected count"
  - "Golden list load guard mandatory: iVerilog silently zeroes unloaded $readmemb memory with no error"

patterns-established:
  - "combinatorial-div-input: when a combinatorial signal drives both next_X and div_start simultaneously, wire divider input to next_X not X_ff to avoid one-cycle stale data"
  - "readmemb-guard: always check a known-prime index (golden[2]===1) immediately after $readmemb to detect missing file before running any tests"

requirements-completed: [INFRA-08]

duration: 6min
completed: 2026-03-26
---

# Phase 1 Plan 2: Prime Engine Testbench Summary

**Python-generated 10008-entry golden list + self-checking iVerilog testbench sweeping 2..10007; caught and fixed a stale-d_ff divisor bug making prime_engine.v produce correct results for all 10006 candidates (PASS).**

## Performance

- **Duration:** 6 min
- **Started:** 2026-03-26T01:39:51Z
- **Completed:** 2026-03-26T01:45:43Z
- **Tasks:** 2
- **Files modified:** 4

## Accomplishments
- Python script generates tb/golden_primes.mem: 10008 lines (0..10007), 1-bit each (1=prime, 0=composite), 1230 primes marked
- Self-checking testbench sweeps all 10006 candidates (2..10007), per-candidate 200000-cycle timeout, golden list load guard fatally exits on missing .mem file
- Fixed RTL bug in prime_engine.v: divider was receiving stale d_ff (0 or prior d) instead of the new next_d value on the same cycle as div_start
- Full simulation completes in ~12 seconds: PASS all 10006 tests passed, zero failures

## Task Commits

1. **Task 1: Golden prime list generator and memory file** - `a85892d` (feat)
2. **Task 2: Self-checking testbench + RTL fix** - `8540da4` (feat/fix)

**Plan metadata:** (docs commit pending)

## Files Created/Modified
- `scripts/gen_golden_primes.py` - Python 6k+/-1 primality, generates tb/golden_primes.mem
- `tb/golden_primes.mem` - 10008-line binary lookup file for $readmemb, indices 0..10007
- `tb/prime_engine_tb.v` - Self-checking testbench: DUT sweep 2..10007, timeout detection, load guard, PASS/FAIL report
- `rtl/prime_engine.v` - Bug fix: divider `.divisor(next_d)` instead of `.divisor(d_ff)`

## Decisions Made
- **Wire `next_d` to divider divisor:** The combinatorial block sets `next_d=3` and `div_start=1` in the same cycle (in CHECK_2_3 state). If the divider is wired to the registered `d_ff`, it sees the OLD value of d (e.g., 0 from reset, or leftover from previous test). Using `next_d` ensures the divider latches the intended divisor value.
- **10007 is prime, count=1230:** The plan stated "1229 primes in range 2..10007" which is wrong. π(10000)=1229, but 10007 is prime, making the correct count 1230. The generator output is correct.
- **Golden list load guard essential:** iVerilog silently fills unloaded $readmemb memory with zeros. Without the guard (`if (golden[2] !== 1'b1)`), every candidate would appear non-prime, producing misleading results with no error message.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed stale divisor input to divider in prime_engine.v**
- **Found during:** Task 2 (running the testbench, simulation produced 1687 failures)
- **Issue:** In `prime_engine.v`, the divider instantiation used `.divisor(d_ff)`. When `div_start=1` is asserted combinatorially from CHECK_2_3 state, `d_ff` still holds the previous cycle's value (e.g., 0 at reset, or leftover from prior test). The `next_d = 3` (for the div-by-3 check) only takes effect at the NEXT posedge. So the divider was always dividing by the wrong number when first testing divisibility by 3. Cascading effect: candidate=5 was wrongly labelled composite (dbz fired), subsequent odd candidates had stale d from prior tests.
- **Fix:** Changed `.divisor(d_ff)` to `.divisor(next_d)`. Since `next_d` is a combinatorial reg driven in `always @(*)`, it reflects the intended divisor on the same clock cycle as `div_start=1`. The same fix also corrects the divisor for TEST_KM1 (which updates `next_d = d_ff + 2` and fires `div_start=1` in the same state).
- **Files modified:** rtl/prime_engine.v
- **Verification:** Debug testbench confirmed cand=5 (prime), cand=9 (composite), cand=25 (composite), cand=49 (composite) all pass. Full sweep: PASS all 10006 tests passed.
- **Committed in:** 8540da4

**2. [Rule 1 - Bug] Plan expected prime count 1229, actual correct value is 1230**
- **Found during:** Task 1 (verification)
- **Issue:** Plan said `grep -c "^1$" tb/golden_primes.mem` should return 1229. This is based on π(10000)=1229, but 10007 is prime so the range 2..10007 contains 1230 primes.
- **Fix:** Generator is correct; acceptance criteria note updated. No code change needed.
- **Committed in:** a85892d

---

**Total deviations:** 2 auto-fixed (2 bugs: 1 RTL divisor wiring, 1 plan spec error)
**Impact on plan:** RTL fix was essential for correctness — without it, 1687 of 10006 tests would fail. Prime count correction is documentation only.

## Issues Encountered
- Python not on PATH as `python3` or `python` (Windows alias issue). Used uv-managed Python at `/c/Users/Jackson/AppData/Roaming/uv/python/cpython-3.14.3-windows-x86_64-none/python.exe`. Script is correct and the .mem file is generated correctly.

## Known Stubs

None. All three output files are fully functional with real data.

## Next Phase Readiness
- prime_engine.v is verified correct for all integers 2..10007 via self-checking testbench
- Both rtl/divider.v and rtl/prime_engine.v are simulation-clean and synthesis-ready
- Ready for Phase 2: DDR2 integration or additional integration testing

---
*Phase: 01-prime-engine-core*
*Completed: 2026-03-26*
