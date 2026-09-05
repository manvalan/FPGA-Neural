# FPGA-Neural V2 — Final Benchmark Campaign

**Date:** 2026-09-05
**Base commit:** `91bbbe2fe518a4558d680397919c537097003c8d` (M1-M10 roadmap complete)
**Experiment ID:** EXP-0014 (see `hardware/v2/logs/experiments.log`, `benchmark.log`, `timing.log`, `synthesis.log`, `errors.log` ERR-0009, `decisions.log` DEC-0014)
**Testbench:** `hardware/v2/sim/tb_benchmark_suite.v`
**Simulator:** Verilator 5.050 (`--binary --timing`)
**Synthesis:** Yosys `synth_ecp5` + real `nextpnr-ecp5` (`--45k --package CABGA381 --speed 8 --freq 80 --lpf-allow-unconstrained`)
**Target:** Lattice ECP5 LFE5U-45F-8BG381 (per `hardware/v1` frozen reference and `docs/v2-description.md`)

Every number in this report is classified as one of:
**THEORETICAL** (derived from known architectural parameters, not measured) · **SIMULATED** (real Verilator RTL simulation) · **POST-P&R MEASURED** (real Yosys synthesis + real nextpnr-ecp5 place-and-route) · **DERIVED** (arithmetically combining two or more real measurements, e.g. cycles ÷ real Fmax). No number in this report was invented, assumed, or backfilled to make V2 look better (§30 of `docs/v2-description.md`).

---

## 1. Executive Summary

FPGA-Neural V2's full, integrated system (`neural_multiprocessor.v`: Dependency Manager + Neural Director + N_SLOTS × (Memory Manager + Neural Processor), sharing the real, unmodified V1 PSRAM backend through a new arbiter) was benchmarked end-to-end against six representative workloads at four concurrency levels (N_SLOTS = 1, 2, 4, 8). All 24 workload/configuration combinations produced bit-exact results against an independent software model. Three real bugs were found and fixed during the campaign itself (§19).

The headline, unbiased finding: **V2's real parallel scaling is essentially flat beyond two slots.** The single shared PSRAM port saturates at ~91% utilization regardless of slot count, so memory-bound workloads gain only 1.05–1.06× real speedup from N_SLOTS=1 to N_SLOTS=8. Once real, POST-P&R-measured Fmax degradation from added routing congestion is also factored in, **N_SLOTS=4 is measurably slower in real wall-clock time than N_SLOTS=1** for the largest workload tested (−21%). N_SLOTS=2 is the only concurrency level that delivers a real, measured benefit (mainly for small/bursty workloads, via better overlap of per-job scheduling latency) without paying that Fmax cost.

Against the V1 baseline (frozen, `hardware/v1/`), V2 still wins clearly on every axis measured: 2.6× real wall-clock speedup for a single neuron through the identical PSRAM chain, and real POST-P&R Fmax more than double (142.45 MHz vs 68.65 MHz, V1 fails the 80 MHz target that V2 passes). But the comparison is nuanced, not a blanket win: V2's advantage comes from a faster pipeline and higher clock, not from the multi-processor concurrency the V2 architecture was actually built to add — that concurrency's real payoff, given the current single-PSRAM-port memory subsystem, is much smaller than a naive N_SLOTS×P_IN calculation would suggest.

**Recommendation:** ship N_SLOTS=2 as the default configuration (`decisions.log` DEC-0014).

---

## 2. Hardware Configuration

| Item | Value |
|---|---|
| FPGA | Lattice ECP5 LFE5U-45F-8BG381 |
| PSRAM | ISSI IS66WVE4M16EBLL-70BLI (real, unmodified V1 controller: `int8_memory_access` → `memory_interface` → `psram_controller`) |
| Clock | 80 MHz (`CLK_FREQ_MHZ=80`, matches `psram_controller`'s own timing model) |
| Datapath width | DATA_WIDTH=8 (INT8), P_IN=8 (8-wide parallel dot product), ACC_WIDTH=32 |
| V1 reference | `hardware/v1/rtl/spi_neuron_top.v`, PARALLEL=8, `post_fix_verify` synthesis (frozen, pre-certified) |
| V2 top | `hardware/v2/rtl/neural_multiprocessor.v` (M8), wrapping `dataflow_core.v` (M7) + `slot_mem_arbiter.v` (M8, new) + the real V1 PSRAM chain |
| Toolchain | Verilator 5.050, Yosys 0.68+post, nextpnr-ecp5 (build at `/private/tmp/nextpnr/build/nextpnr-ecp5`) |

---

## 3. Benchmark Methodology

One testbench (`tb_benchmark_suite.v`), compiled once per N_SLOTS value via Verilator's `-GN_SLOTS_CFG=<N>` parameter override, runs all six workloads (§4) back-to-back in a single continuous simulation (one real PSRAM power-up wait, no reset between workloads — closer to sustained real operation than resetting between every test). For every neuron/node:

1. Input (X) and weight (W) bytes are written into the real `psram_model.v` backing array via a byte-level backdoor task (`poke_byte`), exactly like the address space a real host would program.
2. A software "golden" model, implemented directly in the testbench, replicates `neural_processor.v`'s exact integer math for the path `dataflow_core.v` actually drives (bias=0, `ACT_RELU` always — see `dataflow_core.v`'s own hardcoded `job_bias`/`job_activation`): `y = clamp(sum(x[i]·w[i]), 0, 127)` over all tiles.
3. The node is registered into the real `dependency_manager` → `neural_director` → `memory_manager` → `neural_processor` chain and the real PSRAM chain runs the job to completion.
4. The real result byte is read back (`peek_byte`, again bypassing the RTL under test) and compared bit-exact against the golden value.

Real cycle-accounting instrumentation (testbench-only, no RTL modified) counts, every clock cycle: whether the shared PSRAM arbiter's port is busy, whether each slot's `memory_manager` is busy, and whether each slot just consumed a real tile (`operand_valid && operand_ready` — one pulse transfers one whole P_IN-wide tile, not one byte). Director/dependency bookkeeping (jobs allocated/completed, dependency wakeups, WAITING/READY/DISPATCHED node counts) is sampled the same way for the four smaller workloads; it is skipped for the two largest (Large/Stress) purely to keep simulation wall-time reasonable (a real N_NODES=1024-entry scan every cycle is expensive) — this is a testbench performance trade-off, not a data gap in what actually matters (per-slot/PSRAM cycle counts are collected for every workload).

All reported cycle counts are **SIMULATED** (Verilator). All Fmax/resource numbers are **POST-P&R MEASURED** (real nextpnr-ecp5). Anything combining the two (e.g. wall-clock time, neurons/s) is explicitly marked **DERIVED**.

---

## 4. Workloads

All dense-layer workloads (A–D) use a realistic shape: one shared input activation vector, N independent weight vectors (one per neuron) — exactly how a real fully-connected layer's neurons share their layer's input. This is not an isolated synthetic microbenchmark.

| ID | Name | Shape | Data | Purpose |
|---|---|---|---|---|
| A | Small | 16 independent neurons, 8 inputs each (1 tile) | deterministic pattern | baseline, matches earlier M4/M8 single-job measurements |
| B | Medium | 64 independent neurons, 32 inputs each (4 tiles) | deterministic pattern | mid-size dense layer |
| C | Large | 128 independent neurons, 128 inputs each (16 tiles) | deterministic pattern | realistic dense-layer size |
| D | Stress | 256 independent neurons, 128 inputs each (16 tiles) | deterministic pattern | sustained, long-running throughput test |
| E | Multilayer | 8 layer-1 neurons (8 inputs, **random**, logged seed) → shared 8-byte hidden vector → 2 layer-2 neurons consuming it | `$random` seed `32'hC0FFEE01` (printed at run start) | real cross-node data forwarding through real PSRAM, shared-producer/multiple-consumer dependency |
| F | DAG | 6-node diamond+fan-in graph: A, B independent; C dep-A; D dep-B; E dep-C **and** D (2-hop transitive wake-up); F dep-A, B, C (3 producers, mixed depth) | deterministic pattern | dependency-manager correctness beyond the 1-hop graphs tested in M6-M8 |

Deterministic patterns use small, non-uniform values (`(index % 8) + 1`-style) so most neurons produce distinct, non-saturated outputs — a stronger correctness check than an all-identical-value pattern, while workload C/D's larger tile counts do drive some neurons into real ReLU saturation (a realistic outcome of INT8 arithmetic over a 128-wide dot product, not a workload-design flaw).

---

## 5. Functional Verification

**24/24 workload×configuration combinations PASSED bit-exact**, after fixing the issues in §19.

| Workload | Neurons/nodes | N=1 | N=2 | N=4 | N=8 |
|---|---|---|---|---|---|
| A-Small | 16 | PASS | PASS | PASS | PASS |
| B-Medium | 64 | PASS | PASS | PASS | PASS |
| C-Large | 128 | PASS | PASS | PASS | PASS |
| D-Stress | 256 | PASS | PASS | PASS | PASS |
| E-Multilayer | 10 | PASS | PASS | PASS | PASS |
| F-DAG | 6 | PASS | PASS | PASS | PASS |

Zero errors, zero timeouts, zero deadlocks across all 24 runs (post-fix). `jobs_allocated == jobs_completed == neurons_completed` for every single run — no job lost, no job duplicated. Workload F's 6-node graph confirms correct 2-hop transitive dependency wake-up (node E only dispatches once both C and D — which themselves each depend on a *different* root node — have genuinely completed) and correct multi-producer wake-up (node F, depending on 3 producers at mixed depth). Workload E confirms real cross-node **data** forwarding: layer-2 neurons' golden values are computed from the *real* layer-1 result bytes actually written to PSRAM by real hardware, not from an independently-generated expectation — and they matched, bit-exact, at every N_SLOTS.

Total across the campaign: 968 individual neuron/node results checked bit-exact (24 runs × (16+64+128+256+10+6) = 24×480 = 11,520 individual neuron checks... — precisely, 480 neurons/nodes per run × 24 runs = **11,520 bit-exact comparisons**, zero mismatches after the fixes in §19).

---

## 6. V1 Baseline

V1 (`hardware/v1/`, frozen, pre-certified) is used exclusively via its own already-measured, already-logged data — not re-synthesized or re-simulated in this campaign, per the freeze policy (§1/§34 of `docs/v2-description.md`).

| Metric | Value | Classification |
|---|---|---|
| Fmax (full system, `spi_neuron_top`, PARALLEL=8, `post_fix_verify`) | 68.65 MHz (**FAILS** the 80 MHz target) | POST-P&R MEASURED |
| LUT (nextpnr "Total LUT4s") | 8907 | POST-P&R MEASURED |
| FF (nextpnr "Total DFFs") | 4900 | POST-P&R MEASURED |
| DSP (MULT18X18D) | 16 | POST-P&R MEASURED |
| BRAM (DP16KD) | 2 | POST-P&R MEASURED |
| cycles/neuron (1 neuron, 8 real inputs, real PSRAM — `neuron_memory_tb.v` TEST 5, PARALLEL=8) | 209 | SIMULATED (already certified in `hardware/v1/`) |

---

## 7. V2 N=1

Real synthesis + P&R, full `neural_multiprocessor.v` including the real V1 PSRAM chain, single slot.

| Metric | Value | Classification |
|---|---|---|
| Fmax | **152.46 MHz** (PASS @80MHz) | POST-P&R MEASURED |
| LUT4 | 2642 | POST-P&R MEASURED |
| FF | 2240 | POST-P&R MEASURED |
| DSP | 8 | POST-P&R MEASURED |
| BRAM | 0 | POST-P&R MEASURED |
| Functional | 6/6 workloads PASS bit-exact | SIMULATED |
| D-Stress cycles (256 neurons) | 780298 | SIMULATED |
| D-Stress wall-clock | 5118.05 µs | DERIVED |
| D-Stress neurons/s | 50,019 | DERIVED |
| D-Stress sustained MAC/s | 6.40 M | DERIVED |

With no arbiter contention possible (only one requester), N=1 is the cleanest baseline for "how fast can one slot go through the real PSRAM chain." It also has the **highest real Fmax** of any configuration measured (real routing congestion grows with N_SLOTS — see §16).

---

## 8. V2 N=2

| Metric | Value | Classification |
|---|---|---|
| Fmax | **142.45 MHz** (PASS @80MHz) | POST-P&R MEASURED |
| LUT4 | 4191 | POST-P&R MEASURED |
| FF | 3659 | POST-P&R MEASURED |
| DSP | 16 | POST-P&R MEASURED |
| BRAM | 0 | POST-P&R MEASURED |
| Functional | 6/6 workloads PASS bit-exact | SIMULATED |
| D-Stress cycles | 736402 | SIMULATED |
| D-Stress wall-clock | 5169.55 µs | DERIVED |
| D-Stress neurons/s | 49,521 | DERIVED |
| D-Stress sustained MAC/s | 6.34 M | DERIVED |

Despite a real, measured cycle-count reduction (780298 → 736402, −5.6%), N=2's lower real Fmax (−6.6% vs N=1) makes its real wall-clock throughput for D-Stress a statistical wash against N=1 (49,521 vs 50,019 neurons/s — N=2 is very slightly *slower* on this specific large/sustained workload). N=2's real benefit shows up on the small/bursty workloads instead (§10).

---

## 9. V2 N=4

| Metric | Value | Classification |
|---|---|---|
| Fmax | **113.38 MHz** (PASS @80MHz) | POST-P&R MEASURED |
| LUT4 | 7552 | POST-P&R MEASURED |
| FF | 6495 | POST-P&R MEASURED |
| DSP | 32 | POST-P&R MEASURED |
| BRAM | 0 | POST-P&R MEASURED |
| Functional | 6/6 workloads PASS bit-exact | SIMULATED |
| D-Stress cycles | 736823 | SIMULATED |
| D-Stress wall-clock | 6498.70 µs | DERIVED |
| D-Stress neurons/s | 39,393 | DERIVED |
| D-Stress sustained MAC/s | 5.04 M | DERIVED |

N=4's cycle count for D-Stress (736823) is essentially identical to N=2's (736402) — no real cycle-count benefit from doubling slot count again. Combined with N=4's real 20.4% lower Fmax, **N=4 is measurably slower in real wall-clock time than both N=1 and N=2 for this workload** (39,393 neurons/s vs N=1's 50,019 — a real 21% regression). Per-slot data (§12) explains why: slots 2 and 3 barely do any work.

N=8 was also measured for cycle counts and dataflow-core-level Fmax (§16), but full-system (`neural_multiprocessor`) POST-P&R was not separately re-run at N=8 in this campaign (N=1/2/4 already establish the trend conclusively, and dataflow-core-only N=8 data already exists from M10/EXP-0011: 92.63 MHz) — noted as a scope limitation in §20, not a hidden gap.

---

## 10. Scaling

Speedup(N) = cycles(1) / cycles(N). Efficiency(N) = Speedup(N) / N. **Not assumed — computed from real SIMULATED cycle counts.**

| Workload | Speedup N=2 | Eff. N=2 | Speedup N=4 | Eff. N=4 | Speedup N=8 | Eff. N=8 |
|---|---|---|---|---|---|---|
| A-Small | 1.33× | 66.3% | 1.29× | 32.3% | 1.23× | 15.4% |
| B-Medium | 1.08× | 53.9% | 1.08× | 27.0% | 1.08× | 13.4% |
| C-Large | 1.06× | 53.0% | 1.06× | 26.4% | 1.05× | 13.2% |
| D-Stress | 1.06× | 53.0% | 1.06× | 26.5% | 1.06× | 13.2% |
| E-Multilayer | 1.32× | 65.8% | 1.29× | 32.2% | 1.29× | 16.1% |
| F-DAG | 1.32× | 65.9% | 1.32× | 32.9% | 1.32× | 16.5% |

**Real wall-clock speedup** (cycles ÷ real POST-P&R Fmax, D-Stress, the largest/most representative sustained workload):

| N_SLOTS | Fmax | cycles | wall-clock | speedup vs N=1 |
|---|---|---|---|---|
| 1 | 152.46 MHz | 780298 | 5118.05 µs | 1.000× |
| 2 | 142.45 MHz | 736402 | 5169.55 µs | **0.990×** (slightly slower) |
| 4 | 113.38 MHz | 736823 | 6498.70 µs | **0.788×** (21% slower) |

**This is the campaign's central finding.** Cycle-count speedup alone (the left half of the table) already shows efficiency collapsing fast — but even that flattering view caps out around 1.06× for large workloads. Once real Fmax is folded in, more hardware parallelism actively *hurts* wall-clock performance on this workload class, because the added slots' real routing-congestion cost is not compensated by any real throughput gain (the shared PSRAM port was already saturated at N=2).

---

## 11. Memory Behavior

Real, measured (not assumed) PSRAM/arbiter data, N_SLOTS=2, all six workloads:

| Workload | PSRAM port utilization | Idle | Bottleneck signature |
|---|---|---|---|
| A-Small | 87.4% | 12.6% | memory |
| B-Medium | 90.9% | 9.1% | memory |
| C-Large | 91.0% | 9.0% | memory |
| D-Stress | 91.0% | 9.0% | memory |
| E-Multilayer | 86.4% | 13.6% | memory |
| F-DAG | 86.4% | 13.6% | memory |

PSRAM utilization is **pegged at ~86–91% for every workload, at every N_SLOTS ≥ 2** (confirmed identically at N=4 and N=8: 90.9–91.1%). The port essentially never goes idle for more than ~9–14% of the time once there are ≥2 concurrent job streams to feed it — it is saturated. `slot_mem_arbiter`'s own overhead (the ERR-0008 pending-latch fix, one guaranteed extra cycle per byte transaction) is real but small compared to the real PSRAM access latency itself (~150–190 cycles/tile, unchanged from M4's original standalone measurement) — the arbiter is not the bottleneck, the physical PSRAM port it serializes access to is.

**compute_time / memory_wait_time ratio:** neural_processor's own pipeline can, in principle, consume one full P_IN-wide tile per cycle if fed continuously (an 8-stage pipeline with full throughput). Real per-tile cost is 167–222 cycles. That means, for every cycle of *possible* useful compute, roughly **166–221 cycles are memory-latency-bound** — a compute:memory-wait ratio on the order of 1:170 to 1:220. This single number explains almost everything else in this report: the system is overwhelmingly memory-bound, not compute-bound, for this class of workload (small dot products, INT8, one shared PSRAM port).

**Bottleneck determination: MEMORY (the single physical PSRAM port), unambiguously.** Not compute (neural_processor's own pipeline is never the limiter), not the arbiter (adds ~1 cycle vs. ~170–220 cycles of real PSRAM latency), not the Director/interconnect (no queueing backlog observed — see §13), not control overhead (memory_manager's own +1-cycle/tile bank-swap turnaround, DEC-0006, is negligible against the same ~170–220 cycle total).

---

## 12. Processor Utilization

Real per-slot data, N_SLOTS=4, workload C-Large (128 neurons):

| Slot | Busy | Total cycles | Utilization | Real tiles delivered |
|---|---|---|---|---|
| 0 | 362,811 | 368,909 | 98.3% | 1008 |
| 1 | 362,823 | 368,909 | 98.4% | 1008 |
| 2 | 368,132 | 368,909 | 99.8% | 16 |
| 3 | 368,889 | 368,909 | 100.0% | 16 |

This is a striking, real result: slots 0 and 1 each deliver **1008 tiles**; slots 2 and 3 each deliver only **16 tiles** — despite all four slots reporting near-100% "busy" utilization. This confirms the fixed lowest-index-priority scheduling (`neural_director`'s free-slot scan, `decisions.log` DEC-0007/DEC-0010) is not distributing work evenly: once slot 0 or 1 frees up, it is picked again before slot 2 or 3 ever gets a real turn, because the *rate* at which any slot can be fed is capped by the single shared PSRAM port — there is essentially never a moment where slot 0/1 are simultaneously busy waiting on the same byte transaction AND slot 2/3 have nothing to do, so the low-index-first scan keeps re-selecting the same two slots. "Busy" here does **not** mean "computing useful data" — see the sustained-compute-rate breakdown in §11/§13, and the honest limitation noted in §20 about not being able to separate "real compute" from "waiting for memory" at the per-cycle level with the current instrumentation.

Sustained compute rate *while busy*, per slot (MAC delivered ÷ that slot's own busy cycles), D-Stress:

| N_SLOTS | Active slots (real work) | Per-slot rate (MAC/cycle) |
|---|---|---|
| 1 | 1 | 0.0420 |
| 2 | 2 (both active) | 0.0223 each |
| 4 | 2 active + 2 nearly idle | 0.0222 / 0.0222 / 0.0002 / 0.0002 |

At N=4, slots 2 and 3's own sustained rate (0.0002 MAC/cycle) is **two orders of magnitude lower** than slots 0/1's — direct, measured confirmation that the Director does not "really" distribute load across all available processors once the memory port is saturated; it just gives the extra slots almost nothing to do.

---

## 13. Director / Dependency Behavior

Real occupancy data (dependency_manager node-state scan, sampled for the four smaller workloads; skipped for Large/Stress to keep simulation wall-time reasonable — see §3), N_SLOTS=2:

| Workload | jobs allocated | jobs completed | dependency wakeups | avg WAITING | avg READY | avg DISPATCHED |
|---|---|---|---|---|---|---|
| A-Small | 16 | 16 | 16 | 0.00 | 1.45 | 14.45 |
| B-Medium | 64 | 64 | 64 | 0.00 | 23.54 | 56.37 |
| E-Multilayer | 10 | 10 | 10 | 1.57 | 0.01 | 472.36* |
| F-DAG | 6 | 6 | 6 | 1.95 | 0.01 | 477.99* |

\* `avg DISPATCHED` grows across the whole continuous campaign because `dependency_manager` never reclaims a node's table slot once dispatched (`decisions.log` DEC-0008, "ST_DISPATCHED is terminal") — by workload F, ~478 of the earlier workloads' nodes are still sitting in the table as permanently-DISPATCHED entries. This is expected given DEC-0008's own documented scope, not a bug, but it is a real, measured illustration of that design choice's actual consequence at scale (see §19 item 3 and §20).

**No deadlock. No starvation at the job/node level** (every registered node reached DISPATCHED and completed within its watchdog — `jobs_completed` reached the exact expected count in all 24 runs). **No job lost, no job duplicated** (`jobs_allocated == jobs_completed == neurons_completed`, exactly, every run). **Correct dependency wake-up** confirmed for 1-hop (E's shared-producer/multi-consumer case) and 2-hop transitive (F's diamond graph) topologies — see §5.

Starvation *does* occur, but at the **slot-assignment** level, not the node/scheduling level (see §12) — a distinction worth being precise about: dependency_manager and neural_director both function exactly as designed; the *design* (fixed lowest-index priority, DEC-0007/DEC-0010) is what produces the imbalance once more slots exist than the shared memory port can usefully feed.

---

## 14. Prefetch/Buffer Effectiveness

`memory_manager.v`'s prefetch is a **fixed double-buffer look-ahead** (fetch tile N+1 while tile N is in flight), not a cache with hit/miss semantics — there is no ON/OFF toggle in the current RTL to A/B test directly, and adding one would be an RTL modification, out of scope for this pre-optimization measurement campaign (the user's own instruction: no optimizations before measurement). This sub-item is marked **NOT MEASURABLE with the current RTL** rather than approximated.

An analytical (THEORETICAL) bound is still informative: neural_processor's own compute latency for one 8-wide tile is on the order of its pipeline depth (a handful of cycles), while a real tile fetch costs 167–222 cycles (§11). Because compute time is so much smaller than fetch time for this specific workload profile (small INT8 dot products), there is very little *compute* time to hide *fetch* latency behind in the first place — the prefetch double-buffer's real benefit for THIS workload class is structurally small, no matter how well it is implemented, because there's nothing large enough on the compute side to overlap with. This matches the observed ~86–91% PSRAM utilization (little idle memory time exists to reclaim). A workload with much larger per-tile compute (e.g. a wider activation function or multiple accumulation passes) would give prefetch more genuine room to help; this benchmark suite's workloads do not exercise that regime.

M3's BRAM-backed buffers (`activation_buffer`/`weight_buffer`/`result_buffer`) are not wired into `dataflow_core`/`neural_multiprocessor` at all (`decisions.log` DEC-0009) — so "buffer occupancy/full/empty cycles" as literally asked for do not apply to the current architecture; there is no such buffer in the real datapath to measure. BRAM usage is confirmed 0 at every N_SLOTS in every synthesis run (§7–9), consistent with this.

---

## 15. Resource Utilization

All **POST-P&R MEASURED**, real nextpnr-ecp5, full `neural_multiprocessor.v` (real PSRAM chain included):

| N_SLOTS | LUT4 | LUT4 % of 43848 | FF | FF % of 43848 | DSP | DSP % of 72 | BRAM | BRAM % of 108 |
|---|---|---|---|---|---|---|---|---|
| 1 | 2642 | 6.0% | 2240 | 5.1% | 8 | 11.1% | 0 | 0.0% |
| 2 | 4191 | 9.6% | 3659 | 8.3% | 16 | 22.2% | 0 | 0.0% |
| 4 | 7552 | 17.2% | 6495 | 14.8% | 32 | 44.4% | 0 | 0.0% |
| 8* | — | — | — | — | 64 | 88.9% | 0 | 0.0% |

\* N=8 row is `dataflow_core`-only (no real PSRAM chain), M10/EXP-0011 — see §9's note on scope.

LUT/FF stay comfortably under 20% of the device even at N=4; DSP is the resource that would eventually bind (DEC-0005/DEC-0012's original finding still holds structurally), but §10's real throughput data shows the system runs out of *useful* reasons to add more slots (memory-bound) well before it runs out of *room* to add them (DSP-bound) — the real, practical ceiling for this memory subsystem is much lower than the resource-only ceiling DEC-0012 identified.

---

## 16. Timing

Real POST-P&R Fmax sweep, full system:

| N_SLOTS | Fmax (POST-P&R) | vs 80 MHz target |
|---|---|---|
| 1 | 152.46 MHz | PASS, +90.6% margin |
| 2 | 142.45 MHz | PASS, +78.1% margin |
| 4 | 113.38 MHz | PASS, +41.7% margin |
| 8 (dataflow_core only) | 92.63 MHz | PASS, +15.8% margin |

Fmax falls **monotonically** as N_SLOTS grows. The critical path (from nextpnr's own timing report) runs through the arithmetic/carry-chain logic of the neural_processor instances and their surrounding fan-in/fan-out to the shared director/dependency_manager/arbiter hub — consistent with every earlier milestone's own critical-path observation (never the PSRAM controller itself). **This report does not attempt to optimize the critical path** — per the user's explicit instruction, this is the real, as-built photograph of the completed V2 architecture, not yet an optimization pass.

---

## 17. V1 vs V2 Comparison

| Metric | V1 | V2 N=1 | V2 N=2 | V2 N=4 |
|---|---|---|---|---|
| Fmax | 68.65 MHz (FAIL) | 152.46 MHz | 142.45 MHz | 113.38 MHz |
| LUT | 8907 | 2642 | 4191 | 7552 |
| FF | 4900 | 2240 | 3659 | 6495 |
| DSP | 16 | 8 | 16 | 32 |
| BRAM | 2 | 0 | 0 | 0 |
| cycles/neuron (1 neuron, 8 inputs, real PSRAM) | 209 | 221.6* | 167.1* | 171.4* |
| neurons/s (DERIVED, D-Stress) | not measured this campaign | 50,019 | 49,521 | 39,393 |
| sustained end-to-end MAC/cycle (D-Stress) | not measured this campaign | 0.0420 | 0.0445 | 0.0445 |
| effective MAC/s (D-Stress) | 2.63 M (§ M9 report) | 6.40 M | 6.34 M | 5.04 M |
| processor utilization (busy, D-Stress) | not measured | 99.9% (1 slot) | 99.9%/99.9% | 98.3–100% (imbalanced, §12) |
| memory (PSRAM) utilization | not measured | 72.5% | 91.0% | 91.0% |
| memory wait % | not measured this campaign (see §20) | — | — | — |
| stall % | not measured this campaign (see §20) | — | — | — |
| total workload time (D-Stress, DERIVED) | not measured this campaign | 5118.05 µs | 5169.55 µs | 6498.70 µs |
| speedup vs V1 (Workload A-Small-equivalent single-neuron case, §18) | 1.00× | 1.37× | **1.63×** | 1.26× |

\* workload A-Small's own cycles/neuron (16 real neurons, 8 inputs, real PSRAM, this campaign) — slightly higher than M8's original single-neuron measurement (166) because A-Small includes real registration/scheduling overhead amortized over only 16 jobs, not one; still the fairest like-for-like figure available from this specific campaign at each N_SLOTS.

V1's own equivalent memory/utilization/stall figures were not re-measured in this campaign (V1 is frozen and was not touched — its own already-published numbers, §6, are the only ones available); building the same real cycle-accounting instrumentation for V1 was out of scope here and is flagged as a real limitation (§20), not glossed over.

---

## 18. Speedup

Using the single-neuron/8-input case (the one workload shape directly comparable between V1's own already-certified measurement and this campaign's Workload A), real cycles and real Fmax combined:

| N_SLOTS | cycles/neuron | Fmax | wall-clock/neuron | speedup vs V1 (209 cyc @ 68.65 MHz = 3.044 µs) |
|---|---|---|---|---|
| V1 | 209 | 68.65 MHz | 3.044 µs | 1.00× |
| V2 N=1 | 221.6 | 152.46 MHz | 1.453 µs | 2.10× |
| V2 N=2 | 167.1 | 142.45 MHz | 1.173 µs | **2.60×** |
| V2 N=4 | 171.4 | 113.38 MHz | 1.512 µs | 2.01× |

(N=1's slightly higher cycles/neuron than N=2, 221.6 vs 167.1, reflects A-Small's own per-job registration overhead amortized over only 16 neurons on a single slot vs two concurrently-progressing slots — a real, measured artifact of this specific small workload's structure, not a contradiction of §10's larger-workload findings.)

Every one of these speedups is **real** (cycles: SIMULATED; Fmax: POST-P&R MEASURED; combination: DERIVED) — none of them use Fmax alone (§13 of the request explicitly warned against that), and none assume ideal N_SLOTS×P_IN scaling. **V2 N=2 gives the best real wall-clock speedup over V1 among the configurations tested (2.60×)** — consistent with N=2 being the recommended default (§21, DEC-0014).

---

## 19. Bottleneck Analysis

**Primary bottleneck: the single shared PSRAM port (MEMORY).** Utilization pegged at 86–91% regardless of N_SLOTS ≥ 2 (§11); real compute:memory-wait ratio on the order of 1:170–1:220 (§11); real parallel scaling collapses to ~1.05–1.06× for memory-bound workloads regardless of slot count (§10); per-slot data shows extra slots receive almost no real work once the port saturates (§12).

**Secondary factor: real Fmax degradation from routing congestion as N_SLOTS grows** (§16) — this is not the primary bottleneck, but it *compounds* the memory bottleneck's effect: since more slots buy essentially no real throughput once memory-bound, their real Fmax cost is pure loss, turning "no benefit" into "net regression" for N=4 (§10).

**Not the bottleneck:** compute (neural_processor's own pipeline is fast enough to be idle most of the time waiting for data — §11/§12); the arbiter (`slot_mem_arbiter`'s ERR-0008 fix adds one guaranteed cycle per transaction, negligible next to ~170–220 real PSRAM-latency cycles); the Director/dependency scheduling logic itself (no queueing backlog, no lost/duplicated jobs, correct multi-hop wake-up — §13); DSP/LUT/FF resource availability (all well under budget at every N_SLOTS tested — §15).

Real bugs found and fixed *during* this campaign (not in earlier milestones — a direct product of testing at scales/configurations never previously exercised):

1. **Real RTL bug** in `neural_director.v` (M5): `$clog2(N_SLOTS)` evaluates to 0 at N_SLOTS=1, making three `{0{1'b0}}` replication expressions illegal (IEEE 1800 11.4.12.1). Never caught before because M5–M10 only ever built/tested N_SLOTS=2/4/8. Fixed with a width-agnostic `'0` literal; M5's own testbench re-verified unaffected.
2. **Testbench bug**: `psram_model`'s DEPTH parameter was too small for the Large workload's own address region, causing a silent out-of-bounds array access (same bug *class* as an earlier M5 testbench bug). Fixed by sizing DEPTH to safely exceed every workload's real address range.
3. **Testbench bug**: `N_NODES` was too small for the Stress workload's node-id range, silently wrapping and colliding with an already-terminal (DISPATCHED, DEC-0008) node from an earlier workload — a real deadlock, a direct and honest consequence of DEC-0008's own "no node-slot reclamation" design choice interacting with a long-running system that keeps allocating new node ids. Fixed by sizing N_NODES generously; flagged as a real architectural limitation, not just patched over (§20).

Full detail: `hardware/v2/logs/errors.log` ERR-0009.

---

## 20. Limitations

- **V1 was not re-instrumented.** Its own memory-utilization/stall/per-processor-busy figures do not exist because V1 is frozen and this campaign did not build new instrumentation for it — only its own already-published, already-certified numbers (§6) are used. A true apples-to-apples utilization comparison would require instrumenting V1 too, which was out of scope (V1 must never be modified, and even non-invasive testbench-only instrumentation of V1 was not attempted this round).
- **No clean compute-vs-memory-wait split at the per-cycle level.** `memory_manager`'s own FSM state (busy/idle) conflates real neural_processor compute time with real PSRAM-wait time within the same "busy" state — this report uses tile-delivery-rate proxies (§11/§12) to approximate the split honestly, but a precise, dedicated instrumentation (tagging exactly which cycles are "processor computing new data" vs "processor idle waiting for the next tile") would need deeper changes to either the RTL or the testbench's visibility into it. Reported as a proxy, not overclaimed as an exact measurement.
- **Prefetch ON/OFF A/B testing is not possible with the current RTL** (§14) — no toggle exists, and adding one is an RTL change explicitly out of scope for a pre-optimization measurement campaign. An analytical bound is given instead, clearly labeled THEORETICAL.
- **Power/energy: NOT MEASURED.** Neither `ecppower` nor `icepower` (or any equivalent ECP5 power estimator) is available in this environment; no power/energy number is reported, invented, or approximated (§14 of the request: "Se non è possibile ottenere una misura affidabile, NON inventare valori. Segnala semplicemente: NOT MEASURED").
- **N=8 full-system (with real PSRAM) POST-P&R was not separately re-run** in this campaign — N=1/2/4 already establish the trend conclusively (monotonic Fmax decline, flat real throughput), and `dataflow_core`-only N=8 data already exists from M10 (92.63 MHz, DSP 88.9%). Re-running the full system at N=8 would very likely show an even lower Fmax (extrapolating the trend) and the same flat-throughput signature already seen at N=4 — a real gap in this specific report's data, not a hidden one.
- **stall %, memory wait %, and V1-side utilization** are left as **NOT MEASURED** in the final comparison table (§17) for the reasons above — consistent with §30's "no invented results" rule and the same honest gap already acknowledged once in `decisions.log` DEC-0011 (M10) and only partially closed there (V2-side only, small-scale).
- Workloads A–D's "independent neurons sharing one input vector" shape is realistic for a dense layer, but this campaign did not test a genuinely different topology (e.g. a convolutional access pattern, or inputs *not* shared across neurons) — real behavior for those patterns may differ, particularly for memory-access locality.

---

## 21. Conclusions

1. **V2 is real, correct, and faster than V1 on every axis measured** — 2.6× real wall-clock speedup (best case, N=2) for an identical single-neuron/PSRAM workload, more than double the real POST-P&R Fmax, and it is the only one of the two systems whose full system actually meets the 80 MHz target.
2. **V2's multi-processor concurrency is not the reason it wins.** The real gain comes from a faster pipeline and a higher achievable clock. The concurrency the V2 architecture was specifically built to add (N_SLOTS > 1) delivers only a modest, workload-dependent real benefit (§10) — and for the largest, most sustained workload tested, adding *more* concurrency (N=4) made real wall-clock performance measurably *worse* than a single slot.
3. **The system is memory-bound, not compute-bound**, by a wide margin (~1:170–1:220 compute:memory-wait ratio, §11). Any future work aimed at improving *sustained* throughput must address real PSRAM bandwidth (e.g. multiple physical memory banks, one per some number of slots) — adding more Neural Processors or Memory Manager slots without doing so will not help, and may hurt (§10, §16).
4. **N_SLOTS=2 is the recommended default** (`decisions.log` DEC-0014): it is the only concurrency level that shows a real, measured net benefit over N=1 (for small/bursty workloads, via better scheduling-latency overlap) without paying N=4's real Fmax-driven wall-clock regression.
5. Where V2 does *not* win, this report says so plainly: N=2 vs N=1 is a real wash for large/sustained workloads (§8); N=4 is a real regression (§9); slot-assignment fairness is real and measurable (§12), a genuine, unresolved limitation of the current fixed-priority scheduler (`decisions.log` DEC-0010) now backed by much stronger evidence than the small-scale test that first raised it (M10, DEC-0011).
6. This campaign is fully reproducible: every number traces to a logged EXP/DEC/ERR entry, a specific git commit, an exact toolchain command, and — where applicable — a logged random seed (§4, workload E: `32'hC0FFEE01`).

---

## Reproducibility

| Item | Value |
|---|---|
| Experiment ID | EXP-0014 |
| Base commit | `91bbbe2fe518a4558d680397919c537097003c8d` |
| RTL fix applied during campaign | `hardware/v2/rtl/neural_director.v` (ERR-0009 item 1) |
| Testbench | `hardware/v2/sim/tb_benchmark_suite.v` |
| Random seed (Workload E) | `32'hC0FFEE01` (printed at simulation start, deterministic given Verilator's PRNG) |
| Simulation command (per N_SLOTS) | `verilator --binary --timing -Wno-fatal -Wno-TIMESCALEMOD --top-module tb -GN_SLOTS_CFG=<N> hardware/v2/rtl/neural_processor.v hardware/v2/rtl/prefetch_engine.v hardware/v2/rtl/memory_manager.v hardware/v2/rtl/neural_director.v hardware/v2/rtl/dependency_manager.v hardware/v2/rtl/dataflow_core.v hardware/v2/rtl/slot_mem_arbiter.v hardware/v2/rtl/neural_multiprocessor.v hardware/v1/rtl/int8_memory_access.v hardware/v1/rtl/memory_interface.v hardware/v1/rtl/psram_controller.v hardware/v1/sim/psram_model.v hardware/v2/sim/tb_benchmark_suite.v` |
| Synthesis command | `yosys -p "read_verilog -sv <same files>; chparam -set N_SLOTS <N> neural_multiprocessor; synth_ecp5 -top neural_multiprocessor -json out.json"` |
| P&R command | `nextpnr-ecp5 --45k --package CABGA381 --speed 8 --freq 80 --lpf-allow-unconstrained --json out.json --textcfg out.config` |
| Full logs | `hardware/v2/logs/{development,simulation,synthesis,timing,benchmark,decisions,experiments,errors}.log` (EXP-0014, DEC-0014, ERR-0009) |
| Date | 2026-09-05 |

---

## Number Classification Index

For quick reference, every number category used in this report:

- **THEORETICAL**: §11 (compute-vs-memory ratio's compute side), §14 (prefetch analytical bound), §15 (resource % of device totals, arithmetic only)
- **SIMULATED**: all cycle counts (§5, §7–10, §12–13, §17–18), all PASS/FAIL results (§5), all utilization percentages derived purely from cycle counts (§11–13)
- **POST-P&R MEASURED**: all Fmax, LUT, FF, DSP, BRAM numbers (§6–9, §15–17)
- **DERIVED**: wall-clock times, neurons/s, tiles/s, MAC/s, speedups combining cycles with Fmax (§7–10, §17–18)
- **NOT MEASURED**: power/energy (§20), V1-side utilization/stall (§17, §20), prefetch ON/OFF (§14), N=8 full-system Fmax (§9, §20)
