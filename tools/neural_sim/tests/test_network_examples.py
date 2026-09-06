import numpy as np
import pytest

from tools.neural_sim import examples as ex
from tools.neural_sim.layer import FCLayer
from tools.neural_sim.network import Network


def test_network_rejects_empty():
    with pytest.raises(ValueError):
        Network([])


def test_network_rejects_shape_mismatch():
    layer1 = FCLayer([[1] * 8])           # 8 -> 1
    layer2 = FCLayer([[1] * 8, [2] * 8])  # 8 -> 2, but layer1 outputs only 1
    with pytest.raises(ValueError):
        Network([layer1, layer2])


@pytest.mark.parametrize("name", list(ex.ALL_EXAMPLES.keys()))
def test_all_examples_run_and_stay_in_int8_range(name):
    net = ex.ALL_EXAMPLES[name]()
    rng = np.random.default_rng(123)
    inputs = rng.integers(-128, 128, size=net.n_inputs, dtype=np.int64)
    outputs = net.forward(inputs)
    assert len(outputs) == net.n_outputs
    assert all(-128 <= v <= 127 for v in outputs.tolist())


def test_network_forward_all_matches_forward_final():
    net = ex.example_8_8_1()
    inputs = np.array([1, 2, 3, 4, -1, -2, -3, -4], dtype=np.int64)
    all_outputs = net.forward_all(inputs)
    assert all_outputs[-1].tolist() == net.forward(inputs).tolist()
    assert len(all_outputs) == len(net.layers)
