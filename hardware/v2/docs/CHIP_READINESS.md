# FPGA-Neural V2 — CHIP READINESS

Precise, non-vague criteria per the governing spec's own definition:
V2 hardware is READY only when EVERY box below is checked. If even one
fundamental item is missing, **HARDWARE READY = NO** — no OPEN ITEM is
masked.

```
[x] RTL frozen                       -- nms_neural_multiprocessor_sdram_unified.v,
                                         zero V1 dependency, strict lint clean
[x] regression PASS                  -- 461/461 (isolated controller, 9 configs),
                                         40/40 (isolated unified backend)
[x] bit-exact PASS                   -- 256/256 neurons, N=2 AND N=4, single SDRAM
[x] SDRAM validation PASS            -- init/refresh/read/write/burst/masked-write,
                                         40 real refresh events, zero corruption
[x] N4 synthesis PASS                -- real Yosys 0.68+post, zero errors
[ ] N4 timing >= 80 MHz              -- MARGINAL: only 1/8 real P&R seeds pass
[ ] constraints complete             -- v2_unified.lpf exists, REAL and P&R-verified
                                         for 39/149 signals (clk/rst + full SDRAM bus);
                                         110-signal host bus still unassigned
[ ] pinout complete                  -- 149-signal inventory complete; SDRAM+clk/rst
                                         (39 signals) REALLY assigned from the official
                                         Lattice CSV and P&R-confirmed; host bus (110
                                         signals) deliberately unassigned (see below)
[ ] clock defined                    -- real EHXPLLL RTL now exists (STEP20,
                                         ecp5_pll_sys_clk.v, 16MHz->64MHz), NOT yet
                                         confirmed by synthesis/P&R of the board top
[ ] power defined                    -- rail voltages known; regulators NOT selected
[ ] FPGA configuration defined       -- standard pins identified; flash NOT chosen
[x] host interface defined           -- STEP20: real SPI protocol engine
                                         (spi_host_bridge.v), verified correct
                                         end-to-end (11/11, board-level smoke test),
                                         zero regression to the STEP19 baseline
[x] schematic requirements complete  -- SCHEMATIC_READINESS.md's own block diagram
                                         and interconnection list are complete
[x] first-power-on test defined      -- FIRST_POWER_ON.md's own 12-step procedure
[ ] bitstream reproducible           -- NOT verified: no ball-assigned LPF exists to
                                         produce a REAL, board-usable bitstream from;
                                         the free-placement bitstreams used for
                                         verification this round are reproducible
                                         AS SIMULATION/FIT PROOFS ONLY, not as a
                                         real board-programmable artifact
```

**8 of 14 items checked. HARDWARE READY = NO.**

**STEP20 update:** a real SPI host interface (`spi_host_bridge.v` +
`fpga_neural_v2_top.v`) now exists AND is verified correct end-to-end
(errors.log's "ERR-0025 Part B — RESOLUTION": a registered- vs
combinational-read SRAM timing bug, found via the board-level smoke
test, root-caused, fixed with zero regression to the STEP19 baseline)
— "host interface defined" is now checked. A real EHXPLLL clock
wrapper also now exists (`ecp5_pll_sys_clk.v`) but has not yet been
through synthesis/P&R of the board-level top, so "clock defined"
remains unchecked for that specific, narrower reason. The STEP19 core
(raw `reg_*` interface) remains bit-exact verified and was reconfirmed
fresh this session via Verilator after an unrelated Icarus Verilog
v13.0 toolchain regression was found and ruled out (ERR-0024).

## Why each unchecked item is unchecked (no vague language)

| Item | Why NOT checked |
|---|---|
| N4 timing ≥80MHz | 8 real P&R seeds measured; only 1 (81.84MHz) clears 80MHz. This is a real MARGINAL result, not a PASS, per the governing spec's own explicit classification rule (some seeds pass, most do not). |
| Constraints complete | `v2_unified.lpf` real and P&R-verified for 39/149 signals (clock frequency + clk/rst + the full 37-signal SDRAM bus, sourced from the real Lattice pinout CSV found at `~/Downloads/` during this step's own pre-commit review). The 110-signal host bus is deliberately left unassigned. |
| Pinout complete | Signal inventory is complete (149, exactly matching real P&R); SDRAM+clk/rst (39 signals, 26%) are now really assigned and P&R-confirmed; the 110-signal host bus is unassigned, not because pin data is missing, but because that bus is not yet a real physical protocol (see below) — assigning it balls now would be premature. |
| Clock defined | A real EHXPLLL wrapper now exists (`ecp5_pll_sys_clk.v`, STEP20, real Project Trellis `ecppll`-generated parameters, 16MHz->64MHz) and is instantiated in the board-level top, but has NOT yet been confirmed by synthesis/P&R of that top — deliberately deferred until ERR-0025 Part B was resolved (decisions.log DEC-0037). |
| Power defined | Rail VOLTAGES are known from real datasheets; regulator SELECTION, CURRENT budget, and decoupling are not — no real power-estimation tool was run, and the previously-referenced board power-tree design is not accessible this session to confirm as a concrete plan. |
| FPGA configuration defined | Standard ECP5 config pins (TDI/TDO/TCK/TMS/PROGRAMN/INITN/DONE/CCLK) are correctly identified as existing and standard, but no configuration-flash part number or SPI-vs-JTAG-only bring-up approach has been chosen for V2 specifically. |
| Bitstream reproducible | Every P&R run this project has performed used free (unconstrained) I/O placement — a real, valid way to prove the design FITS the package, but not a way to produce a bitstream a real board's own fixed wiring could actually use. |

## What this means, precisely

The V2 hardware architecture itself — SDRAM device, controller,
memory subsystem, compute datapath, N4/P8 configuration — is **real,
validated, and correct**: bit-exact simulation, real synthesis, real
place-and-route all confirm this. What remains is **entirely physical-
integration work**: a real host interface, a real ball-level pinout, a
real clock source decision, and real power/configuration component
selection. None of these are memory-architecture, datapath, or
correctness questions anymore — they are the next, concrete, well-
defined engineering tasks, precisely enumerated in OPEN_ITEMS.md.

## Final answer

```
HARDWARE FREEZE: PASS (architectural decision + RTL correctness)
CHIP READY:      NO
```
