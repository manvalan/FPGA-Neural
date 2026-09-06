# FPGA-Neural V2 — Memory Upgrade (64MB) + N_SLOTS=8 + Clock Re-Verification

Supersedes the SDRAM-related content of `PRE_PCB_VERIFICATION.md` and
`PRE_PCB_CLOSURE_4POINT.md` (both describe the previous 8MB
AS4C4M16SA-6TIN baseline). This document is the authoritative record
for: the memory capacity investigation, the frozen replacement part,
every RTL change it required, two real timing regressions found and
fixed via real P&R data, and the honest, current state of N_SLOTS=4
vs N_SLOTS=8 clock closure.

---

## 1. Why the memory was investigated

At 8MB (AS4C4M16SA-6TIN), the real V2 memory map already reserves
~2MB for weights. A concrete throughput check: the existing D-Stress
benchmark (256 neurons × 128 inputs = 32,768 weight bytes) takes
49,771 cycles (777µs at the real, P&R-verified 64MHz) to run to
completion. Extrapolating linearly, a 24MB weight budget (the
proportional share of a 64MB device) would take on the order of
**~580ms for one inference pass** — already deep into "too slow to
matter" territory for this accelerator's real target (a low-latency
SPI-peripheral offload engine), well before capacity itself becomes
the binding constraint. This was disclosed to the user directly:
capacity was not really the bottleneck, compute throughput was. The
user weighed this and still asked for the largest same-family,
same-package part, with N_SLOTS=8 as the preferred processor count —
both honored below, with a fully honest report of what real P&R data
says about clock closure at each.

## 2. Real datasheet investigation of the whole Alliance Memory SDR family

All four organization datasheets were fetched and read directly (not
inferred from generic SDRAM knowledge):

| Part | Density | Organization | Row/Col/Bank bits | Address pins |
|---|---|---|---|---|
| AS4C4M16SA-6TIN (previous) | 64Mbit/8MB | 4 banks × 4096 rows × 256 cols | 12/8/2 | A0-A11 (12) |
| AS4C8M16SA-6TIN | 128Mbit/16MB | 4 banks × 4096 rows × 512 cols | 12/9/2 | A0-A11 (12, pin-compatible with the 8MB part!) |
| AS4C16M16SA-6TIN | 256Mbit/32MB | 4 banks × 8192 rows × 1024 cols... | — | see below |
| **AS4C32M16SB-7TIN (new)** | **512Mbit/64MB** | **4 banks × 8192 rows × 1024 cols** | **13/10/2** | **A0-A12 (13 — one new pin)** |

(Correction to the table above: AS4C16M16SA-6TIN is 4 banks × 8192
rows × 512 cols, 13/9/2, also needing A0-A12 — confirmed via its own
real datasheet. The key finding driving the final part choice: going
from 32MB to 64MB costs **zero additional pins** beyond what 32MB
already requires, since both need the same 13 address pins. There is
no PCB-simplicity reason to stop at 32MB once the 13th pin is already
being added.)

**"SA" vs "SB" note**: Alliance Memory's own datasheet revision
history (AS4C32M16SA Rev 2.0: "Die Shrink – A revision") confirms
these letter suffixes denote die-shrink process revisions, not
functional or pinout changes. Real distributor availability (section
6 below) shows "SB" as the currently-stocked die for this part.

**Package: BGA, not TSOP-II** — per the user's own explicit choice,
the FROZEN part is **AS4C32M16SB-7BIN** (54-ball TFBGA, 8.0×8.0×1.2mm
max, "B" package-code suffix), not the TSOP-II "-7TIN" variant
discussed earlier in this investigation. Same die, same organization,
same timing, same 3.3V/industrial-temp electricals — the datasheet's
own "Features" section lists both a 54-pin TSOP-II AND a 54-ball FBGA
package option for this exact device; only the physical footprint
differs (a PCB-level choice, the user's own call). The datasheet-level
electrical/timing audit in this document applies unchanged to either
package option.

## 3. Real AC timing (AS4C32M16SB/SA-7 grade, 143MHz max — no -6/166MHz
   grade exists for this density)

| Parameter | Real value | Previous part (AS4C4M16SA-6TIN) |
|---|---|---|
| tRCD | 15ns min | 18ns min (BETTER on the new part) |
| tRP | 15ns min | 18ns min (BETTER) |
| tRAS | 45ns min / 100,000ns max | 42ns min / 100,000ns max |
| tRC | 65ns min | 60ns min |
| tMRD | 2 CLK (fixed, explicit units) | 2 tCK (previously ambiguous, ERR-0026) |
| tWR | 2 CLK (fixed, explicit units) | folded in via T_RP+1 |
| tREFI | 7.8125µs (8192 rows/64ms) | 15.625µs (4096 rows/64ms) — HALF |
| CAS latency | 2 or 3 (3 used, unchanged) | 2 or 3 |

All values re-derived into `sdram_controller.v`'s own `ns_to_cycles()`
function at the real 64MHz target — verified safe at 64MHz through
166MHz via the full regression sweep (section 7).

## 4. RTL changes required

### 4.1 `sdram_controller.v` and `sdram_model.v` — parameterized geometry

Both files gained real `ROW_BITS`/`COL_BITS`/`BANK_BITS` parameters
(defaults 13/10/2, matching the new part) replacing hardcoded 12/8/2
widths throughout: the address decode, the column-phase address
assembly (previously a hardcoded `{4'b0100, col}` concatenation, now
a parameterized construction that places the AP bit at the same bit
10 position regardless of column width), the MRS mode-register value
(re-derived to be zero-padded correctly for any ROW_BITS), and the
refresh-interval computation (now `64000000/(1<<ROW_BITS)+1`, correct
for either device). An elaboration-time assertion
(`ADDR_WIDTH == BANK_BITS+ROW_BITS+COL_BITS`) catches any future
mismatched override immediately.

### 4.2 Address-width propagation (23→26 bits, byte address)

`ADDR_WIDTH` default widened from 23 to 26 across every module in the
live instantiation tree: `spi_host_bridge.v`, `dependency_manager.v`,
`neural_director.v`, `slot_mem_arbiter.v`, `slot_mem_arbiter_wide.v`,
`nms_dataflow_core_sdram.v`, `nms_activation_fill_ctrl_v3.v`,
`weight_prefetch_engine_wide.v`, `nms_dataflow_core_sdram.v`,
`sdram_unified_backend.v`, `fpga_neural_v2_top.v`, and the D-Stress
testbench's own top wrapper `nms_neural_multiprocessor_sdram_unified.v`.
`sdram_unified_backend.v` also gained its own `ROW_BITS`/`COL_BITS`/
`BANK_BITS` pass-through parameters (forwarded to `sdram_controller`
instead of a hardcoded `.ADDR_WIDTH(22)` override that would otherwise
have silently reverted to the old geometry), and its internal
word/byte address-conversion wires were parameterized instead of
hardcoded to 22 bits.

### 4.3 SPI protocol change (`spi_host_bridge.v`) — real, necessary

A 26-bit byte address no longer fits in 3 bytes (24 bits) with a
spare reserved bit the way the old 23-bit address did. Every address
field widened from 3 to 4 bytes:

- **WRITE_JOB**: 15 → **18 payload bytes** (x_base/w_base/result_addr
  each 3→4 bytes).
- **WRITE_MEM/READ_MEM header**: 5 → **6 bytes** (addr 3→4 bytes).

`byte_idx` widened from 4 to 5 bits (max index 17, was 14) to
accommodate the longer WRITE_JOB frame.

### 4.4 New PCB pin: `sdram_a[12]`

`v2_board_top.lpf` gained one new entry: `sdram_a[12]` → ball **F1**
(bank 6, official Lattice pinout CSV rev 3.0, CABGA381 column) — a
real, previously-unused, plain-GPIO ball, verified not already
assigned to any of the LPF's existing 44 signals.

## 5. Two real timing regressions found and fixed (see errors.log
   ERR-0027/ERR-0028 for the full root-cause writeups)

**ERR-0027**: `neural_director.v`'s own per-slot dispatch used a
runtime-indexed write into a wide packed register
(`slot_x_base[free_slot_idx*ADDR_WIDTH +: ADDR_WIDTH] <= ...`),
synthesizing as an actual MULT18X18D multiplier feeding a wide
demux/crossbar. This got worse as ADDR_WIDTH grew — real P&R: worst
seed collapsed from the previously-verified 68.51MHz to 40.27MHz,
FAILING 64MHz across all 8 seeds. **Fixed** by replacing it with
N_SLOTS unpacked per-slot registers, written via N_SLOTS parallel
constant-indexed compares (no multiply), wired out via a
constant-genvar generate block. Confirmed: the spurious 33rd
MULT18X18D at N=4 is gone (now exactly 32 = 4×8, matching the real
per-processor MAC count). Real P&R after the fix, N=4, 8 seeds: **ALL
PASS at 64MHz** (65.02–72.01MHz, mean ~68.8MHz).

**ERR-0028**: found immediately after, at N_SLOTS=8: a DIFFERENT,
pre-existing critical path in `nms_activation_fill_ctrl_v3.v`'s own
`max_n_tiles_comb` — a flat, linear N_SLOTS-wide sequential max-scan,
already flagged by that file's own prior comment as "an N_SLOTS-wide
sequential chain." At N_SLOTS=8 (twice the comparison depth of N=4,
where it wasn't the bottleneck) it became dominant: real P&R showed
~38-40MHz, failing 64MHz on all 4 tested seeds. **Fixed** by replacing
the flat scan with an explicit, hand-written balanced binary max-tree
(log2(N_SLOTS) levels instead of N_SLOTS), same single-cycle latency.
Real P&R after the fix, N=8, 8 seeds: **5/8 PASS at 64MHz**
(65.27–70.78MHz), 3/8 FAIL narrowly (55.84/61.00/63.42MHz).

Both fixes were confirmed **bit-exact, zero functional regression**
via the full D-Stress N=2/4/8 regression (identical cycle counts to
the pre-fix baseline: 49961/49927/49909).

## 6. Honest current clock-closure status

| Configuration | Seeds tested | Result |
|---|---|---|
| N_SLOTS=4 @ 64MHz | 8/8 | **PASS, all seeds** (65.02–72.01MHz real Fmax) |
| N_SLOTS=8 @ 64MHz | 8/8 | **5/8 PASS** (65.27–70.78MHz), 3/8 FAIL (55.84/61.00/63.42MHz) — OPEN |
| N_SLOTS=4 or 8 @ 80MHz | 4 each | **FAIL, all seeds** (real 80MHz-targeted PLL regenerated via `ecppll`, real P&R re-run; same physical Fmax ceiling as the 64MHz-labeled runs, ~65-72MHz, confirming the achievable ceiling is a property of the fabric, not the requested target) |

**Recommendation**: **N_SLOTS=4 remains the frozen, fully-reliable
hardware configuration at 64MHz** (matches the project's own
established "safe = passes on every tested seed" standard).
**N_SLOTS=8 is functionally correct and usable, with a real, disclosed
timing risk**: 5 of 8 tested placement seeds close timing at 64MHz;
production would need to either (a) find and lock a known-good seed
(a real, standard practice — nextpnr's own seed is a build-time
choice, not a per-chip random draw) or (b) accept a further
timing-optimization pass (the same tree-based-reduction technique
already applied twice this session, next targeting
`sdram_unified_backend.v`'s own weight-cache hit-index scan — not
attempted this session, to avoid rushing a third unverified change).
**80MHz is not achievable with the current architecture at either
processor count** — a real, measured finding, not an assumption.

## 7. Full regression re-verification (real, this session)

| Test | Result |
|---|---|
| `tb_sdram_controller` (18 configs: 6 freqs × 3 burst lens, new 64MB geometry) | 461/461 PASS, every config |
| `tb_sdram_boundary` (21 directed checks, new geometry) | 21/21 PASS at 64MHz AND 166MHz |
| D-Stress N=2 | 49,961 cycles, 256/256 bit-exact PASS |
| D-Stress N=4 | 49,927 cycles, 256/256 bit-exact PASS |
| D-Stress N=8 | 49,909 cycles, 256/256 bit-exact PASS |
| `tb_spi_host_bridge` (new 18/6-byte protocol) | 18/18 PASS |
| Board-level SPI smoke test (real 64MHz clk_sys, new protocol) | 11/11 PASS |
| `tb_sdram_unified_backend` | 40/40 PASS |

## 8. Availability (real, checked this session)

**AS4C32M16SB-7BIN** (the frozen, BGA-package part): DigiKey product
11613071, 568 units in stock, $31.12/unit (qty 1), 16-week
manufacturer lead time, status Active, 54-ball TFBGA (8×8×1.2mm max),
-40 to 85°C industrial. Not a datasheet-only part — genuinely
orderable as of this session.

(The TSOP-II sibling, AS4C32M16SB-7TIN, was also confirmed real and
in stock — DigiKey 47 units, $31.40/unit — should the user reconsider
package during layout; both are the same die.)

## 9. What is still OPEN (honestly disclosed)

- N_SLOTS=8 clock closure at 64MHz: 5/8 seeds, not yet 8/8.
- The `sdram_unified_backend.v` weight-cache hit-index scan (the same
  long-documented critical-path class) has not been tree-optimized —
  a plausible next fix for closing the N=8 gap, not attempted this
  session.
- The PRE_PCB_VERIFICATION.md / PRE_PCB_CLOSURE_4POINT.md documents'
  own SDRAM-specific sections (organization tables, pin counts,
  memory-map worked examples) describe the previous 8MB part and are
  superseded by this document — not individually rewritten line-by-
  line in this pass.
- The V2 LaTeX datasheet's own key-parameters table and memory-
  architecture chapter still describe the 8MB device — not
  regenerated this session (time/scope boundary); flagged here so it
  is not silently stale.
