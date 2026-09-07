# NMS Weight Datapath Scaling (STEP14 Part A)

Status: architectural requirement established and proven (simulation),
**not realizable on real hardware today** (fixed 16-bit physical
PSRAM). Full data: `hardware/v2/reports/step14_weight_scaling.csv`.
Full narrative: `hardware/v2/logs/experiments.log` (EXP-0032, EXP-0033),
`decisions.log` (DEC-0028).

## Question answered

*At what weight-path width does the processor stop being fundamentally
starved by weight delivery?* **64 bits** — exactly `P_IN × DATA_WIDTH`
(8 × 8). Proven by direct cycle-exact simulation, not assumed.

## What was built

`weight_prefetch_engine_wide.v` — a parameterized (`MEM_DATA_WIDTH`)
generalization of the real `weight_prefetch_engine.v`'s continuous
cross-tile-boundary streaming design, simulation-only/exploratory
(same status as `ideal_memory_model.v`). `WORDS_PER_TILE =
ceil(P_IN*DATA_WIDTH / MEM_DATA_WIDTH)`, clamped to a minimum of 1.
`nms_memory_manager_stream_wide.v` pairs it with STEP13's own streaming
memory manager unchanged (A2's requirement), on a *separate* logical
wide port from the real 16-bit result-write-back port.

A real bug was found and fixed during development: address stepping
initially used `WORDS_PER_TILE × BYTES_PER_WORD` as the inter-tile
byte stride, which over-counts whenever the bus is wider than one full
tile (the 128-bit case, `WORDS_PER_TILE=1` but `BYTES_PER_WORD=16`
while the tile itself is only 8 bytes) — this skips over the next
tile's actual data in the packed backing store. Fixed by defining
`TILE_BYTES = TILE_BITS/8` as the canonical, width-independent stride.

## Results (bit-exact + ideal-memory cycle count)

| Width | Words/tile | Steady-state cycles/tile | 16-tile job total |
|---|---|---|---|
| 16-bit | 4 | 4 | 80 |
| 32-bit | 2 | 2 | 48 |
| **64-bit** | **1** | **1** | **32** |
| 128-bit | 1 | 1 | 32 |

All four widths pass bit-exact correctness (9/9 tests each, including
under injected extra memory latency). 64-bit achieves a clean,
cycle-exact **1 cycle/tile** — 100% of `neural_processor.v`'s own
theoretical per-tile acceptance rate, exactly matching the streaming
memory manager's own ceiling (EXP-0027, STEP13). 128-bit gives **zero**
further benefit: a bus wider than one full tile still delivers exactly
one tile per transaction in this single-tile-per-request design (no
multi-tile bursting was attempted).

## The critical distinction: logical vs. physical bandwidth (A5)

STEP14 explicitly warned against assuming a wider logical interface
means the real memory can deliver it. It cannot, here: **the real V1
PSRAM chain is fixed at 16 bits** — a real chip
(ISSI IS66WVE4M16EBLL-70BLI, x16), not an RTL parameter. The
already-existing, already-verified `weight_prefetch_engine.v` (real,
used throughout STEP11-13) *is* exactly what a "64-bit logical / 16-bit
physical" packing adapter would produce: it assembles one 64-bit
logical tile from 4 real sequential 16-bit word transactions. Its real,
repeatedly-measured result is 4 cycles/tile — identical to the ideal
16-bit row above, because the real transaction count is unchanged
regardless of what the logical interface upstream claims. **A logical
wide interface backed by a physically-narrow bus delivers exactly the
narrow bus's own throughput.** No new "packing adapter" module was
built for this reason — the real engine already demonstrates the
answer, conclusively, without further RTL.

## Answer to the primary research questions

- **Is 16-bit weight delivery fundamentally insufficient for P_IN=8?**
  Yes — it costs 4 cycles/tile, 4× the achievable minimum.
- **Is 32-bit enough?** No — still 2× the achievable minimum (2
  cycles/tile).
- **Is 64-bit the natural architectural point?** Yes, exactly — proven
  cycle-exact, not approximate.
- **Does wider logical delivery actually improve real throughput?**
  **Not on this hardware.** Realizing the 64-bit ideal requires a
  matching *physical* bandwidth increase (a real 64-bit-wide external
  bus, or multiple parallel 16-bit PSRAM chips banked together) — a
  board/silicon-level change, outside this project's own RTL scope.

## Recommendation

The 64-bit requirement is now precisely quantified and should inform
any future hardware revision (wider PSRAM, multiple banks). No RTL
change is warranted on the current board: `weight_prefetch_engine.v`
(real, 16-bit) remains the correct, already-optimal implementation
given the fixed physical bus width — STEP13's streaming-manager fix
already extracts everything available from the real interface.
