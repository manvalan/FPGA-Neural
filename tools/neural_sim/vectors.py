"""
Deterministic FPGA-style test vectors + golden-vector JSON export
(B8/B9). Every generator below returns a TestVector whose `expected`
field is computed by this SAME package's own golden model
(layer.FCLayer / numerics.neuron_reference) -- i.e. the vector is
self-consistent and re-verifiable by construction (see
tests/test_vectors.py's own round-trip test), not hand-typed.
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field, asdict
from typing import List, Optional

import numpy as np

from .numerics import ACT_RELU, DEFAULT_P_IN
from .layer import FCLayer


@dataclass
class TestVector:
    name: str
    inputs: List[int]
    weights: List[List[int]]     # shape (n_neurons, n_inputs)
    biases: List[int]            # shape (n_neurons,)
    activation: str
    p_in: int
    expected: List[int]          # shape (n_neurons,)
    numeric_format: str = "int8 in / int8 weight / int32 accumulate (wraparound) / int8 out (saturate)"
    seed: Optional[int] = None

    @property
    def n_neurons(self) -> int:
        return len(self.expected)

    @property
    def n_inputs(self) -> int:
        return len(self.inputs)


def _make_vector(name: str, inputs, weights, biases=None, activation: str = ACT_RELU,
                  p_in: int = DEFAULT_P_IN, seed: Optional[int] = None) -> TestVector:
    layer = FCLayer(weights, biases=biases, activation=activation, p_in=p_in)
    expected = layer.forward(inputs).tolist()
    biases_list = layer.biases.tolist()
    return TestVector(
        name=name, inputs=list(int(v) for v in inputs),
        weights=[[int(w) for w in row] for row in layer.weights.tolist()],
        biases=biases_list, activation=activation, p_in=p_in,
        expected=[int(e) for e in expected], seed=seed,
    )


# ---- Test 1: simple positive ----
def gen_simple_positive(p_in: int = DEFAULT_P_IN) -> TestVector:
    """Small positive inputs/weights, manually predictable:
    inputs=[1..p_in], weights=all 1s -> sum = p_in*(p_in+1)/2."""
    inputs = list(range(1, p_in + 1))
    weights = [[1] * p_in]
    return _make_vector("simple_positive", inputs, weights)


# ---- Test 2: signed values ----
def gen_signed_mix(p_in: int = DEFAULT_P_IN) -> TestVector:
    """Alternating positive/negative INT8 inputs and weights."""
    inputs = [((-1) ** i) * (10 + i) for i in range(p_in)]
    weights = [[((-1) ** (i + 1)) * (5 + i) for i in range(p_in)]]
    return _make_vector("signed_mix", inputs, weights)


# ---- Test 3: extremes ----
def gen_extremes(p_in: int = DEFAULT_P_IN) -> TestVector:
    """-128/127 combinations designed to stress multiplication (the one
    genuinely asymmetric INT8xINT8 case, -128*-128=16384, is
    deliberately included) and accumulation across p_in terms."""
    inputs = [(-128 if i % 2 == 0 else 127) for i in range(p_in)]
    weights = [[(-128 if i % 2 == 1 else 127) for i in range(p_in)]]
    return _make_vector("extremes", inputs, weights)


# ---- Test 4: zero ----
def gen_zero(p_in: int = DEFAULT_P_IN) -> TestVector:
    inputs = [0] * p_in
    weights = [[0] * p_in]
    return _make_vector("zero", inputs, weights)


# ---- Test 5: random (fixed seed) ----
def gen_random(seed: int = 1234, n_inputs: int = 64, n_neurons: int = 4,
               p_in: int = DEFAULT_P_IN) -> TestVector:
    rng = np.random.default_rng(seed)
    inputs = rng.integers(-128, 128, size=n_inputs, dtype=np.int64)
    weights = rng.integers(-128, 128, size=(n_neurons, n_inputs), dtype=np.int64)
    return _make_vector(f"random_seed{seed}", inputs, weights, p_in=p_in, seed=seed)


# ---- Test 6: D-Stress (256 neurons x 128 inputs, reproducing the
# existing RTL D-Stress benchmark's own dimensions) ----
def gen_dstress(seed: int = 42, n_neurons: int = 256, n_inputs: int = 128,
                 p_in: int = DEFAULT_P_IN) -> TestVector:
    rng = np.random.default_rng(seed)
    inputs = rng.integers(-128, 128, size=n_inputs, dtype=np.int64)
    weights = rng.integers(-128, 128, size=(n_neurons, n_inputs), dtype=np.int64)
    return _make_vector("d_stress", inputs, weights, p_in=p_in, seed=seed)


ALL_GENERATORS = {
    "simple_positive": gen_simple_positive,
    "signed_mix": gen_signed_mix,
    "extremes": gen_extremes,
    "zero": gen_zero,
    "random": gen_random,
    "d_stress": gen_dstress,
}


def generate_all() -> dict:
    return {name: fn() for name, fn in ALL_GENERATORS.items()}


# ---- golden-vector export/import (machine-readable, JSON) ----
def to_dict(vector: TestVector) -> dict:
    return asdict(vector)


def export_json(vector: TestVector, path: str) -> None:
    with open(path, "w") as f:
        json.dump(to_dict(vector), f, indent=2)


def load_json(path: str) -> TestVector:
    with open(path) as f:
        d = json.load(f)
    return TestVector(**d)


def export_all_json(path: str) -> None:
    """Export every named generator's vector into one JSON file, keyed
    by name -- convenient for a future RTL testbench harness to load
    once and iterate."""
    vectors = generate_all()
    with open(path, "w") as f:
        json.dump({name: to_dict(v) for name, v in vectors.items()}, f, indent=2)
