"""
Network model: an ordered chain of FCLayer instances, each layer's
INT8 output feeding the next layer's INT8 input.

Scope, deliberately kept small (per this project's own explicit "do
not invent unsupported FPGA functionality" instruction): this models a
linear chain of fully-connected+activation layers. The real V2
hardware's dependency_manager.v is actually more general -- it
schedules an arbitrary DAG of neuron "jobs" via producer_ids/required
fields, so a layer boundary is not a hardware limitation, only a
simulator scope limit for this first phase. A linear chain is exactly
what a linear chain of dependency-graph layers computes, so this is
faithful for the topologies it supports; it does not yet model
arbitrary-DAG job graphs, SPI job submission, or scheduling -- see
README.md "Optional future extension" and PRE_PCB_VERIFICATION.md's
own dependency-graph description for what the real hardware supports
beyond what this simulator currently models.
"""
from __future__ import annotations

import numpy as np

from .layer import FCLayer


class Network:
    def __init__(self, layers: list[FCLayer]):
        if not layers:
            raise ValueError("a Network needs at least one layer")
        for i in range(1, len(layers)):
            if layers[i].n_inputs != layers[i - 1].n_neurons:
                raise ValueError(
                    f"layer {i}'s n_inputs={layers[i].n_inputs} does not match "
                    f"layer {i-1}'s n_neurons={layers[i-1].n_neurons}"
                )
        self.layers = layers

    @property
    def n_inputs(self) -> int:
        return self.layers[0].n_inputs

    @property
    def n_outputs(self) -> int:
        return self.layers[-1].n_neurons

    def forward(self, inputs) -> np.ndarray:
        """Runs `inputs` through every layer in order, returning the
        final layer's INT8 output vector. Also available as
        `forward_all` if every intermediate tensor is needed."""
        return self.forward_all(inputs)[-1]

    def forward_all(self, inputs) -> list[np.ndarray]:
        """Returns [layer0_output, layer1_output, ..., layerN_output]
        -- every intermediate tensor, not just the final one (useful
        for debugging / per-layer golden-vector generation)."""
        x = np.asarray(inputs, dtype=np.int64)
        outputs = []
        for layer in self.layers:
            x = layer.forward(x)
            outputs.append(x)
        return outputs
