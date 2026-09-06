# FPGA-Neural V2 — PINOUT

**SUPERSEDED.** This document predates the SPI host bridge and the
final board-level `fpga_neural_v2_top`/`v2_board_top.lpf` pinout. See
`PRE_PCB_VERIFICATION.md` \S13 for the current, real, P&R-confirmed
16-signal pinout (host bus is no longer BLOCKED). Left in place as a
historical record.

FPGA: **LFE5U-45F-8BG381** (ECP5U, speed grade -8)
Package: **CABGA381**
Frozen top-level: `nms_neural_multiprocessor_sdram_unified` (N_SLOTS=4)
**Single external memory: ONE SDRAM (AS4C4M16SA-6TIN). No PSRAM, no
second memory device anywhere in this design (STEP19/DEC-0034).**

## Status: SDRAM pinout REAL and P&R-verified; host bus still BLOCKED

Correction to an earlier draft of this document: the real Lattice
pinout data source (`FPGA-SC-02034-3-0-ECP5U-45-Pinout.csv`, rev 3.0)
IS available on this machine (`~/Downloads/`), and its own summary
(`docs/pinouts.md`, repo root) already lists real, exact JTAG/config/
power ball assignments for CABGA381 — found during this step's own
pre-commit `git status` review, not assumed missing without checking.
`hardware/v2/constraints/v2_unified.lpf` now contains a REAL,
P&R-verified ball assignment for clk/rst (39 total) and the full
37-signal SDRAM bus, sourced directly from that CSV (bank 6/7 plain-
GPIO pads, avoiding PLL/PCLK-reserved balls) — confirmed by a real
nextpnr-ecp5 run: all 37 SDRAM signals placed successfully, "110
warnings" (exactly the 110 still-unconstrained host-bus signals, a
clean cross-check that the inventory below is complete and accurate).

**This has NOT been electrically cross-verified** (VCCIO6/7 bank
voltage vs the SDRAM's own LVCMOS33 requirement, signal integrity,
trace-length matching for the 16-bit DQ bus) — it is a real, sourced,
P&R-confirmed CANDIDATE assignment, not a board-signed-off pinout.

## Real ball assignments now in place

| Signal | Ball | Source |
|---|---|---|
| `clk` | H5 | Reused from V1's own real, validated LPF |
| `rst` | B4 | Reused from V1's own real, validated LPF |
| `sdram_cke`/`cs_n`/`ras_n`/`cas_n`/`we_n` | B5/C5/C4/A3/B3 | Real CSV, bank 7 |
| `sdram_ba[1:0]` | E4, C3 | Real CSV, bank 7 |
| `sdram_a[11:0]` | D5,D3,F4,E5,E3,F5,A2,B1,C2,C1,D2,D1 | Real CSV, bank 7 |
| `sdram_dq[15:0]` | E1,G5,H3,J5,K3,K2,H1,J1,K1,K4,L4,L5,M5,M4,N4,N5 | Real CSV, banks 7/6 |
| `sdram_dqm[1:0]` | P5, N3 | Real CSV, bank 6 |

Full detail: `hardware/v2/constraints/v2_unified.lpf`.

Real JTAG/config/power balls (from `docs/pinouts.md`, not yet
transcribed into the LPF since this design's own top-level does not
expose them as RTL ports — they are implicit ECP5 device pins):
TDI=R5, TCK=T5, TMS=U5, TDO=V4 (bank 40); PROGRAMN=W3, INITN=V3,
DONE=Y3, CCLK=U3 (bank 8); VCC balls (1.1V) at H8-N13 cluster;
VCCAUX (2.5V) at F6/P6/F15/P15; VCCIO0-8 bank assignments listed in
`docs/pinouts.md`.

## Signal inventory (real, from the frozen top-level's own port list)

Total top-level I/O: **149 signals**, cross-checked exactly against
the real POST-P&R `TRELLIS_IO: 149/245` figure (STEP19) — a real
**45-pin reduction** from STEP18's dual-memory design (194 pins),
exactly matching the removed PSRAM interface's own pin count.

| Group | Count | Ball assignment |
|---|---|---|
| Clock/reset (`clk`, `rst`) | 2 | **Real, assigned** (H5, B4) |
| Host/control (`reg_*`) | 110 | **BLOCKER — see below** |
| SDRAM (`sdram_*`) | 37 | **Real, assigned, P&R-verified** |
| **Total** | **149** | matches P&R exactly |

## CRITICAL finding: the "host" interface is not a physical interface

**110 of 149 pins (73.8%) are the raw `reg_*` job-registration bus** —
a simulation/testbench convenience, not a real board protocol. No RTL
exists to serialize this for physical use. Ball assignment for these
110 signals is deliberately NOT attempted yet, even though real GPIO
balls are available (46+ more plain-GPIO candidates remain in banks
6/7 alone after the 37 used above) — assigning pins to an interface
that must be redesigned first would be premature, wasted work. **This
remains the single largest real BLOCKER to physical realization.**

## I/O standard / bank assignment

LVCMOS33 assumed and used in the LPF above for all 39 real-assigned
signals — matches `docs/pinouts.md`'s own real VCCIO range (1.2–3.3V)
and V1's own real, validated board convention. Real per-bank voltage
compatibility for banks 6/7 specifically (used for SDRAM) has not been
independently re-verified against the SDRAM device's own datasheet
this round (WARNING, not BLOCKER — LVCMOS33 is a reasonable, likely-
correct default, not yet double-checked).

## Configuration pins (JTAG/config)

Now REAL and known (see table above) — `docs/pinouts.md`'s own
summary of the same official CSV. This closes what was previously
documented as a blocker for THESE specific pins; only the general-
purpose host-bus assignment (unrelated to JTAG/config) remains open.

## Summary

| Item | Status |
|---|---|
| Real ball-level LPF for the SDRAM interface | **Done — 37/37 signals, P&R-verified** |
| Real ball-level assignment for clk/rst | **Done — reused from V1** |
| Real ECP5U-45F CABGA381 ball-map data source | **Found — `~/Downloads/FPGA-SC-02034-3-0-ECP5U-45-Pinout.csv`, summarized in `docs/pinouts.md`** |
| Aggregate I/O feasibility (149/245 fits the package) | Confirmed, real POST-P&R |
| Real JTAG/config/power ball identification | **Done — see `docs/pinouts.md`** |
| Physical host interface RTL | **BLOCKER — does not exist (110 raw pins, no serializer, no ball assignment)** |
| I/O standard/bank electrical cross-check | WARNING — LVCMOS33 assumed, not independently re-verified per bank |
