# FPGA-Neural V2 — Datasheet

**Status: DRAFT / PRE-RELEASE.** This datasheet documents the INTENDED
V2 board architecture as of STEP20. It does **not** certify a finished,
release-ready design — see §11 Limitations and
`hardware/v2/docs/OPEN_ITEMS.md` for the current, real blocker list.
Do not read any statement here as "physically validated" unless it
says so explicitly.

## 1. General

FPGA-Neural V2 is an embedded neural-network accelerator built around a
Lattice ECP5 FPGA and a single external SDRAM. It executes small,
dependency-graph-structured INT8 neural networks (dense layers, DAGs)
using a Neural Multiprocessor of parallel MAC engines, streaming
weight/activation tiles from one external SDRAM chip that also holds
results.

Architecture stack (top to bottom): SPI host interface → job
registration → Dependency Manager / Neural Director → N parallel
Neural Processors → Memory Manager / streaming tile delivery → Unified
SDRAM Backend → one physical SDRAM.

## 2. FPGA

| Item | Value | Basis |
|---|---|---|
| Part | Lattice LFE5U-45F | DESIGN DECISION |
| Package | CABGA381 | DESIGN DECISION |
| Speed grade | -8 | DESIGN DECISION |
| Ordering part number | LFE5U-45F-8BG381C | DESIGN DECISION (standard Lattice ordering suffix for this grade/package; not independently cross-checked against a live distributor listing this session) |
| Logic (post-synthesis, N=4, frozen STEP19 compute core) | TRELLIS_FF=6425, TRELLIS_COMB=6023, MULT18X18D=32, DP16KD=0 | VERIFIED (real Yosys synthesis, STEP19) |
| I/O used (frozen STEP19 top, no physical host bus) | 149/245 TRELLIS_IO | VERIFIED (real nextpnr-ecp5 P&R, STEP19) |
| I/O used (this step's new board-level top, SPI + osc + reset + SDRAM) | not yet synthesized this round | OPEN — see §11 |

Operating assumption: single clock domain, no CDC beyond the SPI
bridge's own double-flop synchronizers and the reset synchronizer
(§5).

## 3. Neural accelerator

| Parameter | Value |
|---|---|
| N_PROCESSORS | 4 (frozen reference; N=2 also validated; N=8 is a future evolution) |
| P_IN (MAC width) | 8 |
| Data representation | INT8 operands |
| Accumulator | INT32, ReLU + INT8 saturate on output |
| MAC architecture | 8-wide parallel MAC, balanced adder tree (`neural_processor.v`, unchanged since before this freeze) |
| Processor parallelism | N independent Neural Processors, one dependency-graph node in flight per processor |
| Supported memory traffic | weights (read-only, 64-bit packed fetch, cached), activations (read, byte-maskable), results (write, byte-maskable) — all through the SAME single SDRAM |

**RTL capability vs. software/API capability:** the RTL executes one
pre-compiled dependency graph (nodes with producer/consumer edges,
fixed tile counts) registered via 108 bits of per-job configuration
(node id, dependency list, activation/weight/result base addresses,
tile count). There is no on-chip graph compiler, no floating point, no
training — job graphs and addresses are computed off-chip and loaded
via the host interface (§9).

## 4. Unified memory

```
         ┌─────────────────────┐
         │      FPGA ECP5      │
         │                     │
         │  4x Neural Engines  │
         │         │           │
         │         v           │
         │ Unified SDRAM       │
         │ Backend / Arbiter   │
         └─────────┬───────────┘
                   │ 16-bit SDRAM bus
                   v
         ┌─────────────────────┐
         │ AS4C4M16SA-6TIN     │
         │ Weights             │
         │ Activations         │
         │ Results             │
         └─────────────────────┘
```

| Item | Value | Basis |
|---|---|---|
| Device | Alliance Memory AS4C4M16SA-6TIN | DESIGN DECISION (STEP16-19) |
| Capacity | 4M x 16 (8MB) | DATASHEET VALUE |
| Data width | 16-bit (DQ[15:0]) + DQM[1:0] byte mask | DATASHEET VALUE |
| Addressing | BA[1:0] (4 banks) + A[11:0] (row/col, multiplexed) | DATASHEET VALUE |
| Clock | shared with FPGA system clock (§5) | DESIGN DECISION |
| Initialization/refresh | real, RTL-implemented power-up wait + mode-register-set + periodic AUTO REFRESH (`sdram_controller.v`) | VERIFIED (real refresh events observed in simulation, STEP16-19) |
| Arbitration | single physical port, 2-way logical split: W (weight, read-only, cached) / AR (activation+result, read/write, byte-maskable), each internally arbitrated across N processors by a generic, reused `slot_mem_arbiter` | VERIFIED (STEP19 bit-exact regression, reconfirmed via Verilator this step — see errors.log ERR-0024) |
| Official V2 memory map | weights @0x010000, activations @0x200000, results @0x300000, all within the single 8MB space, 1MB-aligned | DESIGN DECISION |

PSRAM is **not** part of V2. The V1 PSRAM controller (`hardware/v1/rtl/psram_controller.v`) is not instantiated anywhere in the V2 physical path.

## 5. Clock / PLL

```
    16 MHz OSCILLATOR
            |
            v
    ECP5 PLL (EHXPLLL)
    CLKI_DIV=1  CLKFB_DIV=4  CLKOP_DIV=9
    FEEDBK_PATH=CLKOP  VCO=576MHz
            |
            v
    FPGA SYSTEM CLOCK
        64 MHz
       (real, tool-generated ratio: 16 * 4 / 1, CLKOP_DIV=9 -> 576/9=64)
```

| Item | Value | Basis |
|---|---|---|
| Oscillator | 16 MHz (board-level, prior project record) | DESIGN DECISION (part number: TBD — not selected this session) |
| PLL primitive | EHXPLLL (`ecp5_pll_sys_clk.v`) | VERIFIED design-time via Project Trellis `ecppll` v1.4 (real tool, real parameters) |
| Generated system clock | 64 MHz | DESIGN DECISION, chosen over 80MHz because STEP19's own multi-seed P&R data showed only 1/8 seeds closing timing at >=80MHz on the compute-only core, and the new board-level top adds more logic still; 64MHz is not yet itself confirmed by P&R on the NEW top (see §11) |
| PLL lock | `locked` output, feeds `reset_sync.v` | DESIGN DECISION; NOT simulatable (Lattice EHXPLLL has no open sim model) — real lock behavior is a real-hardware-only characterization, see §10 |
| Timing constraints | none yet written for the new board-level top | OPEN — see §11 |

## 6. Interfaces

### SPI host interface (`spi_host_bridge.v`)
Mode 0 (CPOL=0/CPHA=0), MSB-first, one opcode per CS-low period.
Opcodes: `0x10` WRITE_JOB (job registration, 15-byte payload), `0x01`
WRITE_MEM / `0x02` READ_MEM (raw, word-addressed SDRAM access via a
second arbitrated port), `0x20` STATUS, `0x0F` RESET. Verified in
isolation (18/18, `tb_spi_host_bridge.v`). **Not yet verified
end-to-end under realistic multi-job pacing** — see §11/ERR-0025.
The 110-pin `reg_*` bus used by V2's own internal simulation
testbenches is a testbench-only convenience and is **not** the
physical interface.

### JTAG
Standard ECP5 JTAG (TDI/TDO/TCK/TMS), always available regardless of
configuration boot mode, per Lattice's own standard requirement.

### Configuration
Standard ECP5 PROGRAMN/INITN/DONE/CCLK. Boot-mode/flash-part decision:
OPEN (see §11).

## 7. Electrical

Rail voltage requirements are DATASHEET VALUEs (from real device
datasheets); no regulator part numbers, current budget, or decoupling
values are finalized this round. Full detail:
`hardware/v2/docs/POWER_ARCHITECTURE.md`.

## 8. Pinout

Full table: `hardware/v2/docs/PINOUT.md`. Summary: 37 real SDRAM
signals + clk/rst are ball-assigned and P&R-verified (STEP19, against
the STEP19 compute-only top). The board-level top added this step
(SPI + oscillator + reset pins) has **not** had its own ball
assignment or P&R run yet.

## 9. Mechanical / board assumptions

None assumed beyond the package footprint implied by CABGA381. No PCB
dimensions, connector placement, or stack-up are specified — that is
schematic/PCB-capture work, not yet started (see
`hardware/v2/docs/SCHEMATIC_READINESS.md`).

## 10. Programming / first power-on

JTAG programming is standard. A first-power-on procedure exists at
`hardware/v2/docs/FIRST_POWER_ON.md` (procedure only — not executed
against real hardware, since no board has been fabricated).

## 11. Limitations (real, current, as of this datasheet's own writing)

- **The physical SPI host interface is NOT proven end-to-end
  correct.** A real, disclosed defect (errors.log ERR-0025 Part B)
  produces wrong results when two jobs are dispatched with realistic
  SPI pacing, even though registration itself is confirmed correct.
  This is the single largest open item.
- The board-level top (`fpga_neural_v2_top.v`) has not been through
  synthesis or P&R this round — deliberately, since running the real
  toolchain against RTL known to compute wrong answers would not be a
  meaningful result.
- No PCB, schematic capture, or fabricated hardware exists. Nothing in
  this document should be read as "physically validated."
- Regulator, configuration-flash, and connector part numbers are not
  selected.
- The STEP19 compute+memory core (raw `reg_*` interface, no SPI
  bridge) IS bit-exact verified (N=2 and N=4, 256/256, reconfirmed via
  Verilator this session) and remains the actual, working reference
  design underneath this datasheet's own described board architecture.
