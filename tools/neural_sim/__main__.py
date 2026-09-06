"""
CLI for the neural_sim golden simulator.

    python -m tools.neural_sim random-network --n-inputs 8 --n-neurons 4 --seed 1
    python -m tools.neural_sim run --example 8to4 --seed 7
    python -m tools.neural_sim vectors --gen d_stress --out vec.json
    python -m tools.neural_sim vectors --all --out all_vectors.json
    python -m tools.neural_sim compare --expected golden.json --actual fpga_results.json
"""
from __future__ import annotations

import argparse
import json
import sys

import numpy as np

from .layer import FCLayer
from .network import Network
from . import examples as ex
from . import vectors as vec
from .compare import compare_results, load_fpga_results


def cmd_random_network(args):
    rng = np.random.default_rng(args.seed)
    weights = rng.integers(-args.magnitude, args.magnitude + 1,
                            size=(args.n_neurons, args.n_inputs), dtype=np.int64)
    layer = FCLayer(weights, activation=args.activation)
    inputs = rng.integers(-128, 128, size=args.n_inputs, dtype=np.int64)
    outputs = layer.forward(inputs)
    print(f"n_inputs={layer.n_inputs} n_neurons={layer.n_neurons} activation={layer.activation}")
    print(f"inputs:  {inputs.tolist()}")
    print(f"outputs: {outputs.tolist()}")
    if args.save_weights:
        with open(args.save_weights, "w") as f:
            json.dump({"weights": weights.tolist(), "inputs": inputs.tolist(),
                       "outputs": outputs.tolist()}, f, indent=2)
        print(f"saved to {args.save_weights}")


def cmd_run(args):
    if args.example not in ex.ALL_EXAMPLES:
        print(f"unknown example {args.example!r}; choices: {list(ex.ALL_EXAMPLES)}", file=sys.stderr)
        sys.exit(1)
    net = ex.ALL_EXAMPLES[args.example]()
    rng = np.random.default_rng(args.seed)
    inputs = rng.integers(-128, 128, size=net.n_inputs, dtype=np.int64)
    outputs = net.forward(inputs)
    print(f"example={args.example} n_inputs={net.n_inputs} n_outputs={net.n_outputs}")
    print(f"inputs:  {inputs.tolist()}")
    print(f"outputs: {outputs.tolist()}")


def cmd_vectors(args):
    if args.all:
        vec.export_all_json(args.out)
        print(f"exported all {len(vec.ALL_GENERATORS)} named vectors to {args.out}")
        return
    if args.gen not in vec.ALL_GENERATORS:
        print(f"unknown generator {args.gen!r}; choices: {list(vec.ALL_GENERATORS)}", file=sys.stderr)
        sys.exit(1)
    v = vec.ALL_GENERATORS[args.gen]()
    vec.export_json(v, args.out)
    print(f"generated {v.name!r}: n_inputs={v.n_inputs} n_neurons={v.n_neurons} -> {args.out}")


def cmd_compare(args):
    expected = vec.load_json(args.expected).expected if args.expected.endswith(".json") and _is_vector_file(args.expected) \
        else load_fpga_results(args.expected)
    actual = load_fpga_results(args.actual)
    report = compare_results(expected, actual)
    print(report.summary())
    sys.exit(0 if report.exact_match else 1)


def _is_vector_file(path: str) -> bool:
    try:
        with open(path) as f:
            d = json.load(f)
        return isinstance(d, dict) and "expected" in d and "weights" in d
    except Exception:
        return False


def main():
    parser = argparse.ArgumentParser(prog="python -m tools.neural_sim",
                                      description="FPGA-Neural V2 golden functional reference simulator")
    sub = parser.add_subparsers(dest="command", required=True)

    p_rand = sub.add_parser("random-network", help="generate and run a random network")
    p_rand.add_argument("--n-inputs", type=int, default=8)
    p_rand.add_argument("--n-neurons", type=int, default=4)
    p_rand.add_argument("--seed", type=int, default=0)
    p_rand.add_argument("--magnitude", type=int, default=20, help="max abs weight magnitude")
    p_rand.add_argument("--activation", choices=["relu", "none"], default="relu")
    p_rand.add_argument("--save-weights", metavar="PATH", default=None)
    p_rand.set_defaults(func=cmd_random_network)

    p_run = sub.add_parser("run", help="run one of the built-in example networks")
    p_run.add_argument("--example", choices=list(ex.ALL_EXAMPLES), default="8to4")
    p_run.add_argument("--seed", type=int, default=0, help="seed for the random input vector")
    p_run.set_defaults(func=cmd_run)

    p_vec = sub.add_parser("vectors", help="generate golden test vectors")
    p_vec.add_argument("--gen", choices=list(vec.ALL_GENERATORS), default=None)
    p_vec.add_argument("--all", action="store_true", help="export every named generator")
    p_vec.add_argument("--out", required=True, metavar="PATH")
    p_vec.set_defaults(func=cmd_vectors)

    p_cmp = sub.add_parser("compare", help="compare FPGA results against Python golden results")
    p_cmp.add_argument("--expected", required=True, metavar="PATH",
                        help="a vectors-format JSON file (uses its 'expected' field) or a plain results file")
    p_cmp.add_argument("--actual", required=True, metavar="PATH", help="FPGA-generated results file")
    p_cmp.set_defaults(func=cmd_compare)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
