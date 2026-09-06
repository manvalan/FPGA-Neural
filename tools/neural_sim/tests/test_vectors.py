import json
import os

from tools.neural_sim import vectors as vec
from tools.neural_sim.layer import FCLayer


def test_simple_positive_manually_predictable():
    v = vec.gen_simple_positive()
    # inputs=[1..8], weights=all 1 -> sum = 36, ReLU(36)=36
    assert v.expected == [36]


def test_zero_vector_is_all_zero_output():
    v = vec.gen_zero()
    assert v.expected == [0]


def test_extremes_vector_is_self_consistent():
    v = vec.gen_extremes()
    layer = FCLayer(v.weights, biases=v.biases, activation=v.activation, p_in=v.p_in)
    assert layer.forward(v.inputs).tolist() == v.expected


def test_random_vector_is_deterministic_across_calls():
    v1 = vec.gen_random(seed=555)
    v2 = vec.gen_random(seed=555)
    assert v1.inputs == v2.inputs
    assert v1.weights == v2.weights
    assert v1.expected == v2.expected


def test_random_vector_different_seed_differs():
    v1 = vec.gen_random(seed=1)
    v2 = vec.gen_random(seed=2)
    assert v1.inputs != v2.inputs


def test_d_stress_dimensions_match_the_real_rtl_benchmark():
    v = vec.gen_dstress()
    assert v.n_neurons == 256
    assert v.n_inputs == 128


def test_d_stress_is_deterministic():
    v1 = vec.gen_dstress(seed=42)
    v2 = vec.gen_dstress(seed=42)
    assert v1.expected == v2.expected


def test_export_then_import_round_trip(tmp_path):
    v = vec.gen_signed_mix()
    path = str(tmp_path / "vec.json")
    vec.export_json(v, path)
    loaded = vec.load_json(path)
    assert loaded == v


def test_export_all_json_contains_every_generator(tmp_path):
    path = str(tmp_path / "all.json")
    vec.export_all_json(path)
    with open(path) as f:
        data = json.load(f)
    assert set(data.keys()) == set(vec.ALL_GENERATORS.keys())
    for name, d in data.items():
        assert "expected" in d and "weights" in d and "inputs" in d
