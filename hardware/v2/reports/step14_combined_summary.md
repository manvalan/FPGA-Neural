# NMS STEP14 — Weight Datapath Scaling & Activation Fabric Timing: Final Report

Full data: `step14_weight_scaling.csv`, `step14_activation_timing.csv`
(this dir). Architecture: `docs/architecture/weight_datapath_scaling.md`,
`docs/architecture/activation_fabric_timing.md`. Full narrative:
`hardware/v2/logs/experiments.log` (EXP-0029 through EXP-0033),
`decisions.log` (DEC-0026, DEC-0027, DEC-0028).

## Critical comparison table

Real, measured (POST-P&R Fmax/resources; RTL SIMULATION bit-exact
cycles, real V1 PSRAM chain unless noted). D-Stress workload (256
neurons, 16 tiles each) throughout.

| Configuration | N | Fmax (MHz) | Pass 80MHz | LUT4 | CCU2C | FF | DSP | Total cycles | Sustained MAC/cyc |
|---|---|---|---|---|---|---|---|---|---|
| Current NMS (pre-STEP13) | 1 | 160.18 | ✓ | — | — | 2281 | 8 | n/a | n/a |
| Current NMS | 2 | 93.10 | ✓ | 1948 | 266 | 3522 | 16 | 185645 | 0.1765 |
| Current NMS | 4 | 56.62 | ✗ | — | — | 6004 | 32 | 184764 | ~0.177 |
| Streaming NMS (STEP13) | 1 | 137.76 | ✓ | 1464 | 200 | 2245 | 8 | n/a | n/a |
| Streaming NMS | 2 | 95.25 | ✓ | 1908 | 362 | 3449 | 16 | 185398 | 0.1767 |
| Streaming NMS | 4 | 55.22 | ✗ | 2937 | 705 | 5877 | 32 | 184771 | 0.1773 |
| Streaming + wider weight path (IDEAL, MEM_DATA_WIDTH=64, not real-hardware-deployable) | standalone | n/a (I/O-oversubscribed, POST-SYNTH only) | — | 144 | 71 | 386 | 0 | n/a (1 cyc/tile ideal) | n/a |
| Streaming + activation timing fix (v3) | 1 | 138.85 | ✓ | 1431 | 206 | 2282 | 8 | n/a | n/a |
| Streaming + activation timing fix | 2 | **136.09** | ✓ | 1999 | 371 | 3507 | 16 | 185270 | 0.1769 |
| Streaming + activation timing fix | 4 | **106.81** | ✓ | 2776 | 705 | 5957 | 32 | 184771 | 0.1773 |
| Streaming + activation timing fix (= Combined architecture) | 8 | 52.25 | ✗ | 4653 | 1367 | 10855 | 64 | 184771 | 0.1773 |

The "Combined architecture" *is* the "streaming + activation timing
fix" row — Part A's weight-width fix is not realizable on real
hardware (see below), so there is nothing further to combine at the
physical level this round.

## Part A — Weight Datapath Scaling: summary

Built `weight_prefetch_engine_wide.v` (parameterized `MEM_DATA_WIDTH`)
and `nms_memory_manager_stream_wide.v`. Bit-exact at all 4 widths
(16/32/64/128, 9/9 tests each). Ideal-memory cycles/tile: 4, 2, **1**,
1 — confirming **64-bit is the exact architectural point** (matches
`P_IN×DATA_WIDTH`) that removes the weight-fetch bottleneck entirely
(100% of theoretical per-tile rate). 128-bit gives zero further
benefit. **Critically: this cannot be realized on the current board.**
The real V1 PSRAM is a fixed 16-bit physical chip; the already-existing
real `weight_prefetch_engine.v` already represents the "64-bit logical
via 16-bit physical" packing case, and its real measured rate (4
cycles/tile) proves logical width alone yields zero real benefit
without a matching physical bandwidth increase. See
`weight_datapath_scaling.md` for full reasoning.

## Part B — Activation Fabric Timing: summary

Exact critical path traced from the real P&R report (not assumed):
`resident_tag` → `max_n_tiles` computation (line 92) → `resident_count
< max_n_tiles` comparison (line 165) → `pf_start`/`pf_addr`, two
chained 16-bit comparisons in one combinational cone, 18.11 ns. Fixed
in two iterations: v2 (register once) reached 72.78 MHz (insufficient);
v3 (separate the per-slot tag-equality stage from the max-fold stage)
reached **106.81 MHz** at N=4 (+93.4%), bit-exact, zero throughput
regression at N=2 (in fact N=2's own Fmax jumped to 136.09 MHz as a
bonus — the same chain was present there too, just under the 80 MHz
threshold already). N=8: DSP/LUT/FF all feasible, but Fmax still fails
(52.25 MHz) — the fold itself is still O(N_SLOTS)-deep; v3 shifted the
crossover point, a further log₂(N_SLOTS)-scaling fix would be needed
for N=8 (not undertaken, N=8 is exploratory only).

## Roofline update

The EXP-0024 model `T(k) = 17.544 + 167.854/k` is **superseded** by a
decomposed model built from real, RTL-traced components (EXP-0033):

```
T(n_tiles) = T_startup_drain + n_tiles × T_weight     [real hardware, N=1]
           = 16 + n_tiles × 4                           [cycles]
```

- **T_control** (memory-manager serialization): was 3/4 of the old
  floor's per-tile cost — **fixed** (STEP13), now ~0.
- **T_weight** (real 16-bit PSRAM bus): still 4 cycles/tile — a
  **physical bus-width floor**, proven (ideal) to reach 1 cycle/tile
  at 64 bits, but not realizable without a physical bandwidth increase.
- **T_activation** (Fmax only): fixed (Part B) — zero effect on cycle
  count, only on achievable clock frequency.
- **T_startup_drain** (~16 cycles/job): unchanged by any fix, a small,
  genuinely separate, already-minimal residual.
- **T_external_memory** (real port contention, N_SLOTS≥2): the true
  dominant real bottleneck — N=2/4/8 all produce statistically
  identical real cycle counts (185270/184771/184771) despite
  theoretical MAC/cycle scaling 16/32/64. Untouched by any fix in
  STEP13 or STEP14, since neither touches the physical port itself.

**Does the new architecture remove the previous 11.674% asymptotic
ceiling?** **No, not on real hardware today** — the ceiling is
numerically unchanged (still 11.674% at N=2), because its dominant
cause (T_weight, physical bus width, ~64 of every 68.5 cycles/neuron)
was never addressable by any RTL-scheduling fix; the fixes made in
STEP13 (T_control) and STEP14 Part B (T_activation/Fmax) targeted
smaller, genuinely separate components that were already minor
relative to the bus-width floor. **In principle, yes** — both the
control-plane ceiling (STEP13) and the weight-fetch-rate ceiling
(STEP14 Part A, ideal) have *already* been shown to reach the
architectural optimum (1 cycle/tile); only the physical PSRAM interface
itself remains as the blocker, a hardware/board-level dependency
outside this project's own RTL scope.

A DERIVED, hypothetical upper bound (NOT a real-hardware promise):
*if* physical bandwidth reached 64 bits *and* N=2 slots had fully
independent, uncontended ports (unrealistic for a single physical
memory), utilization would reach **50%** — a large improvement over
1.1%, but still short of the 90% target, and almost certainly optimistic
once real port contention at 64-bit width is accounted for (not
measurable — no such real hardware exists to test).

## The twelve final questions, answered directly

1. **Is 16-bit weight delivery fundamentally insufficient for P_IN=8?**
   Yes — costs 4× the achievable minimum (4 vs. 1 cycle/tile).
2. **Is 32-bit enough?** No — still 2× the minimum.
3. **Is 64-bit the natural architectural point?** Yes, exactly —
   proven cycle-exact (`P_IN×DATA_WIDTH`).
4. **Does wider logical weight delivery actually improve real
   throughput?** No, not on this board — requires a matching physical
   bandwidth increase; logical width alone is provably inert (DEC-0028).
5. **What is the exact activation-fill critical path?** `resident_tag`
   → `max_n_tiles` fold (line 92) → `resident_count` comparison (line
   165) → `pf_start`/`pf_addr` — two chained 16-bit comparisons, no
   register between, 18.11 ns total. Traced from the real P&R report,
   not assumed.
6. **What is the minimum fix required for N=4 ≥80 MHz?** Two pipeline
   stages: register the per-slot tag-equality/masking result, then
   separately register the max-fold result before its use — v3,
   106.81 MHz.
7. **Does N=4 become genuinely useful after both fixes?** Timing: yes
   (106.81 MHz, real margin). Throughput: no — real cycle count is
   statistically identical to N=2 (single shared PSRAM port
   saturated), so absolute throughput does not improve, only headroom
   for a future bandwidth increase does.
8. **Is N=8 timing/resource feasible?** Resource: yes (DSP 89%, LUT/FF
   comfortable). Timing: no (52.25 MHz) — the max-fold's O(N_SLOTS)
   depth reappears at 2× the N=4 depth; a log₂(N_SLOTS)-scaling fix
   is required and not yet built.
9. **What external memory bandwidth is required after these fixes?**
   Unchanged from EXP-0024's own quantification (~36-82× today's real
   bandwidth for 90/95/99% targets) — these fixes make the RTL ready
   to exploit that bandwidth if it existed; they do not create it.
10. **What internal SRAM/banking architecture should be designed
    next?** None needed for weight/activation SRAM sizing itself
    (already adequate); the next design target is external —
    real PSRAM bus width/banking, and (separately) a log₂(N_SLOTS)
    activation-fold pipeline for N=8.
11. **Should `neural_processor.v` remain unchanged?** Yes — confirmed
    again this STEP: it was never implicated in either bottleneck.
12. **What is the next experiment?** Two independent, concrete,
    evidence-backed candidates: (a) real hardware feasibility study of
    a wider/banked external PSRAM interface (board-level, outside RTL
    scope); (b) a balanced-tree (log₂(N_SLOTS)-depth) redesign of the
    activation-fill max-computation specifically for N=8.

## Final decision

Both parts closed with real, RTL-traced, bit-exact-verified evidence —
no assumption stood unverified. Part A establishes the precise
architectural requirement (64-bit) and proves it is currently
unrealizable (a hardware, not RTL, gap). Part B delivers a real,
adopted fix (`nms_activation_fill_ctrl_v3.v`) that achieves N=4's
Fmax criterion outright with zero throughput cost. Neither fix moves
the real N=2/4/8 D-Stress cycle count, because both targeted
components that were never the dominant term — the dominant term
(external memory bandwidth) remains exactly as EXP-0024 quantified it,
now with full, precise attribution rather than an unexplained "fixed
overhead."
