# Testbench Run Commands

All commands assume you are at the **project root** (`adv-dig-final\`).
Create the `sim\` output directory once before compiling:

**cmd**
```cmd
if not exist sim mkdir sim
```
**PowerShell**
```powershell
New-Item -ItemType Directory -Force -Path sim | Out-Null
```

---

## prime\_engine\_tb

Self-checking sweep of candidates 2–10007 against a golden reference.
`tb\golden_primes.mem` must exist first — generate it with the script below if missing.

**Generate golden reference (requires Python 3)**
```cmd
python scripts\gen_golden_primes.py
```

**Compile**
```cmd
iverilog -g2001 -o sim\prime_engine_tb.vvp rtl\divider.v rtl\prime_engine.v tb\prime_engine_tb.v
```

**Run**
```cmd
vvp sim\prime_engine_tb.vvp
```

---

## accumulator\_tb

Self-checking unit test for `prime_accumulator.v` and `elapsed_timer.v`.

**Compile**
```cmd
iverilog -g2001 -o sim\accumulator_tb.vvp rtl\prime_accumulator.v tb\accumulator_tb.v
```

**Run**
```cmd
vvp sim\accumulator_tb.vvp
```

---

## mode\_fsm\_tb

Integration test for the full datapath: `mode_fsm` + `prime_engine` + `elapsed_timer` + `prime_accumulator`.

**Compile**
```cmd
iverilog -g2001 -o sim\mode_fsm_tb.vvp rtl\divider.v rtl\prime_engine.v rtl\elapsed_timer.v rtl\prime_accumulator.v tb\prime_fifo_ip.v rtl\mode_fsm.v tb\mode_fsm_tb.v
```

**Run**
```cmd
vvp sim\mode_fsm_tb.vvp
```

---

## ssd\_tb

Self-checking unit test for `ssd.v`.
Tests: reset state, all 16 hex digit decodings, 8-digit anode scan order, digit ordering (MSB/LSB), decimal point per-digit control.

**Compile**
```cmd
iverilog -g2001 -o sim\ssd_tb.vvp rtl\ssd.v tb\ssd_tb.v
```

**Run**
```cmd
vvp sim\ssd_tb.vvp
```

---

## debounce\_tb

Self-checking unit test for `debounce.v`.
Tests clean press/release, glitch rejection, glitch-then-valid-press, burst glitch, reset mid-press, and pulse width verification.

**Compile**
```cmd
iverilog -g2001 -o sim\debounce_tb.vvp rtl\debounce.v tb\debounce_tb.v
```

**Run**
```cmd
vvp sim\debounce_tb.vvp
```

---

## test\_top\_with\_ssd\_tb

Full integration test for `test_top_with_ssd.v`. Exercises debounce → mode\_fsm → 2x prime\_engine → 2x prime\_accumulator → pop FSM → ssd.

**Compile**
```cmd
iverilog -g2001 -o sim\test_top_with_ssd_tb.vvp rtl\divider.v rtl\prime_engine.v rtl\elapsed_timer.v rtl\prime_accumulator.v tb\prime_fifo_ip.v rtl\mode_fsm.v rtl\debounce.v rtl\ssd.v rtl\test_top_with_ssd.v tb\test_top_with_ssd_tb.v
```

**Run**
```cmd
vvp sim\test_top_with_ssd_tb.vvp
```

---

## Run all testbenches in sequence

```cmd
if not exist sim mkdir sim
python scripts\gen_golden_primes.py
iverilog -g2001 -o sim\prime_engine_tb.vvp rtl\divider.v rtl\prime_engine.v tb\prime_engine_tb.v
vvp sim\prime_engine_tb.vvp
iverilog -g2001 -o sim\accumulator_tb.vvp rtl\prime_accumulator.v tb\accumulator_tb.v
vvp sim\accumulator_tb.vvp
iverilog -g2001 -o sim\mode_fsm_tb.vvp rtl\divider.v rtl\prime_engine.v rtl\elapsed_timer.v rtl\prime_accumulator.v tb\prime_fifo_ip.v rtl\mode_fsm.v tb\mode_fsm_tb.v
vvp sim\mode_fsm_tb.vvp
iverilog -g2001 -o sim\debounce_tb.vvp rtl\debounce.v tb\debounce_tb.v
vvp sim\debounce_tb.vvp
iverilog -g2001 -o sim\test_top_with_ssd_tb.vvp rtl\divider.v rtl\prime_engine.v rtl\elapsed_timer.v rtl\prime_accumulator.v tb\prime_fifo_ip.v rtl\mode_fsm.v rtl\debounce.v rtl\ssd.v rtl\test_top_with_ssd.v tb\test_top_with_ssd_tb.v
vvp sim\test_top_with_ssd_tb.vvp
```
