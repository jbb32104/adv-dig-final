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
| `screen_text_rom.v` | `rtl/screen_text_rom.v` | Created — 7 screens x 3 lines x 20 chars, centered text, BRAM |
| `pixel_fifo` | Vivado IP | Created — async 128->16 bit, FWFT, no pipeline registers |
| `vga_driver.v` | `rtl/vga_driver.v` | Created — 16-bit FIFO unpacking, 8->12 bit RGB expansion |
| `mem_arbiter.v` | `rtl/mem_arbiter.v` | Done — 4-port priority arbiter (VGA read > render write > prime round-robin) |
| `vga_reader.v` | `rtl/vga_reader.v` | Done — DDR2 prefetch into pixel_fifo, double-buffer select, vsync CDC |
| `fb_test_writer.v` | `rtl/fb_test_writer.v` | Done — one-shot fill of both FB_A and FB_B with white pixels |
| `test_vga_top.v` | `rtl/test_vga_top.v` | Done — combined VGA + prime engine test top, all 4 arbiter ports active, double-buffer swap controller |
| XDC VGA pins | `rtl/master.xdc` | Uncommented — VGA_R/G/B/HS/VS pin constraints active |

**Hardware test results**:
1. VGA-only test: Three solid white bars at correct y-positions. PLL locked, no FIFO underruns.
2. VGA + DDR2 readback: White bars via DDR2 round-trip (fb_test_writer -> DDR2 -> vga_reader -> pixel_fifo -> vga_driver).
3. VGA + DDR2 + primes: All 4 arbiter ports active simultaneously. White bars remain solid (no magenta underrun) under heavy prime write contention.

### Remaining (to be implemented)

| # | Module | Dependencies | Description |
|---|--------|-------------|-------------|
| 1 | `frame_renderer.v` | font_rom, screen_text_rom, arbiter | Render text->pixels, write to DDR2 (replaces fb_test_writer) |
| 2 | Integration | All above | Wire frame_renderer into test_top_logic.v for production use |

---

## Existing System (Already Working)

- **Prime engines**: Two independent engines (6k+1, 6k-1) generate prime bitmaps
- **Prime accumulators**: Bit-pack results into 32-bit words, write to asymmetric FIFOs (32-bit write / 128-bit read), flush with mod-4 zero-padding
- **mem_arbiter**: 4-port priority arbiter (VGA read > renderer write > prime round-robin), supports both CMD_READ and CMD_WRITE, 3-state FSM: IDLE -> ISSUE -> COOLDOWN
- **DDR2 via MIG**: 128-bit native interface, ~75 MHz ui_clk, calibration handshake
- **PLL**: 100 MHz board clock -> 200 MHz (MIG sys_clk), 25 MHz (clk_vga), 50 MHz (SD clock)
- **Clock domains**: clk (100 MHz), ui_clk (~75 MHz), sys_clk_200 (200 MHz), clk_vga (25 MHz)
- **Reset**: 2-FF synchronizer on cpu_rst_n in clk domain; arb_rst_n = ~ui_clk_sync_rst for ui_clk domain
- **Coding style**: Two-block FSM (combinational always @(*) with next_* signals, sequential always @(posedge clk) for flops only). All registered outputs use _ff suffix.

### Key Files

| File | Purpose |
|------|---------|
| `test_vga_top.v` | Combined VGA + prime engine test top (all 4 arbiter ports, double-buffer swap) |
| `test_top_logic.v` | Production prime-only integration (VGA not yet wired) |
| `test_top_with_ssd.v` | Pin wrapper (no logic, just port pass-through) |
| `mem_arbiter.v` | 4-port DDR2 arbiter with VGA read priority |
| `vga_reader.v` | DDR2 frame buffer prefetch into pixel_fifo, double-buffer select |
| `fb_test_writer.v` | Test pattern writer — fills both FB_A/FB_B with white (to be replaced by frame_renderer) |
| `vga_driver.v` | VGA pixel output — reads pixel_fifo, expands 8-bit RGB332 to 12-bit RGB444 |
| `vga_controller.v` | VGA timing generator (hsync, vsync, video_on, x, y) — outputs registered |
| `font_rom.v` | 8x16 monochrome font ROM in BRAM (synchronous, 1-cycle read latency) |
| `screen_text_rom.v` | Static BRAM with character codes for all 7 screens (1-cycle read latency) |
| `prime_accumulator.v` | Bit-packing + FIFO with flush/padding |
| `mode_fsm.v` | State machine for prime modes (IDLE, PRIME_RUN, PRIME_FLUSH, etc.) |
| `ddr2_wrapper.v` | MIG pass-through wrapper |
| `pll` | Clocking wizard IP (100->200, 25, 50 MHz). Ports: clk_in, resetn, clk_mem, clk_sd, clk_vga, locked |
| `prime_fifo_ip` | Vivado FIFO IP (async, 32-bit write / 128-bit read, FWFT) |
| `pixel_fifo` | Vivado FIFO IP (async, 128-bit write / 16-bit read, FWFT, no pipeline regs) |

---

## VGA Display Spec

- **Resolution**: 640x480 @ 60 Hz, 25 MHz pixel clock (PLL clk_vga output)
- **Content**: 7 screens, each with up to 3 lines of uppercase text
- **Characters**: Lines 1-2: 8 px wide x 16 px tall. Line 0: 16 px wide x 32 px tall (2x scale).
- **Max string length**: 20 characters (including spaces)
- **Text centering**:
  - Lines 1-2: x_start = 240 (horizontally centered 160 px block within 640)
  - Line 0: x_start = 160 (horizontally centered 320 px block within 640, 2x width)
- **Text line y-positions** (fixed for now, will become moveable later):
  - Line 0: y = 64..95   (32 px tall -- 2x height)
  - Line 1: y = 288..303  (16 px tall)
  - Line 2: y = 352..367  (16 px tall)
- **Pixel format**: 8-bit RGB (3:3:2) stored in DDR2, expanded to 12-bit (4:4:4) at VGA output
  - R[3:0] = {pixel[7:5], pixel[7]}
  - G[3:0] = {pixel[4:2], pixel[4]}
  - B[3:0] = {pixel[1:0], pixel[1:0]}
- **Background**: Solid color for non-text regions (no DDR2 read needed)
- **Foreground/background colors**: Per-screen or global constants (TBD)

## Screen Text Content

All text is horizontally centered within a 20-character slot (padding with blank/0x00). Stored in `screen_text_rom.v`.

| Screen | Line 0 (2x) | Line 1 (1x) | Line 2 (1x) |
|--------|-------------|-------------|-------------|
| 0 | `    PRIME FINDER    ` | `SELECT MODE- A B C D` | (blank) |
| 1 | `    MODE - N MAX    ` | `     00 000 000     ` | `     * TO START     ` |
| 2 | `  MODE- TIME LIMIT  ` | `     0 000  SEC     ` | `     * TO START     ` |
| 3 | ` MODE - SINGLE NUM  ` | `     00 000 000     ` | `     * TO START     ` |
| 4 | `     MODE- TEST     ` | `     * TO START     ` | (blank) |
| 5 | `   LOADING PRIMES   ` | (blank) | (blank) |
| 6 | `      RESULTS       ` | (blank) | (blank) |

Note: Line 0 is rendered at 2x scale (16px wide x 32px tall per character). The font_rom stores single-size 8x16 glyphs; the frame_renderer doubles both horizontally and vertically when writing Line 0 pixels to DDR2.

## DDR2 Address Map

```
0x000_0000 - 0x027_FFFF : Prime bitmap 6k+1        (2.5 MB = 20,971,520 bits)
0x028_0000 - 0x04F_FFFF : Prime bitmap 6k-1        (2.5 MB = 20,971,520 bits)
0x050_0000 - 0x050_9FFF : Frame buffer A            (40,960 bytes = 2,560 x 16)
0x050_A000 - 0x051_3FFF : Frame buffer B            (40,960 bytes = 2,560 x 16)
```

FB_A and FB_B are contiguous. FB_B = FB_A + 0xA000.

Prime storage sized for 100M candidate range: only 6k+-1 values tested,
so ~33.3M candidates -> 20M bits per stream covers it with margin.

Each frame buffer stores only the text line scanlines:
- Line 0: 32 rows x 640 bytes = 20,480 bytes (2x height)
- Lines 1-2: 16 rows x 640 bytes each = 10,240 bytes each
- Total: 20,480 + 10,240 + 10,240 = 40,960 bytes per buffer
- 2,560 DDR2 transactions per full buffer write (128 bits = 16 bytes each)

## Double Buffering (Implemented)

- Two frame buffer regions (FB_A and FB_B) in DDR2, contiguous
- **vga_reader.v**: `fb_select` input chooses FB_A or FB_B; latched on vsync rising edge so the buffer base is stable for the entire frame
- **test_vga_top.v**: `fb_display_ff` register toggles on vsync rising edge (after fb_ready). Own vsync CDC (2-FF + edge detect) in ui_clk domain.
- **Swap protocol**: Currently toggles every frame (both buffers have identical test pattern). For production with frame_renderer: toggle only when render_done is asserted (never show a partially-rendered frame).
- vga_reader reads from `fb_display_ff` buffer; frame_renderer writes to `!fb_display_ff` buffer

---

## Remaining Module -- Detailed Spec

### frame_renderer.v (ui_clk domain)

Renders text characters to pixel data and writes to DDR2 via the arbiter's render write port. Replaces fb_test_writer.

- **Clock domain**: ui_clk (~75 MHz)
- **Inputs**: screen_id[2:0] (CDC'd from clk domain), render_buf (which buffer to write: !fb_display_ff)
- **Outputs**: arbiter render write port (render_wr_req, render_wr_addr, render_wr_data, render_wr_grant), render_done
- **Internal instances**: font_rom, screen_text_rom (both clocked on ui_clk)
- **No write-side FIFO needed**: the renderer builds one 128-bit word at a time and writes it directly through the arbiter req/grant handshake. It can stall waiting for a grant -- no real-time deadline.

#### Trigger conditions

- Triggered on screen_id change (detected via CDC + edge compare) or initial render after init_calib_complete
- Renders the full frame buffer for the new screen_id, then asserts render_done
- render_done feeds into the double-buffer swap logic

#### Word-to-character alignment

This is the key insight that simplifies the pipeline:

**Line 0 (2x scale)**: Each 2x character = 16 pixels = exactly 1 DDR2 word (128 bits).
- 640 pixels/scanline = 40 words
- Words 0-9 (pixels 0-159): background
- Words 10-29 (pixels 160-479): text -- word N maps to character (N - 10), one char per word
- Words 30-39 (pixels 480-639): background

**Lines 1-2 (1x scale)**: Each 1x character = 8 pixels, so 2 characters per DDR2 word.
- 640 pixels/scanline = 40 words
- Words 0-14 (pixels 0-239): background
- Words 15-24 (pixels 240-399): text -- word N contains characters (N-15)*2 and (N-15)*2+1
- Words 25-39 (pixels 400-639): background

#### Render pipeline (per 128-bit word)

For a **background word** (outside text region): emit 128 bits of bg_color replicated 16 times. No ROM access needed.

For a **Line 0 text word** (1 char, 2x scale):
1. Read char_code from screen_text_rom: {screen_id, 2'd0, char_pos} -> 1 cycle latency
2. Read glyph row from font_rom: {char_code[6:0], pixel_row[4:1]} -> 1 cycle latency (pixel_row/2 because 2x vertical)
3. Expand 8 glyph bits to 16 pixels (each bit doubled horizontally): bit[7] -> pixels[0:1], bit[6] -> pixels[2:3], ..., bit[0] -> pixels[14:15]. Glyph bit 1 = fg_color, 0 = bg_color.
4. Write the 128-bit word to DDR2

For a **Lines 1-2 text word** (2 chars, 1x scale):
1. Read char_code_A from screen_text_rom: {screen_id, line_num, char_pos_A} -> 1 cycle
2. Read glyph_row_A from font_rom: {char_code_A[6:0], pixel_row[3:0]} -> 1 cycle
3. Read char_code_B from screen_text_rom: {screen_id, line_num, char_pos_B} -> 1 cycle
4. Read glyph_row_B from font_rom: {char_code_B[6:0], pixel_row[3:0]} -> 1 cycle
5. Expand: glyph_A (8 bits) -> pixels[0:7], glyph_B (8 bits) -> pixels[8:15]. 1 = fg, 0 = bg.
6. Write the 128-bit word to DDR2

Steps 1-2 and 3-4 can be pipelined (start char_B ROM read while char_A font read is in flight).

#### Scanline iteration order

```
For line_idx = 0, 1, 2:
  For pixel_row = 0 .. (line_height - 1):     // 32 for line 0, 16 for lines 1-2
    For word_idx = 0 .. 39:
      Build 128-bit word (bg or text as above)
      Write to DDR2 at: render_base + scanline_offset * 640 + word_idx * 16
      Wait for render_wr_grant
```

Total: 64 scanlines x 40 words = 2,560 DDR2 writes per render.

#### Timing

At ~75 MHz with arbiter overhead (~3-6 cycles per write including ISSUE+COOLDOWN), a full render takes roughly 2,560 x 6 = ~15,360 cycles = ~200 us. This is well within the 16.7 ms frame period and doesn't need to run every frame -- only on screen changes.

#### FSM states (suggested)

```
S_IDLE       : wait for render trigger (screen_id change or initial)
S_SETUP      : latch screen_id, render_buf base address, reset counters
S_BG_WORD    : emit background-color word, request DDR2 write
S_TEXT_ROM   : read char code from screen_text_rom (1 cycle latency)
S_FONT_ROM   : read glyph row from font_rom (1 cycle latency)
S_TEXT_ROM_B : (lines 1-2 only) read second char code
S_FONT_ROM_B : (lines 1-2 only) read second glyph row
S_EXPAND     : expand glyph bits to 16 RGB332 pixels, form 128-bit word
S_WRITE      : assert render_wr_req, wait for render_wr_grant
S_NEXT       : advance word_idx, pixel_row, line_idx; loop or finish
S_DONE       : assert render_done, return to S_IDLE
```

---

## Already-Implemented Module Details

### vga_reader.v (Implemented)

Prefetches text line pixels from DDR2 into pixel_fifo.

- **Clock domain**: ui_clk
- **Parameters**: FB_A = 0x050_0000, FB_B = 0x050_A000, WORDS_PER_SCANLINE = 40, LINE0_HEIGHT = 32, LINE12_HEIGHT = 16
- **Inputs**: fb_select (which buffer to read), vsync_vga (CDC'd internally), enable (gate on fb_ready)
- **FSM**: S_WAIT_VS -> S_IDLE -> S_REQ -> S_DATA -> S_IDLE (loop until WORDS_PER_FRAME words read)
- **vsync CDC**: 2-FF synchronizer + rising edge detect
- **fb_select latching**: Latched on vsync rising edge so buffer base is stable for entire frame
- **DDR2 interface**: one read at a time via vga_rd_req/addr -> vga_rd_grant. rd_data/rd_data_valid passed through directly to pixel_fifo.

### mem_arbiter.v (Implemented)

4-port priority arbiter with read + write support.

- **Requestors (priority order)**:
  1. **VGA read** (highest) -- `vga_rd_req` / `vga_rd_addr` -> `vga_rd_grant_ff`
  2. **Frame renderer write** (medium) -- `render_wr_req` / `render_wr_addr` / `render_wr_data` -> `render_wr_grant_ff`
  3. **Prime plus write** (lower, round-robin with minus) -- FIFO auto-address
  4. **Prime minus write** (lower, round-robin with plus) -- FIFO auto-address
- **Read data passthrough**: `rd_data` / `rd_data_valid` wired directly from MIG to VGA reader (only read requestor)
- **Address constants**: `BASE_PLUS = 0x000_0000`, `BASE_MINUS = 0x028_0000`

---

## Clock Domain Crossings

| Signal | From | To | Method |
|--------|------|----|--------|
| vsync | clk_vga (25 MHz) | ui_clk (~75 MHz) | 2-FF synchronizer + edge detect (in vga_reader and test_vga_top swap controller) |
| screen_id[2:0] | clk (100 MHz) | ui_clk (~75 MHz) | 2-FF (slow-changing, only changes between screens) |
| fb_display_ff | ui_clk | ui_clk | Same domain (no CDC needed) |
| render_done | ui_clk | ui_clk | Same domain |

## Recommended Implementation Order (remaining work)

1. **`frame_renderer.v`** -- Implement text rendering with 2x scaling for line 0, 1x for lines 1-2. Internal font_rom and screen_text_rom instances. Test by rendering screen 0 and reading back via vga_reader.
2. **Integration into test_vga_top.v** -- Replace fb_test_writer with frame_renderer. Wire screen_id from mode_fsm (CDC to ui_clk). Update swap logic: toggle fb_display_ff only on vsync + render_done.
3. **Integration into test_top_logic.v** -- Move VGA subsystem from test_vga_top into production top for final build.

## Bandwidth Analysis

- **VGA reads**: 64 text scanlines/frame x 40 reads/scanline x 60 fps = 153,600 reads/sec
- **Frame renderer writes**: 2,560 writes per screen change (infrequent, ~200 us burst)
- **Prime writes**: Continuous during PRIME_RUN, limited by engine speed
- **DDR2 capacity**: ~75M transactions/sec theoretical (128-bit, 75 MHz)
- **VGA uses ~0.2% of bandwidth** -- no contention concern

## Coding Conventions

- font_rom.v glyphs: A-I, L-P, R-U, X, 0-9, *, -, space. 6-pixel-wide strokes centered in 8-pixel cell (1 px padding each side), rows 3-10 active (3 px top padding, 5 px bottom padding)
- All Verilog follows two-block FSM style with next_*/_ff naming convention
- No for loops in synthesizable code (Xilinx BRAM initializes to zero by default)
- VGA DAC on Nexys A7 is resistor-ladder, 4 bits per channel (12-bit RGB)

## Key Design Details

### vga_driver FIFO interface (implemented)
- `fifo_rd_en` is **combinational** (wire, not registered) -- critical for correct FWFT timing
- `pixel_sel_ff` toggles each pixel clock during text lines: sel=0 uses dout[15:8], sel=1 uses dout[7:0] and pops FIFO
- Resets to 0 during blanking and non-text visible regions

### pixel_fifo configuration
- FWFT with **no pipeline registers** -- dout valid same cycle empty deasserts
- Active-high reset
- Module name in Vivado: `pixel_fifo` (not pixel_fifo_ip)

### vga_controller output latency
- All outputs (hsync_ff, vsync_ff, video_on_ff, x_ff, y_ff) are registered -- 1 cycle behind the internal counters
- vga_driver adds 1 more cycle of registered output -- total 2 cycles of consistent pipeline delay, sync signals and pixel data aligned

### Double-buffer address constants
- `FB_A = 27'h050_0000` (vga_reader parameter, also fb_test_writer FB_BASE)
- `FB_B = 27'h050_A000` (FB_A + 2560 words x 16 bytes = FB_A + 0xA000)
- frame_renderer writes to `!fb_display_ff` buffer; vga_reader reads from `fb_display_ff` buffer
