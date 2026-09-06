# NMS STEP11 — Real Weight Prefetch & Latency Hiding: Final Report

Full raw data: `nms_prefetch_sweep.csv` (this dir),
`experiments/EXP-0023/weight_prefetch_ideal_sweep.csv`. Full narrative:
`hardware/v2/logs/experiments.log` (EXP-0023, EXP-0024),
`decisions.log` (DEC-0023), `errors.log` (ERR-0015).

## Final comparison table

All rows below are the real, official D-Stress workload (256
independent neurons, 128 inputs / 16 tiles each, one shared input
activation vector) through the real, unmodified V1 PSRAM chain.
Classification: RTL SIMULATION cycles + POST-P&R MEASURED Fmax/resources,
never mixed with a theoretical or ideal-memory number.

| Configuration | N_SLOTS | PFD | Cycles | Weight stall | Prefetch effectiveness | Sustained MAC/cycle | Utilization (% of theoretical) | LUT4 | FF | BRAM | Fmax |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Current NMS (baseline, no prefetch engine) | 2 | n/a | 185645 | 92.5% | 0.0% | 0.1765 | 1.10% | 1948 | 3522 | 0 | 93.10 MHz |
| NMS + weight prefetch | 1 | 1 (control) | 181489 | 87.91% | 0.02% | 0.1806 | 2.26% | — | — | — | — |
| NMS + weight prefetch | 1 | **2** | 162876 | 86.44% | 0.39% | 0.2012 | 2.52% | 1333 | 2245 | 0 | 132.26 MHz |
| NMS + weight prefetch | 1 | 8 | 162876 | 86.44% | 0.39% | 0.2012 | 2.52% | 1464 | 2245 | 0 | 137.76 MHz |
| NMS + weight prefetch | 2 | 1 (control) | 185410 | 93.32% | 0.78% | 0.1767 | 1.10% | — | — | — | — |
| NMS + weight prefetch | 2 | **2** | 185408 | 93.32% | 0.78% | 0.1767 | 1.10% | 1941 | 3449 | 0 | 97.16 MHz |
| NMS + weight prefetch | 2 | 8 | 185398 | 93.32% | 0.78% | 0.1767 | 1.10% | 1908 | 3449 | 0 | 95.25 MHz |
| NMS + weight prefetch | 2 | 16 | 185390 | 93.33% | 0.78% | 0.1768 | 1.11% | — | — | — | — |

(Theoretical MAC/cycle: 8 for N_SLOTS=1, 16 for N_SLOTS=2. PFD=4 and
PFD=16 rows at N_SLOTS=1, and PFD=4 at N_SLOTS=2, are omitted here
since they are measurement-identical to their neighbors — see the full
CSV for every point actually run.)

## The nine questions, answered directly

1. **Minimum useful PREFETCH_DISTANCE**: **PFD=2**. Every PFD from 2
   to 16 is measurement-identical at both N_SLOTS=1 and N_SLOTS=2 —
   there is no additional benefit from buffering deeper. PFD=1 is
   measurably worse (see the N_SLOTS=1 rows above).
2. **Maximum sustained MAC/cycle achieved**: 0.2012 (N_SLOTS=1,
   PFD≥2) and 0.1768 (N_SLOTS=2, PFD=16) — essentially unchanged from
   the pre-STEP11 baseline (0.1765 at N_SLOTS=2).
3. **Processor utilization**: 2.5% (N=1) / 1.1% (N=2) of theoretical
   peak — far below the 90% target at both configurations.
4. **Remaining weight stall**: 86.4% (N=1) / 93.3% (N=2) of total
   execution cycles — barely moved from the baseline's 92.5%.
5. **Is PSRAM bandwidth now sufficient?** **No.** Reaching the 90%
   target would require roughly **36×** (N=1) to **82×** (N=2) more
   real PSRAM bandwidth than is currently achieved. This is a hard,
   physical ceiling, not a scheduling artifact.
6. **Is PSRAM latency now sufficiently hidden?** **Partially, only at
   N_SLOTS=1** — the engine measurably eliminates the old per-tile
   control-plane restart gap (−10.3% cycles). **No, at N_SLOTS=2** —
   the shared port is already saturated (90.5% busy, identical to the
   baseline) by natural two-slot contention before any lookahead
   scheme gets a chance to act; there is no idle time left to hide
   latency into.
7. **Resource cost**: resource-neutral to slightly cheaper than the
   baseline (LUT4 −2.1%, FF −2.1% at N=2/PFD=8) — the new engine does
   not trade memory-bandwidth problems for a combinational-controller
   problem.
8. **Fmax post-P&R**: 132–138 MHz (N=1), 95–97 MHz (N=2) — all PASS at
   the 80 MHz target, and slightly *higher* than the baseline's 93.10
   MHz at N=2 (+2.3% to +4.4%).
9. **Has NMS achieved the original memory-system objective?** **No,
   not at N_SLOTS=2**, this project's own primary reference
   configuration. **Partially, at N_SLOTS=1**, where a real (if small)
   improvement was proven, bounded by real PSRAM bandwidth rather than
   latency.

## Final decision

**Outcome B (N_SLOTS=1, partial success) / Outcome C (N_SLOTS=2,
failure against the 90% criterion).** See DEC-0023 for full reasoning.
The mechanism is proven correct (bit-exact throughout, continuous
cross-tile-boundary word streaming verified in isolation and in the
real integration) and measurably helps when the PSRAM port has spare
capacity (N_SLOTS=1). It provides **no measurable benefit** at
N_SLOTS=2 because the single physical PSRAM port is already saturated
by cross-slot contention before latency-hiding can act — the honest
architectural finding STEP11 was designed to surface. Both
`nms_neural_multiprocessor.v` (Current NMS) and
`nms_neural_multiprocessor_pf.v` (+ weight prefetch) are preserved
side by side; neither supersedes the other. The evidence-backed next
step is real PSRAM bandwidth (wider bus / multiple banks / faster
memory), not a further on-chip scheduling redesign — explicitly
flagged as future work, not undertaken this round.
