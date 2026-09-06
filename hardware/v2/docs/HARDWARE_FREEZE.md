# FPGA-Neural V2 — HARDWARE FREEZE (FASE #1, single external SDRAM)

**PARTIALLY SUPERSEDED (DEC-0039).** The SDRAM part number below
(AS4C4M16SA-6TIN, 8MB) was upgraded to **AS4C32M16SB-7BIN (64MB)**,
and N_PROCESSORS=8 is no longer merely a "future evolution" — it is
now real, synthesized, P&R-verified (functionally correct, with a
disclosed, real 64MHz timing-closure gap at 5/8 tested seeds). See
`MEMORY_UPGRADE_64MB_N8.md` for the current, authoritative state. The
rest of this document (Neural Processor, dataflow architecture) is
still accurate.

## Frozen reference configuration

```
FPGA:            LFE5U-45F-8BG381, ECP5U, speed grade -8
Neural Processor: P_IN=8, INT8 operands, INT32 accumulator,
                  8 parallel MAC, balanced adder tree (neural_processor.v,
                  UNCHANGED since before this freeze)
Multiprocessor:  N_PROCESSORS=4 (N4/P8 is the frozen reference; N2 also
                  validated; N8 is a FUTURE EVOLUTION, not part of this freeze)
Architecture:    Neural Multiprocessor -> Dataflow -> Neural Director ->
                  Dependency Manager -> Memory Manager -> streaming tile
                  delivery (STEP13 architecture, intact, unchanged)
External memory: ONE SDRAM ONLY -- Alliance Memory AS4C4M16SA-6TIN,
                  serving weights, activations, AND results (DEC-0031/
                  0032/0033/0034). No PSRAM, no second memory device.
Weight path:     PACK128 (BURST_LEN=8, N_ENTRIES=4 cache, STEP18/STEP19)
Target clock:    80 MHz minimum (real oscillator/PLL source: OPEN, see
                  CLOCK_ARCHITECTURE.md)
V1:              golden/reference implementation, untouched (confirmed:
                  zero modifications; V2 no longer instantiates ANY V1
                  RTL at all, since psram_controller.v was removed from
                  the physical path -- DEC-0034)
Frozen top-level: nms_neural_multiprocessor_sdram_unified
                  (hardware/v2/nms/rtl/nms_neural_multiprocessor_sdram_unified.v)
```

N4/P8 is the frozen V2.0 hardware reference. This does not mean N4 is
the final or maximum architecture — N8, higher clocks, or new datapath
ideas are explicitly FUTURE EVOLUTIONS, out of scope for this freeze.

## Repository audit summary

Full detail: see the audit performed for this step (repository
structure, V1/V2 boundary, top-level candidates, dead-code
classification, PSRAM-dependency confirmation, LPF/docs/scripts
inventory). Key findings:

- `hardware/v1/**`: complete, self-contained, untouched. Real
  synthesized/certified golden reference (`spi_neuron_top.v`).
- `hardware/v2/rtl/` + `hardware/v2/nms/rtl/`: the frozen top-level
  (`nms_neural_multiprocessor_sdram_unified.v`) instantiates
  `nms_dataflow_core_sdram.v`, `sdram_unified_backend.v` (STEP19, new),
  `sdram_controller.v`, `nms_memory_manager_stream_wide.v`,
  `weight_prefetch_engine_wide.v`, `nms_activation_replicated.v`,
  `nms_activation_fill_ctrl_v3.v`, `nms_weight_packed.v`,
  `dependency_manager.v`, `neural_director.v`, `neural_processor.v`,
  `slot_mem_arbiter.v`, `slot_mem_arbiter_wide.v`, `prefetch_engine.v`
  — **zero V1 files**, confirmed by successful lint/synthesis with no
  V1 RTL in the file list.
- Every other `nms_neural_multiprocessor_*.v`/`nms_dataflow_core_*.v`
  variant (plain, `_pf`, `_stream`, `_actfix`, `_actfix2`, `_dual32`,
  `_sdram`, `_sdram_pack128`) is real, historical, superseded-but-
  documented project experiment history — dead relative to the frozen
  top, NOT deleted (each remains the subject of its own STEP report).
- `hardware/v2/constraints/` was empty before this step; now contains
  `v2_unified.lpf` (partial — see PINOUT.md).
- The referenced sibling pinout repository (`../basic-ecp5-pcb`) does
  not exist on disk, BUT the real Lattice pinout CSV itself
  (`FPGA-SC-02034-3-0-ECP5U-45-Pinout.csv`, rev 3.0) is present at
  `~/Downloads/` and was found during this step's own pre-commit
  review, with a real summary already at `docs/pinouts.md` (repo
  root). This corrected an earlier draft of this freeze that
  wrongly assumed no real pinout data existed — see PINOUT.md.

## Status table

| Area | Status | Evidence | Blocker |
|---|---|---|---|
| RTL | PASS | Strict Verilator lint (latches/multi-driver/comb-loops/case-completeness): zero findings across the full frozen hierarchy | No |
| Simulation | PASS | Isolated `tb_sdram_controller.v` (461/461, 9 freq/burst configs), isolated `tb_sdram_unified_backend.v` (40/40) | No |
| Bit-exact | PASS | Full N=4 AND N=2 D-Stress (256/256 neurons each), golden software model comparison | No |
| SDRAM | PASS | Real init/refresh/read/write/burst/masked-write, 40 real AUTO REFRESH events interleaved with zero corruption across a ~50,000-cycle run | No |
| Synthesis | PASS | Real Yosys 0.68+post synthesis, N=4: TRELLIS_FF=6425, TRELLIS_COMB=6023, MULT18X18D=32, DP16KD=0 | No |
| P&R | PASS (fits) | Real nextpnr-ecp5 0.11.1, TRELLIS_IO=149/245 (fits with headroom) | No |
| Timing | **MARGINAL** | 8 real seeds: 66.97/74.00/74.45/74.92/79.23/79.53/79.80/81.84 MHz — only 1/8 ≥80MHz | **CRITICAL** |
| Pinout | PARTIAL | 39/149 signals real, sourced, P&R-verified (clk/rst + full 37-signal SDRAM bus); 110-signal host bus unassigned | **BLOCKER (host bus only)** |
| Clock | INCOMPLETE | Single-clock-domain RTL confirmed (no CDC); no PLL exists; oscillator-vs-PLL decision not made | **CRITICAL** |
| Power | INCOMPLETE | Real rail voltages known from datasheets; no regulator selection, no current budget | OPEN |
| Configuration | INCOMPLETE | Standard ECP5 JTAG/config pins identified; no flash part chosen, no V2 config LPF beyond the partial `v2_unified.lpf` | OPEN |
| Host | INCOMPLETE | 110-pin raw parallel bus exists at the RTL boundary; no physical protocol, no serializer RTL | **BLOCKER** |
| PCB | NOT READY | See SCHEMATIC_READINESS.md's own checklist | Multiple (host, pinout, power) |
| Bring-up | READY (procedure only) | FIRST_POWER_ON.md defines the full 12-step test sequence | Cannot execute until host/pinout blockers close |

## Single-SDRAM verification (this step's own core mandate)

- PSRAM dependency: **REMOVED** — confirmed by successful synthesis/
  P&R with zero V1 files in the compile list, and a real, measured
  45-pin I/O reduction (194→149/245 TRELLIS_IO) exactly matching the
  removed PSRAM interface's own pin count.
- Weights/activations/results: **all confirmed sharing the single
  physical SDRAM**, real bit-exact traffic at three distinct,
  non-overlapping memory-map regions, simultaneously, under real N=4
  contention (see MEMORY_ARCHITECTURE.md).
- Real bugs found and fixed during this consolidation (ERR-0023): a
  full deadlock and a subsequent off-by-one data-shift bug in the new
  arbitration logic, both caught via full-system (not merely isolated)
  testing before being accepted — see errors.log for the complete
  root-cause writeups.

## Deliverables produced by this step

`HARDWARE_FREEZE.md` (this file), `CHIP_READINESS.md`,
`MEMORY_ARCHITECTURE.md`, `PINOUT.md`, `POWER_ARCHITECTURE.md`,
`CLOCK_ARCHITECTURE.md`, `SCHEMATIC_READINESS.md`,
`FIRST_POWER_ON.md`, `OPEN_ITEMS.md` (all under `hardware/v2/docs/`),
plus `hardware/v2/constraints/v2_unified.lpf` and new RTL/testbenches
under `hardware/v2/nms/rtl/` and `hardware/v2/nms/sim/`.
