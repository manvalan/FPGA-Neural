import numpy as np
import pytest

from tools.neural_sim.layer import FCLayer
from tools.neural_sim.neuron import neuron_scalar


def test_layer_matches_per_neuron_scalar_reference():
    rng = np.random.default_rng(7)
    n_inputs, n_neurons = 32, 5
    weights = rng.integers(-128, 128, size=(n_neurons, n_inputs), dtype=np.int64)
    biases = rng.integers(-128, 128, size=n_neurons, dtype=np.int64)
    inputs = rng.integers(-128, 128, size=n_inputs, dtype=np.int64)

    layer = FCLayer(weights, biases=biases, activation="relu")
    outputs = layer.forward(inputs)

    for n in range(n_neurons):
        expected = neuron_scalar(inputs.tolist(), weights[n].tolist(), bias=int(biases[n]), activation="relu")
        assert outputs[n] == expected


def test_layer_rejects_bad_input_shape():
    layer = FCLayer([[1] * 8])
    with pytest.raises(ValueError):
        layer.forward([1] * 7)


def test_layer_rejects_non_multiple_of_p_in():
    with pytest.raises(ValueError):
        FCLayer([[1] * 7])


def test_layer_default_bias_is_zero():
    layer = FCLayer([[1] * 8, [2] * 8])
    assert layer.biases.tolist() == [0, 0]


def test_layer_all_outputs_in_int8_range():
    rng = np.random.default_rng(99)
    weights = rng.integers(-128, 128, size=(20, 64), dtype=np.int64)
    inputs = rng.integers(-128, 128, size=64, dtype=np.int64)
    outputs = FCLayer(weights).forward(inputs)
    assert all(-128 <= v <= 127 for v in outputs.tolist())
