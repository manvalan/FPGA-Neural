"""
neural_sim -- the Python GOLDEN FUNCTIONAL REFERENCE for FPGA-Neural V2.

Given weights, activations, and a network topology, this package
computes the mathematically correct result that the real V2 hardware
(hardware/v2/rtl/neural_processor.v, unmodified since before the
single-SDRAM freeze) must reproduce bit-for-bit.

This is NOT a cycle-accurate FPGA simulator: it models the numeric
result only, not clock cycles, memory-controller timing, or SPI
transaction timing. See README.md for the full scope statement and
tools/neural_sim/network.py / tools/neural_sim/memory.py for what IS
and is NOT modeled.

    Python simulator = golden functional reference
    RTL / P&R        = hardware implementation
"""

__version__ = "0.1.0"
