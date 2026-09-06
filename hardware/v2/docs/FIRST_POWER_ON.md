# FPGA-Neural V2 — FIRST POWER-ON PROCEDURE

Target: single-SDRAM V2 board (`nms_neural_multiprocessor_sdram_
unified`, N=4/P8). This procedure defines the MINIMUM real bring-up
test sequence; it cannot be executed on real hardware until the
BLOCKER items in CHIP_READINESS.md (host interface, ball-level
pinout) are resolved — it is written now so the bring-up plan is
ready the moment those blockers close, per the governing spec's own
"prepare the procedure now" instruction.

| # | Step | Stimulus | Expected result | Failure condition | Debug method |
|---|---|---|---|---|---|
| 1 | Power rails | Apply VCC/VCCAUX/VCCIO/SDRAM VDD per POWER_ARCHITECTURE.md | All rails reach nominal voltage within regulator spec time | Any rail fails to reach nominal, or sequencing violates ECP5 requirements | Multimeter/scope on each rail; check regulator datasheets |
| 2 | FPGA configuration | Load the real bitstream (from `nextpnr-ecp5` + `ecppack`, using the FINAL ball-assigned LPF once available) via JTAG or config flash | Device accepts configuration without protocol error | `INITN` asserts (config error) or configuration hangs | Check JTAG chain continuity, config clock, bitstream integrity |
| 3 | DONE | Observe `DONE` pin | `DONE` goes high after configuration completes | `DONE` stays low | Re-check bitstream, JTAG/flash wiring, PROGRAMN sequencing |
| 4 | Clock | Apply/verify the system clock (source per the CLOCK_ARCHITECTURE.md decision — direct oscillator or PLL output) | Clock present at the real ball (H5), correct frequency (80MHz target) | No clock, wrong frequency, excessive jitter | Scope on the clock net; if a PLL is used, verify PLL lock indicator |
| 5 | SDRAM initialization | Release `rst`; observe `sdram_controller.v`'s own real power-up sequence (200µs wait → PRECHARGE ALL → 8× AUTO REFRESH → LOAD MODE REGISTER) | Controller reaches `S_IDLE` (state=7); no `SDRAM_MODEL`-equivalent protocol violation on a real logic analyzer trace of CS#/RAS#/CAS#/WE# | Controller never reaches idle; command sequence doesn't match JEDEC power-up | Logic analyzer on SDRAM command pins; compare against `sdram_controller.v`'s own documented power-up sequence |
| 6 | SDRAM memory test | Issue a real write/read/masked-write sequence via JTAG-driven register pokes (or a dedicated bring-up test harness) covering all three memory-map regions (weights/activations/results) | Bit-exact readback, matching `tb_sdram_unified_backend.v`'s own already-simulated Test A/B/C patterns | Data mismatch, corruption, timeout | Compare against the exact patterns already validated in simulation; check DQM wiring/timing on the real board |
| 7 | Neural Processor test | Register a single independent node (required=0) with a known small weight/activation vector | `reg_ready` handshake completes; a single MAC/accumulate/ReLU/saturate result appears at the expected result address, bit-exact vs the golden software model already used in simulation | No dispatch, wrong result, saturation/overflow mismatch | Compare against the SAME golden model used throughout STEP16-19's own simulation; JTAG-readback intermediate signals if available |
| 8 | Neural Multiprocessor test | Register 4 independent nodes (one per slot) simultaneously | All 4 slots dispatch, execute, and complete without contention errors; results bit-exact | Any slot stalls/deadlocks/produces wrong result | Same golden-model comparison; check `slot_mem_arbiter`/`slot_mem_arbiter_wide` real transaction ordering |
| 9 | Known neural network | Run the full D-Stress workload (256 neurons, 4096 tiles) already validated in simulation (EXP-0048: 49,771 cycles @ N=4) | All 256 results bit-exact vs golden; real wall-clock time within the expected range for the real achieved Fmax | Any neuron wrong, deadlock, timeout | Same golden-model comparison already used in every STEP16-19 simulation |
| 10 | Store result | Confirm result-region SDRAM writes (memory-map region `0x300000`) | Real logic-analyzer/JTAG readback of the result region matches step 9's own expected values | Writes don't land at the expected address, or land with wrong byte masking | Check DQM wiring specifically (the STEP19-introduced write-masking mechanism) |
| 11 | Read result | Read back results via the real host interface (once it exists) or a bring-up JTAG readback path | Bit-exact match to the golden model | Mismatch | Same as step 10 |
| 12 | Compare golden | Full comparison of all 256 D-Stress results against the SAME software golden model used in every prior simulation step | 256/256 bit-exact | Any mismatch | Root-cause exactly as this project's own established discipline requires (real bug investigation, not silent tolerance) — see errors.log for the project's own precedent |

## Real hardware uses ONE physical SDRAM

Every step above assumes and tests the single-SDRAM architecture
(DEC-0034) — there is no separate PSRAM to bring up or test
separately; steps 5–6 cover the ENTIRE external memory subsystem in
one pass.

## Blockers preventing this procedure from running today

- Step 2 needs a real, ball-assigned bitstream — blocked by PINOUT.md.
- Steps 7–12 need a real host interface to issue registrations and
  read results — blocked by the same "110-pin raw bus, no serializer"
  finding in PINOUT.md/SCHEMATIC_READINESS.md.
- Step 1 needs a real power design — blocked by POWER_ARCHITECTURE.md.

This procedure is otherwise complete and ready to execute the moment
those blockers close.
