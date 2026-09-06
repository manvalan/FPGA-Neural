# NMS Real Weight Prefetch Engine (STEP11)

Status: implemented, bit-exact verified, benchmarked against the real
V1 PSRAM chain, synthesized. **Not adopted as the default NMS
configuration** — see Outcome/Recommendation below. Full data:
`hardware/v2/nms/reports/nms_prefetch_sweep.csv`,
`nms_prefetch_summary.md`; full narrative:
`hardware/v2/logs/experiments.log` (EXP-0023, EXP-0024),
`decisions.log` (DEC-0023), `errors.log` (ERR-0015).

## Problem

The "Current NMS" baseline (`nms_memory_manager.v`, backed by
`prefetch_engine.v`) measured `prefetch_effectiveness≈0%` and
`weight_stall≈92.5%` at N_SLOTS=2 (EXP-0022). Tracing the actual RTL
(not assuming from filenames) showed the real gap: `prefetch_engine.v`
is a single-shot FSM (`ST_IDLE`/`ST_READ_W`/`ST_DONE`) that can only
have **one fetch in flight at a time**, and `nms_memory_manager.v`'s
own restart logic only re-triggers the next tile's fetch once the
*previous* tile's fetch has fully completed and the FSM has returned
to idle — paying a real per-tile control-plane restart cost on every
tile boundary. The gap was never insufficient lookahead *distance*
(the old design already tried to fetch as far ahead as `n_tiles`
allowed); it was zero *outstanding-request depth*.

## Real backend constraint

`memory_interface.v` → `psram_controller.v` (V1, reused verbatim,
never modified) is a fire-and-forget, **one-transaction-in-flight**
protocol: a single `mem_req` pulse, wait for `mem_ready`, and that IS
the whole transaction. No wire-level pipelining is physically possible
against a real single PSRAM port. So "multiple outstanding requests"
cannot mean multiple simultaneous word transactions — it means
eliminating the *control-plane* overhead paid at every tile boundary
and letting the fetch stream run continuously across tiles, queueing
up to `PREFETCH_DISTANCE` tiles of lookahead ahead of consumption.

## Design: `weight_prefetch_engine.v`

Two monotonic counters fully describe the engine (tiles are always
fetched in strict sequential order, never reordered or re-fetched, so
no per-tile state array is needed):

- `fetch_tile`/`fetch_word` — the next word to request (or the word
  currently in flight).
- `ready_count` — tiles 0..`ready_count`-1 are fully resident in the
  weight SRAM.

`consumed_count` (the consumer's own tile index, `nms_memory_manager_pf.v`'s
`tile_idx`) bounds a configurable lookahead window:
`window_limit = consumed_count + PREFETCH_DISTANCE`; the engine may
fetch tile K only if `K < n_tiles` **and** `K < window_limit`.

The core mechanism: on `mem_ready && req_outstanding`, the just-completed
word is committed **and**, in the same cycle, the very next request is
issued — either the same tile's next word, or (at a tile boundary) the
next tile's first word — giving zero-gap streaming across tile
boundaries against a backend that only ever has one word in flight.
(An earlier draft used mutually-exclusive `if/else-if` branches for
"commit" vs. "issue next", which reintroduced a 1-cycle gap between
*every* word, not just tile boundaries; fixed by merging both into one
branch — see `weight_prefetch_engine.v`'s own header comment.)

## Integration: the "_pf" A/B variants

Per the explicit "preserve the current NMS baseline" constraint, the
new engine was integrated into parallel `_pf`-suffixed files, leaving
the originals untouched:

- `nms_memory_manager_pf.v` — drop-in replacement for
  `nms_memory_manager.v`'s external interface; internally swaps the
  private `prefetch_engine.v` instance for `weight_prefetch_engine.v`,
  and changes `can_present`'s weight-ready check from
  `tile_idx < wgt_fetched` to `tile_idx < wgt_ready_count`.
- `nms_dataflow_core_pf.v` — mirrors `nms_dataflow_core.v`, adds a
  `PREFETCH_DISTANCE` parameter, instantiates `nms_memory_manager_pf`.
- `nms_neural_multiprocessor_pf.v` — mirrors
  `nms_neural_multiprocessor.v`, instantiates `nms_dataflow_core_pf`.

Both the baseline (`nms_neural_multiprocessor.v`) and the prefetch
variant (`nms_neural_multiprocessor_pf.v`) remain in the repository
side by side; neither supersedes the other.

## Verification

`hardware/v2/nms/sim/tb_weight_prefetch.v` — isolated correctness
testbench: real `sim_word_mem` (configurable extra latency), real
`nms_weight_packed.v` production SRAM, bit-exact fill-pattern checking.
Covers `n_tiles ∈ {0,1,2,PFD,PFD+1,MAX_TILES-1,MAX_TILES}`, back-to-back
jobs with no explicit reset, a dedicated windowing-cap test (frozen
consumer, confirms `ready_count` stops exactly at
`min(PFD,MAX_TILES)`), and (post-ERR-0015) a large-PFD regression case.
10/10 (9/9 at PFD≥MAX_TILES) tests pass bit-exact across
PFD∈{1,2,4,8,32} and under injected extra memory latency.

`hardware/v2/nms/sim/tb_nms_dstress_pf.v` — full real-integration
benchmark: identical D-Stress workload/golden-model/correctness
criteria as `tb_nms_dstress.v` (EXP-0022), instantiating
`nms_neural_multiprocessor_pf` with a `PFD_CFG` parameter, plus new
testbench-only instrumentation for `weight_stall_cycles` and
`prefetch_effectiveness` (tiles consumed with zero weight-blocking
cycles beforehand / total tiles consumed — the exact STEP11
definition). All runs pass 256/256 neurons bit-exact vs. the golden
model.

## ERR-0015: a real bug found and fixed

The initial `window_limit` computation truncated the
`PREFETCH_DISTANCE` *parameter itself* to `CNTW` bits
(`PREFETCH_DISTANCE[CNTW-1:0]`) before adding it to `consumed_count`.
At `MAX_TILES=16` (`CNTW=5` bits), `PFD=32` truncates to 0, making
`window_limit == consumed_count` forever and deadlocking the engine
completely (0/256 neurons ever completed, 0% PSRAM utilization).
Fixed by computing `window_limit` and its comparisons in a fixed
32-bit width, using the untruncated parameter value. Regression-tested
in `tb_weight_prefetch.v`. Full writeup: `errors.log` ERR-0015.

## Results and outcome

See `nms_prefetch_summary.md` for the full comparison table and the
nine explicitly-answered final-report questions. In short:

- **N_SLOTS=1** (no port contention): a real, reproducible **-10.3%**
  cycle-count improvement (PFD=1 → PFD≥2), then a complete plateau —
  deeper buffering gives zero further benefit. Sustained MAC/cycle
  reaches only 2.8% of the theoretical target.
- **N_SLOTS=2** (this project's own primary reference configuration,
  real shared-port contention via `slot_mem_arbiter`): **zero
  measurable benefit** at any PREFETCH_DISTANCE from 1 to 16 — all
  runs are statistically indistinguishable from each other and from
  the pre-STEP11 baseline. The single physical PSRAM port is already
  saturated (90.5% busy, unchanged from baseline) by natural two-slot
  contention before any lookahead scheme can act.

**Final decision: Outcome B (N_SLOTS=1, partial) / Outcome C
(N_SLOTS=2, failure against the 90% criterion).** The mechanism is
correct and does measurably hide latency when the port has spare
capacity; it cannot manufacture bandwidth out of an already-saturated
single physical port. Reaching the STEP11 target would require ~36×
(N=1) to ~82× (N=2) more real PSRAM bandwidth — a hardware-level
constraint, not an RTL-scheduling one. Per DEC-0023, the new engine is
**not** recommended as the default NMS configuration; both variants
are preserved for reference. The evidence-backed next step (real PSRAM
bandwidth — wider bus, multiple independent banks, or a faster backing
technology) is flagged as future work, not undertaken this round.
