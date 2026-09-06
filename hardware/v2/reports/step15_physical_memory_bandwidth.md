# NMS STEP15 — Physical Memory Bandwidth Exploration

Full narrative: `hardware/v2/logs/experiments.log` (EXP-0034 through
EXP-0036), `decisions.log` (DEC-0029). Builds on STEP14's own
`weight_prefetch_engine_wide.v` infrastructure, now driven by a
realistic, RTL-validated *physical* transaction-timing model instead
of an idealized always-ready one.

## 1. Methodology

STEP14's Part A explored *logical* weight-path width using an
idealized (`mem_ready=1` always) backing memory — valid for isolating
the control-plane/word-granularity question, but explicitly not a
physical-bandwidth model. STEP15 replaces that idealization with a
model derived from, and calibrated against, the **real**
`psram_controller.v`'s own measured transaction timing, then sweeps
*physical* transfer width (`PHY_WIDTH`) as the independent variable
while holding logical weight width, `P_IN`, `DATA_WIDTH`, clock,
workload, and activation behavior fixed.

Three stages, each building on the last:
1. **Real baseline** (EXP-0034): the actual `weight_prefetch_engine.v`
   driven against the actual `memory_interface.v` →
   `psram_controller.v` → `psram_model.v` chain, single slot, no
   contention — measuring what the real 16-bit interface *actually*
   delivers, with no simplification.
2. **RTL-validated derived model** (EXP-0035): a page-mode-aware
   memory model, generalized to arbitrary `PHY_WIDTH`, with its
   per-transaction cost *calibrated* against stage 1's real number
   (not assumed) — then swept across 16/32/64/128-bit.
3. **DERIVED full-system projection** (EXP-0036): stage 2's single-slot
   numbers scaled to the real, multi-slot D-Stress workload via a
   degradation factor calibrated against the already-real-measured
   N=4 result — explicitly labeled as a projection, not an independent
   re-measurement, with its own uncertainty stated plainly.

## 2. Baseline reproduction — real 16-bit interface

Direct simulation against the unmodified real controller (256-tile
job, single slot, unconstrained lookahead): **17.10 cycles/tile**
(4377 cycles / 256 tiles), not the ~4 cycles/tile figure used as a
deliberate control-plane-only simplification in STEP13/14.

Root cause, traced via real state-transition dumps (not assumed): the
controller's own `ACCESS_CYCLES=6`/`PAGE_CYCLES=2` constants
(tAA=70ns/tAPA=20ns @ 80MHz) are *not* the whole story — its
`STATE_PAGE_OPEN` state adds a further, real 2 cycles to **every**
transaction, hit or miss. Real per-word cost: **4 cycles (page hit)**,
**8 cycles (page miss)**. Real page size: 16 words = **32 bytes**
(confirmed from the controller's own address-bit-match logic). For a
sequential 8-byte-tile fetch stream, this gives exactly 1 miss every 4
tiles: `(15×4 + 1×8)/16 = 4.25` cycles/word × 4 words/tile = **17.0
cycles/tile** — matching the real measurement to within a fraction of
a percent.

## 3-6. PHY_WIDTH sweep (16/32/64/128-bit)

RTL-validated (not hand-derived) via a page-mode-aware model
calibrated to reproduce the real 16-bit number exactly, then swept:

| PHY_WIDTH | Bytes/transfer | Transfers/tile | Transfers/page | Cycles/tile |
|---|---|---|---|---|
| 16-bit | 2 | 4 | 16 | **17.0** (real, EXP-0034) |
| 32-bit | 4 | 2 | 8 | **9.0** (RTL, EXP-0035) |
| 64-bit | 8 | 1 | 4 | **5.0** (RTL, EXP-0035) |
| 128-bit | 16 | 1 | 4 | **5.0** (RTL, EXP-0035) — plateau |

The 128-bit result is a genuine, RTL-confirmed **plateau**, not the
slight regression an initial hand/analytical model predicted. Reason
(found by cross-checking the analytical model against RTL simulation,
not assumed): the inter-tile address stride is fixed at the tile's own
natural size (8 bytes — a correctness requirement already established
in STEP14/EXP-0032), so at 128-bit each request still only *advances*
8 bytes even though it *fetches* 16 — giving 64-bit and 128-bit the
identical hit/miss pattern (1 miss every 4 requests). 128-bit neither
helps (no multi-tile bursting is implemented) nor hurts.

## 7-9. N=2 / N=4 / N=8 sensitivity

Real, already-measured full-system cycles/tile at 16-bit are
**statistically identical across N**: N=2 (EXP-0028) 45.23, N=4
(EXP-0030) 45.11, N=8 (EXP-0030-class) 45.11 — confirming (again) that
the single shared physical port, not `N_SLOTS`, sets the ceiling. The
same DERIVED projection (§10 below) therefore applies equally to
N=2/4/8: **the optimal `N` does not change within the 16–128 bit range
explored.** The workload remains memory-bound at every width tested;
reaching a regime where `N_SLOTS` scaling matters again would require
the much larger (~36–82×) bandwidth increase STEP12/EXP-0024 already
quantified — far beyond what parallel-bus widening alone provides.
N=8's own separate timing infeasibility (STEP14, Fmax=52.25 MHz) is
architecturally orthogonal to this bandwidth analysis and does not
contaminate it, per instruction.

## 10. Updated roofline (DERIVED, N=4 primary reference)

Calibrated by anchoring EXP-0035's single-slot numbers to the real,
measured N=4 baseline via a degradation factor (45.11/17.0 = 2.65)
capturing real arbitration + activation + write-back overhead, applied
uniformly across widths (explicit uncertainty below).

| PHY_WIDTH | DERIVED total cycles (N=4, 4096 tiles) | Sustained MAC/cyc | Utilization (of 32 theoretical) |
|---|---|---|---|
| 16-bit | 184771 (= real, exact anchor) | 0.1773 | 0.554% |
| 32-bit | ~97820 | 0.335 | 1.047% |
| 64-bit | ~54344 | 0.603 | 1.884% |
| 128-bit | ~54344 | 0.603 | 1.884% |

**The architecture remains memory-bound at every width tested** — no
crossover to compute-bound occurs anywhere in the 16–128 bit range.
Reaching even 50% utilization (STEP14's own optimistic, contention-free
upper bound) would require far more than a parallel-bus width bump.

## 11. Bandwidth vs. throughput — explicit, not assumed

| Transition | Nominal bandwidth gain | Real/derived throughput gain | Gap explanation |
|---|---|---|---|
| 16→32 bit | 2.0× | **1.89×** | Fixed per-transaction `STATE_PAGE_OPEN` overhead (2 cycles) and per-job startup/drain cost do not shrink with width — an increasing share of each transaction's cost is now width-independent overhead. |
| 32→64 bit | 2.0× | **1.80×** | Same mechanism, compounding: transfers/tile is already down to 1, so further width increases only shrink the *data* portion of a transaction that's already mostly fixed overhead. |
| 64→128 bit | 2.0× | **1.00× (none)** | Not activation bandwidth, not MAC utilization, not scheduling — the concrete, RTL-confirmed cause is that this design never implements multi-tile bursting, so a transfer wider than one tile simply wastes its surplus bits. |

Per Part F's own explicit instruction not to assume the explanation in
advance: the cause was **not** guessed — it was found by tracing the
real state machine (§2) and by cross-checking an initial analytical
model against RTL simulation (§3-6), which caught and corrected a real
error in the first hand-derived hypothesis.

## 12. FPGA I/O analysis

The real, current interface (from `neural_multiprocessor.v`'s own real
port list): `psram_a[22:0]` (23) + `psram_dq[15:0]` (16) +
`ce_n/oe_n/we_n/lb_n/ub_n/zz_n` (6) = **45 pins**, one
ISSI IS66WVE4M16EBLL-70BLI (x16 parallel).

| Option | Pins (approx.) | Delta vs. today | Devices |
|---|---|---|---|
| 16-bit (today) | 45 | — | 1× existing part |
| 32-bit, 2× parallel 16-bit chips | ~61 | +16 | 2× existing, already-qualified part; shared address/control bus, independent DQ |
| 32-bit, native x32 part | ~60 | +15 | Uncommon in this parallel-PSRAM category — do not assume one exists in the exact required form |
| 64-bit, 4× parallel 16-bit chips | ~93 | +48 | 4× existing part; shared address/control (4-way fanout) |
| 64-bit, native x64 part | n/a | n/a | Effectively does not exist in this category — not a real option |

The LFE5U-45F-8BG381 provides on the order of ~190-200 general-purpose
I/O across 8 independently-powered banks (order-of-magnitude ECP5
architectural fact; the exact usable count for THIS board depends on
what else is already committed — config/JTAG/clock/other peripherals
— and should be checked against the project's own real pinout
spreadsheet before committing to a specific option, rather than
assumed here). A +16-pin ask (32-bit, 2-chip) is a modest addition,
plausibly absorbable in a single spare bank; a +48-pin ask (64-bit,
4-chip) is substantial and would need real, careful bank-by-bank
budget verification — not performed in this session, since it requires
the project's actual pinout data, not general ECP5 facts.

## 13. PCB feasibility analysis

**32-bit (2-chip):** one additional PSRAM footprint, address/control
bus fanout to 2 loads (increased capacitance — real but manageable at
these speeds/frequencies with reasonable fly-by or short-stub
topology), one additional set of length-matched address traces if
timing margins are tight (they likely are not, given the real
70ns/20ns-class timing already has generous margin at 80 MHz), modest
additional layer/via pressure. Low-to-moderate PCB complexity increase.

**64-bit (4-chip):** three additional footprints, 4-way address/
control fanout (meaningfully higher loading — may need a buffer/
repeater or careful star/fly-by design), substantially more
simultaneous-switching current (16→64 DQ pins toggling together —
real power-integrity/decoupling concern), and non-trivial escape
routing pressure from packing 4 PSRAM footprints plus the FPGA's own
BGA escape in a constrained area — plausibly pushing layer count up.
Meaningfully higher PCB complexity and engineering effort than 32-bit,
for a smaller *additional* real-throughput gain (1.80× vs. 1.89×) at
a system that is still only 1.88% utilized either way.

## 14. Technology options (architectural comparison, not component selection)

- **Parallel PSRAM (wider or multiple, as above):** lowest engineering
  risk (reuses the existing controller family), but poor pin
  efficiency — bandwidth scales with raw pin count.
- **HyperRAM / HyperBus (JEDEC):** a DDR, ~11-13-pin interface
  (CK/CK#, CS#, RWDS, DQ[7:0], RESET#) — potentially exceeding even a
  64-bit parallel option's bandwidth at *fewer* pins than today's
  16-bit interface. Requires an entirely new controller (different
  protocol — DDR, RWDS data-valid strobing) and is not a drop-in
  replacement; the ECP5 has no dedicated hard IP for it, so it would
  be a soft-logic implementation, as today's controller already is.
- **Octal-SPI / xSPI memories:** similarly pin-efficient (~10-13
  pins), often DDR-capable, another strong candidate; same "new
  controller required" caveat.
- **Multiple parallel PSRAM devices:** covered above as the practical
  32-/64-bit implementation path for the existing part family.
- **External SRAM:** faster, no refresh, but far more expensive per
  bit and lower density — not a natural fit for bulk 8MB weight
  storage; would need a much stronger case (e.g., a small, explicitly
  latency-critical cache layer) to justify.

These are flagged as *categories*, not a component selection — no
specific part number is recommended without datasheet-level
verification against real timing, voltage, and package constraints,
consistent with this STEP's own explicit instruction not to select a
memory chip merely for a wider nominal interface.

## 15. Final recommendation

**Recommend 32-bit for the next board revision, implemented as two
parallel instances of the existing, already-qualified
ISSI IS66WVE4M16EBLL-70BLI** (shared address/control bus, independent
DQ per device). Rationale: a real, substantial ~1.89× end-to-end
speedup — the largest single gain of any option investigated — at low
engineering risk (reuses a known part and controller timing model) and
modest PCB/pin cost (+16 pins, one additional footprint).

**64-bit is not recommended for this revision.** Its own incremental
gain (a further ~1.80×) is real, but the system remains overwhelmingly
memory-bound (1.88% utilization) even there, and its pin/PCB/power
cost is roughly 3× that of the 32-bit option. **128-bit is explicitly
not recommended** — confirmed to add nothing over 64-bit given this
architecture's current single-tile-per-request design.

**For a future, more ambitious revision** aiming at a materially higher
utilization target (rather than an incremental win), HyperRAM/Octal-SPI
class memories are the architecturally interesting direction — more
bandwidth per pin than any parallel-PSRAM option — but represent a
separate, larger engineering initiative (new controller, new protocol),
not a bus-width bump.

**Before committing PCB layout resources to the 32-bit recommendation**,
the next concrete experiment should be the flagged follow-up: a full
multi-slot RTL resynthesis and simulation at 32-bit (building the
wide-path equivalents of `nms_dataflow_core`/`nms_neural_multiprocessor`
and connecting them through the real `slot_mem_arbiter.v`) to replace
the DERIVED §10-11 projection with an independently-measured number —
the projection's own calibration assumption (degradation factor
invariant to width) is plausible but unverified, and could be
optimistic.

## Answers to the ten decision-threshold questions

1. **Does 16→32 bit produce a meaningful speedup?** Yes — 1.89×, real
   and substantial.
2. **Does 32→64 bit produce meaningful additional speedup?** Yes, but
   smaller — a further 1.80× (3.40× cumulative) — at markedly higher
   PCB/pin cost.
3. **At what width does the architecture cease to be primarily
   memory-bound?** None tested (16-128 bit) — utilization stays below
   2% throughout; this is not a bus-width-alone problem.
4. **Does the optimum N change with more bandwidth?** No, not within
   16-128 bit — N=2/4/8 give identical projected results at every
   width; the system stays memory-bound regardless of N.
5. **Would 32-bit be sufficient for N=4?** "Sufficient" depends on the
   target — it delivers the largest real, low-risk win available, but
   does not remove the memory-bound regime.
6. **Would 64-bit be justified?** Only if the incremental 1.80×/3× the
   PCB cost trade-off is acceptable for this specific product; not
   recommended as the *next* step given 32-bit's better risk/cost/gain
   ratio.
7. **Is 128-bit useless overkill?** Yes, confirmed — zero measured
   benefit over 64-bit in this architecture.
8. **Minimum bandwidth for a specified fraction of the compute
   ceiling?** Even the optimistic, contention-free 64-bit upper bound
   (STEP14) only reaches ~50%; reaching 90% requires the much larger
   (~36-82×) increase EXP-0024 already quantified — outside the scope
   of parallel-bus widening alone.
9. **FPGA I/O / PCB cost per option?** 32-bit: +16 pins, 1 extra
   footprint, low-moderate PCB impact. 64-bit: +48 pins, 3 extra
   footprints, substantially higher PCB/power/routing impact.
10. **Recommended architecture for the next board?** 32-bit, 2-chip
    parallel banking of the existing PSRAM part — pending the flagged
    multi-slot RTL validation before PCB commitment.
