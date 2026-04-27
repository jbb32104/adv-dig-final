# Prime Finder — Nexys A7 FPGA

Hardware prime number finder targeting the Digilent Nexys A7 (Artix-7) with VGA display, DDR2 frame buffer, keypad input, SD card verification, and seven-segment display.

## Modes

| Mode | Description |
|------|-------------|
| 1 — Count | Find all primes up to N using dual 6k+/-1 engines |
| 2 — Timed | Find primes for T seconds, then stop |
| 3 — Single | Test whether a single number is prime |
| D — SD Test | Verify engine results against a golden prime list read from SD card |

## Architecture

The design is purely structural at the top level (`top.v`) — all logic lives in sub-modules with no `always` blocks or logical assigns in the top.

### Clock Domains

| Clock | Frequency | Domain |
|-------|-----------|--------|
| `clk` | 100 MHz | Engines, accumulators (write), mode FSM, SSD, keypad |
| `clk_vga` | 25 MHz | VGA controller, VGA driver, pixel FIFO read |
| `clk_mem` | 200 MHz | MIG reference clock |
| `ui_clk` | ~75 MHz | DDR2 arbiter, accumulators (read), VGA reader, frame renderer |
| `clk_sd` | 50 MHz | SD card file reader, line parser |

### DDR2 Arbiter Ports

| Port | Function |
|------|----------|
| 0 | VGA reader — DDR2 reads into pixel FIFO (highest priority) |
| 1 | Frame renderer — text-to-pixel rendering into DDR2 frame buffer |
| 2 | Prime plus — 6k+1 bitmap writes from accumulator FIFO |
| 3 | Prime minus — 6k-1 bitmap writes from accumulator FIFO |

### Key Sub-modules

- **`prime_engine`** — trial-division primality tester with FIFO-full stall
- **`prime_accumulator`** — async FIFO bridging engine results (clk) to DDR2 writes (ui_clk)
- **`mode_fsm`** — 10-state dispatcher controlling engine start/stop/flush
- **`frame_renderer`** — renders text screens to DDR2 frame buffer via font ROM
- **`vga_reader`** / **`vga_controller`** / **`vga_driver`** — double-buffered VGA output pipeline
- **`sd_subsystem`** — SD file reader + line parser + clock-domain bridge
- **`test_prime_checker`** — compares SD golden primes against DDR2 bitmap
- **`mem_arbiter`** — 4-port DDR2 read/write arbiter
- **`keypad_nav`** / **`digit_entry`** — 4x4 matrix keypad scanning and number entry

## Directory Structure

```
rtl/           Synthesizable Verilog modules
tb/            Simulation testbenches
scripts/       Python utilities (golden prime generation, bitmap tools)
Final_Proj/    Vivado project
```

## Board I/O

- **VGA** — 640x480 @ 60 Hz, 12-bit color
- **DDR2** — 128 MB frame buffer and prime bitmap storage
- **Keypad** — 4x4 matrix on PMOD JA (mode select, number entry, navigation)
- **SD Card** — reads `CSEE4280Primes.txt` for verification mode
- **Seven-Segment** — 8-digit display showing BCD results
- **LEDs** — 16 debug status signals
- **Buttons** — BTNC (center), BTNR/BTNL (right/left), BTND (test start), CPU_RESETN
