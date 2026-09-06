"""
Small example networks for experimentation (B12). Every example uses
operations the real V2 accelerator actually implements (INT8 in/INT8
weight/INT32-wraparound-accumulate/ReLU-saturate-out, P_IN=8 tiles) --
none invent unsupported functionality. The 2-layer example is
FPGA-compatible at the computational level via the real dependency-
graph mechanism (each layer-2 neuron's producer_ids/required fields
would gate it on all 4 layer-1 neurons completing first), but this
simulator does not yet model the SPI job-construction/address-wiring
needed to actually run it end-to-end on hardware (see network.py's
own scope note).
"""
from __future__ import annotations

import numpy as np

from .layer import FCLayer
from .network import Network


def example_8_to_1() -> Network:
    """8 inputs -> 1 neuron, ReLU. Hand-picked, easy-to-verify weights."""
    weights = [[1, 2, 3, 4, -1, -2, -3, -4]]
    return Network([FCLayer(weights, activation="relu")])


def example_8_to_4() -> Network:
    """8 inputs -> 4 neurons, ReLU. Fixed-seed weights for reproducibility."""
    rng = np.random.default_rng(1)
    weights = rng.integers(-20, 21, size=(4, 8), dtype=np.int64)
    return Network([FCLayer(weights, activation="relu")])


def example_8_to_16() -> Network:
    """8 inputs -> 16 neurons, ReLU. Fixed-seed weights."""
    rng = np.random.default_rng(2)
    weights = rng.integers(-20, 21, size=(16, 8), dtype=np.int64)
    return Network([FCLayer(weights, activation="relu")])


def example_8_8_1() -> Network:
    """8 -> 8 -> 1, both layers ReLU. Fixed-seed weights. The hidden
    layer is 8 wide (not, say, 4) because every layer boundary must
    stay a multiple of P_IN=8 -- the real hardware always tiles in
    groups of 8, so a hidden width that doesn't divide evenly would not
    be a layer this simulator's own FCLayer (or the real accelerator)
    can actually tile. See module docstring for the FPGA-compatibility
    scope note re: multi-layer chaining."""
    rng = np.random.default_rng(3)
    w1 = rng.integers(-15, 16, size=(8, 8), dtype=np.int64)
    w2 = rng.integers(-15, 16, size=(1, 8), dtype=np.int64)
    return Network([FCLayer(w1, activation="relu"), FCLayer(w2, activation="relu")])


ALL_EXAMPLES = {
    "8to1": example_8_to_1,
    "8to4": example_8_to_4,
    "8to16": example_8_to_16,
    "8_8_1": example_8_8_1,
}
