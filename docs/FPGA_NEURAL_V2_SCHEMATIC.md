# FPGA-Neural V2 — Reference Schematic (textual)

**No KiCad schematic was generated this session.** No RTL-to-schematic
or netlist-to-KiCad automation tool is available in this environment,
and the project's own separate, pre-existing KiCad PCB directory
(`FPGA-Neural/FPGA-Neural/FPGA-Neural/`) is an unrelated, independently
tracked project (its own nested `.git`, near-empty as of last check) —
it was not touched, and this document does not assume its contents.
This is a textual/ASCII reference schematic: a real starting point for
PCB capture, not a substitute for one. All ball assignments below are
the real, P&R-verified ones from `hardware/v2/constraints/
v2_unified.lpf` (STEP19) unless marked otherwise.

## 1. Top-level block diagram

```
                     +---------------------------+
                     |        HOST MCU            |
                     |            SPI              |
                     +------------+----------------+
                                  |
                                  v
+----------------------------------------------------------+
|                    ECP5 FPGA (LFE5U-45F-8BG381)           |
|                                                            |
|  +--------------+     +---------------------------+       |
|  | SPI Host     |---->| Register / Control        |       |
|  | Bridge       |     | (job registration)        |       |
|  +--------------+     +-------------+-------------+       |
|                                      |                     |
|                        +-------------v-------------+       |
|                        | Neural Accelerator (N=4)   |       |
|                        | Processor 0..3             |       |
|                        +-------------+-------------+       |
|                                      |                     |
|                        +-------------v-------------+       |
|                        | Unified SDRAM Backend      |       |
|                        +-------------+-------------+       |
+----------------------------------------------------------+
                                       |
                                16-bit SDRAM bus
                                       v
                        +----------------------------+
                        | AS4C4M16SA-6TIN             |
                        | Weights / Activations /     |
                        | Results                     |
                        +----------------------------+

                16 MHz osc --> ECP5 PLL (EHXPLLL) --> 64 MHz system clock
                Power rails --> POR/supervisor --> FPGA reset, SDRAM init
                Configuration flash + JTAG connector (see 5/6)
```

## 2. SDRAM connection table (real, P&R-verified balls)

| Signal | Ball | Bank | I/O std (assumed) | Direction |
|---|---|---|---|---|
| CLK (shared w/ system clk) | H5 | — | LVCMOS33 | FPGA -> SDRAM |
| CKE | B5 | 7 | LVCMOS33 | FPGA -> SDRAM |
| CS_N | C5 | 7 | LVCMOS33 | FPGA -> SDRAM |
| RAS_N | C4 | 7 | LVCMOS33 | FPGA -> SDRAM |
| CAS_N | A3 | 7 | LVCMOS33 | FPGA -> SDRAM |
| WE_N | B3 | 7 | LVCMOS33 | FPGA -> SDRAM |
| BA[0] | E4 | 7 | LVCMOS33 | FPGA -> SDRAM |
| BA[1] | C3 | 7 | LVCMOS33 | FPGA -> SDRAM |
| A[0..11] | D5,D3,F4,E5,E3,F5,A2,B1,C2,C1,D2,D1 | 7 | LVCMOS33 | FPGA -> SDRAM |
| DQ[0..15] | E1,G5,H3,J5,K3,K2,H1,J1,K1,K4,L4,L5,M5,M4,N4,N5 | 7/6 | LVCMOS33 | bidirectional |
| DQM[0..1] | P5,N3 | 6 | LVCMOS33 | FPGA -> SDRAM |

Full source: `hardware/v2/constraints/v2_unified.lpf`. LVCMOS33 is
assumed to match the SDRAM's own real 3.3V requirement and matches
banks 6/7's real VCCIO range per `docs/pinouts.md` — not yet
independently cross-checked at the schematic/PCB level (WARNING, not
BLOCKER).

## 3. Clock schematic

```
  16MHz OSC ---> CLKI (H5, reused from V1's own real LPF)
                    |
              +-----v------+
              |  EHXPLLL   |  CLKI_DIV=1, CLKFB_DIV=4, CLKOP_DIV=9
              |  (hard IP) |  FEEDBK_PATH=CLKOP, VCO=576MHz
              +-----+------+
                    | CLKOP = 64MHz
                    v
             FPGA system clock (feeds compute, SDRAM ctrl, SPI bridge)
                    |
              +-----v------+
              | reset_sync |  <-- ext POR (active-low) + PLL LOCK
              +-----+------+
                    v
                 rst (sync-deassert, feeds every synchronous block)
```

Oscillator part number: **TBD** (not selected this session — a real
16MHz, 3.3V HCMOS clock oscillator in a standard SMD package is the
intended class of part; no specific manufacturer/part number is
claimed without a real datasheet lookup performed this session).

## 4. Power schematic (rails only — no regulator parts selected)

```
  3.3V/1.1V/2.5V rails (regulators: TBD)
       |         |          |
       v         v          v
    VCCIO      VCC(core)  VCCAUX
   (banks      (real ball  (real ball
    6/7=SDRAM   cluster,    cluster,
    I/O, etc)   see         see
                POWER_ARCH   POWER_ARCH
                .md)         .md)
       |
       v
   SDRAM VDD/VDDQ (3.3V, DATASHEET VALUE per AS4C4M16SA-6TIN)
```

Full rail table, decoupling guidance, and current-budget status:
`hardware/v2/docs/POWER_ARCHITECTURE.md` (unchanged this step — no new
power work performed).

## 5. Configuration / JTAG schematic

```
  FPGA
   |-- TDI/TDO/TCK/TMS --> JTAG connector (standard pinout, always
   |                       available regardless of boot mode)
   |-- PROGRAMN/INITN/DONE/CCLK --> configuration flash (part: TBD) or
                                     JTAG-only bring-up (decision: OPEN)
```

No configuration-flash part has been selected; JTAG-only bring-up
remains a valid fallback and is documented as such in
`hardware/v2/docs/CONFIGURATION.md`-equivalent content inside
`OPEN_ITEMS.md` (a dedicated `CONFIGURATION.md` was not created this
round — tracked as an open item, not silently dropped).

## 6. Host interface schematic

```
  Host MCU --SPI--> FPGA: spi_sclk, spi_mosi, spi_miso, spi_cs_n
```

No ball assignment exists yet for these 4 signals (the board-level
top was not run through P&R this session — see the datasheet's own
§11 Limitations). Pull-up on `spi_cs_n` (idle-high) is the standard,
expected design decision for a single-master SPI bus; not yet placed
in any real LPF.

## 7. What this schematic deliberately does NOT claim

- No KiCad artifact. No PCB. No fabricated board.
- No ball assignment for the new SPI/oscillator/reset pins (P&R not
  run against the new board-level top this session, since the design
  has a known, unresolved functional defect — see errors.log
  ERR-0025 Part B).
- No regulator, flash, or connector part numbers.

This document is a real, honest starting point for PCB capture, not a
finished schematic.
