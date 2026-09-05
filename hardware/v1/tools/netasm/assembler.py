"""
netasm assembler -- turns a parsed DenseNet/GraphNet (see parser.py)
into exact byte layouts (descriptor tables, edge blocks) and the SPI
command sequence to load them, per the data formats in the project
spec (§4). Runs entirely on the host; nothing here executes on the
FPGA (§10).

Compile-time validation performed here (spec §9's whole point: catch
these BEFORE the runtime load-time guard in rtl/graph_engine.v ever
sees them):
  - graph: src_id < out_id, src_id/out_id < N_TOTAL, an OUTPUT neuron
    is never used as another neuron's source, every symbolic/literal
    CONN reference resolves to a real signal id.
  - graph: a neuron's padded connection count (see PARALLEL padding
    below) must fit the hardware's build-time MAX_CONN.
  - dense: every layer's real input count must be a PARALLEL
    multiple (the same runtime convention neuron_parallel.v/
    neuron_memory.v already require of n_inputs_real).
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Dict, List, Optional

try:
    from . import frames as F
    from .parser import Conn, DenseNet, GraphNet, Neuron
except ImportError:
    # See cli.py's matching fallback: allows this module to load when
    # imported as a bare top-level module too, not only as part of
    # the `tools.netasm` package.
    import frames as F
    from parser import Conn, DenseNet, GraphNet, Neuron


class NetasmError(Exception):
    pass


def _act_code(name: str) -> int:
    return F.ACT_RELU if name.lower() == "relu" else F.ACT_NONE


def _pad_to_parallel(n_conn: int, parallel: int) -> int:
    # At least one full PARALLEL group even for n_conn == 0 -- a
    # zero-group neuron would forward n_inputs_real=0 into
    # neuron_parallel, which hangs (see rtl/neuron_parallel.v's
    # GROUPS==0 failure mode, and rtl/graph_engine.v's matching
    # load-time guard). Padding edges are (src_id=0, weight=0);
    # src_id=0 is always a valid, already-computed signal for any
    # neuron with id > 0 (every real network has n_in >= 1 inputs at
    # id 0), so this never trips the src_id < out_id guard.
    return max(parallel, math.ceil(max(n_conn, 1) / parallel) * parallel)


# ================================================================
# GRAPH (Type #2)
# ================================================================


@dataclass
class GraphLayout:
    n_in: int
    num_neurons: int
    n_out: int
    n_total: int
    id_of: Dict[str, int]
    order: List[str]  # neuron names in ascending-id order
    table_base: int
    x_base: int
    out_base: int
    edges_base: Dict[str, int]
    descriptor_bytes: bytes
    edge_bytes: Dict[str, bytes]
    n_conn_real: Dict[str, int]
    n_conn_padded: Dict[str, int]
    out_ids: List[str]  # neuron names, in out_base byte order
    frames: List[F.Frame] = field(default_factory=list)


def _resolve_src(
    src_token: str, id_of: Dict[str, int], n_in: int, line: int
) -> int:
    if src_token in id_of:
        return id_of[src_token]
    try:
        v = int(src_token, 0)
    except ValueError:
        raise NetasmError(f"line {line}: unknown source '{src_token}'")
    return v


def assemble_graph(
    net: GraphNet,
    parallel: int,
    max_conn: int = 32,
    n_total: int = 4096,
    table_base: int = 0x000000,
    edges_base: int = 0x010000,
    x_base: int = 0x000000,
    out_base: int = 0x020000,
) -> GraphLayout:

    if parallel <= 0 or (parallel & (parallel - 1)) != 0:
        raise NetasmError(f"PARALLEL must be a positive power of two, got {parallel}")

    n_in = net.n_inputs
    declared_names = [n.name for n in net.neurons]
    neuron_by_name = {n.name: n for n in net.neurons}

    for out_name in net.outputs:
        if out_name not in neuron_by_name:
            raise NetasmError(f"OUTPUT '{out_name}' refers to an undeclared neuron")
    if len(set(net.outputs)) != len(net.outputs):
        raise NetasmError("duplicate name in OUTPUT list")

    # A neuron used as ANY other neuron's source can never be an
    # output sink (spec §4.4's invariant, enforced here at compile
    # time rather than left to the runtime guard).
    referenced_as_source = set()
    for n in net.neurons:
        for c in n.conns:
            if c.src in neuron_by_name:
                referenced_as_source.add(c.src)
    for out_name in net.outputs:
        if out_name in referenced_as_source:
            raise NetasmError(
                f"OUTPUT '{out_name}' is used as a source by another neuron -- "
                "output ids must be pure sinks (spec §4.4)"
            )

    output_set = set(net.outputs)
    non_output_order = [n for n in declared_names if n not in output_set]
    order = non_output_order + list(net.outputs)

    id_of: Dict[str, int] = {}
    for i, name in enumerate(order):
        id_of[name] = n_in + i

    num_neurons = len(order)
    n_total_used = n_in + num_neurons
    if n_total_used > n_total:
        raise NetasmError(
            f"network needs {n_total_used} signal ids (N_in={n_in} + "
            f"{num_neurons} neurons), exceeds N_TOTAL={n_total}"
        )

    edges_base_of: Dict[str, int] = {}
    edge_bytes: Dict[str, bytes] = {}
    n_conn_real: Dict[str, int] = {}
    n_conn_padded: Dict[str, int] = {}
    cursor = edges_base

    for name in order:
        neuron = neuron_by_name[name]
        out_id = id_of[name]
        n_conn = len(neuron.conns)
        padded = _pad_to_parallel(n_conn, parallel)
        if padded > max_conn:
            raise NetasmError(
                f"neuron '{name}' (line {neuron.line}): {n_conn} connection(s) pad "
                f"to {padded} at PARALLEL={parallel}, exceeds MAX_CONN={max_conn}"
            )

        edges_base_of[name] = cursor
        buf = bytearray()

        for c in neuron.conns:
            src_id = _resolve_src(c.src, id_of, n_in, c.line)
            if src_id >= n_total:
                raise NetasmError(
                    f"line {c.line}: src id {src_id} >= N_TOTAL={n_total}"
                )
            if src_id >= out_id:
                raise NetasmError(
                    f"line {c.line}: neuron '{name}' (id {out_id}) connects from "
                    f"src id {src_id}, which is not a strictly earlier signal "
                    "(src_id must be < out_id, §7)"
                )
            buf += src_id.to_bytes(2, "big")
            buf.append(c.weight & 0xFF)
            buf.append(0x00)  # reserved

        for _ in range(padded - n_conn):
            buf += (0).to_bytes(2, "big")  # src_id = 0 (always valid, weight 0)
            buf.append(0x00)  # weight = 0
            buf.append(0x00)  # reserved

        edge_bytes[name] = bytes(buf)
        n_conn_real[name] = n_conn
        n_conn_padded[name] = padded
        cursor += len(buf)

    descriptor = bytearray()
    for name in order:
        neuron = neuron_by_name[name]
        out_id = id_of[name]
        n_conn = n_conn_real[name]
        descriptor += edges_base_of[name].to_bytes(3, "big")
        descriptor += n_conn.to_bytes(2, "big")
        descriptor += out_id.to_bytes(2, "big")
        descriptor.append(_act_code(neuron.activation))
        descriptor.append(neuron.bias & 0xFF)
        descriptor += b"\x00\x00"  # reserved

    n_out = len(net.outputs)

    layout = GraphLayout(
        n_in=n_in,
        num_neurons=num_neurons,
        n_out=n_out,
        n_total=n_total_used,
        id_of=id_of,
        order=order,
        table_base=table_base,
        x_base=x_base,
        out_base=out_base,
        edges_base=edges_base_of,
        descriptor_bytes=bytes(descriptor),
        edge_bytes=edge_bytes,
        n_conn_real=n_conn_real,
        n_conn_padded=n_conn_padded,
        out_ids=list(net.outputs),
    )

    fr: List[F.Frame] = []
    fr.append(F.write_ram(table_base, layout.descriptor_bytes))
    for name in order:
        fr.append(F.write_ram(edges_base_of[name], edge_bytes[name]))
    fr.append(F.set_net_type(F.NET_TYPE_GRAPH))
    fr.append(F.set_base(F.SEL_X_BASE, x_base))
    fr.append(F.set_base(F.SEL_TABLE_BASE, table_base))
    fr.append(F.set_base(F.SEL_BUF_A_BASE, out_base))
    fr.append(F.set_base(F.SEL_N_INPUTS, n_in))
    fr.append(F.set_base(F.SEL_NUM_NEURONS_GRAPH, num_neurons))
    fr.append(F.set_base(F.SEL_N_OUT, n_out))
    fr.append(F.run_network(0))
    layout.frames = fr

    return layout


def dump_graph_debug(layout: GraphLayout) -> str:
    lines = []
    lines.append("=== netasm graph debug dump ===")
    lines.append(f"N_in={layout.n_in} num_neurons={layout.num_neurons} "
                 f"n_out={layout.n_out} N_TOTAL_used={layout.n_total}")
    lines.append(f"table_base=0x{layout.table_base:06x} x_base=0x{layout.x_base:06x} "
                 f"out_base=0x{layout.out_base:06x}")
    lines.append("")
    lines.append("id assignment (ascending):")
    for name in layout.order:
        marker = " <- OUTPUT" if name in layout.out_ids else ""
        lines.append(
            f"  id={layout.id_of[name]:4d}  {name:16s} n_conn={layout.n_conn_real[name]} "
            f"padded={layout.n_conn_padded[name]} edges@0x{layout.edges_base[name]:06x}{marker}"
        )
    lines.append("")
    lines.append(f"descriptor table ({len(layout.descriptor_bytes)} bytes):")
    lines.append("  " + layout.descriptor_bytes.hex(" "))
    lines.append("")
    for name in layout.order:
        lines.append(f"edges for {name} ({len(layout.edge_bytes[name])} bytes):")
        lines.append("  " + layout.edge_bytes[name].hex(" "))
    lines.append("")
    lines.append("SPI load sequence:")
    lines.append(F.frames_as_hex(layout.frames))
    return "\n".join(lines)


# ================================================================
# DENSE (Type #1)
#
# The grammar (spec §9) only declares layer SIZES/activations, not
# weight VALUES -- those come from a trained model and are loaded by
# the host separately (existing WRITE_RAM flow, unchanged from
# before this tool existed). netasm's job for dense is therefore
# layout + descriptor table + load/run command generation: it
# allocates address ranges for each layer's weight matrix and bias
# vector, validates PARALLEL alignment, and reports exactly where
# the host must WRITE_RAM the real weight/bias content before
# RUN_NETWORK.
# ================================================================


@dataclass
class DenseLayerLayout:
    n_inputs_real: int
    n_neurons_real: int
    activation: str
    w_base: int
    bias_addr: int


@dataclass
class DenseLayout:
    n_inputs: int
    layers: List[DenseLayerLayout]
    table_base: int
    x_base: int
    buf_a_base: int
    buf_b_base: int
    descriptor_bytes: bytes
    frames: List[F.Frame] = field(default_factory=list)


def assemble_dense(
    net: DenseNet,
    parallel: int,
    table_base: int = 0x000000,
    weights_base: int = 0x010000,
    x_base: int = 0x000000,
    buf_a_base: int = 0x020000,
    buf_b_base: int = 0x021000,
) -> DenseLayout:

    if parallel <= 0 or (parallel & (parallel - 1)) != 0:
        raise NetasmError(f"PARALLEL must be a positive power of two, got {parallel}")

    layers: List[DenseLayerLayout] = []
    cursor = weights_base
    prev_n = net.n_inputs

    for layer in net.layers:
        if prev_n % parallel != 0:
            raise NetasmError(
                f"line {layer.line}: layer's real input count {prev_n} is not a "
                f"multiple of PARALLEL={parallel} (neuron_parallel.v/"
                "neuron_memory.v both require this at runtime)"
            )
        w_base = cursor
        cursor += prev_n * layer.n_neurons
        bias_addr = cursor
        cursor += layer.n_neurons
        layers.append(
            DenseLayerLayout(
                n_inputs_real=prev_n,
                n_neurons_real=layer.n_neurons,
                activation=layer.activation,
                w_base=w_base,
                bias_addr=bias_addr,
            )
        )
        prev_n = layer.n_neurons

    descriptor = bytearray()
    for l in layers:
        descriptor += l.w_base.to_bytes(3, "big")
        descriptor += l.bias_addr.to_bytes(3, "big")
        descriptor.append(_act_code(l.activation))
        descriptor += l.n_inputs_real.to_bytes(2, "big")
        descriptor += l.n_neurons_real.to_bytes(2, "big")

    layout = DenseLayout(
        n_inputs=net.n_inputs,
        layers=layers,
        table_base=table_base,
        x_base=x_base,
        buf_a_base=buf_a_base,
        buf_b_base=buf_b_base,
        descriptor_bytes=bytes(descriptor),
    )

    fr: List[F.Frame] = []
    fr.append(F.write_ram(table_base, layout.descriptor_bytes))
    fr.append(F.set_net_type(F.NET_TYPE_DENSE))
    fr.append(F.set_base(F.SEL_X_BASE, x_base))
    fr.append(F.set_base(F.SEL_TABLE_BASE, table_base))
    fr.append(F.set_base(F.SEL_BUF_A_BASE, buf_a_base))
    fr.append(F.set_base(F.SEL_BUF_B_BASE, buf_b_base))
    fr.append(F.run_network(len(net.layers)))
    layout.frames = fr

    return layout


def dump_dense_debug(layout: DenseLayout) -> str:
    lines = []
    lines.append("=== netasm dense debug dump ===")
    lines.append(f"N_inputs={layout.n_inputs} layers={len(layout.layers)}")
    lines.append(f"table_base=0x{layout.table_base:06x} x_base=0x{layout.x_base:06x} "
                 f"buf_a_base=0x{layout.buf_a_base:06x} buf_b_base=0x{layout.buf_b_base:06x}")
    lines.append("")
    lines.append("NOTE: weight/bias VALUES are not part of this program -- the")
    lines.append("host must WRITE_RAM the real trained weights/bias at the")
    lines.append("addresses below before RUN_NETWORK.")
    lines.append("")
    for i, l in enumerate(layout.layers):
        lines.append(
            f"  layer {i}: n_inputs_real={l.n_inputs_real} n_neurons_real={l.n_neurons_real} "
            f"activation={l.activation}"
        )
        lines.append(
            f"    w_base=0x{l.w_base:06x} ({l.n_inputs_real * l.n_neurons_real} bytes) "
            f"bias_addr=0x{l.bias_addr:06x} ({l.n_neurons_real} bytes)"
        )
    lines.append("")
    lines.append(f"descriptor table ({len(layout.descriptor_bytes)} bytes):")
    lines.append("  " + layout.descriptor_bytes.hex(" "))
    lines.append("")
    lines.append("SPI load sequence:")
    lines.append(F.frames_as_hex(layout.frames))
    return "\n".join(lines)
