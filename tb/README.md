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
iverilog -g2001 -o sim\accumulator_tb.vvp rtl\elapsed_timer.v rtl\prime_accumulator.v tb\accumulator_tb.v
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
iverilog -g2001 -o sim\mode_fsm_tb.vvp rtl\divider.v rtl\prime_engine.v rtl\elapsed_timer.v rtl\prime_accumulator.v rtl\mode_fsm.v tb\mode_fsm_tb.v
```

**Run**
```cmd
vvp sim\mode_fsm_tb.vvp
```

---

## Run all testbenches in sequence

```cmd
if not exist sim mkdir sim
python scripts\gen_golden_primes.py
iverilog -g2001 -o sim\prime_engine_tb.vvp rtl\divider.v rtl\prime_engine.v tb\prime_engine_tb.v
vvp sim\prime_engine_tb.vvp
iverilog -g2001 -o sim\accumulator_tb.vvp rtl\elapsed_timer.v rtl\prime_accumulator.v tb\accumulator_tb.v
vvp sim\accumulator_tb.vvp
iverilog -g2001 -o sim\mode_fsm_tb.vvp rtl\divider.v rtl\prime_engine.v rtl\elapsed_timer.v rtl\prime_accumulator.v rtl\mode_fsm.v tb\mode_fsm_tb.v
vvp sim\mode_fsm_tb.vvp
```
