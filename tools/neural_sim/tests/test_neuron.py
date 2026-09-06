import numpy as np
import pytest

from tools.neural_sim.neuron import neuron_scalar, neuron_vectorized
from tools.neural_sim.numerics import ACT_NONE, ACT_RELU


@pytest.mark.parametrize("n_tiles", [1, 2, 4, 16])
@pytest.mark.parametrize("activation", [ACT_RELU, ACT_NONE])
@pytest.mark.parametrize("seed", [0, 1, 2, 3, 4])
def test_scalar_and_vectorized_agree(n_tiles, activation, seed):
    rng = np.random.default_rng(seed)
    n = n_tiles * 8
    inputs = rng.integers(-128, 128, size=n, dtype=np.int64).tolist()
    weights = rng.integers(-128, 128, size=n, dtype=np.int64).tolist()
    bias = int(rng.integers(-128, 128))

    scalar = neuron_scalar(inputs, weights, bias=bias, activation=activation)
    vectorized = neuron_vectorized(inputs, weights, bias=bias, activation=activation)
    assert scalar == vectorized


def test_scalar_and_vectorized_agree_on_extremes():
    inputs = [-128, 127] * 4
    weights = [127, -128] * 4
    assert neuron_scalar(inputs, weights) == neuron_vectorized(inputs, weights)


def test_scalar_and_vectorized_agree_on_zero():
    assert neuron_scalar([0] * 8, [0] * 8) == neuron_vectorized([0] * 8, [0] * 8) == 0
