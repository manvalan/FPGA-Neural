"""
netasm parser -- turns the pseudo-assembly text described in the
project spec (§9) into a small AST (DenseNet / GraphNet).

This is host-side tooling only, has nothing to do with synthesizable
RTL, and does not run on the FPGA (see spec §10: "Non mettere un
interprete di istruzioni nell'FPGA").

Grammar (line-oriented, `;` starts a comment that runs to end of line,
blank lines ignored):

    NET dense
    INPUTS <n>
    LAYER <n_neurons> <relu|none>
    ...
    END

    NET graph
    INPUTS <n>
    NEURON <name> <relu|none> bias=<int>
      CONN <src> w=<int>
      ...
    OUTPUT <name>
    ...
    END

`<src>` in a CONN line is either a bare decimal integer (a literal
signal id -- typically one of the network's inputs, 0..INPUTS-1) or
the symbolic name of a previously declared NEURON.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import List, Optional


class NetasmSyntaxError(Exception):
    def __init__(self, message: str, line_no: int):
        super().__init__(f"line {line_no}: {message}")
        self.message = message
        self.line_no = line_no


@dataclass
class DenseLayer:
    n_neurons: int
    activation: str
    line: int


@dataclass
class DenseNet:
    n_inputs: int
    layers: List[DenseLayer] = field(default_factory=list)
    kind: str = "dense"


@dataclass
class Conn:
    src: str  # literal id (decimal string) or symbolic neuron name
    weight: int
    line: int


@dataclass
class Neuron:
    name: str
    activation: str
    bias: int
    conns: List[Conn] = field(default_factory=list)
    line: int = 0


@dataclass
class GraphNet:
    n_inputs: int
    neurons: List[Neuron] = field(default_factory=list)
    outputs: List[str] = field(default_factory=list)
    kind: str = "graph"


def _strip_comment(line: str) -> str:
    idx = line.find(";")
    return line if idx < 0 else line[:idx]


def _parse_kv(token: str, key: str, line_no: int) -> int:
    prefix = key + "="
    if not token.startswith(prefix):
        raise NetasmSyntaxError(f"expected '{key}=<int>', got '{token}'", line_no)
    try:
        return int(token[len(prefix):], 0)
    except ValueError:
        raise NetasmSyntaxError(f"invalid integer in '{token}'", line_no)


def _check_activation(tok: str, line_no: int) -> str:
    t = tok.lower()
    if t not in ("relu", "none"):
        raise NetasmSyntaxError(f"unknown activation '{tok}' (expected relu|none)", line_no)
    return t


def parse(text: str) -> "DenseNet | GraphNet":
    lines = text.splitlines()

    net_kind: Optional[str] = None
    n_inputs: Optional[int] = None
    dense_layers: List[DenseLayer] = []
    graph_neurons: List[Neuron] = []
    graph_outputs: List[str] = []
    seen_names = set()
    cur_neuron: Optional[Neuron] = None
    ended = False

    for i, raw in enumerate(lines, start=1):
        line = _strip_comment(raw).strip()
        if not line:
            continue

        tokens = line.split()
        kw = tokens[0].upper()

        if kw == "NET":
            if net_kind is not None:
                raise NetasmSyntaxError("duplicate NET directive", i)
            if len(tokens) != 2 or tokens[1].lower() not in ("dense", "graph"):
                raise NetasmSyntaxError("expected 'NET dense' or 'NET graph'", i)
            net_kind = tokens[1].lower()
            continue

        if net_kind is None:
            raise NetasmSyntaxError("expected 'NET dense|graph' as the first directive", i)

        if kw == "INPUTS":
            if n_inputs is not None:
                raise NetasmSyntaxError("duplicate INPUTS directive", i)
            if len(tokens) != 2:
                raise NetasmSyntaxError("expected 'INPUTS <n>'", i)
            try:
                n_inputs = int(tokens[1], 0)
            except ValueError:
                raise NetasmSyntaxError(f"invalid input count '{tokens[1]}'", i)
            if n_inputs <= 0:
                raise NetasmSyntaxError("INPUTS must be positive", i)
            continue

        if n_inputs is None:
            raise NetasmSyntaxError("expected 'INPUTS <n>' before any layer/neuron", i)

        if kw == "END":
            ended = True
            continue

        if ended:
            raise NetasmSyntaxError("no directives allowed after END", i)

        if net_kind == "dense":
            if kw != "LAYER":
                raise NetasmSyntaxError(f"unexpected directive '{tokens[0]}' in NET dense", i)
            if len(tokens) != 3:
                raise NetasmSyntaxError("expected 'LAYER <n_neurons> <relu|none>'", i)
            try:
                n_neurons = int(tokens[1], 0)
            except ValueError:
                raise NetasmSyntaxError(f"invalid neuron count '{tokens[1]}'", i)
            if n_neurons <= 0:
                raise NetasmSyntaxError("LAYER neuron count must be positive", i)
            activation = _check_activation(tokens[2], i)
            dense_layers.append(DenseLayer(n_neurons=n_neurons, activation=activation, line=i))
            continue

        # net_kind == "graph"
        if kw == "NEURON":
            if len(tokens) != 4:
                raise NetasmSyntaxError(
                    "expected 'NEURON <name> <relu|none> bias=<int>'", i
                )
            name = tokens[1]
            if name in seen_names or name.lstrip("-").isdigit():
                raise NetasmSyntaxError(f"duplicate or reserved neuron name '{name}'", i)
            seen_names.add(name)
            activation = _check_activation(tokens[2], i)
            bias = _parse_kv(tokens[3], "bias", i)
            if not (-128 <= bias <= 127):
                raise NetasmSyntaxError(f"bias {bias} out of INT8 range", i)
            cur_neuron = Neuron(name=name, activation=activation, bias=bias, line=i)
            graph_neurons.append(cur_neuron)
            continue

        if kw == "CONN":
            if cur_neuron is None:
                raise NetasmSyntaxError("CONN outside of a NEURON block", i)
            if len(tokens) != 3:
                raise NetasmSyntaxError("expected 'CONN <src> w=<int>'", i)
            src = tokens[1]
            weight = _parse_kv(tokens[2], "w", i)
            if not (-128 <= weight <= 127):
                raise NetasmSyntaxError(f"weight {weight} out of INT8 range", i)
            cur_neuron.conns.append(Conn(src=src, weight=weight, line=i))
            continue

        if kw == "OUTPUT":
            if len(tokens) != 2:
                raise NetasmSyntaxError("expected 'OUTPUT <name>'", i)
            graph_outputs.append(tokens[1])
            cur_neuron = None
            continue

        raise NetasmSyntaxError(f"unexpected directive '{tokens[0]}' in NET graph", i)

    if net_kind is None:
        raise NetasmSyntaxError("empty program: missing NET directive", len(lines) + 1)
    if not ended:
        raise NetasmSyntaxError("missing END directive", len(lines) + 1)
    if n_inputs is None:
        raise NetasmSyntaxError("missing INPUTS directive", len(lines) + 1)

    if net_kind == "dense":
        if not dense_layers:
            raise NetasmSyntaxError("NET dense with no LAYER directives", len(lines) + 1)
        return DenseNet(n_inputs=n_inputs, layers=dense_layers)

    if not graph_neurons:
        raise NetasmSyntaxError("NET graph with no NEURON directives", len(lines) + 1)
    if not graph_outputs:
        raise NetasmSyntaxError("NET graph with no OUTPUT directive", len(lines) + 1)
    return GraphNet(n_inputs=n_inputs, neurons=graph_neurons, outputs=graph_outputs)
