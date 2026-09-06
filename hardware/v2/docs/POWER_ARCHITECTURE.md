# FPGA-Neural V2 — POWER ARCHITECTURE

**SUPERSEDED.** See `PRE_PCB_VERIFICATION.md` \S11-\S12 for the
current per-bank voltage table (PASS) and current/power budget
status (still OPEN, same real reasons as below). Left in place for
its own detailed real-value derivation.

## Status (HISTORICAL framing, current status is in PRE_PCB_VERIFICATION.md): OPEN — component/regulator selection not made this round

Per the governing spec's own "NON inventare valori" rule, this
document states what is REALLY known (device-level voltage
requirements, from real datasheets/standard ECP5 knowledge) and
explicitly marks what has NOT been decided, rather than inventing
regulator part numbers or current budgets without real justification.

## Required rails (real device requirements)

Corrected from an earlier draft: real ball-level VCC/VCCAUX/VCCIO
data for this exact package DOES exist (`docs/pinouts.md`, repo root,
sourced from the official Lattice pinout CSV) and is used below rather
than only generic device specs.

| Rail | Nominal voltage | Real balls (CABGA381) | Notes |
|---|---|---|---|
| VCC (core) | 1.1V ±5% | H8,J8,K8,L8,M8,N8,H9,N9,H10,N10,H11,N11,H12,N12,H13,J13,K13,L13,M13,N13 | Real, from `docs/pinouts.md` |
| VCCAUX | 2.5V ±5% | F6, P6, F15, P15 | Real, from `docs/pinouts.md` |
| VCCIO0 | 1.2–3.3V (bank 0) | F9, F10 | Real ball pair; bank/signal assignment TBD |
| VCCIO1 | 1.2–3.3V (bank 1) | F11, F12 | Real ball pair |
| VCCIO2 | 1.2–3.3V (bank 2) | H14, H15, J15 | Real |
| VCCIO3 | 1.2–3.3V (bank 3) | L14, L15, M15 | Real |
| VCCIO6 | 1.2–3.3V (bank 6, used by SDRAM) | L6, L7, M6 | Real — SDRAM signals (see PINOUT.md) live in banks 6/7; 3.3V assumed, matching the SDRAM device's own real LVCMOS33 requirement, NOT yet independently cross-verified |
| VCCIO7 | 1.2–3.3V (bank 7, used by SDRAM) | H6, H7, J6 | Real, same note as VCCIO6 |
| VCCIO8 | config bank | P9, P10 | Real — Lattice's own documentation explicitly ties this rail's voltage to whichever configuration interface is used (OPEN, see Configuration decision below) |
| SDRAM VDD / VDDQ | 3.3V | (external chip, not an FPGA ball) | Per the real AS4C4M16SA-6TIN datasheet's own 3.3V industrial-grade part number |
| Configuration supply | 3.3V (typ.) | tied to VCCIO8 | Depends on the configuration-path decision (OPEN, see below) |

VSS/VSSIO (ground) balls: real per `docs/pinouts.md`'s own note — all
must be connected to the ground plane, none left floating (standard
BGA practice, explicitly called out in the source data).

## What is NOT decided (OPEN ITEMS)

- **Regulator topology/part numbers**: not selected. This project's own
  memory notes reference a sibling repository (`../basic-ecp5-pcb`)
  with a real, working power tree (TLV62568×2 + TLV73325) as a
  possible reference — but that repository is **not present on disk**
  in this environment (confirmed during this step's own audit), so it
  cannot be verified or cited as a concrete plan this round. A future
  step should either locate that reference design or select
  regulators from scratch against the real current budget below.
- **Maximum estimated current**: not computed. This requires a real
  power estimate from the actual synthesized netlist (Lattice's own
  power calculator/estimation tools were not run this session) — NOT
  invented here. The real, measured resource utilization (TRELLIS_FF=
  6425, TRELLIS_COMB=6023, MULT18X18D=32, DP16KD=0 at N=4, POST-P&R,
  STEP19) is available as an INPUT to such a calculation, but the
  calculation itself was not performed.
- **Decoupling/bulk capacitance**: not specified — a schematic-level
  decision that depends on the final regulator selection above.
- **Startup/power sequencing**: ECP5 devices generally require VCC and
  VCCAUX to be sequenced correctly relative to VCCIO and the
  configuration source per Lattice's own real application notes — this
  project has not yet consulted or reproduced those real sequencing
  requirements; flagged as OPEN, not assumed compatible.

## Summary

| Item | Status |
|---|---|
| Real rail voltage requirements (VCC/VCCAUX/VCCIO/SDRAM) identified | Done, from real device specs |
| Regulator selection | **OPEN — not made, no real reference design available this session** |
| Current budget | **OPEN — not computed, would require running a real power-estimation tool** |
| Decoupling/bulk capacitance | **OPEN — depends on regulator selection** |
| Power sequencing verification | **OPEN — not yet checked against real Lattice app notes** |
