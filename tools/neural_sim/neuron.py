"""
Neuron model: y = activation(bias + sum(x[i]*w[i] for i in 0..N_INPUTS-1)),
matching neural_processor.v (P_IN=8 baseline, parameterizable). Two
independent implementations are provided -- a plain-Python scalar
reference (numerics.neuron_reference) and a NumPy-vectorized one below
-- and tests/test_neuron.py proves they always agree, bit-exact,
across every test-vector category.
"""
from __future__ import annotations

import numpy as np

from .numerics import (
    DEFAULT_ACC_WIDTH, DEFAULT_DATA_WIDTH, DEFAULT_P_IN,
    ACT_RELU, accumulate_tile, add_bias, activate_and_saturate,
    check_int8, neuron_reference, wrap_acc,
)


def neuron_scalar(inputs, weights, bias: int = 0, activation: str = ACT_RELU,
                   p_in: int = DEFAULT_P_IN) -> int:
    """Plain-Python scalar reference -- a thin, explicit re-export of
    numerics.neuron_reference (kept as its own name so neuron.py has a
    clearly-named "scalar" counterpart to neuron_vectorized below)."""
    return neuron_reference(inputs, weights, bias=bias, activation=activation, p_in=p_in)


def neuron_vectorized(inputs, weights, bias: int = 0, activation: str = ACT_RELU,
                       p_in: int = DEFAULT_P_IN,
                       acc_width: int = DEFAULT_ACC_WIDTH,
                       data_width: int = DEFAULT_DATA_WIDTH) -> int:
    """
    NumPy-vectorized equivalent of neuron_scalar. Uses int64 numpy
    accumulation WITHIN one tile only (exact -- a single P_IN=8 tile's
    product-sum can never exceed a few hundred thousand in magnitude,
    nowhere near int64's range, so no numpy overflow risk there), then
    applies the SAME explicit 32-bit-wraparound Python arithmetic as the
    scalar path across tiles -- deliberately NOT letting NumPy's own
    int32 dtype silently wrap with platform-dependent behaviour, per
    this project's own "do not allow implicit integer promotion to hide
    overflow" requirement.
    """
    x = np.asarray(inputs, dtype=np.int64)
    w = np.asarray(weights, dtype=np.int64)
    if x.shape != w.shape:
        raise ValueError("inputs and weights must have the same shape")
    if x.size == 0 or x.size % p_in != 0:
        raise ValueError(f"len(inputs)={x.size} must be a nonzero multiple of p_in={p_in}")
    for v in x.tolist():
        check_int8(v, "input")
    for v in w.tolist():
        check_int8(v, "weight")

    n_tiles = x.size // p_in
    x_tiles = x.reshape(n_tiles, p_in)
    w_tiles = w.reshape(n_tiles, p_in)
    # exact per-tile dot products (int64, no overflow risk)
    tile_sums = np.einsum("ij,ij->i", x_tiles, w_tiles)

    acc = 0
    for tile_sum in tile_sums.tolist():
        acc = accumulate_tile(acc, int(tile_sum), acc_width=acc_width)

    final_acc = add_bias(acc, bias, acc_width=acc_width, data_width=data_width)
    return activate_and_saturate(final_acc, activation=activation, data_width=data_width)
