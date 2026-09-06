import json

import pytest

from tools.neural_sim.compare import compare_results, load_fpga_results


def test_exact_match():
    report = compare_results([1, 2, 3], [1, 2, 3])
    assert report.exact_match
    assert report.num_mismatches == 0


def test_single_mismatch_reported_precisely():
    report = compare_results([1, 2, 3], [1, 5, 3])
    assert not report.exact_match
    assert report.num_mismatches == 1
    assert report.first_mismatch_index == 1
    assert report.first_mismatch_expected == 2
    assert report.first_mismatch_actual == 5
    assert report.max_abs_diff == 3


def test_multiple_mismatches_max_abs_diff():
    report = compare_results([0, 0, 0], [10, -5, 0])
    assert report.num_mismatches == 2
    assert report.max_abs_diff == 10


def test_length_mismatch_raises():
    with pytest.raises(ValueError):
        compare_results([1, 2], [1, 2, 3])


def test_load_fpga_results_json_list(tmp_path):
    path = tmp_path / "results.json"
    path.write_text(json.dumps([1, -2, 3]))
    assert load_fpga_results(str(path)) == [1, -2, 3]


def test_load_fpga_results_json_dict_with_results_key(tmp_path):
    path = tmp_path / "results.json"
    path.write_text(json.dumps({"results": [4, 5, 6], "meta": "x"}))
    assert load_fpga_results(str(path)) == [4, 5, 6]


def test_load_fpga_results_plain_text(tmp_path):
    path = tmp_path / "results.txt"
    path.write_text("1 2 -3\n4 5")
    assert load_fpga_results(str(path)) == [1, 2, -3, 4, 5]
