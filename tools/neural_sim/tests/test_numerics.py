import pytest

from tools.neural_sim.numerics import (
    check_int8, wrap_acc, tile_product_sum, accumulate_tile, add_bias,
    activate_and_saturate, neuron_reference, ACT_NONE, ACT_RELU,
)


def test_check_int8_accepts_range():
    assert check_int8(-128) == -128
    assert check_int8(127) == 127
    assert check_int8(0) == 0


def test_check_int8_rejects_out_of_range():
    with pytest.raises(ValueError):
        check_int8(128)
    with pytest.raises(ValueError):
        check_int8(-129)


def test_wrap_acc_no_overflow_is_identity():
    assert wrap_acc(1000, acc_width=32) == 1000
    assert wrap_acc(-1000, acc_width=32) == -1000


def test_wrap_acc_true_32bit_wraparound():
    # 2**31 is one past the max positive signed 32-bit value (2**31 - 1)
    # -- must wrap to the most-negative value, exactly like a Verilog
    # `reg signed [31:0]` silently overflowing.
    assert wrap_acc(2**31, acc_width=32) == -(2**31)
    assert wrap_acc(2**31 - 1, acc_width=32) == 2**31 - 1  # exact boundary, no wrap
    assert wrap_acc(-(2**31) - 1, acc_width=32) == 2**31 - 1


def test_tile_product_sum_exact_known_values():
    # 1*1 + 2*1 + ... + 8*1 = 36
    assert tile_product_sum(list(range(1, 9)), [1] * 8) == 36


def test_tile_product_sum_extreme_product():
    # -128 * -128 = 16384, the one INT8xINT8 case that does not fit
    # symmetrically in magnitude terms
    assert tile_product_sum([-128], [-128], acc_width=32) == 16384


def test_tile_product_sum_rejects_non_power_of_two():
    with pytest.raises(ValueError):
        tile_product_sum([1, 2, 3], [1, 1, 1])


def test_tile_product_sum_rejects_out_of_range_input():
    with pytest.raises(ValueError):
        tile_product_sum([200], [1])


def test_accumulate_tile_matches_wrap_acc():
    assert accumulate_tile(10, 20) == 30
    assert accumulate_tile(2**31 - 1, 1) == -(2**31)


def test_add_bias_wraparound():
    assert add_bias(100, 27) == 127
    assert add_bias(2**31 - 1, 127) == wrap_acc(2**31 - 1 + 127)


def test_activate_relu_zeroes_non_positive():
    assert activate_and_saturate(0, activation=ACT_RELU) == 0
    assert activate_and_saturate(-1, activation=ACT_RELU) == 0
    assert activate_and_saturate(-1000000, activation=ACT_RELU) == 0


def test_activate_relu_passes_in_range():
    assert activate_and_saturate(1, activation=ACT_RELU) == 1
    assert activate_and_saturate(127, activation=ACT_RELU) == 127


def test_activate_relu_saturates_positive():
    assert activate_and_saturate(128, activation=ACT_RELU) == 127
    assert activate_and_saturate(1000000, activation=ACT_RELU) == 127


def test_activate_none_passes_full_signed_range():
    assert activate_and_saturate(-128, activation=ACT_NONE) == -128
    assert activate_and_saturate(127, activation=ACT_NONE) == 127
    assert activate_and_saturate(0, activation=ACT_NONE) == 0


def test_activate_none_saturates_both_sides():
    assert activate_and_saturate(128, activation=ACT_NONE) == 127
    assert activate_and_saturate(-129, activation=ACT_NONE) == -128
    assert activate_and_saturate(1000000, activation=ACT_NONE) == 127
    assert activate_and_saturate(-1000000, activation=ACT_NONE) == -128


def test_neuron_reference_simple_positive():
    y = neuron_reference(list(range(1, 9)), [1] * 8, activation=ACT_RELU)
    assert y == 36


def test_neuron_reference_multi_tile_accumulates_across_tiles():
    # two tiles of 8, same weights -- accumulator must carry across tiles
    inputs = [1] * 8 + [1] * 8
    weights = [1] * 8 + [1] * 8
    assert neuron_reference(inputs, weights, activation=ACT_RELU) == 16


def test_neuron_reference_rejects_length_not_multiple_of_p_in():
    with pytest.raises(ValueError):
        neuron_reference([1] * 5, [1] * 5)


def test_neuron_reference_bias_default_zero_matches_no_bias():
    y_default = neuron_reference([1] * 8, [1] * 8)
    y_explicit = neuron_reference([1] * 8, [1] * 8, bias=0)
    assert y_default == y_explicit
