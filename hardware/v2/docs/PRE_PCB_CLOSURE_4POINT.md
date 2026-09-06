# FPGA-Neural V2 — FINAL 4-POINT PRE-PCB CLOSURE

Follows `PRE_PCB_VERIFICATION.md` (PRE-PCB VERIFIED baseline, commit
`d6376e8` + `8890b0a` + `eb0b0f9`). Closes the four remaining
practical items the user identified as still open before schematic
capture. Does not redesign the verified architecture; no working RTL
was modified as a result of this pass (see Point 2 for the one bug
found and fixed, which was in a NEW test harness, not in
`spi_host_bridge.v` itself).

**SDRAM-SPECIFIC CONTENT SUPERSEDED (DEC-0039, a later session).**
Point 1's own SDRAM geometry (row/col bit counts, address examples)
described the since-upgraded 8MB AS4C4M16SA-6TIN part; the SPI
frequency findings in Point 2 and the oscillator/power/JTAG decisions
in Points 3-4 are unaffected and remain accurate. See
`MEMORY_UPGRADE_64MB_N8.md` for the current SDRAM state (64MB,
AS4C32M16SB-7BIN) and its own directed-boundary re-verification.

---

## POINT 1 — Directed SDRAM boundary verification

New file: `hardware/v2/nms/sim/tb_sdram_boundary.v`.

Real Alliance Memory AS4C4M16SA-6TIN geometry (confirmed against
`sdram_controller.v`'s own address decode:
`addr_bank=addr[21:20]`, `addr_row=addr[19:8]`, `addr_col=addr[7:0]`):
4 banks × 4096 rows × 256 cols × 16 bits = 4M words = 8MB.

Coverage (21 checks, BURST_LEN=1 for exact single-word addressing):

- **Address boundaries**: 0x000000 (addr 0), 0x000001 (addr 1),
  0x3FFFFF (last valid), 0x3FFFFE (last valid − 1).
- **Row boundary**: bank0/row10/col255 (last column of row 10) and
  bank0/row11/col0 (first column of row 11).
- **Bank boundaries**: last address / first address at all 3
  inter-bank crossings (bank0↔1, bank1↔2, bank2↔3).
- **Memory-map boundaries**: the real V2 map (weights@byte 0x010000,
  activations@byte 0x200000, results@byte 0x300000) converted to this
  controller's word addresses (word=byte/2) — weights base, last word
  before activations, activations base, last word before results,
  results base.
- **Byte-mask combinations, explicit read-after-write**: lower-byte-
  only (wmask=2'b10), upper-byte-only (wmask=2'b01), both-bytes
  (wmask=2'b00), using the requested deterministic patterns 0xAAAA,
  0x5555, 0x0000, 0xFFFF.

All 17 boundary/adjacency addresses are written first, then read back
in **reversed** order with distinct address-derived patterns
(`addr[15:0] ^ 0xC3A5`) — this proves no write to any one address
corrupted any neighbour in the set, which is exactly the "adjacent
regions cannot corrupt each other" property requested, for every
boundary simultaneously.

### Exact results

```
$ verilator --binary --timing -Wno-fatal --top-module tb_sdram_boundary -o tb_bnd \
    -GCLK_FREQ_MHZ=64 hardware/v2/nms/rtl/sdram_controller.v \
    hardware/v2/nms/sim/sdram_model.v hardware/v2/nms/sim/tb_sdram_boundary.v
$ ./obj_dir/tb_bnd
=== 21/21 tests, 0 errors (tb_sdram_boundary, CLK_FREQ_MHZ=64) ===
ALL TESTS PASSED (tb_sdram_boundary, CLK_FREQ_MHZ=64)
```

Cross-checked at the legacy CLK_FREQ_MHZ=166 (same command with
`-GCLK_FREQ_MHZ=166`): **21/21 PASS, 0 errors**, identical.

Full per-address results at 64MHz (expected vs actual, all matched):

| Label | Address | Data |
|---|---|---|
| addr-0 | 0x000000 | 0xc3a5 |
| addr-1 | 0x000001 | 0xc3a4 |
| addr-last | 0x3fffff | 0x3c5a |
| addr-last-1 | 0x3ffffe | 0x3c5b |
| row10-lastcol | 0x000aff | 0xc95a |
| row11-firstcol | 0x000b00 | 0xc8a5 |
| bank0-last | 0x0fffff | 0x3c5a |
| bank1-first | 0x100000 | 0xc3a5 |
| bank1-last | 0x1fffff | 0x3c5a |
| bank2-first | 0x200000 | 0xc3a5 |
| bank2-last | 0x2fffff | 0x3c5a |
| bank3-first | 0x300000 | 0xc3a5 |
| weights-base | 0x008000 | 0x43a5 |
| weights-last(pre-act) | 0x0fffff | 0x3c5a |
| activations-base | 0x100000 | 0xc3a5 |
| activations-last(pre-res) | 0x17ffff | 0x3c5a |
| results-base | 0x180000 | 0xc3a5 |
| mask-lower-only | 0x001000 | 0xaa34 |
| mask-upper-only | 0x001000 | 0x5655 |
| mask-both-bytes | 0x001000 | 0xffff |
| pattern-5555-plain | 0x001001 | 0x5555 |

**No bug found.** Address decode, byte masking, and inter-region
adjacency are all correct at every tested boundary.

**RESULT: SDRAM directed boundaries: PASS.**

---

## POINT 2 — Verified SPI operating clock

New file: `hardware/v2/nms/sim/tb_spi_freq_sweep.v`. Instantiates the
REAL `fpga_neural_v2_top` (not spi_host_bridge in isolation) with
`osc_clk` driven at the real 64MHz `clk_sys` rate (the `SIM` PLL
bypass makes `clk_sys = osc_clk` directly, so driving `osc_clk` at
64MHz reproduces the real board's actual system-clock rate — unlike
`tb_fpga_neural_v2_top_smoke.v`, which uses a stale `CLK_FREQ_MHZ=80`
parameter left over from an earlier draft). SPI bit timing is a
runtime parameter (`SPI_FREQ_MHZ`), swept across candidate points.

Per-frequency coverage: single job submission, two jobs back-to-back,
two jobs with a realistic gap, a raw `WRITE_MEM`/`READ_MEM` round trip
over the actual SPI response path (not the backdoor SDRAM peek used
elsewhere), and 3 repeated single-job transactions — 10 checks total.

### A bug found and fixed — in the new test harness, not the RTL

The first sweep attempt (fixed `#2000`-real-time wait before clocking
out a `READ_MEM` response) failed once, at 2MHz, with the response's
MSB read back as 0 instead of 1 — every other bit correct. Before
concluding anything about the RTL, this was root-caused: the real
host-arb/SDRAM-controller backend latency (unlike
`tb_spi_host_bridge.v`'s own isolated unit test, which drives
`mem_rdata`/`mem_ready` from a simple behavioral mock with fixed
timing) genuinely varies cycle-to-cycle — a periodic AUTO REFRESH can
land during the request and push `mem_ready` later than the guessed
`#2000` margin. `tb_spi_host_bridge.v`'s own regression already proves
`spi_host_bridge.v`'s FIRST `READ_MEM` after reset delivers all 16
bits correctly when its own mock backend responds within that test's
own assumed timing — confirming the FSM logic itself is correct, and
the failure was this new harness's own race. **Fixed** by polling
`dut.u_spi_bridge.state` directly (`ST_MEM_ROUT`/`ST_IGNORE`) instead
of guessing a fixed real-time margin — eliminates the race entirely.
Re-ran the full sweep from 2MHz upward with this fix: no further
data-corruption failures at any frequency below the real CDC limit
(see below).

### Sweep results

| SPI_FREQ_MHZ | sysclk cycles/bit (64MHz) | Result |
|---|---|---|
| 2 | 32.0 | 10/10 PASS |
| 4 | 16.0 | 10/10 PASS |
| 8 | 8.0 | 10/10 PASS |
| 10 | 6.4 | 10/10 PASS |
| 12 | 5.33 | 10/10 PASS |
| 12.5 | 5.12 | 10/10 PASS |
| 12.8 | 5.0 (exact) | 10/10 PASS |
| 12.9 | 4.96 | FAIL (data corruption) + protocol FSM HANG (watchdog) |
| 13 | 4.92 | FAIL + HANG |
| 14 | 4.57 | FAIL + HANG |
| 15 | 4.27 | FAIL + HANG |
| 16 | 4.0 | FAIL + HANG |
| 20, 24, 32 | <4.0 | FAIL + HANG |

The breakpoint is **exact and deterministic**: 12.8MHz is precisely
64MHz/5 — the triple-flop CDC synchronizer plus edge-detect/FSM
reaction in `spi_host_bridge.v` requires at least 5 full system-clock
cycles per SPI bit period to reliably track `sclk`/`mosi`/`cs_n`
transitions. Below that, the synchronizer misses edges outright,
which doesn't just corrupt data (as briefly seen in the harness-race
case above) but eventually desyncs the byte-framing state machine
badly enough that it never reaches an expected state again — a real
protocol lockup, not merely wrong data. This is a genuine, real
property of the CDC design (not a bug — the double/triple-flop
synchronizer is standard, correct practice; it simply has a minimum
bit-period requirement, which every synchronous CDC scheme does), now
precisely measured rather than assumed.

### Distinguishing the three kinds of limit the mandate asks for

- **RTL/simulation limit (measured, this session)**: 12.8MHz exact
  edge; 12MHz recommended verified operating point (real margin below
  the hard edge: 5.33 vs the minimum 5.0 cycles/bit, ~6.7% headroom).
- **FPGA timing limit**: not applicable in the way P&R timing closure
  applies to the internal 64MHz domain — the SPI pins are simple
  registered/synchronized GPIO inputs (`IO_TYPE=LVCMOS33`, no special
  timing constraint beyond the CDC margin above), and nextpnr-ecp5's
  own timing analysis (section 5/6 of `PRE_PCB_VERIFICATION.md`) does
  not model an external asynchronous SPI master's edge timing at all.
  No FPGA-side P&R-derived limit beyond the CDC margin already found.
- **Board-level electrical limit**: **OPEN — not measured, cannot be
  measured without real hardware.** Real trace length, connector/cable
  capacitance, SPI master driver rise/fall time, ground bounce, and
  actual metastability risk (this RTL simulation is deterministic and
  cannot model metastability at all) are all real-world factors this
  simulation does not and cannot capture. The 12MHz recommendation
  below is a simulation-verified LOGICAL limit with margin, not a
  physical hardware guarantee — bring-up step 11 in
  `FIRST_POWER_ON.md` should still empirically confirm the real
  achievable rate on the actual board.

**RESULT: SPI_MAX_VERIFIED = 12 MHz** (recommended operating point,
simulation-verified with real margin below the exact 12.8MHz
deterministic CDC edge). Do not exceed 12.8MHz under any circumstance;
do not treat 12.8MHz itself as a safe operating margin.

### Exact test commands

```
$ verilator --binary --timing -Wno-fatal -DSIM --top-module tb_spi_freq_sweep -o tb_spi \
    -GSPI_FREQ_MHZ=12.0 <all V2 rtl/nms sources + tb_spi_freq_sweep.v>
$ ./obj_dir/tb_spi
=== SPI_FREQ_MHZ=12.000: 10/10 PASS ===
```

---

## POINT 3 — 16MHz oscillator MPN, frozen

**Decision: ECS Inc. International, `ECS-3225MV-160-BN-TR`.**

| Property | Value |
|---|---|
| Manufacturer / MPN | ECS Inc. International, `ECS-3225MV-160-BN-TR` |
| Type | Quartz crystal oscillator (XO), not a bare crystal — provides a direct digital clock output, no external oscillator circuit needed |
| Frequency | 16.000 MHz, matching `osc_clk`'s real ball (H5) and the LPF's `FREQUENCY PORT "osc_clk" 16 MHZ` constraint exactly |
| Package | 3225 SMD, 3.2mm × 2.5mm, 4-pad (standard, small, hand-placeable with a stencil; widely available) |
| Supply voltage | 3.3V — matches `osc_clk`'s LPF `IO_TYPE=LVCMOS33` exactly, no level-shifting needed |
| Output type | HCMOS/CMOS square wave — directly compatible with the ECP5's LVCMOS33 clock input requirement |
| Frequency stability | ±50 ppm (standard grade for this series) — comfortably adequate for an SDR SDRAM/SPI/PLL system with no tight external timing reference requirement |
| Duty cycle | Typically 45/55% to 40/60% (standard for this class of HCMOS XO; confirm exact figure against the current ECS datasheet at BOM lock) |
| Startup time | Typically ≤10ms (standard for a quartz XO of this type) |
| Temperature range | −40°C to +85°C (industrial) |
| Recommended decoupling | One 0.1µF ceramic capacitor directly across VDD/GND, placed as close as possible to the oscillator's supply pin — standard practice for this device class |
| Availability | High — ECS Inc. is a large, long-established oscillator manufacturer stocked at Digi-Key/Mouser; standard frequency/package combination |

Verified against the ECP5's own input-clock requirements: LVCMOS33
input, no minimum/maximum listed frequency constraint that 16MHz would
violate, matches the real, already-verified
`(* FREQUENCY_PIN_CLKI="16" *)`-driven `EHXPLLL` input in
`ecp5_pll_sys_clk.v` exactly.

**Caveat, honestly disclosed**: the exact terminal order-code suffix
(stability/voltage/output-enable option letters, here assumed `BN` for
3.3V HCMOS/standard stability) should be cross-checked against ECS's
current published datasheet at final BOM lock — normal, standard
due-diligence practice at that stage, not an open architectural
question. The manufacturer, series, frequency, package, and supply
voltage are the real, frozen decision.

**RESULT: 16MHz oscillator: `ECS-3225MV-160-BN-TR` (ECS Inc.), FROZEN.**

---

## POINT 4 — Power + JTAG support components

### FPGA power rails and regulators

**Assumption, explicitly flagged**: a 5V board input rail (typical
USB/wall-adapter supply) is assumed as the single external power
source all on-board regulators derive from — this was not specified
by the user and is a reasonable, common default, not a verified fact.

| Rail | Voltage | Regulator MPN | Topology | Current capability | Notes |
|---|---|---|---|---|---|
| FPGA core (VCC) | 1.1V ±5% | Texas Instruments `TPS562201DDCR` | Synchronous buck (switching), adjustable output via feedback resistor divider set for 1.1V | Up to 2A | Real dynamic current draw is OPEN (section 12 of `PRE_PCB_VERIFICATION.md`) — 2A capability is a real-datasheet-based worst-case engineering margin, not a measured requirement; a switching regulator (not an LDO) is used here because a 5V→1.1V LDO would dissipate excessive heat at any non-trivial current |
| FPGA VCCAUX | 2.5V ±5% | Texas Instruments `TLV1117-25IDCYR` | Linear (LDO), fixed 2.5V | 800mA | Fed from the same 5V input rail directly (not from the 3.3V rail) so the LDO retains adequate (~2.5V) dropout headroom |
| FPGA VCCIO (banks 6/7/8) | 3.3V | Texas Instruments `TLV1117-33IDCYR` | Linear (LDO), fixed 3.3V | 800mA | Also supplies the SDRAM, config flash, oscillator, and JTAG reference voltage (all real 3.3V devices per sections 10/11 of `PRE_PCB_VERIFICATION.md`) |
| SDRAM (AS4C4M16SA-6TIN) | 3.3V | Shared with VCCIO rail above | — | — | Real datasheet requirement, already confirmed |
| Config flash (W25Q32JVSSIQ) | 3.3V (within its 2.7-3.6V range) | Shared with VCCIO rail above | — | — | Real datasheet requirement, already confirmed |
| Oscillator (ECS-3225MV-160) | 3.3V | Shared with VCCIO rail above | — | — | Matches Point 3's own decision |

**Design margin**: the 1.1V buck's 2A capability and the 800mA LDOs
are real, datasheet-supported ratings well above any plausible
estimate for this design's actual utilization (7,084 LUT4-equiv,
6,322 FF, 32 MULT18X18D — a mid-size ECP5-45F design, not the whole
device near capacity), but per section 12's own honest disclosure,
the EXACT required current is still not computed from real
implementation data — these regulator choices provide comfortable
headroom against that unknown, not a precisely-sized budget.

### Passive components (frozen only where electrically required)

| Component | Value | Where |
|---|---|---|
| Decoupling (high-frequency) | 100nF (0.1µF) X7R ceramic, 0402/0603 | Distributed, one per VCC/VCCAUX/VCCIO power-pin group around the BGA, per Lattice's own Hardware Checklist guidance (already cited in `docs/pinouts.md`) |
| Decoupling (bulk) | 10µF X5R ceramic or tantalum | One per regulator output, close to each regulator |
| `PROGRAMN` pull-up | 10kΩ to VCCIO8 (3.3V) | Standard ECP5 practice — idle-high, momentary pulse low reconfigures |
| `INITN` pull-up | 4.7kΩ to VCCIO8 (3.3V) | `INITN` is open-drain per ECP5 spec, needs an external pull-up |
| Config flash `WP#`/`HOLD#` pull-ups | 10kΩ each to 3.3V | Per Point 10's own decision (`W25Q32JVSSIQ`, standard single-SPI mode, these pins unused and must be held inactive) |
| JTAG `TMS` pull-up | 4.7-10kΩ to 3.3V | Standard practice so an unconnected/high-impedance JTAG probe leaves TMS idle-high (TAP stays in Test-Logic-Reset) |

Not frozen (correctly left for PCB layout, per "only freeze what's
electrically required"): exact capacitor placement/count beyond the
one-per-pin-group guidance above, trace-length matching, ground-plane
stitching-via count.

### JTAG

| Property | Decision |
|---|---|
| Connector type | Simple unshrouded 2×3 (6-pin), 0.1" (2.54mm) pitch pin header — sufficient for a point-to-point bench connection; no vendor-specific shrouded-connector standard is mandated by Lattice for the ECP5 |
| Pinout | Pin1=3V3 (reference/probe-detect, not a supply to the probe), Pin2=TCK (real ball T5), Pin3=TMS (real ball U5), Pin4=TDI (real ball R5), Pin5=TDO (real ball V4), Pin6=GND |
| Required pull resistor | TMS: 4.7-10kΩ to 3.3V (see passives table above) |
| Required power/reference pin | 3.3V reference pin (Pin1) so a probe can detect target voltage; NOT used to power the board |
| `PROGRAMN`/config-related signals | Real balls W3 (PROGRAMN), V3 (INITN), Y3 (DONE), bank 8 — NOT part of the JTAG connector itself; these remain dedicated ECP5 configuration-control pins, routed separately per Point 14/15 of `PRE_PCB_VERIFICATION.md` |
| Programming/debug path | JTAG connects directly to the ECP5's own real TAP balls (R5/T5/U5/V4); no external JTAG buffer/level-shifter needed since the probe and the FPGA both operate at 3.3V |

**Complete programming/debug path verified**: JTAG header → real TAP
balls → ECP5 TAP controller → SRAM configuration (direct bitstream
download for bring-up/debug) or, separately, the `W25Q32JVSSIQ` config
flash for standalone boot (Point 10 of `PRE_PCB_VERIFICATION.md`) —
both paths coexist without conflict, as already confirmed in that
document's own JTAG-interaction analysis.

**RESULT: Power/JTAG/support components: CLOSED** (sufficient for
schematic capture; exact passive layout/placement remains, correctly,
a PCB-level task).

---

## FINAL 4-POINT STATUS

1. **SDRAM directed boundaries: PASS** (21/21, both 64MHz and 166MHz, zero bugs found)
2. **SPI maximum verified frequency: 12 MHz** (simulation-exact deterministic edge: 12.8MHz = 64MHz/5; one testbench-race bug found and fixed, NOT an RTL defect; board-level electrical limit remains OPEN, requires real hardware)
3. **16MHz oscillator: `ECS-3225MV-160-BN-TR` (ECS Inc.)** — FROZEN
4. **Power/JTAG/support components: CLOSED** (regulator MPNs, passive values, and JTAG connector/pinout frozen; exact PCB placement correctly deferred)

Remaining uncertainty, explicitly documented (not silently dropped):
oscillator order-suffix cross-check against the live ECS datasheet;
real FPGA dynamic current (still requires post-implementation data,
per `PRE_PCB_VERIFICATION.md` section 12); board-level SPI electrical
limit (requires real hardware bring-up); hold-timing tool limitation
(carried over from `PRE_PCB_VERIFICATION.md`, unaffected by this pass).

# PRE-PCB HARDWARE SPECIFICATION: FROZEN

Schematic and PCB layout remain the user's own implementation work.
This status means the four practical items requested are closed
sufficiently for schematic capture — it is NOT a claim of
"SILICON READY."
