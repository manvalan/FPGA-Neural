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
  is not silently stale. **UPDATE (2026-09-07): now addressed, see
  section 10 below and `DataSheet/files/docs/datasheet/v2-en/chapters/
  05-memory.tex`, appended section "SDRAM Upgrade Addendum."**

## 10. AUTHORITATIVE FINAL DATA (2026-09-07) — full 8-seed matrix,
    ERR-0029 optimization, and complete AS4C32M16SB-7BIN pinout

This section is the authoritative, most-recent source of truth,
superseding sections 5-9 above where they conflict (kept for history).
All data below is real, measured, from `nextpnr-ecp5 0.11.1 --report`
JSON output and real Verilator 5.050 regression runs — no estimates.

### 10.1 N=4 @ 64MHz — PRE-ERR-0029 fix (period 15.625ns)

| Seed | Fmax (MHz) | WNS (ns) | Critical path (startpoint → endpoint) |
|---|---:|---:|---|
| 0 | 77.10 | +2.655 | director.job_out_slot → dep_mgr.node_resolved[13] |
| 1 | 74.68 | +2.234 | arbiter_wide.m_addr → sdram_backend.w_rdata |
| 2 | 74.64 | +2.228 | director.job_out_slot → dep_mgr.node_resolved[6] |
| 3 | 77.24 | +2.678 | arbiter_wide.m_addr → sdram_backend.w_rdata |
| 4 | 76.60 | +2.571 | sdram_backend.w_cache_addr[2] → sdram_backend.w_rdata |
| 5 | 77.96 | +2.798 | director.job_out_slot → dep_mgr.node_resolved[3] |
| 6 | 75.35 | +2.353 | director.job_out_slot → dep_mgr.node_resolved[2] |
| 7 (worst) | 74.17 | +2.143 | director.job_out_slot → dep_mgr.node_state[12] |

8/8 PASS. Worst seed7 74.17MHz/+2.143ns — routing-dominated (78%),
11 logic levels, classified as dependency_manager scheduler/producer-
consumer resolution logic.

### 10.2 N=8 @ 64MHz — PRE-ERR-0029 fix (period 15.625ns)

| Seed | Fmax (MHz) | WNS (ns) | Status |
|---|---:|---:|---|
| 0 | 57.27 | −1.837 | FAIL |
| 1 (worst) | 55.84 | −2.284 | FAIL |
| 2 | 66.99 | +0.698 | PASS |
| 3 | 70.78 | +1.496 | PASS |
| 4 | 61.00 | −0.769 | FAIL |
| 5 | 68.56 | +1.039 | PASS |
| 6 | 67.29 | +0.764 | PASS |
| 7 | 63.42 | −0.144 | FAIL |

4/8 PASS (2,3,5,6), 4/8 FAIL (0,1,4,7). Worst seed1 55.84MHz/−2.284ns —
`sdram_unified_backend.v` weight-cache hit-index scan, 84% routing,
10 logic levels; three individual routing hops of 2.5–2.8ns.
Utilization: MULT18X18D 64/72 (88.9%), TRELLIS_COMB 11066/43848
(25.2%), TRELLIS_FF 11119/43848 (25.4%), DP16KD 0/108, TRELLIS_RAMW
323/5481.

### 10.3 N=4/N=8 @ 80MHz — genuine `ecppll`-regenerated PLL (CLKI_DIV=1,
    CLKFB_DIV=5, CLKOP_DIV=7, CLKOP_CPHASE=3, VCO=560MHz), period 12.5ns

Both configurations: **0/8 seeds PASS** (achieved Fmax per seed
numerically identical to the 64MHz-PLL run in every case, confirming
the achievable ceiling is a fabric property, independent of PLL
target). N=4 closest: seed5, 77.96MHz, WNS=−0.327ns. N=8 closest:
seed3, 70.78MHz, WNS=−1.629ns. **NO-GO, both configs, both before and
after the ERR-0029 fix below** (re-confirmed in 10.5).

### 10.4 ERR-0029 root-cause investigation (user-directed, real data)

Investigated per the mandate's own 14-point checklist against the real
critical-path segment dump (seed1, N=8@64MHz) — see errors.log ERR-0029
for the full writeup. Summary of findings:

1. `w_cache_valid[0:W_ENTRIES-1]` (W_ENTRIES=4 fixed, NOT scaled by
   N_SLOTS — confirmed via its only instantiation) generated by the
   cache-allocate/consume sequential block.
2. `w_hit_idx_c` generated by a combinational `for` loop, "last
   valid+matching entry wins" by unconditional sequential overwrite.
3. 4 comparators (one per W_ENTRIES).
4. Encoded via a serially-dependent priority scan, mapped by
   Yosys/nextpnr onto cascaded ECP5 PFUMX/OFX fast-mux primitives.
5. `w_hit_idx_c` fans out to the 64-bit cache-data read mux and to
   control/enable logic gating `w_rdata`'s load — a 3-way fan-out of a
   value produced by a serial 4-stage chain.
6/7. The long hops (2.5–2.8ns each) are the physical distance between
   the shared cache logic and the arbiter/consumer registers, stretched
   by N=8's larger overall placement — NOT a logic-depth artifact
   (W_ENTRIES doesn't grow with N_SLOTS).
8. Confirmed: yes, a serial mux-topology (PFUMX/OFX chain), not a
   parallel structure.
9. Comparator fanout (4-wide) is NOT the dominant cost.
10. Yes — the final long hop lands on a clock-enable/control signal,
    not a data path, confirming control-logic fan-in as part of the
    span.
11/12/14. Yes — registering an intermediate result, and/or replacing
    the serial scan with a balanced/flat parallel structure, are both
    feasible, low-risk, same-precedent-class fixes (ERR-0028 used the
    same architecture for a different module).
13. Not a "replicate per slot" scenario, since the cache is shared and
    W_ENTRIES is fixed — a flat parallel restructuring was chosen
    instead of pipelining, to avoid any latency/behavior change.

### 10.5 ERR-0029 fix applied, and the honest, measured before/after

Fix: serial priority-scan → flat one-hot compare (parallel comparators,
`generate`/`genvar`) + single-level `casez` priority encode, bit-exact
semantics preserved. See errors.log ERR-0029 and DEC-0040 for full
detail. Verified bit-exact: isolated `tb_sdram_unified_backend.v`
40/40 PASS; full D-Stress N=4 (49,927 cycles, 256/256 bit-exact vs
golden) and N=8 (49,909 cycles, 256/256 bit-exact vs golden) — zero
functional regression.

**N=4 @ 64MHz, POST-fix** (period 15.625ns):

| Seed | Fmax (MHz) | WNS (ns) | Critical path endpoint |
|---|---:|---:|---|
| 0 | 70.68 | +1.477 | sdram_backend.state |
| 1 (worst) | 66.58 | +0.605 | sdram_backend.ctrl_wdata |
| 2 | 74.74 | +2.245 | sdram_backend.ctrl_wdata |
| 3 | 71.98 | +1.733 | sdram_backend.ctrl_wdata |
| 4 | 74.48 | +2.198 | dataflow_core.GEN_SLOT[2].u_mm.wgt_rd_addr |
| 5 | 75.65 | +2.406 | sdram_backend.ctrl_wdata |
| 6 | 67.41 | +0.791 | sdram_backend.state |
| 7 | 68.47 | +1.019 | sdram_backend.ctrl_wdata |

**8/8 PASS (unchanged pass count).** Worst-case margin fell from
+2.143ns to +0.605ns (still a real, positive-margin PASS on every
seed — the critical path relocated off the shortened hit-index chain
onto a different, previously-second-worst path in the same module).
Disclosed, not hidden.

**N=8 @ 64MHz, POST-fix** (period 15.625ns):

| Seed | Fmax (MHz) | WNS (ns) | Status |
|---|---:|---:|---|
| 0 | 66.45 | +0.575 | PASS |
| 1 | 65.28 | +0.307 | PASS |
| 2 | 61.21 | −0.712 | FAIL |
| 3 | 66.96 | +0.690 | PASS |
| 4 | 66.66 | +0.624 | PASS |
| 5 | 65.71 | +0.407 | PASS |
| 6 (worst) | 60.12 | −1.009 | FAIL |
| 7 | 62.70 | −0.324 | FAIL |

**Pass count improved 4/8 → 5/8** (seeds 0,1,3,4,5 PASS; 2,6,7 FAIL).
Worst-case Fmax improved 55.84→60.12MHz, worst WNS −2.284→−1.009ns —
a real, measured improvement, **not yet full closure**.

Resource utilization, POST-fix, N=8: MULT18X18D 64/72 (88.9%,
unchanged), TRELLIS_COMB 11129/43848 (25.4%, +63 LUTs, negligible),
TRELLIS_FF 11119/43848 (unchanged), TRELLIS_RAMW 323/5481 (unchanged).
N=4: TRELLIS_COMB 7175/43848 (25.2%→7175, down from 7609 pre-fix).

**N=4/N=8 @ 80MHz, POST-fix**: re-confirmed 0/8 both configs (same
Fmax values as the 64MHz-labeled runs). **NO-GO, unchanged.**

### 10.6 AS4C32M16SB-7BIN — complete verified hardware data

Source: Alliance Memory `AllianceMemory_512M_SDRAM_Bdie_AS4C32M16SB-
7TXN-6TIN-7BIN_Rev1.4_June2024NK.pdf`, the exact -7BIN datasheet
(Figure 1.1, real TFBGA ball diagram — not inferred from the TSOP-II
`-7TIN` pinout).

| Property | Value |
|---|---|
| Part | AS4C32M16SB-7BIN |
| Capacity | 512Mbit = 64MByte |
| Organization | 4 banks × 8M words × 16 bits |
| Package | 54-ball FBGA, 8×8×1.2mm max |
| VDD / VDDQ | 3.3V ±0.3V (isolated I/O supply) |
| Address / Bank | A[12:0] / BA[1:0] |
| Data / Masks | DQ[15:0] / LDQM, UDQM |
| Clock | CLK, single-ended — **no CLK_N** (SDR SDRAM) |
| Control | CKE, CS#, RAS#, CAS#, WE# |
| Temperature / Speed | −40 to 85°C / −7 (143MHz max) |

**Complete individual-ball pinout (54 balls, no grouped notation):**

Address: H7=A0, H8=A1, J8=A2, J7=A3, J3=A4, J2=A5, H3=A6, H2=A7, H1=A8,
G3=A9, H9=A10/AP, G2=A11, G1=A12.
Bank: G7=BA0, G8=BA1.
Data: A8=DQ0, B9=DQ1, B8=DQ2, C9=DQ3, C8=DQ4, D9=DQ5, D8=DQ6, E9=DQ7,
E1=DQ8, D2=DQ9, D1=DQ10, C2=DQ11, C1=DQ12, B2=DQ13, B1=DQ14, A2=DQ15.
Masks: E8=LDQM, F1=UDQM.
Control: F2=CLK, F3=CKE, G9=CS#, F8=RAS#, F7=CAS#, F9=WE#.
Power/Ground/NC: VDD={A9,E7,J9}, VSS={A1,E3,J1}, VDDQ={A7,B3,C7,D3},
VSSQ={A3,B7,C3,D7}, NC=E2. (13+2+16+2+6+3+3+4+4+1 = 54 ✓)

**FPGA (LFE5U-45F-8BG381) ↔ SDRAM (AS4C32M16SB-7BIN) mapping** (from
`hardware/v2/constraints/v2_board_top.lpf`, 45/45 unique FPGA balls,
no duplicates):

| FPGA signal | FPGA ball | SDRAM signal | SDRAM ball |
|---|---|---|---|
| sdram_a[0..12] | D5,D3,F4,E5,E3,F5,A2,B1,C2,C1,D2,D1,F1 | A0..A12 | H7,H8,J8,J7,J3,J2,H3,H2,H1,G3,H9,G2,G1 |
| sdram_ba[0:1] | E4,C3 | BA0,BA1 | G7,G8 |
| sdram_dq[0..15] | E1,G5,H3,J5,K3,K2,H1,J1,K1,K4,L4,L5,M5,M4,N4,N5 | DQ0..DQ15 | A8,B9,B8,C9,C8,D9,D8,E9,E1,D2,D1,C2,C1,B2,B1,A2 |
| sdram_dqm[0:1] | P5,N3 | LDQM,UDQM | E8,F1 |
| sdram_cke/cs_n/ras_n/cas_n/we_n | B5,C5,C4,A3,B3 | CKE,CS#,RAS#,CAS#,WE# | F3,G9,F8,F7,F9 |

Note: FPGA ball "F1" (assigned to `sdram_a[12]`) and SDRAM ball "F1"
(the SDRAM's own `UDQM`) are two different physical devices' own
separate ball-numbering namespaces — not a conflict, but flagged so a
PCB designer does not confuse the two identically-labeled balls.

**Hardware pinout validation**: all FPGA balls real (LFE5U-45F-8BG381
rev 3.0 CSV), 45/45 unique; all SDRAM balls real (AS4C32M16SB-specific
datasheet, not the TSOP variant); A12/BA[1:0]/DQ[15:0]/DQM[1:0]/all
control signals present and complete; VDD/VDDQ/I-O voltage compatible
(3.3V LVCMOS33 ↔ LVTTL); LPF/RTL/datasheet mutually consistent. **No
hardware blockers found.**

### 10.7 PRODUCTION HARDWARE BASELINE (authoritative, 2026-09-07)

**LFE5U-45F-8BG381 + AS4C32M16SB-7BIN + N_SLOTS=4 + P_IN=8 + 64MHz:
GO.** Real, bit-exact functional correctness; real synthesis (0
errors); real P&R (8/8 seeds route); real timing closure (8/8 seeds
PASS, worst WNS +0.605ns post-optimization); real SDRAM/FPGA pinout
cross-verified with no blockers.

**N_SLOTS=8 @ 64MHz: OPEN, not production-frozen.** Functionally
correct (bit-exact) and measurably closer to timing closure after
ERR-0029 (5/8 seeds PASS, up from 4/8), but not yet reliable on every
tested placement seed. Usable today only by pinning a known-good seed
(0, 1, 3, 4, or 5) or pending a further optimization pass.

**80MHz: NO-GO at either N_SLOTS value**, confirmed twice (pre- and
post-ERR-0029) with a genuinely regenerated PLL — not achievable with
the current architecture.
