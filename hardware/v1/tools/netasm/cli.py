#!/usr/bin/env python3
"""
netasm CLI: compiles a .netasm source file (see parser.py's docstring
for the grammar) into an SPI load sequence + human-readable debug
dump. Host-side tool only -- see rtl/graph_engine.v / spi_engine.v
for the hardware side of this protocol.

Usage:
    python3 -m tools.netasm.cli input.netasm -o out_prefix \\
        [--parallel 8] [--max-conn 32] [--n-total 4096]

Produces:
    out_prefix.frames.bin   -- length-prefixed SPI transaction bytes
    out_prefix.debug.txt    -- human-readable id/address/byte dump
"""

from __future__ import annotations

import argparse
import sys

try:
    from . import frames as F
    from .assembler import (
        NetasmError,
        assemble_dense,
        assemble_graph,
        dump_dense_debug,
        dump_graph_debug,
    )
    from .parser import DenseNet, GraphNet, NetasmSyntaxError, parse
except ImportError:
    # Allow running this file directly (`python3 tools/netasm/cli.py`)
    # without the package being importable as `tools.netasm` -- e.g.
    # an unrelated `tools` namespace package earlier on PYTHONPATH
    # shadowing this repo's tools/ directory.
    import os
    import sys
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import frames as F
    from assembler import (
        NetasmError,
        assemble_dense,
        assemble_graph,
        dump_dense_debug,
        dump_graph_debug,
    )
    from parser import DenseNet, GraphNet, NetasmSyntaxError, parse


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("source", help="path to a .netasm source file")
    ap.add_argument("-o", "--output", required=True, help="output file prefix")
    ap.add_argument("--parallel", type=int, default=8, help="hardware PARALLEL (default 8)")
    ap.add_argument("--max-conn", type=int, default=32, help="graph_engine's MAX_CONN (default 32)")
    ap.add_argument("--n-total", type=int, default=4096, help="graph_engine's N_TOTAL (default 4096)")
    ap.add_argument("--table-base", type=lambda s: int(s, 0), default=0x000000)
    ap.add_argument("--edges-base", type=lambda s: int(s, 0), default=0x010000)
    ap.add_argument("--x-base", type=lambda s: int(s, 0), default=0x000000)
    ap.add_argument("--out-base", type=lambda s: int(s, 0), default=0x020000,
                     help="graph out_base / dense buf_a_base")
    ap.add_argument("--buf-b-base", type=lambda s: int(s, 0), default=0x021000,
                     help="dense buf_b_base only")
    ap.add_argument("--weights-base", type=lambda s: int(s, 0), default=0x010000,
                     help="dense weight/bias region base")
    args = ap.parse_args(argv)

    with open(args.source, "r") as f:
        text = f.read()

    try:
        net = parse(text)
    except NetasmSyntaxError as e:
        print(f"{args.source}: syntax error: {e}", file=sys.stderr)
        return 1

    try:
        if isinstance(net, GraphNet):
            layout = assemble_graph(
                net,
                parallel=args.parallel,
                max_conn=args.max_conn,
                n_total=args.n_total,
                table_base=args.table_base,
                edges_base=args.edges_base,
                x_base=args.x_base,
                out_base=args.out_base,
            )
            debug = dump_graph_debug(layout)
            frames = layout.frames
        else:
            assert isinstance(net, DenseNet)
            layout = assemble_dense(
                net,
                parallel=args.parallel,
                table_base=args.table_base,
                weights_base=args.weights_base,
                x_base=args.x_base,
                buf_a_base=args.out_base,
                buf_b_base=args.buf_b_base,
            )
            debug = dump_dense_debug(layout)
            frames = layout.frames
    except NetasmError as e:
        print(f"{args.source}: assembly error: {e}", file=sys.stderr)
        return 1

    F.dump_frames(frames, args.output + ".frames.bin")
    with open(args.output + ".debug.txt", "w") as f:
        f.write(debug + "\n")

    print(f"wrote {args.output}.frames.bin ({sum(len(fr.data) for fr in frames)} payload bytes, "
          f"{len(frames)} SPI transactions)")
    print(f"wrote {args.output}.debug.txt")
    return 0


if __name__ == "__main__":
    sys.exit(main())
