# FPGA-Neural V2 — SCHEMATIC READINESS

## Status: NOT READY

## Block diagram (what a hardware designer needs to know)

```
   ┌─────────────┐        ┌──────────────────────────────┐
   │  Clock       │  clk   │                              │
   │  BLOCK       ├───────►│                              │
   │  (OPEN item: │        │                              │
   │  16MHz osc   │  rst   │           FPGA BLOCK          │
   │  vs 80MHz    ├───────►│   LFE5U-45F-8BG381/CABGA381   │
   │  needed --   │        │                              │
   │  see CLOCK_  │        │  nms_neural_multiprocessor_   │
   │  ARCHITECTURE│        │  sdram_unified (N_SLOTS=4)    │
   │  .md)        │        │                              │
   └─────────────┘        │  ┌────────────────────────┐  │      ┌───────────────┐
                            │  │ SDRAM interface (37 pins)├──────►│  SDRAM BLOCK   │
                            │  │ sdram_cke/cs_n/ras_n/    │  │      │ AS4C4M16SA-6TIN│
                            │  │ cas_n/we_n/ba/a/dq/dqm   │  │      │ (ONE chip --   │
                            │  └────────────────────────┘  │      │ weights+       │
                            │                              │      │ activations+   │
                            │  ┌────────────────────────┐  │      │ results ALL    │
                            │  │ Host bus (110 pins,     │  │      │ here)          │
                            │  │ BLOCKER -- raw parallel, │  │      └───────────────┘
                            │  │ not a real protocol yet) │  │
                            │  └────────────────────────┘  │
                            │                              │
   ┌─────────────┐         │  ┌────────────────────────┐  │
   │ CONFIG BLOCK │  JTAG   │  │ TDI/TDO/TCK/TMS/        │  │
   │ (OPEN: no    ├────────►│  │ PROGRAMN/INITN/DONE/    │  │
   │ flash part   │  SPI    │  │ CCLK (standard ECP5,    │  │
   │ chosen)      ├────────►│  │ ball location BLOCKED)  │  │
   └─────────────┘         │  └────────────────────────┘  │
                            └──────────────────────────────┘
                                        │
                            ┌───────────┴───────────┐
                            │      POWER BLOCK        │
                            │ VCC 1.1V / VCCAUX 2.5V / │
                            │ VCCIO 3.3V / SDRAM 3.3V  │
                            │ (OPEN: regulators not    │
                            │ selected)                │
                            └──────────────────────────┘

   ┌─────────────┐
   │ HOST BLOCK   │  <-- BLOCKER: does not exist yet as real RTL.
   │ (a real MCU/ │      Must serialize the 110-pin reg_* bus into
   │ SPI/UART     │      a real physical protocol (SPI, matching V1's
   │ interface)   │      own spi_neuron_top.v precedent, or similar)
   └─────────────┘

   ┌─────────────┐
   │ DEBUG/JTAG   │  <-- standard ECP5 JTAG chain; no V2-specific
   │ BLOCK        │      debug infrastructure beyond that identified
   └─────────────┘      this round.
```

## Interconnections a schematic designer needs (real, from the RTL)

- **FPGA ↔ SDRAM**: 37 real signals (`sdram_cke`, `sdram_cs_n`,
  `sdram_ras_n`, `sdram_cas_n`, `sdram_we_n`, `sdram_ba[1:0]`,
  `sdram_a[11:0]`, `sdram_dq[15:0]` bidirectional, `sdram_dqm[1:0]`) —
  a single-chip, direct point-to-point connection (no bus sharing, no
  second memory device). Real bank/ball assignment is BLOCKED (see
  PINOUT.md) but the SIGNAL LIST itself is complete and final.
- **FPGA ↔ Clock**: one clock input pin (ball H5, reused from V1's own
  real, validated assignment) — the SOURCE feeding that pin (direct
  80MHz+ oscillator, or 16MHz oscillator + internal PLL) is an OPEN
  decision (see CLOCK_ARCHITECTURE.md); the schematic cannot be
  finalized for this block until that choice is made.
- **FPGA ↔ Reset**: one reset input pin (ball B4, reused from V1) —
  real synchronization to a power-on-reset supervisor or button is
  OPEN (not designed).
- **FPGA ↔ Configuration**: standard ECP5 JTAG/config pins exist by
  device definition; whether the board ALSO includes an SPI
  configuration flash (for standalone, non-JTAG boot) is an OPEN
  decision (see CHIP_READINESS.md and OPEN_ITEMS.md).
- **FPGA ↔ Host**: **BLOCKER**. The real RTL currently exposes a
  110-pin raw parallel bus with no serializing interface. A schematic
  cannot meaningfully route "the host connection" until a real
  physical protocol (and its own RTL bridge) exists.
- **FPGA ↔ Power**: standard ECP5 rail requirements (VCC/VCCAUX/VCCIO)
  plus the SDRAM's own 3.3V rail — real regulator selection is OPEN
  (see POWER_ARCHITECTURE.md).

## What IS ready

- The FPGA/package/speed-grade target is fixed and unambiguous
  (LFE5U-45F-8BG381, CABGA381, -8).
- The external memory device is fixed and unambiguous (ONE
  AS4C4M16SA-6TIN, no second chip).
- The complete, real signal list for the SDRAM interface is final (37
  signals, confirmed by real POST-P&R synthesis).
- Real rail VOLTAGES (not currents) are known from device datasheets.

## What blocks starting the schematic today

1. Host interface: no real physical protocol exists (BLOCKER).
2. Ball-level pinout: no real assignment exists for SDRAM or host
   signals (BLOCKER, same root cause as PINOUT.md's own finding).
3. Clock source decision: oscillator-only vs oscillator+PLL (CRITICAL,
   OPEN).
4. Power regulator selection and current budget (OPEN).
5. Configuration-flash decision (OPEN).

**Conclusion: NOT READY.** A hardware designer could begin laying out
the SDRAM-to-FPGA net list today (that part is real and complete), but
could not close the schematic without resolving items 1–5 above.
