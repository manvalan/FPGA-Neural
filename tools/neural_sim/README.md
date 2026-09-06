# neural_sim — FPGA-Neural V2 golden functional reference

    Python simulator = golden functional reference
    RTL / P&R        = hardware implementation

This package is **not** a cycle-accurate FPGA simulator. It does not
model clock cycles, SDRAM controller timing, or SPI transaction
timing. Given weights, activations, and a network topology, it
computes the mathematically correct result that the real V2 hardware
(`hardware/v2/rtl/neural_processor.v`) must reproduce bit-for-bit. Its
job is to be the reference everything else — RTL simulation, and
eventually real hardware — is checked against.

## 1. Numeric model

INT8 in / INT8 weight / INT32 accumulate / INT8 out, matching
`neural_processor.v` exactly (re-derived by reading that file, not
assumed — see `numerics.py`'s own module docstring for the full,
line-by-line derivation):

| Stage | Width | Overflow behaviour |
|---|---|---|
| Multiply (INT8 × INT8) | 16-bit signed product | Cannot overflow for INT8 operands |
| Per-tile adder tree (P_IN=8 products) | 32-bit signed | Cannot overflow for P_IN=8 |
| Cross-tile accumulator | 32-bit signed | **Wraparound** (true two's-complement, matches a Verilog `reg signed [31:0]`'s silent overflow) |
| Bias add | 32-bit signed | **Wraparound** |
| Final activation/output | 8-bit signed | **Saturating** (the only saturating stage) |

`numerics.wrap_acc()` implements genuine 32-bit wraparound (not
Python's arbitrary-precision integers hiding the boundary) —
`tests/test_numerics.py::test_wrap_acc_true_32bit_wraparound` proves
`2**31` wraps to `-(2**31)`, exactly like the RTL.

This package reuses `tools/validation/mac_oracle.py`'s own
independently-derived two's-complement primitives (`to_signed`,
`mac8_tree`) rather than duplicating them — that file already is this
project's own hand-verified oracle for the identical wraparound-add
semantics used by `rtl/mac_unit.v`/`rtl/mac8.v`, which
`neural_processor.v`'s own header states is the SAME accumulation
lineage.

## 2. Neuron equation

```
y = activate(bias + sum(x[i] * w[i] for i in 0..N_INPUTS-1))
```

computed tile-by-tile in groups of `P_IN` (default 8, matching the
frozen hardware reference), with the cross-tile accumulator carrying
state (with wraparound) between tiles — exactly how
`neural_processor.v`'s own pipeline works (one tile enters per cycle,
`acc_reg` only clears at job load, activation is applied once at the
end after `tile_last`).

Two independent implementations are provided and cross-tested
(`tests/test_neuron.py`):
- `neuron.neuron_scalar` — plain Python, easiest to audit line-by-line
  against the RTL.
- `neuron.neuron_vectorized` — NumPy-based (int64 intra-tile dot
  products, since that stage can never overflow; explicit Python
  wraparound arithmetic across tiles, so NumPy's own dtype-wraparound
  behaviour is never silently relied on).

## 3. Layer equation

```
output[n] = activate(bias[n] + sum(input[i] * weight[n][i] for i in 0..N_INPUTS-1))
```

for `n` in `0..N_NEURONS-1` — `layer.FCLayer`, matching how a real job
batch is submitted (one `WRITE_JOB` per neuron, same `x_base`
activation tile, each with its own `w_base`/`result_addr`).

## 4. Network model (deliberately small scope)

`network.Network` is an ordered chain of `FCLayer`s. This is a real,
deliberate scope limit, not a hardware limit: the real
`dependency_manager.v` schedules an arbitrary DAG of neuron jobs via
`producer_ids`/`required` fields, not just linear layer chains. A
linear chain is what this first phase implements and verifies; see
"Optional future extension" below for what's deferred.

## 5. Memory model

`memory.MemoryModel` reproduces the real, official V2 unified-SDRAM
memory map's logical byte contents and addresses (weights@0x010000,
activations@0x200000, results@0x300000, all within the single 8MB
0x000000–0x7FFFFF space) — **not** SDRAM cycle timing (see
`hardware/v2/nms/rtl/sdram_controller.v` / `sdram_model.v` for that).
`write_weight`/`read_weight`/`write_activation`/`read_activation`/
`write_result`/`read_result` are bounds-checked against each region's
own real base address.

## 6. Quantization / activation behaviour

Exactly two activation encodings exist in `neural_processor.v`:

- **`relu`** (the RTL's own `default` case — i.e. any activation code
  other than exactly `ACT_NONE` also produces ReLU): `acc <= 0 -> 0`;
  `0 < acc <= 127 -> acc` exactly; `acc > 127 -> 127`. **This is the
  only activation the real, currently-exposed V2 SPI job protocol
  applies** (`spi_host_bridge.v`'s `WRITE_JOB` opcode has no
  activation-selection field) — matches the V2 LaTeX datasheet's own
  "Activation: ReLU + INT8 saturate, fixed".
- **`none`**: a two-sided saturating clamp to the full signed INT8
  range `[-128, 127]` — implemented in the module and modeled here for
  completeness, but not reachable via the real, currently-exposed
  protocol.

No other quantization/scaling/shift stage exists in the real RTL, and
none is invented here.

## 7. FPGA correspondence

| This simulator | Real hardware |
|---|---|
| `numerics.py` | `hardware/v2/rtl/neural_processor.v` (bit-exact, line-referenced) |
| `memory.py` | `hardware/v2/nms/rtl/sdram_controller.v`'s logical address space (not its timing) |
| `network.py` (linear chains only) | `hardware/v2/rtl/dependency_manager.v` (arbitrary DAG — a superset, not yet modeled here) |
| — (not modeled) | `spi_host_bridge.v` transaction timing, SDRAM refresh/burst timing, tile-scheduling latency |

## 8. CLI usage

```
python -m tools.neural_sim random-network --n-inputs 8 --n-neurons 4 --seed 1
python -m tools.neural_sim run --example 8to4 --seed 7
python -m tools.neural_sim vectors --gen d_stress --out vec.json
python -m tools.neural_sim vectors --all --out all_vectors.json
python -m tools.neural_sim compare --expected vec.json --actual fpga_results.json
```

Built-in examples (`--example`): `8to1`, `8to4`, `8to16`, `8_8_1` (an
8→8→1 two-layer network — the hidden width is 8, not some other
number, specifically because every layer boundary must stay a
multiple of `P_IN=8`, the same tiling constraint the real hardware
has).

## 9. Test-vector generation and export

`vectors.py` provides six deterministic generators (`gen_simple_positive`,
`gen_signed_mix`, `gen_extremes`, `gen_zero`, `gen_random`, `gen_dstress`
— the last reproducing the existing RTL benchmark's own 256-neuron ×
128-input dimensions). Every vector's `expected` field is computed by
this package's own golden model, not hand-typed, and stores `inputs`,
`weights`, `biases`, `activation`, `p_in`, `numeric_format`, and `seed`
(when applicable) — everything a future RTL testbench needs to load a
vector and check its own result, without re-deriving anything by hand:

```
Python (vectors.py) -> JSON golden vectors -> (future) Verilog testbench -> FPGA
```

## 10. FPGA-result comparison

`compare.compare_results(expected, actual)` returns a `ComparisonReport`
with `exact_match`, `num_mismatches`, `first_mismatch_index`,
`first_mismatch_expected`/`_actual`, and `max_abs_diff`. **0 mismatches
is the only passing criterion** — this package never hides a real
numeric difference behind a tolerance. `compare.load_fpga_results(path)`
accepts either a JSON list of ints or a plain whitespace/line-separated
results file (a common shape for an RTL testbench's own dump).

## Running the tests

```
python3 -m pytest tools/neural_sim/tests/ -q
```

96 tests, all passing as of this writing: signed-arithmetic edge
cases (including a direct 32-bit wraparound check), neuron
scalar-vs-vectorized cross-checks (parametrized across tile counts,
activations, and seeds), layer tests, memory bounds/adjacency tests,
golden-vector determinism and JSON round-trip tests, and comparison-
utility tests.

## Optional future extension (not implemented — by design)

This first phase deliberately stops at "the mathematical golden model
is unquestionably correct." A future phase could add, without
changing anything above: a cycle-accurate scheduler model,
`N_PROCESSORS` ∈ {1,2,4} scheduling, tile scheduling, SDRAM traffic
estimation, SPI transaction modeling, and latency prediction. None of
that exists yet, and this package does not claim to be
"cycle-accurate" anywhere.
