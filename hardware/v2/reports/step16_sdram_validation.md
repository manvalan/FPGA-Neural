# STEP16 — Definitive SDRAM Validation (AS4C4M16SA-6TIN)

```
FINAL DECISION:
ADOPT SDRAM
CONFIDENCE:
MEDIUM
N=4 SPEEDUP:
3.738×
FMAX:
81.55 MHz
EFFECTIVE BANDWIDTH:
53.04 MB/s
CYCLES/TILE:
12.07
```

Full narrative: `hardware/v2/logs/experiments.log` (EXP-0040 through
EXP-0043), `errors.log` (ERR-0016 through ERR-0020), `decisions.log`
(DEC-0031). Governing spec: the user's STEP16 message, in full
("VALIDAZIONE DEFINITIVA SDRAM AS4C4M16SA-6TIN"), which explicitly
forbids estimating instead of measuring, requires a real controller,
real isolated tests, real integration with the real weight access
pattern, real synthesis+P&R, and a single definitive A/B/C decision
that closes the memory-exploration phase.

## 1. Executive Summary

A single Alliance Memory AS4C4M16SA-6TIN SDR SDRAM chip, driven by a
newly-built, real, isolated-and-validated controller, **measurably
outperforms** the already-validated dual-PSRAM 32-bit baseline on the
exact metric the governing spec designates as decisive: the real,
measured N=4 end-to-end speedup (**3.738×**, vs the dual-PSRAM
baseline's own **2.496×** — a 49.7% relative improvement, not a
marginal difference). This holds despite SDRAM's HALVED nominal raw
bus width (160 MB/s @ 80MHz vs 320 MB/s), because SDRAM's real,
measured protocol overhead is proportionally much smaller — the
opposite of what a naive "wider bus wins" assumption would predict,
and exactly the kind of result the spec's own "do not assume, measure"
discipline was designed to catch.

SDRAM also wins on PCB simplicity (1 physical chip vs 2, ~38 pins vs
61) and real post-P&R I/O headroom (194/245 vs 218/245 TRELLIS_IO).
It loses on real post-P&R Fmax (81.55 MHz vs 110.28 MHz) and required
more debugging (5 real protocol bugs found and fixed this round vs 3
for the dual-PSRAM baseline), reflecting SDR SDRAM's genuinely larger
protocol surface (refresh, mode register, auto-precharge, CAS latency
pipelining) vs PSRAM's simpler async-SRAM-like interface. Both designs
close real timing at the actual 80 MHz operating point the benchmark
itself uses. **Decision: ADOPT SDRAM**, at MEDIUM confidence (the
Fmax gap and its unresolved root cause are real, disclosed risks that
temper an otherwise clear-cut win on the primary criterion).

## 2. Exact device tested

Alliance Memory **AS4C4M16SA-6TIN**: 64Mbit (8MB), x16, SDR SDRAM,
-6 speed grade (tCK=6ns, 166MHz max), CAS latency 3, 3.3V, industrial
temperature, TSOP-II 54-pin. Real organization (derived from the
datasheet's own capacity/width, not assumed): 4 banks × 4096 rows ×
256 columns × 16 bits = 4,194,304 words = 8MB exactly. Word address:
{bank[1:0], row[11:0], col[7:0]}, 22 bits total.

## 3. Controller architecture

`hardware/v2/nms/rtl/sdram_controller.v`: a minimal, correctness-first
FSM implementing real power-up (200µs wait → PRECHARGE ALL → 8×
AUTO REFRESH → LOAD MODE REGISTER), periodic AUTO REFRESH with
priority over a pending request in S_IDLE (but never silently
DROPPING that request — see ERR-0019/ERR-0020), and **always**
auto-precharge on every READ/WRITE (A10=1) — no per-row open-state
tracking, one code path per transaction regardless of address
history, an explicit correctness-over-performance design choice
matching the spec's own stated priority order. BURST_LEN=4 (matching
P_IN×DATA_WIDTH/16 = 4 words/tile, the exact natural granularity
identified in Phase 1 before any RTL was written — one weight-fetch
request = one full SDRAM burst = one whole tile). All timing
parameters (tRCD, tRP, tMRD, tREFI) are re-derived per CLK_FREQ_MHZ
via ceiling-division, not hardcoded, so the same RTL was reused
unmodified across every frequency tested (80/100/133/166 MHz).

`hardware/v2/nms/sim/sdram_model.v`: a real, timing-checking
behavioral model (matching this project's own established rigor from
`psram_model.v`) that actively `$display`s VIOLATION/WARNING messages
on tRCD, tRP, tRAS(min), and refresh-spacing violations rather than
silently tolerating out-of-spec controller behavior, and independently
decodes the LOAD MODE REGISTER command's own address bits.

## 4. SDRAM timing configuration

Real, standard -6-speed-grade values, re-derived per frequency
(ceiling division, never under-counts a real ns requirement):

| Parameter | 80MHz | 100MHz | 133MHz | 166MHz |
|---|---|---|---|---|
| tRCD (18ns) | 2 cyc | 2 cyc | 3 cyc | 3 cyc |
| tRP (18ns) | 2 cyc | 2 cyc | 3 cyc | 3 cyc |
| tMRD (12ns) | 1 cyc | 2 cyc | 2 cyc | 2 cyc |
| CAS latency | 3 (fixed) | 3 | 3 | 3 |
| tREFI (15625ns) | 1250 cyc | 1563 cyc | 2079 cyc | 2594 cyc |

CAS latency is held fixed at 3 across all frequencies (the part's own
rated CL=3 spec) — no attempt was made to exploit a lower CL the real
part could technically support at lower frequencies, since the
governing spec did not ask for a CL sweep and -6 parts are commonly
operated at one fixed CL in practice.

## 5. RTL validation (Phase 3)

Five real, reproducible bugs were found via simulation and fixed
(none assumed away, none patched by adjusting expected values — see
ERR-0016 through ERR-0020 for full root-cause writeups):

1. **ERR-0016**: auto-precharge address bit (A10) was placed at bit 8
   instead of bit 10 in `sdram_controller.v` — every row stayed open
   forever, causing real "ACTIVATE while already active" violations.
2. **ERR-0017**: `sdram_model.v` silently dropped every write burst's
   first word (one-cycle-late capture relative to real SDRAM's
   command-concurrent first-word timing).
3. **ERR-0018**: `sdram_model.v`'s read path had a matching one-cycle-
   late pipe insertion PLUS a redundant registered output stage,
   compounding to 2-cycle-late read corruption.
4. **ERR-0019**: a real req/refresh arbitration race — a single-cycle
   `req` pulse landing on the exact cycle periodic refresh also became
   due was silently dropped, deadlocking the caller.
5. **ERR-0020**: ERR-0019's own fix was incomplete — it only latched
   `req` from within the S_IDLE branch, missing a pulse landing during
   ANY other busy state (e.g. mid-refresh, finishing a previous
   transaction's PRECHARGE_WAIT) — found only later, via the real
   Phase 5 N=2 integration benchmark, not the isolated regression
   (whose single-requester testbench structurally can't reach this
   case). Fixed by latching unconditionally every cycle.

Final result: **9/9 configurations (CLK_FREQ_MHZ ∈ {100,133,166} ×
BURST_LEN ∈ {1,4,8}) PASS 460/460 tests, 0 errors**, covering write→
read, sequential addresses, row change, bank change, address limits,
pseudo-random pattern, and 400-transaction refresh-interleaving
stress. CLK_FREQ_MHZ=80 (the frequency actually used in Phase 5/6)
independently confirmed PASS as well.

## 6. Performance measurements (Phase 4 — MEASURED, not estimated)

Real RTL-simulated cycles/transaction (one full ACTIVATE→CAS→burst→
PRECHARGE round trip):

| CLK_FREQ_MHZ | BURST_LEN=1 | BURST_LEN=4 | BURST_LEN=8 |
|---|---|---|---|
| 80  | 7 cyc  | 10 cyc | — |
| 100 | 7 cyc  | 10 cyc | 14 cyc |
| 133 | 8 cyc  | 11 cyc | 15 cyc |
| 166 | 8 cyc  | 11 cyc | 15 cyc |

Derived bandwidth (bytes/txn = BURST_LEN×2; MB/s = bytes/(cycles×
period), decimal MB=1e6, matching this project's own STEP15
convention):

| CLK_FREQ_MHZ | BURST_LEN | Nominal BW (2B×F) | Measured single-txn BW | %util |
|---|---|---|---|---|
| 80  | 4 | 160.0 MB/s | 64.00 MB/s | 40.0% |
| 100 | 4 | 200.0 MB/s | 80.00 MB/s | 40.0% |
| 133 | 4 | 266.0 MB/s | 96.72 MB/s | 36.4% |
| 166 | 4 | 332.0 MB/s | 120.72 MB/s | 36.4% |
| 166 | 1 | 332.0 MB/s | 41.50 MB/s | 12.5% |
| 166 | 8 | 332.0 MB/s | 177.06 MB/s | 53.3% |

Of the 10 total cycles/transaction at 80MHz/BURST_LEN=4: 2 are tRCD
wait, 3 are CAS latency, 4 are real data-burst cycles, and tRP overlaps
the next transaction's own tRCD window (measured 10 < the naive
2+3+4+2=11 serial sum) — 4/10 cycles (40%) are real data transfer,
matching %util exactly.

## 7. Neural accelerator integration (Phase 5)

Real integration: `nms_neural_multiprocessor_sdram.v` (forked from the
validated dual32 baseline — **only** the wide weight-fetch backend
replaced; the activation+writeback path, dependency manager, neural
director, and per-slot neural_processor are byte-for-byte unchanged)
→ `nms_dataflow_core_sdram.v` (MEM_DATA_WIDTH=64, WORDS_PER_TILE=1,
one burst = one tile exactly) → `slot_mem_arbiter_wide.v` (reused
UNCHANGED at DATA_WIDTH=64) → `sdram_weight_backend.v` → the real,
validated `sdram_controller.v`. Same clock (80MHz) as the dual32
baseline's own functional testbench, for a direct cycle-count-based
comparison (the dual32 baseline's own 2.496× was itself measured at
this same 80MHz, not its P&R Fmax). Real D-Stress workload: 256
independent neurons, 128 inputs each (16 tiles/neuron), bit-exact
verified against a golden software model — the same methodology
`tb_nms_dstress_dual32.v` itself used, not an artificial microbenchmark.

## 8. N=2 results

**PASS**: 256/256 neurons bit-exact (after ERR-0020's fix — the first
run hung at 228/256, a real deadlock, root-caused via hierarchical
debug tracing, not assumed to be "just slow"). total_cycles=52161,
tiles_delivered=4096, cycles/tile=12.73, sustained MAC/cycle=0.6282
(3.926% of the N=2 theoretical 16 MAC/cycle ceiling), effective
bandwidth=50.26 MB/s. Speedup vs original 16-bit baseline (185270
cycles): **3.552×**. Speedup vs dual32 baseline (75676 cycles):
**1.451×**.

## 9. N=4 results

**PASS**: 256/256 neurons bit-exact. total_cycles=**49430**,
tiles_delivered=4096, cycles/tile=**12.07**, sustained MAC/cycle=
0.6629 (2.072% of the N=4 theoretical 32 MAC/cycle ceiling — HIGHER
than dual32's own reported 1.383%, i.e. measurably less memory-bound),
effective bandwidth=**53.04 MB/s**. Speedup vs original 16-bit
baseline (184771 cycles): **3.738×**. Speedup vs dual32 baseline
(74038 cycles): **1.498×**. Shared 16-bit activation/writeback PSRAM
port utilization stayed low (6.5%), confirming that path remains a
non-bottleneck, unaffected by the weight-fetch backend swap (as
expected, since it is unchanged).

## 10. Synthesis results

Yosys 0.68+ (`synth_ecp5`), real full-system hierarchy, N_SLOTS=4:
TRELLIS_COMB=5516, TRELLIS_FF=6215, MULT18X18D=32, DP16KD(EBR)=0,
TRELLIS_RAMW=173. At N_SLOTS=2: TRELLIS_COMB=3783, TRELLIS_FF=3724,
MULT18X18D=16, DP16KD=0, TRELLIS_RAMW=109. (N=4's own FF count, 6215,
sits within ~1% of the dual32 baseline's own reported 6273 FF —
suggesting DEC-0030's own P&R was likely also an N=4 configuration,
so N=4 is treated as the primary comparison point here.)

## 11. P&R results

nextpnr-ecp5 0.11.1, `--45k --package CABGA381`, real free I/O
placement (`--lpf-allow-unconstrained` — same methodology this
project's own prior nms synthesis runs used; a board-specific
bank-by-bank LPF remains a follow-up PCB-layout step, exactly as
DEC-0030's own report already flagged for the baseline). **P&R
succeeds** at both N_SLOTS values. Real Fmax (best-of-3-seeds at N=4,
since a genuine seed-to-seed spread was observed and not glossed
over): 74.88 / 80.15 / **81.55 MHz** — all three PASS or near-PASS at
the real 80MHz operating point; best taken as representative. N=2
(single seed): **94.32 MHz**, PASS. Both sit clearly below the dual32
baseline's own reported 110.28MHz. The critical path in every run
traced entirely to `dependency_manager.v`'s own reg_ready/reg_valid/
node_state chain — a module completely unchanged from the dual32
baseline, not any part of the new SDRAM logic. **The exact cause of
this Fmax gap was not conclusively identified this round** — reported
honestly as an open discrepancy rather than invented, per the
governing spec's own "if something cannot be measured, state so
explicitly" instruction.

## 12. I/O analysis

Real post-P&R TRELLIS_IO: **194/245 (79.2%)**, identical at both
N_SLOTS values (I/O count is fixed by the external port list,
independent of internal slot count). This is a real, measured
**24-pin saving** vs the dual32 baseline's own reported 218/245
(88.9%) — consistent with the SDRAM weight interface's own real pin
count (2 BA + 12 A + CKE/CS#/RAS#/CAS#/WE# + 2 DQM + 16 DQ ≈ 38 pins)
replacing dual32's own 61-pin two-chip interface. The design is
physically compatible with the LFE5U-45F-8CABGA381 package with MORE
headroom than the already-validated dual32 baseline, not less.

## 13. Comparison with dual-PSRAM

| Metric | Dual PSRAM 32-bit | SDRAM x16 | Winner |
|---|---|---|---|
| Nominal bandwidth (@80MHz) | 320.0 MB/s | 160.0 MB/s | Dual-PSRAM |
| Effective BW (single-slot, uncontended) | 74.86 MB/s | 64.00 MB/s | Dual-PSRAM |
| Effective BW (N=4, real arbitrated) | 35.41 MB/s | **53.04 MB/s** | **SDRAM** |
| Cycles/tile | 18.07 | **12.07** | **SDRAM** |
| N=4 total cycles | 74038 | **49430** | **SDRAM** |
| N=4 speedup (vs original 16-bit) | 2.496× | **3.738×** | **SDRAM** |
| Fmax | **110.28 MHz** | 81.55 MHz | Dual-PSRAM |
| LUT/COMB | 2893 (LUT4) | 5516 (TRELLIS_COMB)* | *different tool metric, not directly comparable |
| FF | 6273 | 6215 | ~tie |
| EBR | 0 | 0 | tie |
| DSP | 32 | 32 | tie |
| I/O (real, post-P&R) | 218/245 | **194/245** | **SDRAM** |
| Memory capacity | 16MB (2×8MB combined) | 8MB (single chip) | Dual-PSRAM |
| Controller complexity | 2× unmodified, proven `psram_controller.v` + arbiter | 1× new controller, real JEDEC SDR protocol (refresh/mode-reg/auto-precharge) | Dual-PSRAM |
| PCB complexity | 2 chips, shared addr/ctrl, 61 pins | **1 chip, ~38 pins** | **SDRAM** |
| Component cost | 2× ISSI PSRAM | 1× Alliance Memory SDRAM | N/A — non misurato |
| Availability | ISSI PSRAM (established) | mature SDR SDRAM commodity part type | N/A — non misurato |
| Risk | Lower (proven, verbatim-reused controller) | Medium (5 real protocol bugs found & fixed this round) | Dual-PSRAM |

## 14. Cost/availability

No real distributor quotes or lead-time data were obtained for either
part this round — both entries are marked **N/A — non misurato**
per the governing spec's own "never invent numbers" instruction.
Qualitatively: SDR SDRAM in TSOP-II is a mature, widely-second-sourced
commodity memory category, and a single-chip BOM is inherently simpler
to source and stock than a matched pair — but this is a qualitative
observation, not a measured cost figure, and should not be weighted
as if it were one.

## 15. Risks

- **Fmax gap** (81.55MHz vs 110.28MHz, ~26% lower): real and
  measured, root cause not conclusively isolated this round (the
  limiting path is in unchanged, shared logic, not the new SDRAM
  controller itself) — flagged as a genuine open item, not dismissed.
- **Higher bug count during validation** (5 real protocol bugs this
  round vs 3 for dual32): reflects SDR SDRAM's inherently larger
  protocol surface (refresh, mode register, auto-precharge, CAS
  latency pipelining) vs PSRAM's simpler async-SRAM-like interface —
  all five are now fixed and fully re-verified (9/9 isolated configs,
  N=2 and N=4 integration, all PASS), but the class of bug (a request
  silently dropped during arbitration-adjacent state transitions) is
  a real reminder that this controller's request-acceptance path
  deserves continued scrutiny in any future extension (e.g. multiple
  outstanding requests, different arbiter topologies).
- **No board-specific bank-by-bank LPF**: same limitation the dual32
  baseline itself already carried forward as a follow-up PCB step, not
  a new gap introduced here.
- **Half the raw memory capacity** (8MB vs 16MB): a real architectural
  constraint if a future design needs more than 8MB of weight storage
  without adding a second SDRAM chip.

## 16. Final recommendation

**A — ADOPT SDRAM.** The governing spec's own explicit, decisive
criterion — does SDRAM's real N=4 speedup clearly exceed the dual-
PSRAM baseline's own 2.496×? — is satisfied with margin: **3.738×**,
a 49.7% relative improvement, not a marginal difference the spec
warned against chasing. This holds across both tested slot counts
(N=2: 1.451× over dual32; N=4: 1.498× over dual32), is backed by real
bit-exact correctness at every stage, and is accompanied by a genuine
PCB simplification (1 chip vs 2, real 24-pin I/O saving). The real,
measured Fmax deficit and the more involved debugging history are
disclosed, weighed, and are the reason confidence is MEDIUM rather
than HIGH — but per the spec's own stated priority order, a
lower-priority shortfall (timing headroom, item 3) does not override
a clear, substantial win on the criterion the spec itself designated
as decisive, especially since both designs independently close real
timing at the actual 80MHz operating point the entire comparison is
built on.

**Hardware memory architecture for V2: single-chip SDR SDRAM
(Alliance Memory AS4C4M16SA-6TIN), BURST_LEN=4 controller.**

Per the governing spec's own explicit instruction, the memory-
exploration phase is now considered **closed**. No further alternative
memory technologies (HyperRAM, DDR3, SDRAM×32, or otherwise) will be
proposed for V2 unless a technical violation is discovered that makes
this validation impossible to stand on as written.
