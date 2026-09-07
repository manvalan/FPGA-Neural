# NMS Continuous Tile Stream — Memory Manager Redesign (STEP13)

Status: implemented, bit-exact verified, synthesized. **Adopted** as
the new reference NMS memory-manager configuration (DEC-0025). Full
data: `hardware/v2/nms/reports/batch_processor_{sweep.csv,summary.md}`.
Full narrative: `hardware/v2/logs/experiments.log` (EXP-0025 through
EXP-0028), `decisions.log` (DEC-0024, DEC-0025).

## Why this file is not `neural_processor_batch.v`

The governing brief for this STEP asked for a "batch/continuous
neuron execution model" — multiple neurons processed per dispatch, or
a continuous neuron stream — to amortize the ~68.5-cycles/neuron
non-memory floor found in EXP-0024. Before writing any RTL, Step 1
required tracing the actual RTL to find exactly where those cycles
go, rather than assuming.

That trace (EXP-0025, an isolated testbench with `neural_processor.v`
+ `nms_memory_manager_pf.v` driven with zero real memory latency
anywhere) found: **93.4% of the floor is explained by a 4-cycles/tile
serialization bug inside the memory manager's own `ST_RUN` state**,
not by per-job dispatch overhead (only 6.6%). `ST_RUN` implements
operand delivery as a strictly sequential chain —
`read_issued → read_ready → present → consumed` — with zero overlap
between consecutive tiles, even though:

- the local activation/weight SRAMs (`nms_activation_replicated.v`,
  `nms_weight_packed.v`) have only a 1-cycle `rd_en`-to-data latency;
- `neural_processor.v`'s own `operand_ready` is held continuously high
  through the whole tile-loading phase — its datapath is explicitly
  designed (per its own header comment) to accept a new tile every
  cycle while previous tiles drain through the adder tree/accumulator.

Neither side of this interface requires 4 cycles/tile. It is purely
an artifact of the memory manager's own un-pipelined FSM. **The fix is
therefore a continuous per-tile streaming redesign of the memory
manager, not a neuron-batching scheme — hence
`nms_memory_manager_stream.v`, not `neural_processor_batch.v`.**
`neural_processor.v` itself required no modification.

## Design: `nms_memory_manager_stream.v`

Drop-in replacement for `nms_memory_manager_pf.v` (identical external
interface, same `weight_prefetch_engine.v` instance, same outer job
FSM `ST_IDLE`/`ST_WAIT_RESULT`/`ST_WRITE_RES`/`ST_DONE`). Only
`ST_RUN`'s internal operand-delivery logic differs:

- `rd_ptr` — the read-**issue** pointer (which tile's SRAM read has
  been, or is about to be, issued), independent of and normally one
  tile ahead of `tile_idx` (the **consumption** pointer, i.e. how many
  tiles `neural_processor.v` has actually accepted).
- A 1-deep skid buffer (`buf_valid`/`buf_input`/`buf_weight`/
  `buf_last`) holds one tile's fully-read SRAM data, presented to NP
  as `operand_valid`/`input_data`/`weight_data`/`tile_last`.
- Every cycle: if a read issued last cycle is landing now (1-cycle
  SRAM latency), it's captured into the skid buffer; independently, a
  new read is issued for `rd_ptr` whenever legal (in bounds, weight +
  activation ready) **and** the buffer will not overflow (empty, or
  being drained this same cycle).

Since `operand_ready` stays high throughout the tile-loading phase,
the skid buffer drains every cycle it's full, so a new read can be
issued every cycle too — sustained ~1 cycle/tile, down from 4.

`tile_idx` (the consumption pointer) is still what feeds
`weight_prefetch_engine.v`'s own `consumed_count` port — its external
contract is unchanged; only the local SRAM read-issue pointer
(`rd_ptr`) is new, and it can run up to one tile ahead of `tile_idx`
(the skid buffer's own depth).

## Verification chain (all real, none assumed)

1. **EXP-0025**: isolated zero-latency trace of the *old* design —
   established the 4-cycles/tile floor and its 93.4% share of
   EXP-0024's real measured floor.
2. **EXP-0026**: same isolated trace against the *new* design — the
   fix works exactly as designed (confirmed cycle-by-cycle), but
   total cycles barely move (81→80), because it immediately hits a
   *second*, previously-masked bottleneck: `weight_prefetch_engine.v`'s
   own word-fetch rate is *also* exactly 4 cycles/tile (P_IN=8 bytes ÷
   16-bit bus = 4 word-transactions, 1 cycle/word minimum even at
   zero real latency) — a bus-**width** ceiling, structurally
   different from an FSM-serialization ceiling, that happens to
   coincide numerically today.
3. **EXP-0027**: a direct control experiment — a scratch variant with
   weight-fetch bypassed (always-ready) isolates the new design's
   *own* ceiling: a clean 1 cycle/tile (100% of `neural_processor.v`'s
   theoretical per-tile rate), vs. the old design's hard 4-cycles/tile
   cap under the identical bypass. This is the direct proof that the
   fix removes a real, 4× architectural ceiling — it was just masked
   by a coincidentally-equal second bottleneck.
4. **EXP-0028**: full real-system integration
   (`nms_dataflow_core_stream.v` → `nms_neural_multiprocessor_stream.v`,
   real V1 PSRAM chain) — bit-exact PASS, 256/256 neurons, D-Stress
   workload identical to EXP-0022/0024. Real cycle count: 185270 vs.
   185398 (`_pf` baseline), -0.07% — confirms the "masked, zero net
   benefit today" prediction exactly. Real synthesis + P&R: N=1
   Fmax=142.92 MHz (+3.7% vs. baseline), N=2 Fmax=92.57 MHz (-2.8%,
   still comfortably above 80 MHz), resource cost within ±6%. N=4:
   55.22 MHz, FAILS 80 MHz — but for the *pre-existing*,
   already-documented `nms_activation_fill_ctrl.v` priority-scan
   regression (EXP-0022), unrelated to and unaffected by this fix.

## Outcome and adoption

**Outcome B** (helps, but another bottleneck appears — see
DEC-0025 and `batch_processor_summary.md` for the full nine-question
final decision). `nms_memory_manager_stream.v` is adopted as the new
reference configuration: it is a strict improvement (bit-exact,
resource-neutral, no measured downside) and is **required groundwork**
for any future PSRAM bandwidth increase to actually translate into a
throughput gain — without it, a wider/faster memory would immediately
hit the old FSM's 4-cycles/tile ceiling and realize only 25% of its
potential benefit. The original `nms_memory_manager.v` and
`nms_memory_manager_pf.v` remain preserved, unmodified, for A/B/C
reference. Neuron-batching (the brief's original Model B/C) was not
pursued — evidence showed it addresses only 6.6% of the real floor and
would deliver no measurable benefit today for the identical reason
(weight-fetch-rate-bound). N=4/N=8 viability remains blocked by two
independent issues neither addressed by this STEP: external PSRAM
bandwidth, and the activation fill controller's own Fmax regression —
both flagged as future work.
