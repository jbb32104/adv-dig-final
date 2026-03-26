# Roadmap: PrimeFPGA

## Overview

Seven phases take the project from a verified prime-finding FSM through DDR2 integration, VGA rendering, SD card test mode, and finally full hardware bring-up on the Nexys A7. Each phase is simulation-verified before any hardware integration. The prime engine ships first; everything else is built around proven math.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [x] **Phase 1: Prime Engine Core** - 6k±1 FSM verified in simulation; coding standards established (completed 2026-03-26)
- [ ] **Phase 2: Prime Modes FSM** - Mode 1/2/3 logic, elapsed time counter, digit-entry state machines (sim only)
- [ ] **Phase 3: DDR2 Integration** - MIG IP instantiated, AXI4 arbiter, framebuffer + prime storage working
- [ ] **Phase 4: VGA + Input Drivers** - Pixel clock, sync, framebuffer display controller, joystick driver, 7SD driver
- [ ] **Phase 5: VGA UI** - UI panels, sprite, color states, double-buffer swap on VBlank
- [ ] **Phase 6: SD Card + Test Mode** - SPI master, SD init, file parser, Mode 4 FSM
- [ ] **Phase 7: Full Integration** - Top-level module, mode FSM wiring, end-to-end hardware validation

## Phase Details

### Phase 1: Prime Engine Core
**Goal**: The 6k±1 prime engine FSM is simulation-verified to produce correct results, and the project coding standard is enforced from the first line of RTL
**Depends on**: Nothing (first phase)
**Requirements**: PRIME-01, INFRA-03, INFRA-04, INFRA-05, INFRA-06, INFRA-07, INFRA-08
**Success Criteria** (what must be TRUE):
  1. Simulation confirms the engine correctly classifies known primes and composites up to at least 10,000
  2. The engine FSM reaches a DONE state and asserts a valid `is_prime` output for every tested candidate without hanging
  3. No `for` loops appear in any synthesis file; blocking and non-blocking assignments are in strictly separate `always` blocks
  4. Every flip-flop signal carries the `_ff` suffix; every active-low signal carries the `_n` suffix
  5. A self-checking testbench exists for `prime_engine.v` and passes with zero assertion failures in iVerilog and Vivado sim
**Plans**: 3 plans

Plans:
- [x] 01-01: prime_engine.v — 6k±1 FSM (IDLE, CHECK_2_3, INIT_K, TEST_KM1, TEST_KP1, DONE states); synthesizable, no for loops
- [x] 01-02: prime_engine_tb.v — self-checking testbench; sweeps 2–10007, cross-checks against golden list
- [x] 01-03: Coding-standard audit pass — verify _ff/_n naming, blocking/non-blocking split, default/else coverage across all Phase 1 files

### Phase 2: Prime Modes FSM
**Goal**: Modes 1, 2, and 3 are fully exercised in simulation — the mode FSM accepts a user-supplied N or T, runs the prime engine repeatedly, accumulates results, and terminates correctly
**Depends on**: Phase 1
**Requirements**: PRIME-02, PRIME-03, PRIME-04, PRIME-05, PRIME-06
**Success Criteria** (what must be TRUE):
  1. Mode 1 simulation finds all primes ≤ 100 (25 primes), stores each result in sequence, and asserts done
  2. Mode 2 simulation terminates after the configured cycle count and reports the correct count of primes found
  3. Mode 3 simulation accepts a single candidate, drives the prime engine, and returns is_prime + elapsed cycles; display freezes on completion
  4. Running prime count increments live on each prime found; last-20 ring buffer holds the correct 20 values at termination
  5. Elapsed-time counter increments by 1 every 100 MHz cycle and freezes exactly when the mode FSM asserts done
**Plans**: TBD

Plans:
- [ ] 02-01: mode_fsm.v — top-level mode dispatcher (IDLE, MODE_SELECT, NUMBER_ENTRY, TIME_ENTRY, PRIME_RUN, PRIME_DONE, ISPRIME_ENTRY, ISPRIME_RUN, ISPRIME_DONE)
- [ ] 02-02: elapsed_timer.v — 32-bit cycle counter with freeze; 1-second tick derived at 100 MHz
- [ ] 02-03: prime_accumulator.v — prime count register, last-20 ring buffer, sequential DDR2-write interface stub
- [ ] 02-04: mode_fsm_tb.v + accumulator_tb.v — self-checking sim for all three modes

### Phase 3: DDR2 Integration
**Goal**: The MIG IP is instantiated and the AXI4 arbiter correctly services both framebuffer writes and prime storage writes without conflict, verified first in simulation then on hardware
**Depends on**: Phase 2
**Requirements**: DDR-01, DDR-02, DDR-03, DDR-04
**Success Criteria** (what must be TRUE):
  1. MIG calibration completes (mmcm_locked + init_calib_complete asserted) on the Nexys A7 within 200 ms of reset release
  2. A single prime write and read-back via the AXI4 controller returns the correct value in simulation
  3. Two framebuffer address regions (front/back, ~600 KB each) are defined as constants and do not overlap with the prime storage region
  4. The AXI4 arbiter grants exactly one request at a time; simulation shows no simultaneous read/write conflicts
**Plans**: TBD

Plans:
- [ ] 03-01: MIG IP configuration for Nexys A7 DDR2; ui_clk, mmcm_locked, init_calib_complete wiring
- [ ] 03-02: axi4_arbiter.v — round-robin arbiter for framebuffer-write vs prime-write channels; address map constants
- [ ] 03-03: ddr2_ctrl_tb.v — behavioral DDR2 model sim; verify write-then-read round-trip for primes and framebuffer base addresses
- [ ] 03-04: Hardware smoke test — MIG calibration on board; LED confirms init_calib_complete

### Phase 4: VGA + Input Drivers
**Goal**: The board produces a stable 640x480 VGA signal and the joystick + 7-segment drivers are simulation-verified and physically tested
**Depends on**: Phase 3
**Requirements**: VGA-01, VGA-02, VGA-03, INPUT-01, INPUT-02, INPUT-03
**Success Criteria** (what must be TRUE):
  1. A monitor locks onto the VGA signal and displays a solid color or test pattern without sync errors
  2. The display controller reads from a fixed DDR2 address region and drives correct RGB values onto the VGA port
  3. Joystick X/Y axes and button state are debounced and readable in simulation and on hardware
  4. The digit-navigation FSM correctly increments/decrements the selected digit and advances position on joystick input
  5. The 7-segment driver shows the correct 8-digit decimal value matching the internal register state
**Plans**: TBD

Plans:
- [ ] 04-01: vga_sync.v — 25.175 MHz pixel clock (MMCM), hsync/vsync timing, active-region blanking
- [ ] 04-02: vga_display_ctrl.v — DDR2 read sequencer for front framebuffer; burst-read to pixel pipeline
- [ ] 04-03: joystick_driver.v + digit_nav_fsm.v — SPI/parallel PMOD read, debounce, digit-position FSM
- [ ] 04-04: seg7_driver.v — 8-digit multiplexed 7-segment controller with BCD decode
- [ ] 04-05: Hardware integration test — test pattern on monitor, joystick echo on 7SD
**UI hint**: yes

### Phase 5: VGA UI
**Goal**: The VGA output renders all required UI panels with correct data, a moving sprite, meaningful color states, and tear-free double-buffer swaps synchronized to VBlank
**Depends on**: Phase 4
**Requirements**: VGA-04, VGA-05, VGA-06, VGA-07
**Success Criteria** (what must be TRUE):
  1. Prime count panel, last-20 list, elapsed time, mode status, and entered value are all visible and update during a Mode 1 run
  2. A sprite moves continuously and does not corrupt surrounding UI regions
  3. Active computation uses one color scheme; mode-complete freezes the display and changes the status color to indicate done
  4. No tearing is visible during a buffer swap — swap occurs only when the display controller is in the VBlank interval
  5. All panel pixel writes target the back buffer; the front/back pointer flips atomically at VBlank
**Plans**: TBD

Plans:
- [ ] 05-01: ui_renderer.v — tile-based renderer writes prime count, last-20 list, elapsed time, mode status to back buffer via AXI4
- [ ] 05-02: sprite_engine.v — position register, per-frame move step, bounding-box clip, pixel blit to back buffer
- [ ] 05-03: double_buffer_ctrl.v — VBlank detection, front/back pointer swap, render-complete handshake
- [ ] 05-04: color_theme.v — color constants for active/complete/error states; integrated into ui_renderer
- [ ] 05-05: End-to-end UI sim + hardware visual verification with Mode 1 run
**UI hint**: yes

### Phase 6: SD Card + Test Mode
**Goal**: The SD card can be initialized and read over SPI, a plain-text prime file is parsed into integers, and Mode 4 compares SD-sourced primes against DDR2-stored primes reporting pass or fail
**Depends on**: Phase 5
**Requirements**: SD-01, SD-02, SD-03, SD-04, VGA-08
**Success Criteria** (what must be TRUE):
  1. SPI master clocks at ~400 kHz during init; CMD0/CMD8/ACMD41/CMD58 sequence completes and card enters transfer state
  2. A known test file (decimal primes, one per line) is read from the SD card and parsed into a sequence of integers in simulation
  3. Mode 4 FSM compares the first N primes from DDR2 against the SD card file and asserts pass when they match
  4. On mismatch, the VGA display shows "Failed" in red with the failing DDR2 value and SD card value both visible
  5. On full pass, the VGA display shows "Passed" in green with the total prime count checked
**Plans**: TBD

Plans:
- [ ] 06-01: spi_master.v — configurable clock divider (400 kHz / 25 MHz), CPOL=0 CPHA=0, byte-at-a-time interface
- [ ] 06-02: sd_init_fsm.v — CMD0, CMD8, ACMD41, CMD58 sequence; SDHC/SDXC flag; ready signal out
- [ ] 06-03: sd_file_reader.v — block-read state machine; ASCII decimal parser (one prime per line, LF/CRLF)
- [ ] 06-04: test_mode_fsm.v — reads DDR2 prime list, reads SD prime list, compares in order, drives pass/fail output + VGA overlay
- [ ] 06-05: sd_tb.v + test_mode_tb.v — behavioral SD model sim; inject known-good and known-bad reference files

### Phase 7: Full Integration
**Goal**: A single top-level module wires all subsystems together with no logic at the top level; the board runs all four modes end-to-end with correct behavior on real hardware
**Depends on**: Phase 6
**Requirements**: INFRA-01, INFRA-02, INPUT-04
**Success Criteria** (what must be TRUE):
  1. Vivado implementation completes with no critical warnings; timing closure at 100 MHz system clock
  2. Mode selection via joystick navigates between all four modes and the 7SD reflects the current mode
  3. Mode 1 finds all primes ≤ 1000 (168 primes) and displays the correct count on VGA
  4. Mode 2 runs for a user-entered time, stops, and freezes the display with correct elapsed time shown
  5. Mode 3 correctly identifies a known prime and a known composite, showing elapsed time on VGA
  6. Mode 4 passes against a correct SD card reference file and fails (with correct failing value) against a seeded bad file
**Plans**: TBD

Plans:
- [ ] 07-01: top.v — ANSI instantiation of all submodules; constraint file (XDC) with all pin assignments
- [ ] 07-02: top_fsm.v — IDLE, MODE_SELECT, NUMBER_ENTRY, TIME_ENTRY, PRIME_RUN, PRIME_DONE, ISPRIME_ENTRY, ISPRIME_RUN, ISPRIME_DONE, TEST_RUN, TEST_DONE states
- [ ] 07-03: System-level sim — drive all four mode sequences through top-level testbench; verify outputs
- [ ] 07-04: Hardware bring-up — flash bitstream; walk through all four modes; document results

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3 → 4 → 5 → 6 → 7

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Prime Engine Core | 3/3 | Complete   | 2026-03-26 |
| 2. Prime Modes FSM | 0/4 | Not started | - |
| 3. DDR2 Integration | 0/4 | Not started | - |
| 4. VGA + Input Drivers | 0/5 | Not started | - |
| 5. VGA UI | 0/5 | Not started | - |
| 6. SD Card + Test Mode | 0/5 | Not started | - |
| 7. Full Integration | 0/4 | Not started | - |

## Traceability

| Requirement | Description | Phase |
|-------------|-------------|-------|
| PRIME-01 | 6k±1 trial division engine as synthesizable FSM | Phase 1 |
| PRIME-02 | Mode 1 — find all primes ≤ N, store in DDR2 | Phase 2 |
| PRIME-03 | Mode 2 — find all primes within T seconds, store in DDR2 | Phase 2 |
| PRIME-04 | Mode 3 — is-it-prime check with elapsed time | Phase 2 |
| PRIME-05 | Running prime count + last-20 primes updated live | Phase 2 |
| PRIME-06 | Elapsed time counter; freezes on mode completion | Phase 2 |
| DDR-01 | MIG 7-series IP instantiated; UI clock generated | Phase 3 |
| DDR-02 | Two 640x480x16-bit framebuffers in DDR2 | Phase 3 |
| DDR-03 | Prime results written to DDR2 sequentially; readable | Phase 3 |
| DDR-04 | AXI4 arbiter for framebuffer writes + prime storage | Phase 3 |
| VGA-01 | 640x480 @ 60 Hz pixel clock; sync signals in spec | Phase 4 |
| VGA-02 | 12-bit RGB output; 16 bits per pixel in DDR2 | Phase 4 |
| VGA-03 | Display controller reads front framebuffer; no tearing | Phase 4 |
| VGA-04 | UI layout: prime count, last-20, elapsed time, mode status | Phase 5 |
| VGA-05 | Moving sprite on screen | Phase 5 |
| VGA-06 | Color used meaningfully throughout UI | Phase 5 |
| VGA-07 | Mode-complete: display freezes + done indicator | Phase 5 |
| VGA-08 | Test mode: "Passed" green / "Failed" red with details | Phase 6 |
| SD-01 | SPI master controller (400 kHz init, 25 MHz transfer) | Phase 6 |
| SD-02 | SD initialization sequence (CMD0, CMD8, ACMD41, CMD58) | Phase 6 |
| SD-03 | Read test reference file (decimal primes, one per line) | Phase 6 |
| SD-04 | Test mode FSM: parse + compare + report pass/fail | Phase 6 |
| INPUT-01 | PMOD joystick driver: X/Y axis + button states | Phase 4 |
| INPUT-02 | Digit-navigation FSM: select position, increment, confirm | Phase 4 |
| INPUT-03 | 7-segment driver: entered number + debug values | Phase 4 |
| INPUT-04 | Mode selection via joystick at top-level FSM | Phase 7 |
| INFRA-01 | Top-level instantiates all submodules; no logic at top | Phase 7 |
| INFRA-02 | Top-level FSM with all required states | Phase 7 |
| INFRA-03 | _ff suffix for FFs; _n suffix for active-low signals | Phase 1 |
| INFRA-04 | Blocking/non-blocking in strictly separate always blocks | Phase 1 |
| INFRA-05 | No for loops in any synthesis file | Phase 1 |
| INFRA-06 | Combinational logic in always @(*); FFs in always @(posedge clk) | Phase 1 |
| INFRA-07 | default: in all case statements; final else in all if-else chains | Phase 1 |
| INFRA-08 | Self-checking Vivado testbench for every module | Phase 1 |

**Coverage:** 34/34 v1 requirements mapped — 0 orphans

---
*Roadmap created: 2026-03-25*
*Last updated: 2026-03-25 after initial creation*
