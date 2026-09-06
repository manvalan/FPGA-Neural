import pytest

from tools.neural_sim.memory import (
    MemoryModel, WEIGHTS_BASE, ACTIVATIONS_BASE, RESULTS_BASE, SDRAM_SIZE,
)


def test_read_after_write_each_region():
    mem = MemoryModel()
    mem.write_weight(0, -5)
    mem.write_activation(0, 42)
    mem.write_result(0, -128)
    assert mem.read_weight(0) == -5
    assert mem.read_activation(0) == 42
    assert mem.read_result(0) == -128


def test_regions_are_at_the_real_v2_addresses():
    mem = MemoryModel()
    mem.write_weight(0, 1)
    mem.write_activation(0, 2)
    mem.write_result(0, 3)
    assert mem.read_byte(WEIGHTS_BASE) == 1
    assert mem.read_byte(ACTIVATIONS_BASE) == 2
    assert mem.read_byte(RESULTS_BASE) == 3


def test_adjacent_regions_do_not_corrupt_each_other():
    mem = MemoryModel()
    mem.write_weight(0x0FFFFF - WEIGHTS_BASE, 0x11)  # last word before activations
    mem.write_activation(0, 0x22)                     # first word of activations
    assert mem.read_weight(0x0FFFFF - WEIGHTS_BASE) == 0x11
    assert mem.read_activation(0) == 0x22


def test_out_of_range_byte_raises():
    mem = MemoryModel()
    with pytest.raises(IndexError):
        mem.read_byte(-1)
    with pytest.raises(IndexError):
        mem.read_byte(SDRAM_SIZE)


def test_value_out_of_int8_range_raises():
    mem = MemoryModel()
    with pytest.raises(ValueError):
        mem.write_byte(0, 128)
    with pytest.raises(ValueError):
        mem.write_byte(0, -129)


def test_region_bounds_checking_rejects_spillover():
    mem = MemoryModel()
    weights_size = ACTIVATIONS_BASE - WEIGHTS_BASE
    with pytest.raises(IndexError):
        mem.write_weight(weights_size, 0)  # one byte past the weights region


def test_bulk_helpers_round_trip():
    mem = MemoryModel()
    values = list(range(-10, 10))
    mem.write_weights(0, values)
    assert mem.read_weights(0, len(values)) == values
