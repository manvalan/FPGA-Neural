# FPGA-Neural V2 — OPEN ITEMS

**SUPERSEDED.** See `PRE_PCB_VERIFICATION.md`'s own final release-gate
table for the current, consolidated OPEN/PASS status of every item
below — most of the BLOCKER/CRITICAL items here (host interface,
clock/PLL, pinout) are now CLOSED. Left in place as a historical
record.

Consolidated from HARDWARE_FREEZE.md, PINOUT.md, CLOCK_ARCHITECTURE.md,
POWER_ARCHITECTURE.md, SCHEMATIC_READINESS.md. Classified per the
governing spec's own rule: BLOCKER / CRITICAL / WARNING / OPEN /
FUTURE.

## BLOCKER (impede la realizzazione o il funzionamento del chip)

0. **RESOLVED (STEP20).** A real SPI host interface (`spi_host_bridge.v`)
   is now implemented, protocol-correct in isolation (18/18,
   `tb_spi_host_bridge.v`), AND verified correct end-to-end through the
   full SPI→dependency_manager→compute→SDRAM→result path under both
   tight and realistic (widely time-separated) job pacing (11/11,
   `tb_fpga_neural_v2_top_smoke.v`) — see errors.log's own "ERR-0025
   Part B — RESOLUTION" entry for the full root-cause writeup (a
   registered- vs combinational-read latency mismatch in the shared
   weight/activation SRAMs, fixed with zero regression to the STEP19
   baseline). This item is CLOSED — kept here only for the historical
   record; item 1 below is likewise no longer a real blocker in the
   sense of "the RTL doesn't exist" — it remains open only for real
   pinout/board-connector work (see item 1's own updated text).
1. **RESOLVED (STEP20).** The RTL's own internal "host" ports (`reg_valid`
   /`reg_node_id`/`reg_required`/`reg_producer_ids`/`reg_x_base`/
   `reg_w_base`/`reg_n_tiles`/`reg_result_addr`) remain a simulation/
   testbench-only bus for `nms_neural_multiprocessor_sdram_unified.v`
   in isolation, but the board-level top (`fpga_neural_v2_top.v`) now
   drives these SAME internal ports from `spi_host_bridge.v`, a real,
   verified SPI protocol engine (WRITE_JOB/WRITE_MEM/READ_MEM/STATUS/
   RESET), matching V1's own `spi_neuron_top.v` precedent. The 110-pin
   bus is no longer exposed as a physical top-level port at all in
   `fpga_neural_v2_top.v` — only 4 real SPI pins (sclk/mosi/miso/cs_n)
   are.
2. **The 110-pin host/registration bus has no real ball assignment** —
   moot now (see item 1): it is an internal signal, not a top-level
   port, in the board-level top. The 4 real SPI pins likewise have no
   ball assignment yet, since `fpga_neural_v2_top.v` has not been
   through P&R this round (see the next open item). The SDRAM bus (37
   signals) and clk/rst (2 signals) now DO have a
   real, sourced, P&R-verified assignment (`hardware/v2/constraints/
   v2_unified.lpf`, from the real Lattice pinout CSV found at
   `~/Downloads/FPGA-SC-02034-3-0-ECP5U-45-Pinout.csv` during this
   step's own pre-commit review) — this item is narrower than
   originally scoped.
3. **No schematic exists; no PCB has been started.**

## CRITICAL (rischio elevato, deve essere risolto prima del freeze)

1. **Timing closure is MARGINAL, with an unfavorable pass rate.** 8
   real P&R seeds for the frozen N=4 single-SDRAM design: only 1/8
   reach ≥80MHz (66.97–81.84MHz range). This is WORSE than STEP18's
   own dual-memory design (5/8 pass). The critical path itself is
   unchanged (still `dependency_manager.v`'s own pre-existing
   `first_ready_idx`/`reg_ready` chain) — the regression is attributed
   to added overall die/routing pressure from consolidation, not a new
   RTL defect, but it is real and unresolved.
2. **Clock source/oscillator gap -- PARTIALLY ADDRESSED (STEP20).** A
   real EHXPLLL wrapper (`ecp5_pll_sys_clk.v`, real Project Trellis
   `ecppll`-generated parameters, 16MHz->64MHz) now exists and is
   instantiated in `fpga_neural_v2_top.v`. NOT YET confirmed by real
   synthesis/P&R of that board-level top this round (deliberately
   deferred until ERR-0025 Part B was resolved -- see decisions.log
   DEC-0037) -- this is the immediate next real step. Prior project memory
   records a 16MHz board oscillator. Neither "source an 80MHz+
   oscillator" nor "add a real PLL to the RTL" has been decided.
3. **Two physical memories were required through STEP18** — RESOLVED
   this round (DEC-0034): the V2 physical path no longer instantiates
   `hardware/v1/rtl/psram_controller.v` at all. Kept here only as a
   closed CRITICAL item for the historical record.

## WARNING (non blocca il prototipo ma deve essere documentato)

1. N=2's real Fmax (86.04MHz in STEP18's own dual-memory design) and
   the STEP19 single-SDRAM N=2 config were not both measured with the
   same best-of-N-seed rigor as N=4 — a real, disclosed gap in
   measurement thoroughness, not a functional issue.
2. `W_ENTRIES`/cache sizing in the weight-fetch path was set to match
   `N_SLOTS` (4) by construction reasoning, not swept for optimality.
3. I/O standard (LVCMOS33 assumed for all 149 signals) has not been
   verified per real VCCIO bank once ball assignment becomes possible.

## OPEN (decisione ancora da prendere)

1. Configuration-flash part number / SPI-flash-boot vs JTAG-only
   bring-up.
2. Power regulator topology and part numbers (the previously-recorded
   `../basic-ecp5-pcb` reference design is not accessible this
   session to confirm as a concrete plan).
3. Real current budget (requires running a real power-estimation tool
   against the actual synthesized netlist — not done this round).
4. Decoupling/bulk capacitance values (depend on regulator selection).
5. Reset synchronization to a real external POR/supervisor source.
6. Real per-bank VCCIO/I-O-standard verification once ball data is
   available.

## FUTURE EVOLUTION (miglioramento post-freeze — explicitly deferred)

1. N=8 evaluation.
2. A smarter W/AR priority scheme in `sdram_unified_backend.v` to
   recover some of the +10.8% (N=4) / +5.1% (N=2) cycle-count cost of
   single-SDRAM unification (STEP18 EXP-0046's own packing win is
   still present — this is about the NEW W-vs-AR contention specifically).
   generic
3. Page-mode / keep-row-open SDRAM controller redesign (STEP18's own
   identified next bottleneck for raw memory bandwidth, independent of
   the single-vs-dual-memory question).
4. True multi-outstanding SDRAM request pipelining (STEP18 Part E's
   own documented, deliberately out-of-scope boundary).
5. A real physical host-interface RTL bridge (SPI or similar),
   resolving BLOCKER #1 above.
6. Floorplanning / seed-pinning work to convert the current MARGINAL
   timing result into a reliable PASS.
