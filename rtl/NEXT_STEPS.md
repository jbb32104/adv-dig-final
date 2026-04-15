# NEXT_STEPS — DDR2 Memory Integration

Planning doc for connecting the existing prime datapath and the future VGA
pipeline through the MIG-controlled DDR2 on the Nexys A7. Covers the MIG
configuration already chosen, the set of memory-using blocks, the arbiter,
and the sequencing of each data stream.

---

## 1. MIG Configuration (already generated)

The `mig_ddr2` IP was created with these choices:

| Setting | Value |
|---|---|
| Memory part | MT47H64M16HR-25E (Nexys A7 on-board DDR2) |
| Data width | 16 bits (physical DQ width of the chip) |
| Memory clock period | 3333 ps (300 MHz DDR) |
| PHY-to-controller ratio | **4:1** |
| `ui_clk` output | ~75 MHz |
| `app_wdf_data` / `app_rd_data` width | **128 bits** |
| Burst length | 8 (BL8) |
| Burst type | Sequential |
| Input clock | 200 MHz, single-ended |
| Reference clock | Single-ended (wired to the same 200 MHz source as sys_clk) |
| System reset polarity | Active-low (matches `cpu_rst_n`) |
| Internal Vref | **Enabled** — required so DDR2 DQ pins can share a bank with Vref pins |
| Debug signals | OFF |

### Why 128-bit 4:1 mode

DDR2 has a **minimum burst length of 4**, so every DRAM access transfers at
least `4 edges × 16 bits = 64 bits`. With `nCK_PER_CLK = 4` (the 4:1 PHY
ratio), the MIG aggregates two bursts per `ui_clk` cycle, giving:

```
2 (DDR edges/cycle) × 4 (PHY ratio) × 16 (DQ width) = 128 bits per ui_clk
```

This is the **narrowest** native port the MIG can expose for this memory —
you cannot request 32-bit writes to DDR2. The tradeoff of 4:1 vs 2:1 is:

- **4:1 → 75 MHz ui_clk, 128-bit port** (chosen). Easier timing on
  Artix-7; matches the 4-way packing we already do on the prime FIFOs.
- **2:1 → 150 MHz ui_clk, 64-bit port**. Narrower bus but much harder to
  meet timing in our user logic.

All modules on the user side of the MIG will clock from `ui_clk` and
exchange data 128 bits at a time.

---

## 2. Memory-Using Blocks

Seven blocks either produce data bound for DDR2 or consume data coming from
DDR2. Each connects to the arbiter, not directly to the MIG.

| Block | Direction | Width at arbiter | Purpose |
|---|---|---|---|
| **BRAM 6k+1 FIFO** | DDR2-bound (write) | 128 bits | Bitmap of 6k+1 primality results from `prime_accumulator` plus. Asymmetric: 32-in / 128-out. Already instantiated. |
| **BRAM 6k-1 FIFO** | DDR2-bound (write) | 128 bits | Bitmap of 6k-1 primality results from `prime_accumulator` minus. Asymmetric: 32-in / 128-out. Already instantiated. |
| **Prime Calculation Pointer** | Internal to memory manager | — | Two write-address counters (one per prime stream) tracking the next DDR2 address to drop a 128-bit word at. Lives in the arbiter/manager. |
| **Pixel (write) FIFO** | DDR2-bound (write) | 128 bits | Frame data coming from whatever generates pixels (drawing engine, test pattern, etc.). Asymmetric: 16-in / 128-out — 8 pixels (16 bpp) packed per DDR2 transaction. Not yet built. |
| **Write Buffer** | Region in DDR2 | — | The frame currently being drawn. Physical DDR2 address range. Target of the Pixel (write) FIFO's drain. |
| **Read Buffer** | Region in DDR2 | — | The frame currently being displayed. Physical DDR2 address range. Source for the Pixel (read) FIFO's fill. Ping-pongs with Write Buffer at vsync. |
| **Pixel (read) FIFO** | From DDR2 (read) | 128 bits | Feeds the VGA pipeline. Asymmetric: 128-in / 16-out — each 128-bit read fills 8 pixels. Sized to hold roughly **one scanline (640 pixels)** so the VGA controller never starves between refills. Not yet built. |

### Address map (first pass)

DDR2 is 128 MB on this board — we're using <4 MB total, so layout is loose.

| Region | Base address (byte) | Size | Notes |
|---|---|---|---|
| 6k+1 prime bitmap | `0x000_0000` | ≤ 1.25 MB | 128-bit writes, sequential |
| 6k-1 prime bitmap | `0x020_0000` | ≤ 1.25 MB | Aligned to 2 MB for easy addressing |
| Frame buffer A | `0x040_0000` | 600 KB | 640 × 480 × 16 bpp |
| Frame buffer B | `0x050_0000` | 600 KB | Ping-pong partner of A |

Addresses are **byte addresses** into the MIG's `app_addr`; we increment by
16 per 128-bit transaction (128 bits = 16 bytes).

---

## 3. Arbiter Module — Why We Need It

The MIG exposes **one** native port (`app_cmd` / `app_addr` / `app_wdf_*` /
`app_rd_data*`). We have **four independent data streams** wanting that
port:

- Stream A: 6k+1 prime writes
- Stream B: 6k-1 prime writes
- Stream C: Pixel (write) FIFO → Write Buffer
- Stream D: Read Buffer → Pixel (read) FIFO

An arbiter module (tentative name `mem_arbiter` or `memory_manager`) owns
the MIG port and multiplexes these four streams with a fixed priority.

### Priority (highest first)

1. **Pixel (read) FIFO fill** — deadline-critical. If the VGA pipeline
   drains its FIFO below a "refill threshold," the arbiter must service
   DDR2 reads immediately to keep the 25.175 MHz pixel clock fed. A
   starved read FIFO produces visible tearing / garbage on the monitor.
2. **Pixel (write) FIFO drain** — not as hard a deadline as the read
   side, but new frames need to land in DDR2 before vsync so the swap
   is clean.
3. **6k+1 and 6k-1 prime writes** — lowest priority. The prime
   accumulator FIFOs will back-pressure the engines via `prime_fifo_full`
   if the arbiter can't service them immediately. Engines tolerate
   arbitrary stalls.

Within the two prime streams, round-robin between 6k+1 and 6k-1 to keep
them balanced.

### Arbiter responsibilities

- Watch `init_calib_complete` — hold off all activity until DDR2 is ready.
- Inspect FIFO status flags (empty/full/almost-empty/almost-full) to
  decide which stream to service this cycle.
- Maintain **four address pointers** (one per region):
  - `wr_ptr_plus` — next 6k+1 bitmap word address
  - `wr_ptr_minus` — next 6k-1 bitmap word address
  - `wr_ptr_frame` — next pixel write address inside the current Write
    Buffer (wraps within the 600 KB region, reset at vsync)
  - `rd_ptr_frame` — next pixel read address inside the current Read
    Buffer (wraps within the 600 KB region, reset at vsync)
- Track which physical buffer (A or B) is Read vs. Write and swap at
  vsync pulse from the VGA controller.
- Respect MIG handshakes: `app_rdy` gates command issue,
  `app_wdf_rdy` gates write-data issue. Hold transactions when either is
  low.
- Route `app_rd_data` with `app_rd_data_valid` into the Pixel (read)
  FIFO's write side.

### Coding style

Same two-block pattern as every other module:

- One `always @(*)` with all combinational logic, including reset handling
  as `if (!rst_n)`.
- One `always @(posedge ui_clk)` with ONLY `*_ff <= next_*;` lines.
- Every output port is `_ff` and is a direct flop.
- No `rst = ~rst_n;` anywhere; take `rst_n` on the port and use `!rst_n`
  inline where needed. The MIG's `sys_rst` takes inverted polarity and is
  handled at its instantiation site, not globally.

---

## 4. Data-Flow Diagram

```
  prime_accumulator plus       prime_accumulator minus
        (32-in FIFO)                 (32-in FIFO)
             │                              │
           128                            128
             │                              │
             └──────────┬───────────────────┘
                        │
  pixel write source    │        (arbiter)        (VGA controller)
    (draws pixels)      │             ▲                   ▲
         │              │             │                   │ 16 bpp
        16              │           128                 pixels
         │              │             │                   │
    [Pixel WR FIFO]──128┤         [ ARBITER ]──128──[ Pixel RD FIFO ]
     16-in / 128-out    │             │                   │
                        ▼             │                   │
                 ┌──────────────┐     │                   ▼
                 │  MIG native  │◀────┘                 VGA
                 │    port      │                       timing
                 └──────┬───────┘
                        │ DDR2 128-bit via BL8 burst
                        ▼
                  ┌───────────┐
                  │   DDR2    │  Regions:
                  │  (128MB)  │    0x0000000 — 6k+1 bitmap
                  └───────────┘    0x0200000 — 6k-1 bitmap
                                   0x0400000 — Frame A
                                   0x0500000 — Frame B
```

---

## 5. Build Order

Recommended sequence — each step is testable before moving on:

1. **Clocking infrastructure**: add a Clocking Wizard (MMCM) to produce
   the 200 MHz single-ended input for the MIG from the Nexys A7's 100 MHz
   board clock. Output `sys_clk_i` and `clk_ref_i` (same net). Add
   `pixel_clk` (25.175 MHz) from the same MMCM while we're here.
2. **Instantiate the MIG** in a new top-level wrapper (`top_ddr2.v`) that
   pulls the DDR2 pins out to the package. Keep the existing
   `test_top_logic` reachable behind a build switch so bring-up can
   continue without DDR2.
3. **Simple MIG exerciser**: a tiny FSM that writes a known pattern to
   DDR2 and reads it back, printing mismatches on LEDs. Proves
   calibration and basic read/write before any arbiter work.
4. **Arbiter skeleton (one stream)**: wire just the 6k+1 FIFO →
   arbiter → MIG write path. Confirm prime bits land in DDR2 by reading
   them back via the exerciser.
5. **Add the 6k-1 stream + round-robin** between prime writes.
6. **Build the Pixel (write) FIFO and Write Buffer path**. No VGA yet —
   just drive from a test pattern generator and read back via the
   exerciser.
7. **Build the Pixel (read) FIFO and VGA controller**. The read FIFO
   depth should be ≥640 (one scanline) so the arbiter has slack to
   service other streams between refills.
8. **Add vsync-driven buffer swap** in the arbiter. Read and Write buffer
   roles flip; `wr_ptr_frame` and `rd_ptr_frame` reset.
9. **Full integration**: connect the running prime datapath on top of
   the now-complete frame buffer system. Visualize the bitmap on VGA
   (e.g., display a slice of the prime bitmap as a texture).

---

## 6. Notes / Open Questions

- **When do prime writes happen?** Two options: drain FIFOs continuously
  while engines run, or batch the full bitmap after `done_ff`. Continuous
  drain is simpler for the arbiter (always some data available when FIFO
  not empty) and avoids a giant dump at the end. Leaning continuous.
- **Frame buffer swap source**: the VGA controller should emit a 1-cycle
  vsync pulse to the arbiter. Arbiter owns the "which is Read, which is
  Write" register.
- **Init sequencing**: hold the prime engines in reset (or stall via a
  new `mem_ready` signal gating `mode_fsm`'s IDLE exit) until
  `init_calib_complete` is asserted. Otherwise the accumulator FIFOs
  fill and stall the engines anyway, but an explicit gate is cleaner.
- **Read latency**: the MIG read path has multi-cycle, non-fixed
  latency. The arbiter must track in-flight read commands (a small
  counter) and treat `app_rd_data_valid` as the only authoritative
  "data is here" signal — do not assume a fixed number of cycles.
- **Pixel (read) FIFO underflow watchdog**: add an LED that latches if
  the VGA ever tries to pop an empty FIFO. Cheap insurance during
  bring-up.
