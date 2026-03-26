# Requirements: PrimeFPGA

**Defined:** 2026-03-25
**Core Value:** Correct, fast prime computation with a smooth VGA display — the 6k±1 algorithm must produce verified results with no screen tearing.

## v1 Requirements

### Prime Engine

- [x] **PRIME-01**: 6k±1 trial division engine implemented as a synthesizable FSM (no for loops, no blocking/non-blocking mixing)
- [ ] **PRIME-02**: Mode 1 — find all primes ≤ N; N entered via joystick + 7SD (up to 8 decimal digits); store all found primes in DDR2
- [ ] **PRIME-03**: Mode 2 — find all primes within T seconds; T entered via joystick + 7SD (1-second granularity, max 3600); store all found primes in DDR2
- [ ] **PRIME-04**: Mode 3 — determine if entered number is prime; show elapsed time; freeze display on completion
- [x] **PRIME-05**: Running prime count and last 20 primes found updated live during Modes 1 and 2
- [x] **PRIME-06**: Elapsed time counter runs during active computation; freezes on mode completion

### Storage (DDR2 via MIG)

- [ ] **DDR-01**: MIG 7-series IP instantiated and configured for Nexys A7 DDR2; UI clock generated
- [ ] **DDR-02**: Two full 640×480×16-bit framebuffers allocated in DDR2 (~600 KB each, ~1.2 MB total)
- [ ] **DDR-03**: Prime number results written to DDR2 sequentially; readable for test mode comparison
- [ ] **DDR-04**: AXI4 read/write arbiter manages framebuffer writes and prime storage without conflict

### VGA Display

- [ ] **VGA-01**: 640×480 @ 60 Hz pixel clock generation (~25.175 MHz); sync signals within spec
- [ ] **VGA-02**: 12-bit RGB color output (4 bits per channel) on Nexys A7 VGA port; padded to 16 bits per pixel in DDR2
- [ ] **VGA-03**: Display controller reads front framebuffer from DDR2; no tearing (double-buffer swap on VBlank)
- [ ] **VGA-04**: UI layout: prime count panel, last-20-primes list, elapsed time, mode status, entered value
- [ ] **VGA-05**: Moving sprite displayed somewhere on screen (design TBD at UI phase)
- [ ] **VGA-06**: Color used meaningfully throughout UI (e.g., active/complete state colors)
- [ ] **VGA-07**: Mode-complete state: display freezes and mode-done indicator shown
- [ ] **VGA-08**: Test mode: "Passed" in green with prime count checked, or "Failed" in red with failing number and SD card comparison value

### SD Card (SPI)

- [ ] **SD-01**: SPI master controller for SD card (400 kHz init, up to 25 MHz transfer)
- [ ] **SD-02**: SD card initialization sequence (CMD0, CMD8, ACMD41, CMD58); handles SDHC/SDXC
- [ ] **SD-03**: Read test reference file — plain-text decimal primes, one per row
- [ ] **SD-04**: Test mode FSM: parse SD card file, compare each prime against DDR2-stored primes in order, report first mismatch or full pass

### Input

- [ ] **INPUT-01**: PMOD joystick driver: read X/Y axis and button states
- [ ] **INPUT-02**: Digit-navigation input FSM: joystick selects digit position on 7SD, up/down increments digit, button confirms entry
- [ ] **INPUT-03**: 7-segment display driver: show entered number during input; show debug values during testing
- [ ] **INPUT-04**: Mode selection: joystick or button navigates between Mode 1 / Mode 2 / Mode 3 / Mode 4 at top-level FSM

### Top-Level FSM & Infrastructure

- [ ] **INFRA-01**: Top-level module instantiates all submodules in ANSI format; no logic at top level
- [ ] **INFRA-02**: Top-level FSM states: IDLE, MODE_SELECT, NUMBER_ENTRY, TIME_ENTRY, PRIME_RUN, PRIME_DONE, ISPRIME_ENTRY, ISPRIME_RUN, ISPRIME_DONE, TEST_RUN, TEST_DONE
- [x] **INFRA-03**: All module flip-flops use `_ff` suffix; active-low signals use `_n` suffix
- [x] **INFRA-04**: Blocking (`=`) and non-blocking (`<=`) assignments in strictly separate `always` blocks
- [x] **INFRA-05**: No `for` loops in any synthesis file
- [x] **INFRA-06**: All combinational logic (including synchronous reset decode) in `always @(*)`; only `always @(posedge clk)` for flip-flops
- [x] **INFRA-07**: `default:` in all `case` statements; final `else` in all `if-else` chains
- [x] **INFRA-08**: Self-checking Vivado testbench for every module; iVerilog behavioral testbenches for rapid iteration

## v2 Requirements

### Enhancements

- **ENH-01**: Segmented Sieve or Wheel factorization for further speed improvement (post-v1 optimization)
- **ENH-02**: Export found primes from DDR2 to SD card (currently SD card is read-only in v1)
- **ENH-03**: Configurable VGA resolution (800×600 SVGA option)
- **ENH-04**: Parallel prime finders (multiple 6k±1 engines on different candidate ranges)

## Out of Scope

| Feature | Reason |
|---------|--------|
| Keypad input | Joystick + 7SD satisfies PMOD requirement with less wiring complexity |
| SDIO mode for SD card | SPI sufficient; SDIO adds complexity without meaningful benefit for read-only test file access |
| Sieve of Eratosthenes (v1) | Would require O(N) DDR2 writes up-front; at N=99,999,999 this is impractical with DDR2 latency; deferred to v2 |
| Ethernet / UART output | Not required by spec; display is primary output |
| Non-Verilog HDL | Class requirement mandates Verilog |
| Logic at top level | Class rule: no combinational logic at top level |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| PRIME-01 | Phase 1 | Complete |
| PRIME-02 | Phase 2 | Pending |
| PRIME-03 | Phase 2 | Pending |
| PRIME-04 | Phase 2 | Pending |
| PRIME-05 | Phase 2 | Complete |
| PRIME-06 | Phase 2 | Complete |
| DDR-01 | Phase 3 | Pending |
| DDR-02 | Phase 3 | Pending |
| DDR-03 | Phase 3 | Pending |
| DDR-04 | Phase 3 | Pending |
| VGA-01 | Phase 4 | Pending |
| VGA-02 | Phase 4 | Pending |
| VGA-03 | Phase 4 | Pending |
| VGA-04 | Phase 5 | Pending |
| VGA-05 | Phase 5 | Pending |
| VGA-06 | Phase 5 | Pending |
| VGA-07 | Phase 5 | Pending |
| VGA-08 | Phase 6 | Pending |
| SD-01 | Phase 6 | Pending |
| SD-02 | Phase 6 | Pending |
| SD-03 | Phase 6 | Pending |
| SD-04 | Phase 6 | Pending |
| INPUT-01 | Phase 4 | Pending |
| INPUT-02 | Phase 4 | Pending |
| INPUT-03 | Phase 4 | Pending |
| INPUT-04 | Phase 7 | Pending |
| INFRA-01 | Phase 7 | Pending |
| INFRA-02 | Phase 7 | Pending |
| INFRA-03 | Phase 1 | Complete |
| INFRA-04 | Phase 1 | Complete |
| INFRA-05 | Phase 1 | Complete |
| INFRA-06 | Phase 1 | Complete |
| INFRA-07 | Phase 1 | Complete |
| INFRA-08 | Phase 1 | Complete |

**Coverage:**
- v1 requirements: 34 total
- Mapped to phases: 34
- Unmapped: 0 ✓

---
*Requirements defined: 2026-03-25*
*Last updated: 2026-03-25 after initial definition*
