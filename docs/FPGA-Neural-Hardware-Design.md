# FPGA-Neural — Hardware Design Document

Status: draft, pre-schematic. Component choices below are researched
against current distributor listings (2026-09-02) but not yet
ordered/prototyped. No PCB layout exists yet.

Goal: a board carrying the project's actual target device
(`LFE5U-45F-8BG381C`) plus the parallel PSRAM the current RTL
(`rtl/psram_controller.v`) is written for, so real hardware exists
to run everything already synthesized/benchmarked in this repo.

---

## 1. Why a new board (not `basic-ecp5-pcb`)

A reference ECP5 dev board (Matt Venn's `basic-ecp5-pcb`,
OSHWA-approved, in this workspace at `../basic-ecp5-pcb`) exists and
is a useful source of **proven power/config circuitry** — but it
carries the wrong chip for this project and has no RAM at all:

| | `basic-ecp5-pcb` | This project's target |
|---|---|---|
| Device | `LFE5U-45F-6BG256C` | `LFE5U-45F-8BG381C` |
| Package | 256-ball CABGA | 381-ball CABGA |
| Speed grade | -6 (slowest ECP5 grade) | -8 (fastest ECP5 grade) |
| RAM | none (6 PMODs, no memory chip) | parallel PSRAM required |

Same die (`LFE5U-45F`, same 44K LUT / 72 DSP), different package and
a materially slower speed grade. All Fmax numbers measured so far in
this repo (`docs/FPGA-NeuralNetwork-Engine.md` §15 "Phase 7 — Optimization") target
the -8 grade; they do not directly transfer to a -6 part.

**What we reuse from it anyway:** the power tree and bitstream-config
approach (§4, §5) are package-independent and already validated on
real, shipped hardware — no reason to redesign those from scratch.

---

## 2. I/O pin budget (real ball data, CABGA381)

Extracted from Lattice's own ECP5-45 pinout table (`../basic-ecp5-pcb/docs/ECP5Upinouts.ods`,
sheet `ECP5U45Pinout`, `CABGA381` column) — not estimated:

| Bank | Usable I/O balls |
|---|---|
| 0 | 29 |
| 1 | 35 |
| 2 | 35 |
| 3 | 36 |
| 6 | 36 |
| 7 | 35 |
| 8 | 22 |
| 40 (config-related) | 4 |
| **Total usable** | **~232** |
| Power/ground/NC (remaining of 381 balls) | 149 |

Signal budget this design actually needs:

| Function | Pins |
|---|---|
| PSRAM (`psram_a` 22b worst case, `psram_dq` 16b, `ce_n/oe_n/we_n/lb_n/ub_n/zz_n` 6b) | up to 44 (real usage likely less — see §3, address lines can be trimmed to match actual chip density) |
| Application SPI (`sclk/mosi/miso/cs_n`) | 4 |
| `clk`, `rst` | 2 |
| Config SPI (to onboard FLASH) | 4 |
| JTAG (recommended, for bring-up/debug) | 4 |
| **Total** | **~58** |

~58 of ~232 usable I/O used — **plenty of headroom** (~170+ spare
pins) for LEDs, buttons, a debug PMOD-style header, or a second SPI
host, without any pin-count pressure. This board does not need to be
pin-constrained the way a 256-ball/PMOD-only design would.

---

## 3. PSRAM subsystem (the piece `basic-ecp5-pcb` doesn't have)

`rtl/psram_controller.v` implements a plain **asynchronous parallel**
interface — address bus, 16-bit data bus, `ce_n`/`oe_n`/`we_n` and
byte-lane `lb_n`/`ub_n`, plus `zz_n` — and its timing already
hardcodes a **70&nbsp;ns access latency** assumption
(`ACCESS_CYCLES = ceil(70ns × CLK_FREQ_MHZ / 1000)`). This is a
classic async-SRAM-style bus, not QSPI — most "PSRAM" sold today
(including what's on typical ESP32 boards) is serial/QSPI and **will
not** plug into this controller without a rewrite.

**Recommended part: ISSI IS66WVE4M16EBLL-70BLI**
- 64&nbsp;Mbit (4M × 16), parallel pseudo-SRAM, async, **70&nbsp;ns
  access** — matches the controller's timing assumption exactly, no
  RTL change needed.
- TSOP-44/48 package — hand-solderable-adjacent, real distributor
  listings (DigiKey, Mouser) at time of writing.
- **Address bus note:** the chip is 4M×16 words (8&nbsp;MB total,
  needs a real 22-bit word address, A0&ndash;A21). The current RTL's
  `ADDR_WIDTH=22` is a **byte** address (4&nbsp;MiB space) that
  `int8_memory_access.v` right-shifts by 1 (`addr >> 1`) into a word
  address before it reaches `psram_controller` — so only **21**
  word-address bits are actually driven today. Wire all 22 chip
  address balls, but the chip's topmost line (A21) stays unused/tied
  low until `ADDR_WIDTH` is widened to 23 to use the chip's full
  8&nbsp;MB instead of today's 4&nbsp;MiB. Free headroom, not a defect.

**Fallback: ISSI IS61WV6416DBLL / IS61WV102416BLL** (true async
SRAM, not pseudo-SRAM) — electrically drop-in on the same
`ce_n/oe_n/we_n/lb_n/ub_n` signals, no internal refresh (so `zz_n`
can just be tied inactive), faster than needed (~10&nbsp;ns), useful
if the ISSI PSRAM specifically is out of stock. Smaller density
(1&ndash;16&nbsp;Mbit depending on exact part) — fine for this
project's current memory footprint (weights/biases/activations for
the networks exercised so far are well under 1&nbsp;MB).

Real part numbers, not yet ordered — verify current stock/pricing
before BOM lock.

---

## 4. Clock

`basic-ecp5-pcb` uses a fixed **16&nbsp;MHz** MEMS oscillator
(SiTime SiT2001B family) — no crystal driver on the ECP5, the clock
input must come from an oscillator IC into a `PCLK` pad.

**Recommendation: keep 16&nbsp;MHz**, same SiT2001B family (or
SiT1602/SiT8008, same vendor, also in stock). Rationale, not just
"reuse what worked":

- No PLL exists anywhere in this project's RTL yet — `CLK_FREQ_MHZ`
  is a **timing parameter**, not a clock generator. Whatever
  oscillator is fitted drives `clk` directly.
- Every Fmax measured so far for the *full* integrated system
  (`spi_neuron_top`, Phase 5) sits at 39.5&ndash;45&nbsp;MHz across a
  seed sweep (`docs/FPGA-NeuralNetwork-Engine.md` §15 "Phase 7 — Optimization") —
  confirmed structural, not placement luck. 16&nbsp;MHz sits well
  under that with real margin.
- **`CLK_FREQ_MHZ` must be set to match whatever oscillator is
  actually fitted** (16, if this recommendation is taken) — it feeds
  the PSRAM access-timing formulas directly (§3); using the RTL's
  default of 80 with a 16&nbsp;MHz real clock would under-time the
  PSRAM by 5×.

A higher oscillator (e.g. 25 or 32&nbsp;MHz) is possible with margin
to spare, but revisit once the Phase 7 timing-closure work
(`docs/FPGA-NeuralNetwork-Engine.md`) lands rather than guessing a
number now.

---

## 5. Power

Reuse `basic-ecp5-pcb`'s proven three-rail tree as-is (same device
family, same rail requirements regardless of package):

| Rail | Value | Part | Load | Status |
|---|---|---|---|---|
| Core | 1.1&nbsp;V | TLV62568 (buck) | ≥600&nbsp;mA | Confirmed in production, DigiKey/Mouser listed |
| I/O | 3.3&nbsp;V | TLV62568 (buck) | 1&nbsp;A (all banks + PSRAM + PMODs share this) | Confirmed in production |
| Auxiliary | 2.5&nbsp;V | TLV73325 (LDO) | 10&nbsp;mA | Confirmed in production |

Decoupling: one cap per I/O bank minimum, per Lattice's ECP5
Hardware Checklist (referenced by `basic-ecp5-pcb`, not re-derived
here).

---

## 6. Configuration (bitstream load)

Reuse `basic-ecp5-pcb`'s SPI-FLASH-boot approach:

- **W25Q128JV** SPI NOR flash (16&nbsp;MB) — confirmed in production,
  multiple package options (WSON, SOIC) currently listed.
- ECP5 reads its bitstream from this flash at power-on (`sysCONFIG`
  SPI master mode); no external programmer needed for normal
  power-up, only for the initial flash write.

**Lessons reused from `basic-ecp5-pcb`'s errata (do not re-discover
these the hard way):**

- Config-mode select pins should tie directly to GND, not through a
  10&nbsp;k resistor — the ECP5 test point is ~1&nbsp;V, too close to
  the 3.3&nbsp;V bank's input threshold through a resistor divider.
- Not every SPI flash that claims QSPI actually has a usable QE
  (quad-enable) bit in practice — `basic-ecp5-pcb` hit this with an
  IS25LP016D and switched to the W25Q12x family instead. Stick with
  W25Q128JV rather than substituting on price alone.
- **The dedicated config-SPI clock pin cannot be reused as a general
  input** post-configuration without extra board-level workaround
  (`basic-ecp5-pcb` needed a bodge wire to let a Raspberry Pi talk
  SPI to the FPGA over the *same* physical pin used for flash boot).
  **This project's application SPI** (`spi_neuron_top`'s
  `sclk`/`mosi`/`miso`/`cs_n`, the host-facing protocol in
  `docs/FPGA-NeuralNetwork-Engine.md` §8.1) **must land on separate,
  ordinary I/O pins — never the config-SPI pins** — precisely to
  avoid needing that same workaround.

---

## 7. Signal map (draft — not yet a real LPF)

No `.lpf` pin constraints exist for this device/package combination
yet (all `.lpf` files in `synth/` are currently empty — nextpnr has
been auto-placing I/O for every synthesis run so far, fine for
Fmax/resource benchmarking, **not** sufficient for a real board).
Before schematic capture, someone needs to:

1. Pick actual CABGA381 ball numbers for each signal below from the
   pinout table referenced in §2 (bank-aware: keep the PSRAM data/
   address bus in one or two adjacent banks to ease layout and
   timing).
2. Write a real `.lpf` with those assignments and re-run
   `nextpnr-ecp5` with it (current benchmark runs deliberately
   skipped this — see `tools/fpga_benchmark.py`).
3. Confirm bank voltage compatibility (all banks are 3.3&nbsp;V I/O
   in this design, per §5 — fine for both the PSRAM candidates in §3
   and standard SPI-level signaling).

| Signal group | Port(s) | Count | Target bank (TBD) |
|---|---|---|---|
| PSRAM address | `psram_a[21:0]` | 22 | one bank |
| PSRAM data | `psram_dq[15:0]` | 16 | same or adjacent bank |
| PSRAM control | `psram_ce_n/oe_n/we_n/lb_n/ub_n/zz_n` | 6 | same bank as above |
| Application SPI | `sclk/mosi/miso/cs_n` | 4 | any bank, NOT the config-SPI bank (§6) |
| Clock/reset | `clk`, `rst` | 2 | `clk` must land on a `PCLK`-capable pad |
| Config SPI | to onboard flash | 4 | dedicated config bank (bank "40" balls, §2) |
| JTAG (debug) | TCK/TMS/TDI/TDO | 4 | dedicated JTAG balls |

---

## 8. Bill of materials (draft)

| Ref | Part | Function | Availability |
|---|---|---|---|
| U1 | LFE5U-45F-8BG381C | FPGA | Already the project's confirmed target (see main docs, price/stock table) |
| U2 | ISSI IS66WVE4M16EBLL-70BLI | Parallel PSRAM, 64Mb, 70ns | Verified listed, DigiKey/Mouser |
| U3, U4 | TLV62568 | Buck converter, core + IO rails | Confirmed in production |
| U5 | TLV73325 | LDO, 2.5V aux rail | Confirmed in production |
| U6 | W25Q128JV | SPI NOR flash, config | Confirmed in production, multiple packages |
| Y1 | SiT2001B, 16&nbsp;MHz | System clock oscillator | Confirmed in production |

Not yet specified: exact package/footprint per part, decoupling cap
values, JTAG header, PSRAM address-bus trim if a smaller/cheaper
density than 4M×16 turns out to be sufficient once real network
sizes are decided.

---

## 9. Open items before schematic capture

- [ ] Decide real PSRAM density needed (drives whether `ADDR_WIDTH`
      stays 22 or can shrink, and whether the fallback true-SRAM
      part in §3 is sufficient instead of the pseudo-SRAM)
- [ ] Real `.lpf` pin assignment (§7) and a synthesis run against it
      (current benchmark results all use auto-placed I/O)
- [ ] Confirm PSRAM/SPI signal integrity at whatever clock is
      actually fitted (§4) — no signal integrity analysis done yet
- [ ] JTAG header footprint choice
- [ ] KiCad (or other) schematic capture — none exists yet for this
      device/package combination
