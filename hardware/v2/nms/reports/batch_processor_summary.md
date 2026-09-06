# NMS STEP13 — Batch/Continuous Neural Processor: Final Report

Full data: `hardware/v2/nms/reports/batch_processor_sweep.csv`. Full
narrative: `hardware/v2/logs/experiments.log` (EXP-0025 through
EXP-0028), `decisions.log` (DEC-0024, DEC-0025). Architecture:
`hardware/v2/docs/architecture/neural_processor_batch.md`.

## What was actually built (and why it differs from the initial brief)

The governing spec framed the problem as "batch K neurons per
dispatch" to amortize the ~68.5-cycles/neuron non-memory floor
EXP-0024 measured for N_SLOTS=2. **Step 1's own mandatory RTL trace
overturned that framing before any RTL was written.**

Tracing `nms_memory_manager_pf.v` + `neural_processor.v` with a
zero-real-memory-latency isolated testbench (EXP-0025) showed the
floor is **93.4% explained by a 4-cycles/tile serialization bug**
inside the memory manager's own `ST_RUN` state (a strictly sequential
`read_issued → read_ready → present → consumed` chain with zero
overlap between tiles), not by per-job dispatch overhead (only 6.6% of
the floor). Neither the local SRAMs (1-cycle read latency) nor
`neural_processor.v` (designed for continuous 1-tile/cycle acceptance)
require this — it's purely an artifact of the manager's own
un-pipelined FSM.

**The fix built is therefore a continuous per-tile streaming redesign
of the memory manager** (`nms_memory_manager_stream.v`), not a
neuron-batching scheme. `neural_processor.v` was not modified — it was
never the bottleneck.

## Results

1. **The fix works exactly as designed** (EXP-0026): a read-ahead
   pointer + 1-deep skid buffer decouples "issue next tile's read"
   from "current tile consumed," confirmed cycle-by-cycle in
   simulation.
2. **It immediately exposed a second, previously-hidden bottleneck**
   at the *same* numeric value: `weight_prefetch_engine.v`'s own
   word-fetch rate is capped at 4 cycles/tile (P_IN=8 bytes ÷ 16-bit
   real PSRAM bus = 4 word-transactions/tile, 1 cycle/word minimum
   even at zero real latency) — a physical bus-**width** ceiling, not
   a latency or scheduling ceiling.
3. **Net real-system benefit at today's bandwidth: ~0%** (EXP-0028:
   185270 vs. 185398 cycles at N=2/PFD=8, -0.07%, noise-level). Bit-exact
   PASS, 256/256 neurons.
4. **The fix genuinely removes a 4× architectural ceiling** — proven
   directly (EXP-0027, a control experiment with weight-fetch
   bypassed): the new design achieves a clean **1 cycle/tile** (100%
   of `neural_processor.v`'s own theoretical per-tile acceptance
   rate), where the old design is hard-capped at 4 cycles/tile (25%)
   **regardless of bandwidth**. This ceiling is real and was
   previously invisible because a coincidentally-equal bandwidth
   ceiling was masking it.
5. **Resource/Fmax cost is small and in the expected direction**
   (EXP-0028): N=1 Fmax +3.7% (142.92 vs 137.76 MHz), N=2 Fmax -2.8%
   (92.57 vs 95.25 MHz, still comfortably above the 80 MHz target);
   LUT4/FF/CCU2C all within ±6%. No combinational-controller blowup.
6. **N=4 fails the 80 MHz target** (55.22 MHz) — but for a
   *different*, already-documented reason (`nms_activation_fill_ctrl.v`'s
   own priority-scan Fmax regression, first found in EXP-0022),
   unrelated to and unaffected by this STEP's own fix.

## The nine final-decision questions, answered directly

1. **Is per-neuron dispatch still acceptable?** Yes — it was never the
   dominant cost (only 6.6% of the floor). Batching neurons was not
   pursued; it would not have addressed the real bottleneck.
2. **What batch/stream granularity is optimal?** Per-*tile* streaming
   within a job (1-deep read-ahead), not per-neuron batching.
3. **What is the new fixed overhead?** With weight-fetch not the
   limiter, steady-state cost drops to 1 cycle/tile (down from 4) —
   the fixed per-job overhead (~17 cycles: entry, pipeline drain,
   write-back) is essentially unchanged and now the dominant residual
   cost per job.
4. **New asymptotic utilization ceiling?** For the control-plane
   component alone: 100% (removed entirely). For the *whole system*
   at today's real bandwidth: unchanged from EXP-0024's ~11.674%
   ceiling — the weight-fetch bus-width ceiling is now the sole real
   limiter.
5. **Does N=4 become viable?** No — blocked by a separate, pre-existing
   Fmax regression in the activation fill controller (55.22 MHz vs. 80
   MHz target), not by anything this STEP addressed.
6. **Does N=8 become viable?** No, for the same reason (N=4 already
   fails; N=8 was not synthesized given N=4's own failure).
7. **What memory bandwidth is actually required after this fix?** The
   same requirement EXP-0024 quantified (~36-82× today's real
   bandwidth for 90-99% targets) — this STEP's fix is *necessary but
   not sufficient*: without it, a future bandwidth increase would
   immediately hit the old 4-cycles/tile FSM ceiling and only realize
   25% of its potential benefit; with it, a future bandwidth increase
   can translate into up to 100% of its potential benefit.
8. **Is `neural_processor.v` reusable?** Fully reusable, unmodified —
   confirmed by direct RTL trace to already support the required
   continuous 1-tile/cycle acceptance; it was never the bottleneck.
9. **Next architectural step?** Real external memory bandwidth
   (wider bus, multiple independent PSRAM banks, or a redesigned
   weight-fetch protocol able to move more than one 16-bit word per
   cycle) — and, independently, the already-documented
   `nms_activation_fill_ctrl.v` Fmax regression that blocks N=4/N=8
   regardless of memory bandwidth. Both are flagged as future work,
   not undertaken this round.

## Final decision

**Outcome B** (STEP13's own framework: "batching/continuous execution
helps, but another bottleneck appears"). The executed fix — continuous
per-tile streaming inside the memory manager, not neuron-batching — is
real, correct (bit-exact), resource-neutral, and **removes a genuine,
previously-hidden 4× architectural ceiling** (proven via a direct
control experiment). It delivers **zero measurable benefit today**
because a second, independent, currently-co-dominant bottleneck
(weight-fetch bus width) already caps the system at the identical
rate. `nms_memory_manager_stream.v` is **adopted** as the new reference
NMS configuration: it is required groundwork for any future bandwidth
increase to actually pay off, and has no measured downside today. The
old `nms_memory_manager_pf.v` and `nms_memory_manager.v` remain
preserved for A/B/C reference. N=4/N=8 viability is now blocked by two
*separate* issues (external bandwidth, and the activation fill
controller's own Fmax regression) — neither of which this STEP could
or should redesign without further dedicated evidence, per the
project's own "no major redesign without evidence" discipline.
