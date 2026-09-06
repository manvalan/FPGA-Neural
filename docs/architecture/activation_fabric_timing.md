# NMS Activation Fill Controller Timing (STEP14 Part B)

Status: fixed, real post-P&R verified, bit-exact, adopted. Full data:
`hardware/v2/reports/step14_activation_timing.csv`. Full narrative:
`hardware/v2/logs/experiments.log` (EXP-0029, 0030, 0031),
`decisions.log` (DEC-0026, DEC-0027).

## B1 — Exact critical path (not assumed)

Mined directly from the real nextpnr-ecp5 P&R report for
`nms_neural_multiprocessor_stream.v` at N_SLOTS=4
(Fmax=55.22 MHz, FAIL @ 80 MHz). Full path, 18.11 ns total (6.25 ns
logic + 11.85 ns routing):

```
SOURCE:  u_act_fill.resident_tag[11]  (register Q)
   -> COMBINATIONAL, chained, NO register in between:
      (1) max_n_tiles computation, nms_activation_fill_ctrl.v:92
          (N_SLOTS-wide running-max fold, each iteration gated by a
          23-bit tag-equality check) -- long CCU2C carry chain
      (2) resident_count < max_n_tiles comparison, line 165
          (the ST_IDLE refill/continue decision) -- ANOTHER 16-bit
          magnitude-comparison carry chain, feeding directly off (1)
          in the SAME cycle
      (3) into pf_start's own next-state logic
DESTINATION: u_act_fill.pf_addr's clock-enable (CE) pin
```

Two full 16-bit magnitude comparisons sit in **one** combinational
cone across **one** clock edge. This confirms, at the exact RTL-line
level, the failure class DEC-0016/EXP-0022 predicted analytically
("O(N_SLOTS) unpipelined combinational scan feeding directly into a
control decision") — but precisely localizes it to the comparison
logic (lines 92 and 165), *not* the priority-encoder
(`desired_valid`/`desired_x_base`, lines 77-86), which does not appear
in this critical path at all.

## B2 — Scaling behavior

The bottleneck is the `max_n_tiles` running-max fold: an imperative
`for` loop creates a data dependency between iterations (`max_n_tiles`
after iteration *i* depends on iteration *i-1*), which Yosys
synthesizes as a sequentially-chained carry structure — inherently
O(N_SLOTS) deep, not O(log N_SLOTS). At N_SLOTS=4 the chain reached
6.25 ns logic + 11.85 ns routing; at N_SLOTS=8 it doubles again (see
below).

## B3 — Minimum fix (two iterations, evidence-driven)

**v2** (one pipeline stage: register `max_n_tiles` before its use in
the `resident_count` comparison): Fmax 55.22 → 72.78 MHz (+31.8%) —
real improvement, still fails 80 MHz. Re-tracing showed the *remaining*
critical path was entirely inside `max_n_tiles`'s own computation
(now feeding its own register), confirming the fix needed to go one
level deeper.

**v3** (second stage: register each slot's tag-equality/masking result
first — independent per-slot work, no N_SLOTS-dependent chain — *then*
fold the already-registered, already-masked values): Fmax 55.22 →
**106.81 MHz** (+93.4%). **PASSES** 80 MHz with real margin. Resource
cost: LUT4 -5.5%, FF +1.4% (2 added pipeline registers), CCU2C
unchanged.

## B4 — No serialization reintroduced

Verified directly: N_SLOTS=2 bit-exact regression test (D-Stress, real
V1 PSRAM chain) gives **numerically identical** cycle count and
sustained MAC/cycle before and after the fix (185270/185270 cycles,
0.1769/0.1769 MAC/cycle). The 3 total cycles of added latency apply
only to the rare, tile-refill-boundary-only decision — never to the
real-time per-tile consumption path (already fully decoupled by
STEP13's own streaming manager). Higher Fmax, zero throughput cost —
satisfying B4's explicit requirement.

## N=8 (exploratory)

`nms_activation_fill_ctrl_v3.v` at N_SLOTS=8: DSP=64/72 (89%, FEASIBLE),
LUT4=4653, FF=10855 (both comfortably FEASIBLE). **Fmax=52.25 MHz,
FAILS 80 MHz** — the v3 fix's second stage (the max-fold itself) is
still O(N_SLOTS)-deep; at N=8 it is twice as deep as at N=4 and becomes
dominant again. This is expected: v3 shifted the crossover point, it
did not eliminate the underlying dependency. A genuine balanced-tree
reduction (or a pipeline scaling with log₂(N_SLOTS) rather than a flat
2-stage split) would be required for N=8 — not undertaken this round
(N=8 is explicitly exploratory; the limiting resource (Fmax, not
DSP/LUT/FF/BRAM) is precisely identified and quantified, per spec).

## Adoption

`nms_activation_fill_ctrl_v3.v` is adopted as the reference activation
fill controller for N_SLOTS≥4 configurations (DEC-0027). The original
and the insufficient v2 are preserved for reference.
