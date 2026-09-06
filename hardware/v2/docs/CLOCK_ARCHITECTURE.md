# FPGA-Neural V2 — CLOCK ARCHITECTURE

## Status: CRITICAL — real, unresolved oscillator/clock-input mismatch

## What the RTL actually assumes

Every module in the frozen hierarchy (`nms_neural_multiprocessor_
sdram_unified.v` down to `sdram_controller.v`) takes a **single** `clk`
input and treats it directly as both the system clock AND the SDRAM
clock (`CLK_FREQ_MHZ=80` is a pure timing-derivation parameter fed
into `sdram_controller.v`'s own `ns_to_cycles()` function — it does
NOT configure a PLL; there is no PLL anywhere in this hierarchy).
Confirmed mechanically: every real synthesis run this project has
performed (STEP16 through this freeze) reports `EHXPLLL: 0/4 0%` in
nextpnr's own device-utilisation output — **zero PLL primitives are
instantiated**, in any variant, ever.

**This means the design requires a real, external 80MHz (or faster)
clock source wired directly to the FPGA's clock input pin.**

## The real gap

This project's own memory notes (established in an earlier session,
before the SDRAM decision) record the confirmed hardware target board
as using a **16MHz** oscillator. 16MHz ≠ 80MHz, and there is no PLL in
the current RTL to bridge that gap. **Two mutually exclusive
resolutions exist, and neither has been chosen:**

1. **Source an oscillator that directly provides ≥80MHz** (a
   commodity part — plain crystal oscillators at 80, 100, or higher
   MHz are standard, low-risk components) and retire the 16MHz
   assumption. Zero RTL change required. Simplest, lowest-risk path.
2. **Keep the 16MHz oscillator and add a real PLL** (ECP5's own
   `EHXPLLL` primitive, e.g. 16MHz→80MHz = ×5) to the RTL, with its
   own real timing constraints (lock time, jitter, generated-clock
   declaration in the constraints file) — genuinely new RTL/constraint
   work, not yet done, and not exercised by any of this project's own
   real synthesis/timing-closure runs to date (every Fmax number in
   STEP16-18 assumes a clean, ideal `clk` input, not a PLL output with
   its own jitter/lock-time budget).

**This is an OPEN, real architectural decision, not a detail** — it
determines whether a new oscillator needs sourcing or a PLL needs
designing, and affects the CLOCK_SOURCE→FPGA_CLOCK diagram below,
which cannot be finalized until it is made.

## Clock tree (as far as it CAN be stated today)

```
[UNRESOLVED: either an 80MHz+ oscillator, or a 16MHz oscillator + PLL]
        |
        v
   FPGA clk pin (ball location: BLOCKER, see PINOUT.md)
        |
        v
   single system clock domain, 80 MHz target
        |
        +--> Neural Multiprocessor / Dependency Manager / Director /
        |    Memory Manager / Neural Processors (all synchronous,
        |    single clock domain — confirmed, no clock-domain-crossing
        |    logic exists anywhere in the frozen hierarchy)
        |
        +--> SDRAM controller (same clock, no separate SDRAM clock
             domain — sdram_controller.v drives the SDRAM chip's own
             CLK pin combinationally/directly from the same system
             clock; real board layout must still budget for the
             SDRAM's own real clock-to-pin round-trip delay, which
             was NOT part of this project's own RTL-simulation/P&R
             timing closure — flagged as an OPEN ITEM for board bring-
             up, see FIRST_POWER_ON.md)
```

## Reset

A single `rst` input, synchronous to `clk` in every module observed
(no asynchronous reset assertion/de-assertion synchronizer chain was
found in this session's own lint pass). **Reset release timing/
synchronization to a real external reset source (power-on reset chip,
button, or host-driven) has not been designed** — this is a normal,
solvable board-level concern (a standard POR/supervisor IC), not
flagged as a blocker, but not yet decided (OPEN ITEM).

## Clock constraints used so far

Every P&R run in STEP16-18 used `nextpnr-ecp5 --freq 80` (a target
frequency for the placer's own timing-driven effort), NOT a real `.lpf`
`FREQUENCY` constraint tied to a real pin — because no `.lpf` exists at
all for any V2 top-level (see PINOUT.md). A real constraints file with
a proper `FREQUENCY PORT "clk" 80 MHZ;` (or the real achieved-vs-
required frequency once the oscillator/PLL decision above is made)
must be written before this can be considered a genuine, board-ready
clock constraint.

## Summary

| Item | Status |
|---|---|
| Single-clock-domain RTL, no CDC logic found | Confirmed by lint, real |
| PLL present in RTL | **No — confirmed absent (0/4 EHXPLLL in every P&R run)** |
| Oscillator frequency vs required system clock | **CRITICAL — 16MHz (prior project memory) vs 80MHz (RTL requirement), unresolved** |
| Oscillator-vs-PLL decision | **OPEN — not made** |
| Real `.lpf` clock constraint | Partial — `hardware/v2/constraints/v2_unified.lpf` now exists with a frequency constraint and clk/rst ball reuse from V1; full ball-level pinout for the remaining 147 signals is still blocked (see PINOUT.md) |
| Reset synchronization to a real external source | OPEN, not yet designed (not a hard blocker) |
| SDRAM clock-to-pin board-level timing budget | OPEN — not part of RTL-level timing closure |
