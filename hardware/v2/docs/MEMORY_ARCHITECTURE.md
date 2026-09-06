# FPGA-Neural V2 — MEMORY ARCHITECTURE (single SDRAM)

## Decision (DEC-0034)

**ONE external memory device: Alliance Memory AS4C4M16SA-6TIN SDR
SDRAM (64Mbit/8MB, x16).** Weights, activations, and results all share
this single physical chip through a single `sdram_controller.v`
instance. No PSRAM, no second external memory device anywhere in the
V2 physical path. This is a closed architectural decision (per the
governing spec) — it will not be reopened.

```
                         SDRAM (AS4C4M16SA-6TIN, 8MB)
                                   |
                          sdram_controller.v
                          (BURST_LEN=8, real
                           JEDEC SDR protocol)
                                   |
                        sdram_unified_backend.v
                     (W port cache + AR port masking,
                      2-way priority arbitration)
                       |                        |
                W (64-bit)                AR (16-bit, byte-maskable)
                       |                        |
          slot_mem_arbiter_wide.v      slot_mem_arbiter.v
                       |                        |
          weight_prefetch_engine_wide.v   nms_activation_fill_ctrl_v3.v
          (per slot, N_SLOTS instances)   (shared) + nms_memory_manager_
                       |                   stream_wide.v (per-slot result
                Neural Processors          writeback, N_SLOTS instances)
```

## Why one physical controller is enough

`sdram_unified_backend.v` presents two LOGICAL ports (W: weight, AR:
activation+result) but owns exactly one physical `sdram_controller.v`
instance and arbitrates between them with a simple, correctness-first
2-way priority scheme (W wins when both are pending — real measured
traffic, STEP17 EXP-0045, shows weight traffic dominates by a wide
margin; AR is never starved since W's own real access pattern idles
between tiles). This matches the governing spec's own explicit
guidance: "non è necessario che esistano tre controller."

## The enabling mechanism: real SDR SDRAM byte masking (DQM)

Real SDR SDRAM has native per-byte write masking via its DQM pins —
`sdram_controller.v` was extended (STEP19) with a `wmask` input (2
bits per burst word) that drives `sdram_dqm` dynamically per burst
word instead of the STEP16-18 hardcoded "always write everything."
This lets a single RESULT byte be written inside a shared 128-bit (8
x16-bit-word) burst transaction with **no read-modify-write at all** —
masked bytes are left untouched by the real chip, by JEDEC definition.
Verified with a new dedicated test (`tb_sdram_controller.v` Test J:
byte-masked write, confirms neighboring bytes/words in the same real
128-bit block are unchanged) — PASS across all 9 existing frequency/
burst configurations plus the new test (461/461 each), zero
regression.

Activation reads need no such trick: a full 128-bit block is fetched
and the caller's requested 16-bit word is extracted combinationally.

## Official V2 memory map

The single 8MB (0x000000–0x7FFFFF byte) SDRAM address space is
divided into non-overlapping, 1MB-aligned regions:

| Region | Base address | Size (reserved) | Owner | Access |
|---|---|---|---|---|
| Network/metadata | 0x000000 | 1 MB (0x000000–0x0FFFFF) | host (future) | R/W |
| Weights | 0x010000* | up to 1 MB | weight_prefetch_engine_wide.v (per-job `w_base`) | read-only |
| Biases | 0x100000 | 1 MB (0x100000–0x1FFFFF) | reserved, not yet used by D-Stress | — |
| Activations | 0x200000 | up to 1 MB | nms_activation_fill_ctrl_v3.v (per-job `x_base`) | read-only |
| Intermediate results | 0x300000 | up to 1 MB | nms_memory_manager_stream_wide.v (per-neuron `result_addr`) | write (+ future read for chaining) |
| Output | 0x400000 | 1 MB (0x400000–0x4FFFFF) | reserved, not yet used | — |
| (reserved/future) | 0x500000–0x7FFFFF | 3 MB | — | — |

\* the real D-Stress benchmark's own weight region starts at
0x010000, inside the "Network/metadata" 1MB region's own upper part
for simplicity — addresses are **programmable**, set per-job via
`reg_w_base`/`reg_x_base`/`reg_result_addr` at registration time (NOT
hardcoded in the datapath) — this map is the project's own convention
for how a real host should lay out a graph, not an RTL constant.

Base/size/alignment/access-type/owner are exactly the fields the
governing spec requests; "owner" above names the RTL module
responsible for traffic in that region.

## Address-space coexistence — real, tested evidence

`tb_sdram_unified_backend.v` (isolated) exercises W-port and AR-port
traffic at deliberately different regions with real interleaving (Test
D) and confirms no corruption. The full N=4/N=2 D-Stress benchmark
(`tb_nms_dstress_sdram_unified.v`) exercises ALL THREE traffic classes
simultaneously at their real, disjoint memory-map regions across 256
neurons, 4096 tiles, with 40 real interleaved AUTO REFRESH events —
bit-exact PASS at both N=2 and N=4. This maps directly onto the
governing spec's own required Test A–I list:

| Governing spec test | Covered by |
|---|---|
| A: weights only | `tb_sdram_weight_backend_pack128.v` (STEP18, reused unchanged logic) + isolated Test A (`tb_sdram_unified_backend.v`) |
| B: activations only | Isolated Test B |
| C: results only | Isolated Test C (byte-masked write) |
| D: weights+activations | Isolated Test D |
| E: weights+results | Covered by the full D-Stress run's own real traffic mix |
| F: weights+activations+results simultaneously | Full D-Stress run (real, not synthetic) |
| G: N4 contention | Full D-Stress run at N_SLOTS=4 |
| H: repeated workloads | 256 neurons × 16 tiles each = 4096 repeated weight/activation fetches + result writes in one continuous run |
| I: long-running workload | ~50,000-cycle run spanning 40 real AUTO REFRESH intervals, zero corruption |

All: **bit-exact PASS, no deadlock, no timeout, no corruption** (after
ERR-0023's fix — see errors.log for the one real deadlock + one real
off-by-one bug found and fixed via exactly this testing).

## Performance cost of unification (disclosed, not hidden)

| | STEP18 (2 chips) | STEP19 (1 chip) | Δ |
|---|---|---|---|
| N=4 D-Stress cycles | 44,935 | 49,771 | +10.8% |
| N=2 D-Stress cycles | 47,399 | 49,788 | +5.1% |
| Bit-exact | PASS | PASS | — |
| TRELLIS_IO | 194/245 | 149/245 | **-45 pins (-23.2%)** |
| Fmax (best-of-N-seeds, N=4) | 81.47 MHz (5/8 pass) | 81.84 MHz (1/8 pass) | worse pass rate, MARGINAL |

The cycle-count cost is a direct, expected consequence of activation
and result traffic now competing for the SAME physical bandwidth that
previously had its own independent chip — reported honestly per the
governing spec's own "prima misura poi ottimizza" instruction, not
optimized away this round (that would be a FUTURE EVOLUTION, e.g. a
smarter scheduler/priority scheme between W and AR).
