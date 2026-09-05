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
sheet `ECP5U45Pinout`, `CABGA381` column) — not estimated. **Caveat added
2026-09-03**: that spreadsheet is no longer present in this environment, so
these per-bank counts could not be re-verified against it. §7's actual pin
assignment instead uses Project Trellis's own device database directly
(same data `nextpnr-ecp5` uses) and gets somewhat lower generic-I/O counts
per bank (e.g. 32/33 usable in banks 2/3 vs. 35/36 here) — Trellis's
`packages`/`pio_metadata` only enumerates *programmable* I/O, not every ball
a full datasheet table would list as "usable I/O" (some datasheet-usable
balls may not appear as ordinary PIO sites in Trellis's model). The totals
below are kept for historical reference; §7 is the verified source for
actual pin placement:

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
| Host attention (`irq_n`, `data_ready_n`, added 2026-09-03 — §7) | 2 |
| Flash runtime SPI bus (`flash_sclk`/`flash_mosi`/`flash_miso`/`flash_cs_n` — fully independent, all ordinary GPIO, no config-primitive shared; implemented Phases F1-F7) | 4 |
| JTAG (recommended, for bring-up/debug) | 4 |
| **Total** | **~60** |

~60 of ~232 usable I/O used (57 actually placed and place&route-verified
in the flash-subsystem synthesis, `synth/ecp5/spi_neuron_top_flash/
nextpnr.log`) — **plenty of headroom** (~170+ spare
pins) for LEDs, buttons, a debug PMOD-style header, or a second SPI
host, without any pin-count pressure. This board does not need to be
pin-constrained the way a 256-ball/PMOD-only design would.

---

## 3. PSRAM subsystem (the piece `basic-ecp5-pcb` doesn't have)

`rtl/psram_controller.v` implements an **asynchronous parallel**
interface with **page-mode burst reads** — address bus, 16-bit data
bus, `ce_n`/`oe_n`/`we_n` and byte-lane `lb_n`/`ub_n`, plus `zz_n` —
and its timing already hardcodes a **70&nbsp;ns random-access
latency** assumption (`ACCESS_CYCLES = ceil(70ns × CLK_FREQ_MHZ /
1000)`). This is a classic async-SRAM-style bus, not QSPI — most
"PSRAM" sold today (including what's on typical ESP32 boards) is
serial/QSPI and **will not** plug into this controller without a
rewrite.

**Page mode (2026-09-03, `psram_page_mode_tb.v`):** the ISSI part is
"asynchronous/**page mode**", meaning sequential reads inside the
same 16-word page (address bits above `A[3]` unchanged) don't need
the full 70&nbsp;ns each — only `tAPA`/`tPC` = **20&nbsp;ns**, once
CE#/OE# are already asserted. Earlier revisions of this controller
did not use that mode at all — every access, sequential or not, paid
the full random-access latency. The controller now:
- Enables page mode on the chip itself at power-up, via the
  datasheet's software configuration-register sequence (2 dummy
  reads + 2 writes at the top address, CR = `0x00F0`) — page mode is
  **off by default** on the real chip, so this step is load-bearing,
  not cosmetic.
- Keeps CE#/OE# asserted after a read completes (`STATE_PAGE_OPEN`)
  instead of closing every single-word transaction; a following read
  in the same page only pays `tAPA`; a following read in a
  *different* page still avoids a CE# toggle but pays a full `tAA`
  for that one word (matches the datasheet: "any change in addresses
  A[4] or higher initiates a new tAA access time").
- Byte-enable (`lb_n`/`ub_n`) changes do **not** close the page.
  `int8_memory_access.v` alternates them on nearly every access
  (byte-granular reads over the 16-bit bus), so treating that as a
  close condition — the first implementation attempt — made the real
  workload *slower*, not faster (measured regression, corrected
  before this was documented as done: see
  `docs/FPGA-Neural-Datapatch-Benchmark.md` for before/after
  numbers). Only a WRITE, or holding CE# low for close to the
  8&nbsp;µs `tCEM` refresh limit, closes the page.
- `sim/psram_model.v` (the timing-strict simulation model used by
  every PSRAM-backed testbench) was extended with its own
  independent `tAPA`/`tAA` continuation check, so a passing
  regression run is a real timing proof, not just a data-match.

**Recommended part: ISSI IS66WVE4M16EBLL-70BLI**
- 64&nbsp;Mbit (4M × 16), parallel pseudo-SRAM, async, **70&nbsp;ns
  access** — matches the controller's timing assumption exactly, no
  RTL change needed.
- TSOP-44/48 package — hand-solderable-adjacent, real distributor
  listings (DigiKey, Mouser) at time of writing.
- **Address bus (2026-09-02: full addressing, all 22 chip lines
  wired):** the chip is 4M×16 words (8&nbsp;MB total), needing a
  real 22-bit word address, A0&ndash;A21. `ADDR_WIDTH` is now **23**
  bits across every module (`rtl/neuron_memory.v`,
  `rtl/psram_controller.v`, etc. — bumped from the earlier 22-bit/
  4&nbsp;MiB default specifically to reach the full chip).
  `int8_memory_access.v` right-shifts the 23-bit **byte** address by
  1 (`addr >> 1`) into a 22-bit **word** address before it reaches
  `psram_controller` — that 22-bit word address maps exactly onto
  the chip's real A0&ndash;A21, with nothing left unconnected. Full
  8&nbsp;MB is addressable today, not deferred.

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

## 7. Signal map — real `.lpf`, place&route-verified (2026-09-03)

**Source of truth changed from the plan in §2**: the `../basic-ecp5-pcb/docs/ECP5Upinouts.ods`
spreadsheet referenced there is no longer present in this environment. The
assignment below instead comes directly from **Project Trellis's own device
database** (`prjtrellis`'s `database/ECP5/LFE5U-45F/iodb.json`) — the same
data `nextpnr-ecp5` itself uses — joining each `CABGA381` ball to its bank
and any dual function via `pio_metadata`. This is real data, not invented
numbers, and it has been **verified by an actual `nextpnr-ecp5` place&route
run**, not just picked by eye:

```
nextpnr-ecp5 --45k --package CABGA381 --speed 8 --freq 80 \
  --json synth/ecp5/spi_neuron_top_graph/top.json \
  --lpf synth/ecp5/spi_neuron_top.lpf \
  --textcfg <out>.config
```

Result: **0 constraint errors**, full route completes, `Program finished
normally` (log: `synth/ecp5/spi_neuron_top_graph/nextpnr_constrained.log`).
Fmax with this real, fixed pinout: **54.58&nbsp;MHz** at the time this pinout
was first verified (FAIL at the 80&nbsp;MHz target; the critical path was
then the saturation-comparator carry chain in `rtl/neuron_parallel.v`,
unrelated to pin placement). **Superseded 2026-09-03** by the timing-closure
work in `WORKLOG.md` ("Timing closure di `neuron_parallel`"): with the same
real pinout, Fmax is now **75.30&nbsp;MHz** (up from 55.59&nbsp;MHz
unconstrained originally) — the pin assignment itself did not need to
change, only the RTL critical path did. **Further updated 2026-09-03**
after adding the `irq_n`/`data_ready_n` host attention pins (2 more
signals, same bank 7, no other ball reassigned): re-verified with a fresh
place&route run, **0 constraint errors**, Fmax 73.88&nbsp;MHz (within the
same noise band already characterized for this pin count in
`WORKLOG.md`'s timing-closure seed sweep — not a regression). TRELLIS_IO
usage: 53/245 (21%) — still confirms the §2 headroom estimate.

**Further updated 2026-09-04** after the flash subsystem (Phases F1-F6,
`WORKLOG.md`) added 3 real pins (`flash_mosi`, `flash_miso`, `flash_cs_n`
— bank 7, generated additively by `tools/pinout/gen_lpf.py`, confirmed via
`git diff` on `synth/ecp5/spi_neuron_top.lpf` to leave every existing ball
unchanged). Full-system real Yosys+nextpnr-ecp5 synthesis (`synth/ecp5/
spi_neuron_top_flash/nextpnr.log`), **0 constraint errors**, full route
completes, Fmax **66.68&nbsp;MHz**. TRELLIS_IO usage: 56/245 (23%).

**Superseded again the same day (Phase F7)**: the flash bus's SCLK
originally reused the boot `CCLK` pad via the ECP5 `USRMCLK` primitive
(no dedicated pin) — dropped after the user pointed out this made the
"exclusive flash bus" claim electrically misleading (SCLK still
depended on the same pad as the config engine) and it carried an
unresolved verification gap (`USRMCLKTS` pad-enable timing never
checked against the primary Lattice sysCONFIG Usage Guide,
FPGA-TN-02039, absent from this project's document set). `flash_sclk`
is now a 4th ordinary GPIO ball (`E3`, bank 7), added purely additively
(`git diff` confirms only the new line, no existing ball moved) — the
flash bus is now 4 independent wires (`sclk`/`mosi`/`miso`/`cs_n`), zero
pins shared with any ECP5 config primitive. Re-verified with a fresh
full-system synthesis: **0 constraint errors**, Fmax **67.91&nbsp;MHz**
(slightly better than 66.68, placement noise, not a regression),
critical path confirmed unchanged (`neuron_parallel` accumulator carry
chain, no flash module involved), `USRMCLK` utilisation now **0/1
(0%)** — direct confirmation the primitive is no longer used at all.
TRELLIS_IO usage: 57/245 (23%). See `WORKLOG.md`'s Phase F7 entry.

**Cross-checked against the real Lattice datasheet (2026-09-03, user-
provided `FPGA-DS-02012-3-4-ECP5-ECP5G-Family-Data-Sheet.pdf`)**: its §4.3.2
"LFE5U" Pin Information Summary table gives, for LFE5U-45 / 381caBGA, GPIO
counts per bank of 27/33/32/32/–/33/32/13 (banks 0/1/2/3/4/6/7/8) — this
matches the Trellis-derived counts used above **exactly on 6 of 7 relevant
banks**, off by exactly 1 ball on bank 3 (33 in Trellis's model vs 32 in the
datasheet, immaterial here since only 33 of that bank's balls were even
candidates and none of the 51 actually assigned came from the contested
one). Strong independent confirmation that using Trellis's device database
in place of the no-longer-available spreadsheet was the right call, not a
shortcut that introduced drift.

**What the datasheet does NOT have, confirmed by reading all of it (115
pages, §4 "Pinout Information" in full)**: any ball-by-ball table. §4.1 is
purely functional signal descriptions (no ball numbers at all) and §4.3 is
only the summary-count table quoted above — Lattice ships the actual
per-ball assignment as a separate resource (spreadsheet/pinout file, e.g.
the `.ods` originally referenced, or Diamond/Radiant's own device
database), not inside this PDF. This means the config-SPI (`PROGRAMN`,
`INITN`, `DONE`, `CCLK`, `CFG[2:0]` — the datasheet's "Miscellaneous
Dedicated Pins", counted at 7 for this package) and JTAG (`TCK`/`TMS`/
`TDI`/`TDO` — its "TAP", counted at 4) ball numbers are still not pinned
down to specific balls here.

**That gap does not block anything in this repo, though**: those pins are
dedicated/fixed-function silicon, not part of any user netlist — `rtl/
spi_neuron_top.v` has no TCK/TMS/TDI/TDO/PROGRAMN/etc. ports, so `nextpnr-
ecp5` never needs a `LOCATE` for them (confirmed by the 0-error run above,
which never mentions them) and no `.lpf` entry is possible or necessary for
them regardless. Their exact ball numbers only matter for **PCB schematic
capture** — routing a JTAG header connector and the SPI config-flash chip —
which is the user's own separate, in-progress KiCad work (untracked
`FPGA-Neural/` directory at the repo root), not an RTL/synthesis
deliverable. Downgraded accordingly in the checklist below.

**Placement rationale** (die-edge geometry from Trellis's `globals.json`,
confirmed by joining ball → (col,row) → bank): banks 2 (die col=90, row
11–32) and 3 (col=90, row 35–68) sit contiguously along the chip's **right**
edge — used together for the whole 44+1-signal PSRAM bus, exactly the "one
or two adjacent banks" the appendix asks for. Bank 7 (col=0, row 11–32, the
**left** edge, physically opposite the PSRAM bus) holds the application SPI
+ clock/reset, deliberately on the opposite side from PSRAM to keep the two
buses from crossing. `clk` is pinned to `H5` (`GR_PCLK7_0`), a dedicated
global-clock pad in bank 7. Plain (no dual-function) balls were preferred
first within each bank; where a bank ran out of plain balls (bank 2, for
part of `psram_dq`), the next-best dual-function ball was used as ordinary
GPIO — flagged individually below, and confirmed by the actual nextpnr run
above to be perfectly usable as such (including the one `VREF1_2` ball).

`psram_a[22]` is a real synthesized port bit (`ADDR_WIDTH`=23 sizes the
*byte* address everywhere in this design) that is always 0 in practice — see
§3: `int8_memory_access.v` shifts the byte address right by 1 before it
reaches the PSRAM, so only 22 bits (`psram_a[21:0]`) ever carry real
address information, matching the chip's actual 4M-word (2²²) capacity. It
still needs a physical pin for the tool, given a spare ball, and is a
no-connect on the actual board.

**Clock / reset:**

| Signal | Ball | Bank | Note |
|---|---|---|---|
| `clk` | H5 | 7 | `GR_PCLK7_0` — dedicated global clock pad |
| `rst` | B4 | 7 |  |

**Application SPI:**

| Signal | Ball | Bank | Note |
|---|---|---|---|
| `cs_n` | B3 | 7 |  |
| `miso` | A3 | 7 |  |
| `mosi` | C5 | 7 |  |
| `sclk` | B5 | 7 |  |

**Host attention pins** (added 2026-09-03, active-low, level, driven
from already-registered sticky bits — see `rtl/spi_neuron_top.v` for
the exact rationale):

| Signal | Ball | Bank | Note |
|---|---|---|---|
| `data_ready_n` | C3 | 7 | low while a result is waiting to be read (mirrors STATUS.bit1, clear-on-STATUS-read) |
| `irq_n` | C4 | 7 | low while `graph_engine`'s load-time guard has tripped (mirrors STATUS.bit2 / §7 of the network-engine spec); clears only on RESET or a fresh graph `run_start`, NOT on a plain STATUS read |

**Flash subsystem — runtime SPI to the onboard W25Q128JV** (added
2026-09-04, Phases F1-F6, made fully independent in Phase F7 same day —
`rtl/spi_flash_master.v`, `WORKLOG.md`; all 4 signals ordinary GPIO,
generated the same additive way as every other row here, confirmed by
`git diff` against the pre-flash `.lpf` to leave every existing ball
unchanged):

| Signal | Ball | Bank | Note |
|---|---|---|---|
| `flash_cs_n` | E4 | 7 |  |
| `flash_miso` | D5 | 7 |  |
| `flash_mosi` | D3 | 7 |  |
| `flash_sclk` | E3 | 7 | added Phase F7 — see below |

**Phase F7 (2026-09-04): `flash_sclk` is now a real, independent GPIO
ball, not a CCLK/`USRMCLK` reuse.** An earlier version drove SCLK
through the ECP5 `USRMCLK` primitive, reclaiming the same physical CCLK
net already used for bitstream boot, to save one pin. Dropped: it made
the "exclusive flash bus" claim electrically misleading (SCLK still
depended on the config engine's own pad) and carried an unresolved
verification gap (`USRMCLKTS` pad-enable timing never checked against
the primary Lattice sysCONFIG Usage Guide, FPGA-TN-02039, absent from
this project's document set). Re-synthesized full system: `USRMCLK`
utilisation now 0/1 (0%), directly confirming the primitive is no
longer used at all. See §6/§9 for the board-level wiring implication
(the flash chip's DI/DO/CS/CLK pins must be dual-wired to both the
dedicated sysCONFIG pins and these 4 ordinary balls — a board-level
duplication inherent to using one physical chip for both boot and
runtime persistence, not something Phase F7 changed).

**PSRAM address:**

| Signal | Ball | Bank | Note |
|---|---|---|---|
| `psram_a[0]` | E16 | 2 |  |
| `psram_a[1]` | F16 | 2 |  |
| `psram_a[2]` | D18 | 2 |  |
| `psram_a[3]` | E17 | 2 |  |
| `psram_a[4]` | E18 | 2 |  |
| `psram_a[5]` | F18 | 2 |  |
| `psram_a[6]` | F17 | 2 |  |
| `psram_a[7]` | G16 | 2 |  |
| `psram_a[8]` | G18 | 2 |  |
| `psram_a[9]` | H16 | 2 |  |
| `psram_a[10]` | H17 | 2 |  |
| `psram_a[11]` | H18 | 2 |  |
| `psram_a[12]` | J16 | 2 |  |
| `psram_a[13]` | J17 | 2 |  |
| `psram_a[14]` | C20 | 2 |  |
| `psram_a[15]` | D19 | 2 |  |
| `psram_a[16]` | E19 | 2 |  |
| `psram_a[17]` | E20 | 2 |  |
| `psram_a[18]` | F19 | 2 |  |
| `psram_a[19]` | F20 | 2 |  |
| `psram_a[20]` | G20 | 2 |  |
| `psram_a[21]` | H20 | 2 |  |
| `psram_a[22]` | P18 | 3 | always 0 (23-bit byte `ADDR_WIDTH` / 22-bit real word address, §3) — NC on the board |

**PSRAM data:**

| Signal | Ball | Bank | Note |
|---|---|---|---|
| `psram_dq[0]` | K18 | 2 |  |
| `psram_dq[1]` | C18 | 2 | dual-function ball (URC_GPLL0T_IN), used here as plain GPIO |
| `psram_dq[2]` | D17 | 2 | dual-function ball (URC_GPLL0C_IN), used here as plain GPIO |
| `psram_dq[3]` | D20 | 2 | dual-function ball (VREF1_2), used here as plain GPIO |
| `psram_dq[4]` | G19 | 2 | dual-function ball (GR_PCLK2_1), used here as plain GPIO |
| `psram_dq[5]` | J18 | 2 | dual-function ball (GR_PCLK2_0), used here as plain GPIO |
| `psram_dq[6]` | J19 | 2 | dual-function ball (PCLKT2_1), used here as plain GPIO |
| `psram_dq[7]` | J20 | 2 | dual-function ball (PCLKT2_0), used here as plain GPIO |
| `psram_dq[8]` | K19 | 2 | dual-function ball (PCLKC2_1), used here as plain GPIO |
| `psram_dq[9]` | K20 | 2 | dual-function ball (PCLKC2_0), used here as plain GPIO |
| `psram_dq[10]` | L17 | 3 |  |
| `psram_dq[11]` | M18 | 3 |  |
| `psram_dq[12]` | M17 | 3 |  |
| `psram_dq[13]` | N16 | 3 |  |
| `psram_dq[14]` | N18 | 3 |  |
| `psram_dq[15]` | P17 | 3 |  |

**PSRAM control:**

| Signal | Ball | Bank | Note |
|---|---|---|---|
| `psram_ce_n` | N17 | 3 |  |
| `psram_lb_n` | T16 | 3 |  |
| `psram_oe_n` | R16 | 3 |  |
| `psram_ub_n` | N19 | 3 |  |
| `psram_we_n` | R17 | 3 |  |
| `psram_zz_n` | N20 | 3 |  |

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

- [x] `ADDR_WIDTH` set to 23 (full 8&nbsp;MB) across all RTL modules
      and testbenches, matching the recommended part's real capacity
      (2026-09-02) — see §3.
- [ ] If the fallback true-SRAM part in §3 is used instead (smaller
      density), decide whether to shrink `ADDR_WIDTH` back down to
      match it or keep 23 with the extra range simply unused.
- [x] Real `.lpf` pin assignment for `clk`/`rst`/application SPI/PSRAM
      (§7, `synth/ecp5/spi_neuron_top.lpf`), place&route-verified
      (2026-09-03) — 0 constraint errors; cross-checked against the
      real Lattice datasheet (§7, matches on 6/7 banks exactly). Fmax
      54.58&nbsp;MHz when this pinout was first verified, 75.30&nbsp;MHz
      after the `neuron_parallel` timing-closure work, 73.88&nbsp;MHz
      after adding the host-attention pins, 66.68&nbsp;MHz after adding
      the flash subsystem, and **67.91&nbsp;MHz** for the current full
      system after making the flash SPI bus fully independent (Phase F7,
      §7, 2026-09-04) — see §7 for the full history and why each change is
      pin-placement noise, not a regression.
      **Config-SPI and JTAG ball numbers are still not pinned down**
      (§7) — confirmed by reading the full real datasheet that it has
      no per-ball table at all (only functional descriptions and
      summary counts: TAP=4, misc dedicated=7 for this package), so
      the actual per-ball assignment remains a separate Lattice
      resource not available in this environment. **This does not
      block any RTL/synthesis work**: those are dedicated/fixed-
      function pins with no corresponding port in `rtl/spi_neuron_top.v`,
      so no `.lpf` entry is possible or needed for them, and every
      place&route run above already completes with 0 errors without
      them. They only matter for **PCB schematic capture** (JTAG
      header + config-flash routing) — the user's own separate,
      in-progress KiCad work, not something this repo's synthesis
      flow needs to resolve.
      **Distinct from this open item** (do not conflate the two): the
      flash subsystem's own runtime SPI pins (`flash_sclk`, `flash_mosi`,
      `flash_miso`, `flash_cs_n` — Phases F1-F6, made fully independent
      in Phase F7, `WORKLOG.md`) **are** real, pinned, place&route-
      verified ordinary GPIO on bank 7 (`flash_sclk`=E3, `flash_mosi`=D3,
      `flash_miso`=D5, `flash_cs_n`=E4), generated the same way as every
      other signal in this table — **no pin shared with any ECP5 config
      primitive** (Phase F7 removed the earlier `USRMCLK`/CCLK reuse for
      SCLK; `USRMCLK` utilisation in the current full-system synthesis
      is 0/1, confirming it). §5's PCB-level implication: the
      W25Q128JV's DI/DO/CS/CLK pins must be wired to *both* the dedicated
      sysCONFIG pins (for boot) *and* these 4 ordinary GPIO balls (for
      runtime access after configuration completes) — a board-level
      duplication inherent to using one physical chip for both roles,
      not yet reflected in a schematic since none exists yet (see the
      KiCad item below).
- [ ] Confirm PSRAM/SPI signal integrity at whatever clock is
      actually fitted (§4) — no signal integrity analysis done yet
- [ ] JTAG header footprint choice (blocked on the JTAG ball question
      above)
- [ ] KiCad (or other) schematic capture — none exists yet for this
      device/package combination
