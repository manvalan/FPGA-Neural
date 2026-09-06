"""
Fully-connected layer: N_INPUTS -> N_NEURONS, each neuron with its own
weight vector (and, optionally, its own bias), all sharing one
activation setting -- matching how a real V2 job batch is submitted
(one WRITE_JOB per neuron, all against the same x_base activation
tile, each with its own w_base/result_addr).

output[n] = activation(bias[n] + sum(input[i]*weight[n][i] for i in
0..N_INPUTS-1)), computed with the EXACT same tile-wise, wraparound-
accumulate-then-saturate semantics as numerics.neuron_reference.
"""
from __future__ import annotations

import numpy as np

from .numerics import ACT_RELU, DEFAULT_P_IN, check_int8
from .neuron import neuron_vectorized


class FCLayer:
    """
    weights: array-like, shape (n_neurons, n_inputs), signed INT8.
    biases:  array-like, shape (n_neurons,), signed INT8 (default: all
             zero, matching the real V2 protocol's own lack of a bias
             field -- see numerics.py's own module docstring).
    activation: 'relu' (default, matches the real, currently-exposed
             V2 system) or 'none'.
    p_in:    tile width (default 8, matches the frozen P_IN=8 reference).
    """

    def __init__(self, weights, biases=None, activation: str = ACT_RELU,
                 p_in: int = DEFAULT_P_IN):
        self.weights = np.asarray(weights, dtype=np.int64)
        if self.weights.ndim != 2:
            raise ValueError("weights must be 2D: (n_neurons, n_inputs)")
        self.n_neurons, self.n_inputs = self.weights.shape
        if self.n_inputs % p_in != 0:
            raise ValueError(f"n_inputs={self.n_inputs} must be a multiple of p_in={p_in}")
        for row in self.weights.tolist():
            for w in row:
                check_int8(w, "weight")

        if biases is None:
            self.biases = np.zeros(self.n_neurons, dtype=np.int64)
        else:
            self.biases = np.asarray(biases, dtype=np.int64)
            if self.biases.shape != (self.n_neurons,):
                raise ValueError("biases must have shape (n_neurons,)")
            for b in self.biases.tolist():
                check_int8(b, "bias")

        self.activation = activation
        self.p_in = p_in

    def forward(self, inputs) -> np.ndarray:
        """inputs: array-like, shape (n_inputs,), signed INT8. Returns
        an int64 numpy array of shape (n_neurons,) -- each element is
        an exact signed INT8 value (kept as int64 purely for easy
        downstream composition; every value is guaranteed in
        [-128, 127])."""
        inputs = np.asarray(inputs, dtype=np.int64)
        if inputs.shape != (self.n_inputs,):
            raise ValueError(f"inputs must have shape ({self.n_inputs},), got {inputs.shape}")
        for v in inputs.tolist():
            check_int8(v, "input")

        outputs = np.empty(self.n_neurons, dtype=np.int64)
        for n in range(self.n_neurons):
            outputs[n] = neuron_vectorized(
                inputs, self.weights[n], bias=int(self.biases[n]),
                activation=self.activation, p_in=self.p_in,
            )
        return outputs
