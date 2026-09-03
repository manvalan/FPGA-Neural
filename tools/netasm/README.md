# netasm

Host-side assembler for the FPGA-Neural network engine. Compiles a
small pseudo-assembly description of a network (dense Type #1 or
sparse-graph Type #2, see the project spec §9) into:

- the exact on-disk byte layout (descriptor table + edge blocks,
  spec §4), and
- the SPI command sequence (`SET_NET_TYPE` / `SET_BASE` / `WRITE_RAM`
  / `RUN_NETWORK`) needed to load and start it.

This is **host tooling only**. Nothing here runs on the FPGA — see
`rtl/graph_engine.v` and `rtl/spi_engine.v` for the hardware side of
this protocol.

## Grammar

```
; Tipo #1 (dense)
NET dense
INPUTS 256
LAYER 64 relu
LAYER 16 relu
LAYER 4 none
END
```

```
; Tipo #2 (graph)
NET graph
INPUTS 4                 ; id 0..3
NEURON n4 relu bias=2
  CONN 0 w=5
  CONN 1 w=-3
NEURON n5 none bias=0
  CONN n4 w=2            ; symbolic reference to n4's output
  CONN 2 w=7
OUTPUT n5
END
```

`;` starts a comment that runs to end of line. A `CONN <src> w=<int>`
source is either a bare decimal id (typically one of the network's
inputs) or the name of a previously declared `NEURON`.

For `NET dense`, only layer **sizes** and activations are declared —
weight/bias **values** come from a trained model and are loaded by
the host separately (unchanged `WRITE_RAM` flow); netasm's job there
is layout (address allocation, PARALLEL-alignment validation,
descriptor table, load/run commands).

For `NET graph`, netasm assigns every neuron's signal id (inputs get
0..N_in-1; every `OUTPUT` neuron is guaranteed the highest ids, as
required by spec §4.4 — reordering non-output neurons is never
needed for correctness since the grammar already forces
before-you-use declaration order), resolves symbolic `CONN`
references, pads each neuron's edge list to a `PARALLEL` multiple
with zero-weight edges (spec §2.6 — this is a full, physical
edge block, not a hint: hardware just streams `n_conn_padded` real
bytes from PSRAM), and emits the descriptor table + edge blocks +
load/run command sequence.

## Compile-time validation

Catches these before the runtime load-time guard in
`rtl/graph_engine.v` ever would (spec §9's whole point):

- `src_id < out_id` (no cycles / forward references)
- `src_id`, `out_id` < `N_TOTAL`
- an `OUTPUT` neuron is never used as another neuron's source
- every `CONN` reference (symbolic or literal) resolves to a real id
- a neuron's *padded* connection count fits the hardware's
  build-time `MAX_CONN`
- (dense) every layer's real input count is a `PARALLEL` multiple

## Usage

```
python3 tools/netasm/cli.py <input.netasm> -o <out_prefix> \
    [--parallel 8] [--max-conn 32] [--n-total 4096] \
    [--table-base 0x...] [--edges-base 0x...] [--x-base 0x...] \
    [--out-base 0x...] [--buf-b-base 0x...] [--weights-base 0x...]
```

Produces:

- `<out_prefix>.frames.bin` — length-prefixed SPI transaction bytes
  (2-byte big-endian length + that many payload bytes, repeated); a
  host driver replays each record by asserting CS, shifting the
  bytes out, then deasserting CS.
- `<out_prefix>.debug.txt` — human-readable id/address/byte dump for
  review before flashing real hardware.

See `examples/graph_example.netasm` and `examples/dense_example.netasm`.

## Tests

```
python3 tools/netasm/tests/test_netasm.py -v
```

Includes a byte-exact test against the same worked graph example
used throughout the RTL testbenches (`sim/graph_format_tb.v`,
`sim/graph_engine_tb.v`, `sim/spi_neuron_top_graph_tb.v`), plus one
test per compile-time guard above.
