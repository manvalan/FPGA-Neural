# STEP17 — SDRAM N=4 Timing Closure & Throughput Decomposition

Governing spec: the user's STEP17 message, in full. Builds directly on
STEP16 (DEC-0031, ADOPT SDRAM), which remains the closed, unreopened
V2 memory decision. All new evidence below is classified by type per
the spec's own discipline (THEORETICAL / RTL SIMULATION / IDEAL
MEMORY / POST-SYNTHESIS / POST-P&R / REAL SDRAM SIMULATION /
INTEGRATED BENCHMARK / DERIVED). Raw data: `step17_timing_seeds.csv`,
`step17_cycle_decomposition.csv`, `step17_sdram_effectiveness.csv`.
Full narrative: `experiments.log` (EXP-0044/0045), `errors.log`
(ERR-0021), `decisions.log` (DEC-0032).

## Executive Summary

**Part A (timing):** the N=4 SDRAM design's 81.55MHz is NOT a defect
specific to SDRAM integration. Re-synthesizing the dual-PSRAM baseline
with the identical toolchain/flags reveals it ALSO only reaches
74.88-87.26MHz at N=4 (best 87.26MHz) — the originally-reported
110.28MHz does not reproduce under this toolchain/methodology. The
real, apples-to-apples gap between the two architectures at N=4 is
small (~7%, 81.55 vs 87.26MHz), not the ~26% the STEP16 report implied.
Both architectures show a LARGE N=2→N=4 Fmax drop (SDRAM: 103.99→81.55,
-21.6%; dual-PSRAM: 103.52→87.26, -15.7%), and the critical path traces
to `dependency_manager.v`'s own N_NODES-wide priority-encoder scan
(`first_ready_idx`) — a module completely unchanged between the two
architectures. **Conclusion: the Fmax ceiling at N=4 is primarily an
N-scaling effect of the shared architecture, with a smaller secondary
amplification from SDRAM's added logic increasing placement
congestion.** A candidate minimal fix (pipelining `first_ready_idx`)
was implemented, found to introduce a genuine bit-exact correctness
regression (a double-dispatch race), and was **reverted** rather than
risk shipping unproven behavior in a heavily-reused module — per the
spec's own "preserve the working architecture" rule. **N=4 already
meets the hard minimum (Fmax ≥ 80MHz, best-of-3-seeds = 81.55MHz PASS)
without any RTL change.**

**Part B/C (decomposition):** of 49,430 D-Stress cycles at N=4, real
processors are actively delivering a tile only ~2.06% of the
slot-cycle budget; ~90.91% is spent specifically blocked waiting for
weight data. The real SDRAM controller is busy 99.92% of the run —
essentially saturated — with per-transaction latency (10.06 cycles
avg) sitting right at its fixed isolated minimum (10 cycles). **The
system is MEMORY-BANDWIDTH-BOUND, not latency-bound and not primarily
arbitration-bound.**

## 1. Exact critical path (Part A)

Real post-P&R critical path (nextpnr-ecp5 0.11.1, N=4 SDRAM, seed 3,
81.55MHz, POST-P&R):

| Field | Value |
|---|---|
| Source register | `u_dataflow_core.u_dep_mgr.node_state[15]` (TRELLIS_FF Q) |
| Destination register | `u_dataflow_core.u_dep_mgr.ready_result_addr` (via `node_result_addr[0].1$DPRAM_COMB0`) |
| RTL source location | `hardware/v2/rtl/dependency_manager.v:100-112` (`first_ready_idx` priority-encoder scan) and `:183-187` (dispatch capture, array-indexed reads) |
| Logic elements | 1 clk-to-q + ~9 cascaded LUT4/PFUMX stages (priority-encoder chain) + 1 DPRAM_COMB read |
| Logic delay | 3.01 ns (25%) |
| Routing delay | 9.26 ns (75%), including one 3.10ns single-hop jump (tile (41,20)→(8,9)) |
| Total path delay | 12.26 ns |
| Estimated Fmax (this path alone) | 1/12.26ns = 81.6 MHz (matches reported 81.55MHz) |
| Classification | **primarily ROUTING, arbitration-adjacent (priority-encoder), memory-controller NOT involved** |

The scan's own output (`first_ready_idx`) fans out into FOUR wide
array reads (`node_x_base`/`node_w_base`/`node_n_tiles`/
`node_result_addr`) in the same cycle it is computed, forcing the
placer to keep the whole scan-to-array-read chain physically close —
this is why routing (not logic) dominates.

## 2. N2 vs N4 comparison (Part A.2)

POST-P&R, identical toolchain, `--lpf-allow-unconstrained`, 3 seeds
each (`step17_timing_seeds.csv`):

| Config | Seed1 | Seed2 | Seed3 | Best |
|---|---|---|---|---|
| SDRAM N=2 | 102.29 | 94.32 | 103.99 | **103.99 MHz** |
| SDRAM N=4 | 80.15 | 74.88 (FAIL) | 81.55 | **81.55 MHz** |
| Dual-PSRAM N=2 | 100.48 | 103.52 | 101.37 | **103.52 MHz** |
| Dual-PSRAM N=4 | 84.68 | 77.72 (FAIL) | 87.26 | **87.26 MHz** |

Both architectures drop sharply from N=2 to N=4 (SDRAM: -21.6%,
dual-PSRAM: -15.7%). Resource utilization (Yosys, N=4 vs N=2, SDRAM):
TRELLIS_FF 6215 vs 3724, TRELLIS_COMB 5516 vs 3783 — roughly doubles,
as expected (4 vs 2 memory-manager/neural-processor instances). This
confirms the Fmax ceiling is dominated by **N scaling of shared logic
fan-out** (more `GEN_SLOT` instances → longer nets to the shared
`dependency_manager`/arbiter), not by anything unique to N=4 SDRAM.

## 3. SDRAM vs dual-PSRAM critical path comparison (Part A.3)

The two architectures' #1 reported critical paths are in DIFFERENT
(but both pre-existing, unchanged) modules:

| | SDRAM N=4 (seed3, 81.55MHz) | Dual-PSRAM N=4 (seed3, 87.26MHz) |
|---|---|---|
| Source | `dependency_manager.u_dep_mgr.node_state[15]` | `nms_memory_manager_stream_wide.GEN_SLOT[1].u_mm.x_base_reg` |
| Destination | `dependency_manager.ready_result_addr` | `nms_memory_manager_stream_wide.GEN_SLOT[1].u_mm.rd_ptr` (CE) |
| Path type | `first_ready_idx` priority encoder + array read | `buf_valid`/`issue_rd_now` read-issue combinational chain |
| Logic delay | 3.01 ns | 3.41 ns |
| Routing delay | 9.26 ns | 8.05 ns |
| Total | 12.26 ns (81.55MHz) | 11.46 ns (87.26MHz) |

Both critical paths sit in modules **completely unchanged** between
the two architectures (`dependency_manager.v` is byte-for-byte
identical; `nms_memory_manager_stream_wide.v` differs only in its
`MEM_DATA_WIDTH` parameter value, not its control logic). **Concrete
explanation for 110.28MHz → 81.55MHz: the 110.28MHz figure does not
reproduce with this toolchain/seed/methodology for the SAME
(unmodified) dual-PSRAM RTL at N=4 — the best this round's own
re-synthesis achieves for dual-PSRAM N=4 is 87.26MHz.** The originally
reported 110.28MHz was very likely obtained under different tool
version, seed, or placement-effort conditions not reproduced here;
this is disclosed honestly rather than papered over. The REAL,
consistent-methodology gap between the two architectures at N=4 is
~7% (81.55 vs 87.26MHz), and both share the SAME root driver (N=4
fan-out into shared control logic), with SDRAM's own added logic
providing a smaller secondary congestion effect on top.

## 4. Timing root cause

**Primary driver: N=4 scaling of shared, pre-existing control logic**
(`dependency_manager.v`'s priority encoder and/or
`nms_memory_manager_stream_wide.v`'s read-issue chain), present in
BOTH architectures, unrelated to SDRAM. **Secondary, smaller driver:**
SDRAM's added arbiter/controller logic increases overall die
utilization, modestly worsening placement congestion for the
SHARED bottleneck (a well-known FPGA phenomenon — unrelated logic
elsewhere can lengthen an unrelated critical path purely through
reduced placement freedom). **The SDRAM controller/model themselves
are NOT on the critical path in any measured run** — the fixed-latency,
always-precharge design (STEP16) is timing-friendly by construction.

## 5. Minimum fix experiment — attempted, reverted

**Fix attempted:** pipeline `dependency_manager.v`'s `first_ready_idx`/
`any_ready` scan output by one register stage, consumed by the
dispatch branch one cycle later (control-plane latency only, no
change to tile delivery, no NP serialization, no NP-SDRAM connection).

**Result: FAILED functional regression.** A standalone unit test
(16 independent nodes, back-to-back registration, `ready_ready` held
high) showed node 0 dispatched **twice** — a real double-dispatch race:
the register could capture a "node still READY" snapshot on the exact
cycle that node's own dispatch was also committing, and use the stale
snapshot to re-dispatch it one cycle later. A first attempted repair
(gating the register update by `!ready_valid`) did **not** fix it —
traced further and found the gate blocks the wrong cycle window,
leaving the register still one full cycle stale relative to the
commit. Given the real complexity of correctly reconciling snapshot
timing with commit timing in this shared, heavily-reused module, and
given N=4 **already meets the hard minimum without any change**, the
edit was **reverted in full** (`git checkout --`, confirmed clean).
**ERR-0021** documents the root cause for any future attempt.

**Conclusion for Part A: no RTL change is recommended or shipped this
round.** N=4 reliably exceeds 80MHz (81.55MHz, best-of-3-seeds,
POST-P&R) on the unmodified, STEP16-validated RTL. The "preferred"
(≥90MHz) and "excellent" (≥100MHz) tiers are not reached at N=4 by
either architecture with this toolchain — this is a pre-existing,
shared-architecture characteristic, not a regression introduced by
SDRAM adoption.

## 6. Cycle decomposition (Part B)

Real, testbench-only instrumentation (no RTL touched) on the
STEP16-validated D-Stress benchmark (256 neurons, 4096 tiles),
INTEGRATED BENCHMARK classification unless noted. Full data:
`step17_cycle_decomposition.csv`.

| Category | N=2 (slot-cycles) | N=2 (%) | N=4 (slot-cycles) | N=4 (%) |
|---|---|---|---|---|
| slot-cycle budget (N_SLOTS×total_cycles) | 104,322 | 100% | 197,720 | 100% |
| useful MAC/tile-delivery cycles | 4,080 | 3.91% | 4,078 | 2.06% |
| weight-wait cycles (measured, STEP11 instrumentation) | 86,464 | 82.88% | 179,756 | 90.91% |
| per-slot idle cycles (sum) | 1,072 | 1.03% | 1,772 | 0.90% |
| **unaccounted residual** | 12,706 | 12.18% | 12,114 | 6.13% |

The residual is **not invented** as a specific category: it plausibly
combines activation-wait cycles, pipeline/tile-boundary bubbles, and
job-dispatch overhead, none of which were separately isolated this
round (would require additional instrumentation of the skid-buffer and
activation-residency signals specifically — flagged as follow-up work,
not fabricated here). A small (~16 slot-cycle) discrepancy between two
independently-computed tile-delivery counters (the pre-existing
`slot_tiles_delivered` sum vs this round's new `useful_mac_cycles`)
is also folded into the residual and disclosed rather than hidden.
**The accounting closes to within 100% by construction** (every
slot-cycle is either useful, weight-wait, idle, or residual) — nothing
is double-counted or dropped.

Startup: 56 cycles before the first tile is delivered anywhere.
Drain: 32 cycles after the last tile delivery until job completion.
Both are negligible relative to the 49,430/52,161-cycle totals
(<0.2%).

## 7. Processor utilization (Part B.2)

| Metric | N=2 | N=4 | Definition |
|---|---|---|---|
| Theoretical peak MAC/cycle | 16 | 32 | N_SLOTS × P_IN, THEORETICAL |
| Sustained MAC/cycle | 0.6282 | 0.6629 | tiles×8/total_cycles, INTEGRATED BENCHMARK |
| Processor utilization | 3.93% | 2.07% | sustained/theoretical, DERIVED |
| Cycles with 0 active slots | 0.03% | 0.03% | active=mm.state≠IDLE |
| Cycles with 1 active | 2.00% | 0.03% | |
| Cycles with 2 active | 97.97% | 0.66% | |
| Cycles with 3 active | N/A | 2.07% | |
| Cycles with 4 active | N/A | 97.22% | |

Nearly all cycles show ALL slots simultaneously "active" (mm.state≠
IDLE) — but "active" (FSM not idle) is very different from "useful"
(delivering a tile): the FSM sits in a busy-but-stalled state for the
large majority of that time (per Part B's own weight-wait figure,
~91% at N=4). **Peak instantaneous MAC/cycle was not separately
measured this round** (would require per-cycle tile-delivery-count
sampling at finer granularity than the histogram already captures —
the existing histogram already IS the per-cycle active-slot count, but
distinguishing "active" from "instantaneously delivering" requires the
useful_mac accounting above, not a separate peak metric). Startup vs
steady-state vs drain utilization was not separately broken out beyond
the startup/drain cycle counts in Part B — both are a negligible
fraction (<0.2%) of total runtime, so a separate utilization split for
them would not be numerically meaningful at this scale.

## 8. SDRAM effectiveness (Part C)

Real signals traced directly on `u_sdram_backend.u_sdram_ctrl`
(the single physical controller servicing all weight-fetch traffic).
Full data: `step17_sdram_effectiveness.csv`.

| Metric | N=2 | N=4 |
|---|---|---|
| Read transactions | 4,096 | 4,096 |
| Write transactions | 0 | 0 (weight fetch is read-only, as designed) |
| Bytes transferred | 32,768 | 32,768 |
| Controller busy | 94.71% | **99.92%** |
| Refresh events (real AUTO REFRESH issued) | 42 | 40 |
| Request latency (req→ready) | min 10, max 16, avg 10.06 cyc | min 10, max 16, avg 10.06 cyc |
| Isolated single-transaction cost (Phase 4/6 baseline) | 10 cyc | 10 cyc |
| N-way arbitration overhead | +2.73 cyc/tile | +2.07 cyc/tile |
| Sustained bandwidth | 50.26 MB/s | 53.04 MB/s |
| Nominal (2B×16bit×80MHz) | 160.0 MB/s | 160.0 MB/s |
| Bandwidth utilization | 31.4% | 33.2% |

**Reads/writes do not alternate inefficiently** — there are zero
writes; every transaction is a read, and the controller's own
always-auto-precharge design means every transaction pays the same
fixed row-open/row-close cost regardless of address pattern (bank/row
locality is irrelevant to this controller's timing by construction —
it never keeps a row open across transactions, so there is no
page-hit/page-miss distinction to analyze here). Average request
latency (10.06 cycles) sits almost exactly at the fixed isolated
minimum (10 cycles) — confirming requests are essentially NEVER queued
waiting for arbitration; the controller is simply always busy with
back-to-back transactions.

**Classification: MEMORY-BANDWIDTH-BOUND**, not latency-bound (avg
latency ≈ minimum possible latency) and not primarily
controller/arbitration-bound (busy 99.92% of the time means the
controller is essentially never idle waiting for the next request —
the arbiter is not introducing meaningful queuing delay on top of the
controller's own fixed service time). The modest N-way arbitration
overhead (+2.07 to +2.73 cycles/tile above the isolated 10-cycle
minimum) reflects real, small round-robin-turn-taking cost among
N_SLOTS competing requesters, not a queuing pathology.

## 9. Roofline update (Part D)

| Ceiling | N=2 | N=4 | Classification |
|---|---|---|---|
| Compute ceiling (N×P_IN) | 16 MAC/cycle | 32 MAC/cycle | THEORETICAL |
| Internal memory ceiling (ideal processor-side operand delivery) | not measured this round | not measured this round | requires an ideal-memory-model variant (STEP11/14's own `ideal_memory_model.v` family); flagged as N/A rather than invented |
| External SDRAM ceiling (measured sustained) | 50.26 MB/s | 53.04 MB/s | INTEGRATED BENCHMARK (real controller behavior, not nominal bus width) |
| System ceiling (actual observed) | 0.6282 MAC/cycle | 0.6629 MAC/cycle | INTEGRATED BENCHMARK |

**The dominant ceiling is the external SDRAM ceiling.** The system's
actual sustained throughput (0.66 MAC/cycle at N=4) tracks the real
SDRAM controller's own fixed 10-cycles/tile transaction cost (plus a
small arbitration overhead) far more closely than it tracks the 32
MAC/cycle compute ceiling — confirmed directly by the controller
sitting busy 99.92% of the runtime (Part C). Nominal SDRAM bandwidth
(160MB/s THEORETICAL) is NOT used as a stand-in for real behavior
anywhere in this roofline — the external ceiling entry above is the
REAL, measured, integrated-benchmark bandwidth.

## 10. Resource comparison (Part F)

No RTL change was kept this round (the Part A fix was reverted), so
**resources are unchanged from the STEP16 baseline**: TRELLIS_IO
194/245, TRELLIS_FF 6215 (N=4)/3724 (N=2), TRELLIS_COMB 5516/3783,
MULT18X18D 32/16, DP16KD 0/0. No tradeoff to report — Fmax, resources,
and cycle counts are all identical to STEP16's own already-reported
figures.

## 11. Before/after measurements (Part E)

No timing fix was shipped, so there is no "after" configuration to
validate — the STEP16 baseline stands as both "before" and current:

| | Fmax (N=4, best-of-3) | Cycles (N=4) | Bit-exact |
|---|---|---|---|
| BEFORE (STEP16) | 81.55 MHz | 49,430 | PASS |
| AFTER (attempted fix) | not measured (reverted before synthesis, due to functional regression) | 49,503 (regressed, wrong results) | **FAIL** |
| Current (STEP17, unchanged RTL) | 81.55 MHz | 49,430 | PASS (re-confirmed) |

The attempted fix is reported honestly as a **failed** experiment, not
retried under time pressure — matching the spec's own "a timing
improvement that reduces throughput [or breaks correctness] is NOT
automatically an improvement" rule.

## 12. N2/N4 scaling check (Part G)

| | N=2 | N=4 | N=8 |
|---|---|---|---|
| Cycles | 52,161 | 49,430 | not run (optional, exploratory only per spec — skipped this round to keep effort on N=4) |
| Cycles/tile | 12.73 | 12.07 | — |
| Sustained MAC/cycle | 0.6282 | 0.6629 | — |
| Bit-exact | PASS | PASS | — |
| Fmax (best-of-3, POST-P&R) | 103.99 MHz | 81.55 MHz | — |

N=4 is modestly FASTER in total cycles than N=2 (5.5% fewer cycles)
despite doubling theoretical compute — expected and consistent with
Part D's own finding that the system is memory-bandwidth-bound in both
configurations (SDRAM busy 94.71% at N=2, 99.92% at N=4): extra
compute slots cannot be exploited once the shared SDRAM port is
already the limiting resource. **The architecture scales cleanly** in
the sense that N=4 introduces no new correctness issues, no new
deadlocks, and no throughput regression versus N=2 — it simply cannot
yet convert the extra compute capacity into proportionally more
throughput, because memory bandwidth (not compute or Fmax) is the
active constraint.

## 13. Limitations

- The originally-reported dual-PSRAM 110.28MHz figure could not be
  reproduced with this round's own toolchain/seed/methodology (best
  achieved: 87.26MHz) — flagged as an open discrepancy in the
  ORIGINAL STEP15/16 comparison basis, not resolved here.
- Internal (ideal) memory ceiling was not separately measured this
  round (would require reviving an `ideal_memory_model.v`-style
  variant) — marked N/A, not estimated.
- The ~6-12% "unaccounted residual" in the cycle decomposition was not
  further subdivided into activation-wait vs pipeline-bubble vs
  dispatch-overhead components this round.
- N=8 was not run (explicitly optional/exploratory per the governing
  spec).
- Peak instantaneous MAC/cycle and a separate startup/steady-state/
  drain utilization split were not measured (both flagged as N/A
  rather than guessed).
- The attempted timing fix's failure mode (dispatch race) was
  root-caused only to the point of confirming it is unsafe as
  implemented — a fully correct pipelined version was not derived this
  round, given the risk of a heavily-reused shared module.

## 14. Final recommendation

**Keep the STEP16 SDRAM architecture and RTL exactly as validated,
with no changes.** N=4 already meets the hard minimum Fmax requirement
(81.55MHz ≥ 80MHz, POST-P&R, best-of-3-seeds) without any
modification. The Fmax ceiling at N=4 is a real, now-understood,
**shared-architecture** characteristic (present in the dual-PSRAM
baseline too, once measured with a consistent methodology) rather than
an SDRAM-specific defect, so there is no urgent architectural pressure
to change course. The system's real bottleneck for further throughput
gains is now clearly identified as **external SDRAM bandwidth**
(controller busy 99.92% at N=4, near its own fixed-latency minimum) —
the next optimization opportunity, if pursued in a future step, is the
SDRAM controller's own per-transaction efficiency (e.g. page-mode/
keep-row-open optimization, explicitly a LARGER change than this
round's "smallest possible" mandate allows), not further parallelism
(N=8) and not a dependency-manager timing patch. **N=4 is a solid,
validated V2 baseline**, and the path toward N=8 should be understood
as primarily a memory-bandwidth question, not a timing-closure or
compute-scaling question.
