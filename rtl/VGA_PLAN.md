# VGA + DDR2 Frame Buffer Integration Plan

## Overview

Add VGA text display to the existing prime engine project on Nexys A7. The VGA output shows one of 7 screens, each with up to 3 lines of centered uppercase text. Frame buffers are stored in DDR2 (double-buffered). Only the text line regions are read/written — not the full 640x480 frame.

---

## Progress Summary

### Completed (verified on hardware)

| Module | File | Status |
|--------|------|--------|
| `vga_controller.v` | Pre-existing | Working — 640x480 VGA timing generator |
| `font_rom.v` | `rtl/font_rom.v` | Created — 8x16 monochrome glyphs in BRAM, no for loops |
| `screen_text_rom.v` | `rtl/screen_text_rom.v` | Created — 7 screens × 3 lines × 20 chars, centered text, BRAM |
| `pixel_fifo` | Vivado IP | Created — async 128→16 bit, FWFT, no pipeline registers |
| `vga_driver.v` | `rtl/vga_driver.v` | Created — 16-bit FIFO unpacking, 8→12 bit RGB expansion |
| `test_vga_top.v` | `rtl/test_vga_top.v` | Created — standalone VGA test with PLL + feeder + LEDs |
| XDC VGA pins | `rtl/master.xdc` | Uncommented — VGA_R/G/B/HS/VS pin constraints active |

**Hardware test result**: Three solid white horizontal bars displayed at correct y-positions on black background. PLL locked, no FIFO underruns, 25 MHz heartbeat confirmed.

### Remaining (to be implemented)

| # | Module | Dependencies | Description |
|---|--------|-------------|-------------|
| 1 | `vga_reader.v` | pixel_fifo, arbiter | Prefetch text line pixels from DDR2 into pixel_fifo |
| 2 | `frame_renderer.v` | font_rom, screen_text_rom, arbiter | Render text→pixels, write to DDR2 |
| 3 | Integration | All above | Wire into `test_top_logic.v` and `test_top_with_ssd.v` |

### Recently Completed

| Module | Status |
|--------|--------|
| `mem_arbiter.v` expansion | Done — 4-port priority arbiter with read support, VGA/renderer ports stubbed in test_top_logic.v |
| Prime address regions | Enlarged to 2.5 MB each (20M+ bits) for 100M candidate range |
| `app_rd_data` wiring | Connected from ddr2_wrapper through arbiter |

---

## Existing System (Already Working)

- **Prime engines**: Two independent engines (6k+1, 6k-1) generate prime bitmaps
- **Prime accumulators**: Bit-pack results into 32-bit words, write to asymmetric FIFOs (32-bit write / 128-bit read), flush with mod-4 zero-padding
- **mem_arbiter**: 4-port priority arbiter (VGA read > renderer write > prime round-robin), supports both CMD_READ and CMD_WRITE, 3-state FSM: IDLE → ISSUE → COOLDOWN
- **DDR2 via MIG**: 128-bit native interface, ~75 MHz ui_clk, calibration handshake
- **PLL**: 100 MHz board clock → 200 MHz (MIG sys_clk), 25 MHz (clk_vga), 50 MHz (SD clock)
- **Clock domains**: clk (100 MHz), ui_clk (~75 MHz), sys_clk_200 (200 MHz), clk_vga (25 MHz)
- **Reset**: 2-FF synchronizer on cpu_rst_n in clk domain; arb_rst_n = ~ui_clk_sync_rst for ui_clk domain
- **Coding style**: Two-block FSM (combinational always @(*) with next_* signals, sequential always @(posedge clk) for flops only). All registered outputs use _ff suffix.

### Key Files

| File | Purpose |
|------|---------|
| `test_top_logic.v` | Main integration module, all instantiations and wiring |
| `test_top_with_ssd.v` | Pin wrapper (no logic, just port pass-through) |
| `mem_arbiter.v` | DDR2 write arbiter for prime FIFOs (to be expanded) |
| `prime_accumulator.v` | Bit-packing + FIFO with flush/padding |
| `mode_fsm.v` | State machine for prime modes (IDLE, PRIME_RUN, PRIME_FLUSH, etc.) |
| `vga_controller.v` | VGA timing generator (hsync, vsync, video_on, x, y) — outputs registered |
| `font_rom.v` | 8x16 monochrome font ROM in BRAM (synchronous, 1-cycle read latency) |
| `screen_text_rom.v` | Static BRAM with character codes for all 7 screens (1-cycle read latency) |
| `vga_driver.v` | VGA pixel output — reads pixel_fifo, expands 8-bit RGB332 to 12-bit RGB444 |
| `test_vga_top.v` | Standalone VGA test top (PLL + controller + driver + FIFO + white feeder) |
| `ddr2_wrapper.v` | MIG pass-through wrapper |
| `pll` | Clocking wizard IP (100→200, 25, 50 MHz). Ports: clk_in, resetn, clk_mem, clk_sd, clk_vga, locked |
| `prime_fifo_ip` | Vivado FIFO IP (async, 32-bit write / 128-bit read, FWFT) |
| `pixel_fifo` | Vivado FIFO IP (async, 128-bit write / 16-bit read, FWFT, no pipeline regs) |

---

## VGA Display Spec

- **Resolution**: 640x480 @ 60 Hz, 25 MHz pixel clock (PLL clk_vga output)
- **Content**: 7 screens, each with up to 3 lines of uppercase text
- **Characters**: Lines 1–2: 8 px wide × 16 px tall. Line 0: 16 px wide × 32 px tall (2x scale).
- **Max string length**: 20 characters (including spaces)
- **Text centering**:
  - Lines 1–2: x_start = 240 (horizontally centered 160 px block within 640)
  - Line 0: x_start = 160 (horizontally centered 320 px block within 640, 2x width)
- **Text line y-positions** (fixed for now, will become moveable later):
  - Line 0: y = 64..95   (4 char heights from top, 32 px tall — 2x height)
  - Line 1: y = 288..303  (3 char heights above line 2)
  - Line 2: y = 352..367  (22 char heights from top)
- **Pixel format**: 8-bit RGB (3:3:2) stored in DDR2, expanded to 12-bit (4:4:4) at VGA output
  - R[3:0] = {pixel[7:5], pixel[7]}
  - G[3:0] = {pixel[4:2], pixel[4]}
  - B[3:0] = {pixel[1:0], pixel[1:0]}
- **Background**: Solid color for non-text regions (no DDR2 read needed)
- **Foreground/background colors**: Per-screen or global constants (TBD)

## Screen Text Content

All text is horizontally centered within a 20-character slot (padding with blank). Stored in `screen_text_rom.v`.

| Screen | Line 0 | Line 1 | Line 2 |
|--------|--------|--------|--------|
| 0 | PRIME FINDER | SELECT MODE- A B C D | (blank) |
| 1 | MODE - N MAX | 00 000 000 | * TO START |
| 2 | MODE- TIME LIMIT | 0 000  SEC | * TO START |
| 3 | MODE - SINGLE NUM | 00 000 000 | * TO START |
| 4 | MODE- TEST | * TO START | (blank) |
| 5 | LOADING PRIMES | (blank) | (blank) |
| 6 | RESULTS | (blank) | (blank) |

## DDR2 Address Map

```
0x000_0000 – 0x027_FFFF : Prime bitmap 6k+1        (2.5 MB = 20,971,520 bits)
0x028_0000 – 0x04F_FFFF : Prime bitmap 6k-1        (2.5 MB = 20,971,520 bits)
0x050_0000 – 0x050_9FFF : Frame buffer A            (40,960 bytes)
0x060_0000 – 0x060_9FFF : Frame buffer B            (40,960 bytes)
```

Prime storage sized for 100M candidate range: only 6k±1 values tested,
so ~33.3M candidates → 20M bits per stream covers it with margin.

Each frame buffer stores only the text line scanlines:
- Line 0: 32 rows × 640 bytes = 20,480 bytes (2x height)
- Lines 1–2: 16 rows × 640 bytes each = 10,240 bytes each
- Total: 20,480 + 10,240 + 10,240 = 40,960 bytes per buffer
- 2,560 DDR2 transactions per full buffer write (128 bits = 16 bytes each)

## Double Buffering

- Two frame buffer regions (A and B) in DDR2
- `buf_sel_ff` register: 0 = display A / render to B, 1 = display B / render to A
- Swap on vsync AND render_done (never show a partially-rendered frame)
- vga_reader reads from the display buffer; frame_renderer writes to the render buffer

---

## Remaining Modules — Detailed Specs

### 1. vga_reader.v (ui_clk domain)

Prefetches text line pixels from DDR2 into pixel_fifo.

- **Inputs**: vsync (CDC'd from clk_vga), DDR2 read data from arbiter
- **Outputs**: DDR2 read commands to arbiter, pixel_fifo write port (128-bit)
- **Behavior**:
  - Tracks which scanline the VGA beam is approaching (derive from vsync + scanline counter in ui_clk domain, or CDC the y position)
  - When approaching a text line scanline: issues 40 sequential DDR2 read commands (640 pixels / 16 per transaction)
  - Pushes app_rd_data into pixel_fifo on app_rd_data_valid
  - Reads from display buffer (base address selected by buf_sel_ff)
  - Resets to top of frame on vsync rising edge
  - Idle during non-text scanlines (no DDR2 reads, no FIFO writes)
  - Line 0 has 32 scanlines (2x height), lines 1–2 have 16 scanlines each → 64 total text scanlines/frame
- **Timing budget**: ~2,400 ui_clk cycles per scanline (32 us × 75 MHz), needs 40 reads (~120 cycles). Very relaxed.
- **DDR2 address calculation**:
  - Buffer base = buf_sel_ff ? FB_B_BASE : FB_A_BASE
  - Scanline offset within buffer = scanline_index × 40 (40 transactions × 16 bytes each = 640 bytes/scanline)
  - scanline_index: 0–31 for line 0, 32–47 for line 1, 48–63 for line 2

### 2. frame_renderer.v (ui_clk domain)

Renders text characters to pixel data and writes to DDR2.

- **Inputs**: screen_id (which screen to render, CDC'd from clk domain), font_rom read port, screen_text_rom read port
- **Outputs**: DDR2 write commands to arbiter, render_done signal
- **Behavior**:
  - Triggered on screen change or initial render after DDR2 calibration
  - For line 0 (2x scale): for each of 32 pixel rows (each font glyph row used twice):
    1. Build a 640-byte scanline: background color everywhere
    2. For each of 20 character positions: read char code from screen_text_rom → read glyph row from font_rom (row index = pixel_row / 2) → stamp 16 pixels at x = 160 + char_pos × 16 (each glyph pixel doubled horizontally: glyph bit → 2 consecutive pixels of fg or bg color)
    3. Write the 640-byte scanline to DDR2 render buffer via arbiter (40 DDR2 write transactions)
  - For lines 1–2 (1x scale): for each of 16 pixel rows:
    1. Build a 640-byte scanline: background color everywhere
    2. For each of 20 character positions: read char code from screen_text_rom → read glyph row from font_rom → stamp 8 pixels at x = 240 + char_pos × 8 (where glyph bit = 1 → fg, bit = 0 → bg)
    3. Write the 640-byte scanline to DDR2 render buffer via arbiter (40 DDR2 write transactions)
  - When all 64 scanlines (32 + 16 + 16) are written: assert render_done
  - Total: 64 × 40 = 2,560 DDR2 write transactions per render (~34 us at 75 MHz)
- **Font ROM access**: font_rom is instantiated inside frame_renderer (or shared via ports). 1-cycle read latency means the renderer pipeline needs to account for this.
- **Screen text ROM access**: Same — 1-cycle latency, pipeline accordingly.
- **Scanline buffer**: Build each 640-byte scanline in a local register array or BRAM, then burst-write to DDR2 in 40 × 128-bit transactions.

### 3. mem_arbiter.v (Implemented)

4-port priority arbiter with read + write support.

- **Requestors (priority order)**:
  1. **VGA read** (highest) — `vga_rd_req` / `vga_rd_addr` → `vga_rd_grant_ff`
  2. **Frame renderer write** (medium) — `render_wr_req` / `render_wr_addr` / `render_wr_data` → `render_wr_grant_ff`
  3. **Prime plus write** (lower, round-robin with minus) — FIFO auto-address
  4. **Prime minus write** (lower, round-robin with plus) — FIFO auto-address
- **Read data passthrough**: `rd_data` / `rd_data_valid` wired directly from MIG to VGA reader (only read requestor)
- **Read commands**: For reads, `data_sent` is pre-set to 1 in IDLE (no write data phase); completion requires only command acceptance
- **Address constants**: `BASE_PLUS = 0x000_0000`, `BASE_MINUS = 0x028_0000`
- **Existing prime behavior preserved**: identical write path when VGA/renderer ports are idle

### 4. Integration in test_top_logic.v and test_top_with_ssd.v

1. Connect PLL clk_vga output (currently unused) to vga_controller and vga_driver
2. Instantiate new modules: vga_driver, vga_reader, frame_renderer, screen_text_rom, pixel_fifo
3. Expand mem_arbiter port list for VGA read and frame renderer write channels
4. Connect app_rd_data / app_rd_data_valid from ddr2_wrapper (currently unconnected)
5. Add buf_sel_ff register with swap logic (vsync + render_done)
6. CDC for vsync and screen_id from clk/clk_vga to ui_clk domain
7. Add VGA output pins to test_top_with_ssd.v port list:
```verilog
output wire [3:0] VGA_R,
output wire [3:0] VGA_G,
output wire [3:0] VGA_B,
output wire       VGA_HS,
output wire       VGA_VS
```

---

## Clock Domain Crossings Required

| Signal | From | To | Method |
|--------|------|----|--------|
| vsync | clk_vga (25 MHz) | ui_clk (~75 MHz) | 2-FF synchronizer + edge detect |
| screen_id[2:0] | clk (100 MHz) | ui_clk (~75 MHz) | Gray code or 2-FF (slow-changing) |
| text line y-positions | ui_clk | clk_vga | 2-FF (slow-changing, only updated between frames) |
| buf_sel_ff | ui_clk | ui_clk | Same domain (no CDC needed) |
| render_done | ui_clk | ui_clk | Same domain |

## Recommended Implementation Order (remaining work)

1. **Expand `mem_arbiter.v`** — Add read command support, 4-port priority selection, app_rd_data routing. Test that existing prime writes still work after expansion.
2. **`vga_reader.v`** — Implement DDR2 prefetch into pixel_fifo. Can test with a known pattern pre-written to DDR2 frame buffer region.
3. **`frame_renderer.v`** — Implement text rendering with 2x scaling for line 0, 1x for lines 1–2. Test by rendering a screen and reading back via vga_reader.
4. **Full integration** — Wire everything into test_top_logic.v, add CDC logic, buf_sel_ff swap, connect VGA pins through test_top_with_ssd.v. Verify end-to-end: screen_id → renderer → DDR2 → reader → FIFO → driver → VGA output.

## Bandwidth Analysis

- **VGA reads**: 64 text scanlines/frame × 40 reads/scanline × 60 fps = 153,600 reads/sec
- **Frame renderer writes**: 2,560 writes per screen change (infrequent, ~34 us burst)
- **Prime writes**: Continuous during PRIME_RUN, limited by engine speed
- **DDR2 capacity**: ~75M transactions/sec theoretical (128-bit, 75 MHz)
- **VGA uses ~0.2% of bandwidth** — no contention concern

## Coding Conventions

- font_rom.v glyphs: A-I, L-P, R-U, X, 0-9, *, -, space. 6-pixel-wide strokes centered in 8-pixel cell (1 px padding each side), rows 3-10 active (3 px top padding, 5 px bottom padding)
- All Verilog follows two-block FSM style with next_*/_ff naming convention
- No for loops in synthesizable code (Xilinx BRAM initializes to zero by default)
- VGA DAC on Nexys A7 is resistor-ladder, 4 bits per channel (12-bit RGB)

## Key Design Details for Implementation

### vga_driver FIFO interface (already implemented)
- `fifo_rd_en` is **combinational** (wire, not registered) — critical for correct FWFT timing
- `pixel_sel_ff` toggles each pixel clock during text lines: sel=0 uses dout[15:8], sel=1 uses dout[7:0] and pops FIFO
- Resets to 0 during blanking and non-text visible regions

### pixel_fifo configuration
- FWFT with **no pipeline registers** — dout valid same cycle empty deasserts
- Active-high reset
- Module name in Vivado: `pixel_fifo` (not pixel_fifo_ip)

### vga_controller output latency
- All outputs (hsync_ff, vsync_ff, video_on_ff, x_ff, y_ff) are registered — 1 cycle behind the internal counters
- vga_driver adds 1 more cycle of registered output — total 2 cycles of consistent pipeline delay, sync signals and pixel data aligned
