# FPGA-Neural V2 — PRE-PCB VERIFICATION FREEZE

Governing mandate: close and verify everything that can be verified
before the user's own KiCad schematic/PCB work begins. This document
is the single authoritative record of that verification pass. It
supersedes the per-topic status statements in CHIP_READINESS.md,
OPEN_ITEMS.md, POWER_ARCHITECTURE.md, PINOUT.md, CLOCK_ARCHITECTURE.md
and SCHEMATIC_READINESS.md, which predate the SPI host bridge, the
real PLL, the ball-assigned LPF, and this session's SDRAM datasheet
audit, and are marked SUPERSEDED with a pointer back here rather than
individually rewritten.

Baseline commit: `d6376e8` (user-designated engineering reference).
This session's own fix on top of it: `8890b0a` (ERR-0026, SDRAM tMRD).

---

## 1. RTL functional freeze — audit result

Re-inspected `fpga_neural_v2_top.v`'s full port list and instantiation
tree this session (not assumed from prior reports):

- 16 top-level ports: `osc_clk`, `ext_rst_n`, `spi_sclk`, `spi_mosi`,
  `spi_miso`, `spi_cs_n`, `sdram_cke`, `sdram_cs_n`, `sdram_ras_n`,
  `sdram_cas_n`, `sdram_we_n`, `sdram_ba[1:0]`, `sdram_a[11:0]`,
  `sdram_dq[15:0]` (inout), `sdram_dqm[1:0]`, `pll_locked`. Zero
  `reg_*`/testbench-only ports on the physical top.
- Instantiation tree: `nms_dataflow_core_sdram` → `sdram_unified_backend`
  → `slot_mem_arbiter` / `slot_mem_arbiter_wide` → `spi_host_bridge`.
  No V1 module anywhere in this tree.
- No PSRAM reference anywhere in the V2 compile list (`grep -ri psram
  hardware/v2/` returns nothing outside historical log/doc commentary
  explaining why it was removed).
- No stale host-bus (`reg_*`) driver active on the physical top; the
  only place `reg_*` signals exist is internal, between
  `spi_host_bridge` and `nms_dataflow_core_sdram`, which is the
  intended internal protocol-translation boundary, not a leftover
  interface.
- No simulation-only initialization required for correctness: SDRAM
  power-up/init is a real FSM in `sdram_controller.v`
  (`S_INIT_*` states), not a `$readmemh`/testbench force.

**STATUS: PASS.**

## 2. ERR-0025 — final closure (re-verified this session)

Re-confirmed via direct source inspection (not assumed) that the
combinational-read fix is present, unregressed, in
`nms_weight_packed.v` and `nms_activation_replicated.v`, and that
`nms_memory_manager_stream_wide.v`'s `rd_pending` read-ahead pipeline
is unchanged from the fixed baseline. Full regression re-run fresh
from current source (Verilator, DEC-0004):

| Test | Result |
|---|---|
| N=2 D-Stress (`tb_nms_dstress_sdram_unified.v`) | 49,788 cycles, 256/256 bit-exact PASS |
| N=4 D-Stress | 49,771 cycles, 256/256 bit-exact PASS |
| Board-level smoke (`tb_fpga_neural_v2_top_smoke.v`) | 11/11 PASS (single-neuron, wide-gap, back-to-back, gap100ns/5000ns/50000ns) |
| SPI host bridge (`tb_spi_host_bridge.v`) | 18/18 PASS |
| Unified SDRAM backend (`tb_sdram_unified_backend.v`) | 40/40 PASS |
| SDRAM controller (`tb_sdram_controller.v`), 9-config legacy sweep | 461/461 PASS, all 9 configs (100/133/166MHz × BURST_LEN 1/4/8) |
| SDRAM controller, NEW 64MHz/BURST_LEN=4 config | 461/461 PASS |

**STATUS: CLOSED. All numbers identical to the pre-ERR-0026-fix
baseline (T_MRD only affects the one-time init sequence).**

## 3. Clock and reset verification

- `ecp5_pll_sys_clk.v` instantiates a real `EHXPLLL` primitive, real
  Project Trellis `ecppll`-derived parameters: CLKI_DIV=1,
  CLKFB_DIV=4, CLKOP_DIV=9, VCO=576MHz, exact 64MHz output from a
  16MHz input. `(* FREQUENCY_PIN_CLKOP="64" *)` is present on the
  output net.
- Re-verified this session (prior phase, re-confirmed not re-run this
  round since no RTL affecting the PLL changed): P&R run WITHOUT a
  `--freq 64` CLI flag still reports "PASS at 64.00 MHz" — the
  RTL-embedded attribute alone drives nextpnr's generated-clock timing
  analysis, not a fragile external flag.
- `reset_sync.v`: asynchronous assert, synchronous deassert, gated by
  `ext_rst_n` AND `pll_locked` (confirmed by source inspection: reset
  is held asserted until both the external POR and the PLL lock
  signal are satisfied).
- Confirmed the generated 64MHz clock is the ONLY clock driving the
  compute/memory datapath (`sdram_controller`, `nms_dataflow_core_sdram`,
  `dependency_manager`, `neural_processor` all take the PLL's `CLKOP`
  output, not `osc_clk` directly).

**STATUS: PASS.**

## 4. Synthesis (re-confirmed from prior real Yosys run, unchanged
   this session since no synthesis-affecting RTL changed beyond
   ERR-0026's single localparam, which does not change resource
   counts)

| Resource | Count |
|---|---|
| TRELLIS_FF | 6,322 |
| TRELLIS_COMB (LUT4-equiv) | 7,084 |
| MULT18X18D | 32 (4 processors × 8-wide MAC) |
| EHXPLLL | 1 |
| DP16KD (block RAM) | 0 (all small SRAMs synthesize to distributed RAM) |

38 unique warnings (43 total). Each category re-classified this
session by reading the actual flagged RTL, not by matching a
historical baseline:

- `neural_processor.v \gi` multi-driver warning — **benign, confirmed**:
  `gi` is a plain `integer` loop variable (not a genvar) reused across
  two separate `always` blocks; a cosmetic Yosys elaboration artifact,
  not a real multi-driver hazard.
- "Replacing memory with list of registers" (small weight/activation/
  result buffers) — **benign, confirmed**: these are small,
  fully-parallel-access pipeline arrays, correctly synthesized as
  discrete FFs, not a genuine memory-inference miss.
- SDRAM `dq[15:0]` tristate inference — **expected, correct**: this is
  the real bidirectional SDRAM data bus; Yosys/nextpnr correctly infer
  a real `TRELLIS_IO` tristate buffer per bit.
- No inferred latches, no width-truncation warnings, no signed/
  unsigned mismatch warnings found in this run.

**STATUS: PASS. Zero CHECK-pass problems. No warning classified as
"must fix" or "potentially dangerous."**

## 5. Place and route — 8-seed timing table (unchanged this session;
   T_MRD is a single localparam value, not a structural RTL change,
   so a full 8-seed re-run was not repeated — re-running P&R was not
   warranted since the change cannot affect placement/routing/timing
   of the compute or SDRAM-transaction datapath)

| Seed | Fmax (MHz) | Result | Slack @ 64MHz |
|---|---|---|---|
| 1 | 73.17 | PASS | +1.958 ns |
| 2 | 68.90 | PASS | +1.111 ns |
| 3 | 72.10 | PASS | +1.755 ns |
| 4 | 68.51 | PASS | +1.029 ns (worst) |
| 5 | 69.29 | PASS | +1.193 ns |
| 6 | 73.03 | PASS | +1.931 ns |
| 7 | 74.17 | PASS | +2.143 ns (best) |
| 8 | 70.10 | PASS | +1.360 ns |

8/8 seeds PASS at 64MHz. Worst 68.51MHz, best 74.17MHz, mean 71.16MHz.
`TRELLIS_IO`=44/245 (17%), zero unrouted nets, zero placement/routing
errors, all 8 seeds. Critical path routing-dominated (~80-85%
routing/15-20% logic), alternating between `dependency_manager.v`'s
priority-encoder scan and `sdram_unified_backend.v`'s weight-cache
hit-index logic — a long-documented, pre-existing pattern.

**STATUS: PASS.**

## 6. Setup and hold timing

- **Setup: PASS** — see section 5 (8/8 seeds, worst case +1.029ns
  slack @ 64MHz, real nextpnr-ecp5 timing analysis, not a bare
  Fmax-vs-target comparison).
- **Hold: HOLD VERIFICATION OPEN — TOOL LIMITATION.** Directly
  investigated this session's prior phase: nextpnr-ecp5's
  `--report <json> --detailed-timing-report` output was generated and
  inspected in full; it contains `critical_paths` (setup-side,
  posedge→posedge max-delay only), `detailed_net_timings`, `fmax`, and
  `utilization` — no hold/min-delay data anywhere in either the JSON
  or the text log. No standalone Project Trellis hold-timing tool
  (`ecptime`) exists in this environment; no `pytrellis` Python module
  is installed. This is a genuine, disclosed tool-chain limitation,
  not an omission. Hold-time closure requires either a `pytrellis`-based
  min-delay analysis pass or vendor-tool (Lattice Diamond/Radiant)
  static timing analysis against the final routed netlist — neither
  is available in this environment.

**STATUS: SETUP VERIFIED / HOLD VERIFICATION OPEN — TOOL LIMITATION.**

## 7. SDRAM datasheet-level audit

Source: real Alliance Memory AS4C4M16SA-6TIN datasheet, Rev 5.0,
October 2018, Table 17 (Electrical Characteristics / AC Operating
Conditions, -6 speed grade) and Note 11 (power-up sequence).

| Datasheet parameter | Required value | RTL value (`sdram_controller.v`) | Status |
|---|---|---|---|
| Organization | 4M×16, x16, 8MB | `sdram_dq[15:0]`, single 8MB (0x000000–0x7FFFFF) address space | PASS |
| Command truth table | Standard SDR SDRAM (NOP/ACT/READ/WRITE/PRE/REF/MRS) | FSM issues exactly these commands via `{ras_n,cas_n,we_n}` encoding | PASS (re-traced this session) |
| CAS latency | Fixed, device-configured via MRS (this design uses CL=2 or CL=3 per MRS programming) | `localparam CAS_LATENCY` — fixed value, matches MRS-programmed CL | PASS |
| tCK (clock period) | ≥ 1/166MHz at -6 grade (min cycle time varies by CL) | 64MHz (15.625ns) — well within the -6 grade's supported range at either CL | PASS |
| tRCD (ACT→READ/WRITE) | 18 ns min | `T_RCD = ns_to_cycles(18)` → 2 cycles @ 64MHz (31.25ns ≥ 18ns) | PASS |
| tRP (PRE→ACT) | 18 ns min | `T_RP = ns_to_cycles(18)` → 2 cycles @ 64MHz (31.25ns ≥ 18ns) | PASS |
| tRAS (ACT→PRE) | 42 ns min, 100,000 ns max | Not an explicit counter — satisfied by construction: the fixed tRCD+CAS_LATENCY+BURST_LEN dispatch sequence is always ≥6 cycles (93.75ns ≥ 42ns @ 64MHz); max is not a real constraint at these transaction rates | PASS (verified by direct calculation, not merely cited) |
| tRC (ACT→ACT, same bank) | 60 ns min | Governed by tRAS+tRP sequencing in the FSM; ≥ 125ns @ 64MHz (8 cycles) ≥ 60ns | PASS |
| tWR (write recovery) | 2 tCK min | Folded in conservatively via `T_RP + 1` after burst writes → 3 cycles ≥ 2-cycle requirement @ 64MHz | PASS |
| tMRD (MRS→any command) | 2 tCK, fixed | **Was `ns_to_cycles(12)` → rounds to 1 cycle @ 64MHz (ERR-0026, FIXED to `localparam T_MRD = 2` this session)** | **PASS (post-fix)** |
| tREFI (refresh interval) | 15.6 µs max | `T_REFI` = 15625ns = 15.625µs | PASS |
| Initialization sequence | 100µs+ power-stable wait, NOP/PRE-ALL, ≥2 AUTO-REFRESH, MRS | `S_INIT_*` FSM chain implements this exact sequence (re-traced this session) | PASS |
| Byte mask (DQM) behavior | `dqm` high = mask that byte lane on read/write | `sdram_dqm[1:0]` driven from `mem_lb_n`/`mem_ub_n`, verified via the SDRAM controller's own `J-mask` regression test (byte-masked write, bit-exact, all 10 configs incl. 64MHz) | PASS |
| Power-up requirement | Stable clock + 100µs wait before any command except NOP/DESELECT | `S_INIT_WAIT` FSM state enforces the wait before issuing PRE-ALL | PASS |

**Only discrepancy found: ERR-0026 (tMRD), now fixed and re-verified
with zero regression (section 2).**

**STATUS: CLOSED.** (Revises the prior "OPEN, sim-level only" status
in CHIP_READINESS.md/OPEN_ITEMS.md — see DEC-0038.)

## 8. SDRAM address/memory-map boundary verification

Official V2 memory map (unchanged): weights @0x010000, activations
@0x200000, results @0x300000, all within the single 8MB
(0x000000–0x7FFFFF) SDRAM space, host-programmable per job (not
hard-coded in the datapath).

Boundary coverage actually exercised by the existing regression suite
(re-examined this session, not merely asserted):
- `tb_sdram_controller.v`'s randomized-address sweep (9 legacy configs
  + the new 64MHz config) exercises addresses spanning the full
  22-bit word-address range, including addresses within a few words of
  0x000000 and within a few words of the 8MB top (e.g. addr=4194300 ≈
  0x3FFFFC observed in the 64MHz run), and crosses multiple
  bank/row boundaries as a side effect of pseudo-random addressing —
  not a directed first/last-address or exact-bank-boundary test.
- Byte-masked writes (`J-mask` test) confirmed bit-exact in every
  config.
- Simultaneous read/write traffic under realistic load is exercised by
  the D-Stress N=2/N=4 regressions (concurrent weight reads + result
  writes across multiple slots via the arbiter), not by an isolated
  directed test.

**No directed test exists for the EXACT first address (0x000000),
EXACT last address (0x7FFFFF), or an EXACT bank/row boundary
crossing.** Given the controller's address decode is a uniform,
parameterized bit-slice (no special-cased boundary logic to fail), and
the randomized sweep already exercises addresses adjacent to both
extremes without failure, the residual risk is assessed as low — but
per the mandate's own "do not invent margins" rule, this is disclosed
as a genuine, narrow **OPEN** item rather than claimed closed by
inference.

**STATUS: PASS (randomized coverage, high confidence) / OPEN (no
directed first/last-address or exact-boundary-crossing test exists).**

## 9. SPI host bridge — protocol documentation

Source: `hardware/v2/rtl/spi_host_bridge.v` (re-read in full this
session).

- **Mode/polarity/phase**: SPI mode 0 (CPOL=0, CPHA=0), MSB-first,
  one opcode byte per CS-low period. Triple-flop CDC synchronizer on
  `sclk`/`mosi`/`cs_n` (metastability-safe crossing into the 64MHz
  system-clock domain).
- **Max tested clock**: the board-level smoke test
  (`tb_fpga_neural_v2_top_smoke.v`) drives SPI at a 500ns bit period
  (~2MHz effective SCLK rate). **This is the only rate actually
  exercised in simulation.** The CDC synchronizer's own latency
  (3 system-clock cycles ≈ 46.9ns @ 64MHz) bounds a theoretical
  maximum SPI rate well above 2MHz, but no empirical test exists above
  2MHz — **max real operating SPI clock is OPEN, to be characterized
  at bring-up** (this is exactly what `FIRST_POWER_ON.md` step 11
  already exists to determine).
- **Command set** (opcode, MSB-first byte, one CS-low transaction
  each): `0x00 NOP` (0 payload), `0x0F RESET` (0 payload, pulses
  `soft_rst_pulse` one cycle after CS rises), `0x10 WRITE_JOB` (15
  payload bytes: node_id, required, producer_ids[15:0], x_base[22:0],
  w_base[22:0], n_tiles[15:0], result_addr[22:0] — all MSB-first,
  23-bit address fields packed as byte,byte,byte with the top byte's
  MSB reserved/zero), `0x20 STATUS` (0 payload, 1 response byte:
  bit0=job_busy, bit1=mem_busy, bit2=last_job_accepted [sticky,
  cleared by next WRITE_JOB], bits[7:3]=0), `0x01 WRITE_MEM` (5 header
  bytes [addr[22:0], len_words[15:0]] + 2×len_words payload bytes,
  WORD address not byte address), `0x02 READ_MEM` (5 header bytes,
  same shape, 0 further MOSI payload; 2×len_words response bytes
  clocked out on MISO). Any other opcode is treated as NOP (0 payload,
  MISO drives 0x00) — confirmed inert, never wedges the bus.
- **Response latency**: `WRITE_JOB` holds `reg_valid` until
  `reg_ready` (same-cycle valid&&ready acceptance, never a blind
  pulse) — latency is whatever `dependency_manager`'s own
  `reg_ready` takes to assert (job-queue-dependent, not fixed).
  `WRITE_MEM`/`READ_MEM` each issue one `mem_req`/`mem_ready` handshake
  per word — latency is the backend arbiter's per-word grant latency
  (see MEMORY_ARCHITECTURE.md), not a fixed cycle count either.
- **Reset behavior**: `0x0F RESET` pulses `soft_rst_pulse` for one
  system-clock cycle after CS deasserts; this is a soft, protocol-level
  reset pulse distinct from the board's own `ext_rst_n`/PLL-lock-gated
  hardware reset (section 3).
- **Framing / back-to-back transactions**: a new CS assertion normally
  restarts the opcode state machine — EXCEPT when the previous
  transaction is still pending a backend handshake (`ST_JOB_WAIT`,
  `ST_MEM_WISS`, `ST_MEM_RISS`), in which case state is deliberately
  NOT reset, preventing a new WRITE_JOB's incoming bytes from
  corrupting the still-pending previous job's fields through the same
  registers (a real bug found and fixed during this project's own
  STEP20 development, documented in the module's own header comment
  and re-confirmed present in the current source this session).
  Back-to-back WRITE_JOB transactions are exercised and PASS in the
  board-level smoke test (`C-back-to-back-A/B`, 11/11 PASS overall).
- **No reliance on testbench-only timing**: the synchronizer and FSM
  operate purely on `posedge clk` and edge-detected `sclk`/`cs_n`
  transitions; nothing in the design depends on a specific testbench
  delay value, only on real edges crossing the CDC boundary.

**STATUS: PASS (documented, protocol-correct, end-to-end verified at
the one tested rate) / max operating clock rate OPEN pending bring-up
characterization.**

## 10. FPGA configuration flash — FROZEN (not left OPEN)

**Decision: Winbond `W25Q32JVSSIQ`.**

| Property | Value |
|---|---|
| Manufacturer / MPN | Winbond Electronics, `W25Q32JVSSIQ` |
| Capacity | 32 Mbit (4 MB) — the LFE5U-45F's own uncompressed bitstream is well under 1MB, giving >4x margin even uncompressed, more with `ecppack` compression |
| Package | SOIC-8, 208-mil body (standard, hand-solder/hobby-friendly, widely stocked) |
| Supply voltage | 2.7–3.6V (VCC), matches the bank-8 (config bank) VCCIO which this design sets to 3.3V, matching the SDRAM's own 3.3V LVCMOS33 I/O already used throughout banks 6/7 |
| Protocol | Standard/Dual/Quad SPI, JEDEC-standard command set; ECP5's own "Master SPI" configuration boot mode uses only standard single-line SPI reads, which this part supports natively |
| Pull resistors | `WP#` and `HOLD#` (pins 3 and 7 of the standard 8-SOIC pinout) must be pulled to VCC (or tied directly) since this design uses standard single-SPI mode only, not the quad I/O functions those pins double as — unused-active-low-pin convention, standard practice |
| Reset/hold/WP behavior | No dedicated `RESET#` pin on this part (some competing devices have one; this part does not) — `HOLD#` pauses the bus mid-transaction when asserted low, tied inactive (high) here since this design never needs to pause a config read |
| Config clock requirement | ECP5 Master SPI mode drives its own `CCLK` output during configuration at a rate set by the `ecppack --freq` option at bitstream-generation time; this part supports standard SPI reads up to 104MHz, far above any practical `ecppack` config-clock setting |
| Boot-mode requirement | Must be wired for ECP5's "Master SPI" (also called "SPI Flash") boot mode — mode selection is via the ECP5's own dedicated CFG mode-strap balls (distinct from JTAG/PROGRAMN/INITN/DONE); **exact CFG-strap ball numbers for this specific package are not yet extracted from the pinout CSV and remain a schematic-level lookup, OPEN** (the component decision itself does not depend on this) |
| JTAG interaction | JTAG (TDI/TCK/TMS/TDO, real balls R5/T5/U5/V4, bank 40) remains available in parallel with SPI-flash boot for direct bitstream download/debug without touching the flash — standard ECP5 dual-boot-path behavior, no conflict |
| DONE/INITN/PROGRAMN | Real balls Y3 (DONE), V3 (INITN), W3 (PROGRAMN), all bank 8 — these are configuration-control signals common to every ECP5 boot mode, not specific to the flash choice |
| ECP5-flow support | `ecppack` (Project Trellis) natively supports generating SPI-flash-compatible bitstream images (`.bit`/raw binary) with a selectable config-clock frequency; Winbond W25Qxx-series parts are a standard, widely-used choice in the ECP5/Project-Trellis open-source ecosystem (used on multiple real, shipped ECP5 boards) |
| Availability confidence | High — standard, long-lived, multi-source JEDEC part, stocked at major distributors (Digi-Key, Mouser); not a claim of real-time stock levels, which were not checked |

**STATUS: CLOSED. Concrete, purchasable, technically appropriate part
frozen.** (One narrow sub-item — the exact CFG mode-strap ball
numbers — remains a schematic-level CSV lookup, not a blocker to this
component decision.)

## 11. FPGA power requirements — real per-bank table

Source: official Lattice pinout CSV (`FPGA-SC-02034-3-0-ECP5U-45-
Pinout.csv`, rev 3.0) and Lattice's own published LFE5U voltage
requirements (VCC=1.1V±5%, VCCAUX=2.5V±5%, VCCIO=1.2–3.3V
per-bank-selectable, VCCIO8=configuration-bank, voltage must match the
chosen config interface).

| Bank | VCCIO | Used signals | Function | Status |
|---|---|---|---|---|
| Core (VCC) | 1.1V | internal fabric/PLL core | FPGA core logic supply | Real, required, all `VCC` balls (H8–N13 region) must connect |
| VCCAUX | 2.5V | PLL analog/aux circuitry | Required for `EHXPLLL` operation | Real, required, all 4 `VCCAUX` balls (F6/P6/F15/P15) must connect |
| Bank 6 | 3.3V (LVCMOS33, per LPF) | `spi_sclk`, `spi_mosi`, `spi_miso`, `spi_cs_n` (some), SDRAM bus (some) | SPI host + SDRAM I/O | Real, matches SDRAM's own 3.3V requirement |
| Bank 7 | 3.3V (LVCMOS33, per LPF) | `pll_locked`, SDRAM bus (remainder), `osc_clk`, `ext_rst_n` | Clock/reset/debug + SDRAM I/O | Real, matches SDRAM's own 3.3V requirement |
| Bank 8 | 3.3V (must match config interface) | `CCLK` (U3), `PROGRAMN` (W3), `INITN` (V3), `DONE` (Y3) + config-flash SPI lines (mode-strap balls not yet extracted, see section 10) | FPGA configuration | Real for CCLK/PROGRAMN/INITN/DONE; flash SPI-line ball numbers OPEN |
| Bank 40 | (JTAG, standard 3.3V/1.8V-tolerant per ECP5 JTAG spec) | `TDI` (R5), `TCK` (T5), `TMS` (U5), `TDO` (V4) | JTAG programming/debug | Real balls, standard JTAG voltage compliance (not independently re-verified against the exact chosen VCCIO this session) |
| Banks 0/1/2/3 | 1.2–3.3V (unused this design) | none | Unused general-purpose I/O | Not used by this design; no signals assigned |

**Note (unchanged from the prior draft, re-confirmed real, not yet
independently cross-verified at the schematic/PCB level): all
banks 6/7/8 signals are assumed LVCMOS33 — a disclosed WARNING to
double-check at schematic capture, not a blocker.**

**STATUS: PASS (voltage requirements and bank/signal mapping are
real and sourced) — current/decoupling BUDGET remains a separate,
explicitly OPEN item (section 12).**

## 12. Power budget

Per the mandate's own explicit rule ("do not pretend to know FPGA
dynamic power exactly without implementation data"), this section
states only what is genuinely known and marks the rest OPEN rather
than inventing numbers:

- **Known real values**: rail voltages (section 11) and each part's
  own datasheet-stated supply-voltage range (SDRAM 3.3V±0.3V per
  AS4C4M16SA-6TIN Table 17; config flash 2.7–3.6V per section 10).
- **NOT known / OPEN**: exact static and dynamic current draw for the
  ECP5-45F at this design's actual utilization (7,084 LUT4-equiv,
  6,322 FF, 32 MULT18X18D, 1 PLL) and actual 64MHz toggle rate. This
  requires either the Lattice Power Calculator tool (not available in
  this Yosys/nextpnr-only environment) or the vendor's own published
  ECP5-45F datasheet current tables cross-referenced against the real
  post-P&R netlist — neither was performed this session, and no
  number is invented in their place.
- **SDRAM/flash/oscillator current**: each part's own datasheet
  states typical operating currents (SDRAM: on the order of tens of
  mA active, per AS4C4M16SA-6TIN Table 17 — not re-quoted here to
  avoid restating a number from memory rather than re-reading the
  table; re-read the datasheet directly if an exact figure is needed
  for schematic-stage regulator sizing).
- Regulator selection itself is explicitly out of scope for this
  document (that is PCB/schematic-level component selection, the
  user's own stated responsibility).

**STATUS: OPEN (voltage requirements known and real; current/power
budget genuinely not computable without post-implementation data or
tools not present in this environment — explicitly disclosed, not
fabricated).**

## 13. I/O and pinout freeze

All 16 top-level signals of `fpga_neural_v2_top.v` carry a real ball
assignment in `v2_board_top.lpf`, sourced from the official Lattice
pinout CSV (rev 3.0):

| Signal | Ball | Bank | Direction | Function | Status |
|---|---|---|---|---|---|
| `osc_clk` | H5 | — | in | 16MHz board oscillator input | Real, reused from V1's validated LPF |
| `ext_rst_n` | B4 | — | in | active-low external reset | Real, reused from V1's validated LPF |
| `spi_sclk` | L3 | 6/7 | in | SPI host clock | Real, plain GPIO |
| `spi_mosi` | M3 | 6/7 | in | SPI host data in | Real, plain GPIO |
| `spi_miso` | L2 | 6/7 | out | SPI host data out | Real, plain GPIO |
| `spi_cs_n` | N2 | 6/7 | in | SPI host chip-select | Real, plain GPIO |
| `pll_locked` | L1 | 6/7 | out | PLL lock status (bring-up/debug) | Real, plain GPIO |
| `sdram_cke` | B5 | 6/7 | out | SDRAM clock enable | Real |
| `sdram_cs_n` | C5 | 6/7 | out | SDRAM chip select | Real |
| `sdram_ras_n` | C4 | 6/7 | out | SDRAM RAS | Real |
| `sdram_cas_n` | A3 | 6/7 | out | SDRAM CAS | Real |
| `sdram_we_n` | B3 | 6/7 | out | SDRAM WE | Real |
| `sdram_ba[1:0]` | E4, C3 | 6/7 | out | SDRAM bank address | Real |
| `sdram_a[11:0]` | D5,D3,F4,E5,E3,F5,A2,B1,C2,C1,D2,D1 | 6/7 | out | SDRAM row/column address | Real |
| `sdram_dq[15:0]` | E1,G5,H3,J5,K3,K2,H1,J1,K1,K4,L4,L5,M5,M4,N4,N5 | 6/7 | inout | SDRAM data bus | Real |
| `sdram_dqm[1:0]` | P5, N3 | 6/7 | out | SDRAM byte mask | Real |

Duplicate/illegal/incompatible-assignment check (re-verified this
session by direct LPF inspection): 44/44 ball assignments are
distinct sites, all IOBUF entries specify `IO_TYPE=LVCMOS33`
consistently, no ball appears twice, no config-reserved ball (CCLK/
PROGRAMN/INITN/DONE/JTAG, section 10/11) is accidentally reused by any
design signal.

**STATUS: PASS. Real, P&R-confirmed, no placeholders, no conflicts.**

## 14. Configuration/JTAG/boot strategy

- **JTAG connector**: standard 4-wire JTAG (TDI=R5, TCK=T5, TMS=U5,
  TDO=V4, bank 40) plus the board's own GND/VCC reference — a
  standard 2×5 or 2×7 JTAG header is a schematic-level choice, not
  frozen here (connector part number is a BOM item, section 15).
- **Config flash**: Winbond `W25Q32JVSSIQ` (section 10), wired for
  ECP5 "Master SPI" boot mode.
- **PROGRAMN/INITN/DONE**: real balls W3/V3/Y3, bank 8. Standard ECP5
  behavior: pulsing `PROGRAMN` low re-triggers configuration;
  `INITN` low indicates a configuration error (or is held during the
  init-wait window); `DONE` goes high once configuration completes
  successfully and the fabric is released from configuration reset.
- **Boot mode**: SPI-flash boot (Master SPI) is the primary path;
  JTAG remains available in parallel for direct bitstream download
  during bring-up/debug without touching the flash (section 10).
- **Pull resistors**: `PROGRAMN` typically needs a pull-up (idle-high,
  momentary-pulse-low to reconfigure) per standard ECP5 practice;
  `INITN` is open-drain, needs a pull-up; exact resistor values are a
  schematic-level detail, not fixed here.
- **Reset interaction**: `ext_rst_n`/`pll_locked`-gated internal reset
  (section 3) is entirely independent of the FPGA's own configuration
  reset (PROGRAMN/INITN/DONE cycle) — the design's internal reset
  logic only takes effect after configuration completes and the
  fabric is live.
- **First-programming and recovery**: initial bring-up should use
  JTAG direct-to-SRAM configuration first (fastest iteration, no flash
  programming risk); once verified, program the SPI flash via JTAG
  (using nextpnr/Project-Trellis-generated `.bit` converted to a flash
  image) for standalone power-on boot. Recovery from a bad flash image
  is via JTAG direct configuration, which does not depend on flash
  content.

**STATUS: PASS (strategy defined with real ball/part data) — exact
CFG mode-strap ball numbers and connector/pull-resistor values remain
schematic-level detail, consistent with this mandate's own scope
boundary (user does schematic/PCB).**

## 15. Preliminary BOM (not PCB — component decisions only)

| Component | Manufacturer / MPN | Package | Voltage | Role | Mandatory/Optional | Availability confidence |
|---|---|---|---|---|---|---|
| FPGA | Lattice `LFE5U-45F-8BG381C` | CABGA381 | 1.1V core / 2.5V aux / 1.2-3.3V I/O per bank | Compute | Mandatory | Not independently checked this session (real, standard part number, previously confirmed target) |
| SDRAM | Alliance Memory `AS4C4M16SA-6TIN` | TSOP-II-54 (standard for this part family) | 3.3V | Unified weight/activation/result memory | Mandatory | Not independently checked this session (real datasheet on file, previously confirmed target) |
| Config flash | Winbond `W25Q32JVSSIQ` | SOIC-8 | 2.7-3.6V | FPGA configuration boot | Mandatory | High (standard, multi-source JEDEC part) — see section 10 |
| Oscillator | 16MHz, real device MPN not re-selected this session | — | 3.3V (typical) | System clock source | Mandatory | **OPEN — no specific MPN frozen this session; only the frequency (16MHz) and its ball (H5) are fixed by the RTL/LPF** |
| JTAG connector | not selected this session | — | — | Programming/debug | Mandatory for bring-up | **OPEN — schematic-level choice** |
| Pull resistors (PROGRAMN, INITN, WP#, HOLD#) | generic, values not specified | 0402/0603 | — | Config-signal biasing | Mandatory | OPEN — standard values (e.g. 4.7kΩ-10kΩ), exact value is schematic-level |
| Decoupling capacitors | generic, per Lattice Hardware Checklist guidance (distributed network, not one-cap-per-ball) | 0402/0603 | — | Power integrity | Mandatory | OPEN — exact count/placement is PCB-level |
| Voltage regulators (1.1V core, 2.5V aux, 3.3V I/O) | not selected this session | — | — | Power supply | Mandatory | **OPEN — depends on the still-open current budget (section 12)** |

**STATUS: PARTIAL.** FPGA, SDRAM, and config flash are frozen, real,
purchasable parts. Oscillator MPN, JTAG connector, regulators, and
passive values are explicitly left OPEN — genuinely not decidable
without either a prior explicit decision (oscillator) or the current
budget this session could not fabricate (regulators), consistent with
"do not invent stock availability" and "do not invent margins."

## 16. First-board bring-up spec

Already exists at `hardware/v2/docs/FIRST_POWER_ON.md` (14+ step
procedure with measurable PASS/FAIL criteria: power rails → FPGA
configuration → DONE → JTAG detection → clock → SDRAM init → SPI host
comm → memory test → neural test). Re-read this session and confirmed
its sequencing and pass/fail criteria remain consistent with the
current design (SPI host interface, real PLL, real pinout) — no
update needed beyond noting here that this document's own prior
"cannot be executed until BLOCKER items close" caveat is now
significantly narrowed: the SPI host interface and ball-level pinout
BLOCKERs it references are CLOSED as of this session; the only
genuine hardware-domain blockers remaining are schematic/PCB/BOM
completion (sections 12, 15) and the max-SPI-clock characterization
noted in section 9.

**STATUS: PASS (procedure exists, real criteria, consistent with
current design).**

## 17. Benchmark finalization

Real, current-source benchmark results (Verilator, this session):

| Config | Cycles | Result |
|---|---|---|
| N=2 D-Stress | 49,788 | 256/256 bit-exact PASS |
| N=4 D-Stress | 49,771 | 256/256 bit-exact PASS |
| Board-level SPI (single job) | 99-100 cycles/job | PASS |
| Board-level SPI (back-to-back) | 88-100 cycles/job | PASS |
| Board-level SPI (gap100ns/5000ns/50000ns) | 88-100 cycles/job (steady-state unaffected by gap) | PASS |

At the real, P&R-verified 64MHz system clock: N=4 D-Stress (49,771
cycles) corresponds to 49,771 / 64,000,000 = **777.7 µs** wall-clock
for the full 256-neuron D-Stress workload. Throughput scaling from
N=2→N=4 is essentially flat in total cycle count (49,788→49,771,
<0.1% difference) because D-Stress's own workload shape keeps the
SDRAM/arbiter bandwidth as the binding constraint at this tile size,
not per-processor compute — consistent with this project's own prior
scaling analysis (STEP17/STEP18 reports), not a new finding.

**No embedded-target (ESP32-class) physical baseline is available —
this remains explicitly OPEN, not fabricated.** No comparison against
an unrelated desktop CPU is made here.

**STATUS: PASS (real cycle counts, real 64MHz-derived wall-clock
time) — embedded-baseline comparison OPEN (no hardware available).**

## 18. Datasheet (LaTeX) — status

`hardware/v2/docs/DatasheetLatex/` chapters were re-read this session
(00-features, 02-architecture, 05-pinout-timing, 08-status-roadmap).
Content is current and accurate against this session's own findings
EXCEPT the readiness checklist in `08-status-roadmap.tex`, which
predates this session's SDRAM-datasheet-audit closure (section 7) and
config-flash freeze (section 10). That chapter is updated as part of
this same change (see the diff to `08-status-roadmap.tex`) to move
"SDRAM datasheet-parameter cross-check" and "Configuration flash
selection" from OPEN to closed/decided, and the PDF is rebuilt and
confirmed to compile cleanly.

**STATUS: PASS (updated and rebuilt this session).**

## 19. Cross-domain consistency audit

Checked this session:
- RTL (`fpga_neural_v2_top.v` port list) ↔ LPF (`v2_board_top.lpf`):
  all 16 ports have exactly one LPF entry each, no orphaned port, no
  orphaned LPF entry. **Consistent.**
- LPF ↔ FPGA device: all sites are real CABGA381 balls per the
  official Lattice CSV; IO_TYPE=LVCMOS33 throughout banks 6/7,
  consistent with the SDRAM's 3.3V requirement. **Consistent.**
- RTL SDRAM timing constants ↔ real SDRAM datasheet: closed this
  session (section 7), one discrepancy found and fixed (ERR-0026).
  **Consistent (post-fix).**
- SPI host protocol (section 9) ↔ config-flash SPI (section 10): two
  functionally and physically SEPARATE interfaces — the host SPI uses
  banks 6/7 GPIO (L3/M3/L2/N2), the config flash uses bank-8
  dedicated config-mode balls — confirmed no ball overlap. **Consistent.**
- Power requirements (section 11) ↔ BOM (section 15): SDRAM and
  config-flash voltage requirements (3.3V, 2.7-3.6V) are both
  satisfiable by a single 3.3V I/O rail choice; no contradiction found.
  **Consistent.**
- Datasheet (section 18) ↔ this document: reconciled by this same
  session's edit to `08-status-roadmap.tex`. **Consistent.**
- No stale V1 component name, no stale PSRAM reference, no
  inconsistent memory-size/timing/performance number found across any
  of the documents re-read this session.

**STATUS: PASS.**

---

## FINAL RELEASE GATE

| Item | Status |
|---|---|
| RTL functional freeze | PASS |
| ERR-0025 closure | PASS |
| Regression (full suite, this session) | PASS |
| Synthesis | PASS |
| Place & route (8 seeds) | PASS |
| Setup timing | PASS |
| Hold timing | **OPEN — TOOL LIMITATION** |
| PLL / clock generation | PASS |
| Reset architecture | PASS |
| SDRAM functional (sim) | PASS |
| SDRAM datasheet audit | PASS (closed this session, ERR-0026 fixed) |
| SDRAM address/memory-map boundary | PASS (randomized) / OPEN (no directed first/last/exact-boundary test) |
| SPI host protocol | PASS (documented, verified at tested rate) |
| Configuration flash | **PASS — FROZEN (Winbond W25Q32JVSSIQ)** |
| FPGA power requirements (voltage/bank mapping) | PASS |
| Power budget (current/decoupling) | OPEN (no implementation-level current data available) |
| I/O / pinout | PASS |
| Configuration / JTAG / boot strategy | PASS (strategy defined; mode-strap ball numbers schematic-level) |
| Preliminary BOM | PARTIAL (FPGA/SDRAM/flash frozen; oscillator MPN/regulators/connector/passives OPEN) |
| First-board bring-up spec | PASS |
| Benchmark | PASS (embedded baseline OPEN, no hardware) |
| Datasheet | PASS (updated, rebuilt) |
| Cross-domain audit | PASS |

**CLASSIFICATION: PRE-PCB VERIFIED**, with the following items
explicitly and honestly OPEN (not silently dropped): hold-time
verification (tool limitation), exact first/last-address and
bank-boundary directed SDRAM tests, max operating SPI clock rate,
FPGA power/current budget, oscillator MPN, JTAG connector, pull
resistor/decoupling values, voltage regulator selection, and an
embedded-target (ESP32-class) benchmark baseline.

**SCHEMATIC: USER IMPLEMENTATION PENDING.**
**PCB: USER IMPLEMENTATION PENDING.**
**SILICON READY: NO — SCHEMATIC AND PCB NOT YET IMPLEMENTED.**
