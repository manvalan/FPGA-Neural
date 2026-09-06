"""
Logical memory model of the real, official V2 unified-SDRAM memory map
(hardware/v2/docs/DatasheetLatex/chapters/02-architecture.tex's own
"Official V2 memory map" table, cross-checked against
hardware/v2/nms/sim/tb_sdram_boundary.v's own use of the same
addresses):

    Region       Base address   Notes
    Weights      0x010000       1MB-aligned
    Activations  0x200000       1MB-aligned
    Results      0x300000       1MB-aligned

all three non-overlapping within the single 8MB (0x000000-0x7FFFFF)
SDRAM address space. This model reproduces the LOGICAL byte contents
and addresses only -- it does NOT reproduce SDRAM cycle timing,
refresh, or burst behaviour (see hardware/v2/nms/sim/sdram_model.v /
sdram_controller.v for that; this is a plain flat byte array).

Region sizes are inferred from adjacency (each region's own end is the
next region's own base) -- the real hardware does not enforce region
size limits in the datapath itself (base addresses are host-
programmable per job), so this is this model's own deliberately
conservative bounds-checking convention, matching the same assumption
tb_sdram_boundary.v's own "weights-last(pre-act)"/"activations-
last(pre-res)" checks use.
"""
from __future__ import annotations

SDRAM_SIZE = 8 * 1024 * 1024  # 8MB, 0x000000-0x7FFFFF

WEIGHTS_BASE = 0x010000
ACTIVATIONS_BASE = 0x200000
RESULTS_BASE = 0x300000

WEIGHTS_END = ACTIVATIONS_BASE       # exclusive
ACTIVATIONS_END = RESULTS_BASE       # exclusive
RESULTS_END = SDRAM_SIZE             # exclusive


def _to_unsigned8(v: int) -> int:
    return v & 0xFF


def _to_signed8(v: int) -> int:
    v &= 0xFF
    return v - 256 if v >= 128 else v


class MemoryModel:
    """A flat 8MB byte array standing in for the real unified SDRAM,
    with bounds-checked, region-aware, signed-INT8 read/write helpers."""

    def __init__(self):
        self._mem = bytearray(SDRAM_SIZE)

    # ---- raw byte access (any address in the full 8MB space) ----
    def read_byte(self, addr: int) -> int:
        if not (0 <= addr < SDRAM_SIZE):
            raise IndexError(f"address 0x{addr:06x} out of range [0, 0x{SDRAM_SIZE:06x})")
        return _to_signed8(self._mem[addr])

    def write_byte(self, addr: int, value: int) -> None:
        if not (0 <= addr < SDRAM_SIZE):
            raise IndexError(f"address 0x{addr:06x} out of range [0, 0x{SDRAM_SIZE:06x})")
        if not (-128 <= value <= 127):
            raise ValueError(f"value {value} out of signed INT8 range [-128, 127]")
        self._mem[addr] = _to_unsigned8(value)

    # ---- region-aware helpers (B7's own required helper names) ----
    def _region_check(self, base: int, end: int, offset: int, label: str) -> int:
        addr = base + offset
        if not (base <= addr < end):
            raise IndexError(
                f"{label} offset {offset} (address 0x{addr:06x}) falls outside "
                f"its own region [0x{base:06x}, 0x{end:06x})"
            )
        return addr

    def write_weight(self, offset: int, value: int) -> None:
        self.write_byte(self._region_check(WEIGHTS_BASE, WEIGHTS_END, offset, "weight"), value)

    def read_weight(self, offset: int) -> int:
        return self.read_byte(self._region_check(WEIGHTS_BASE, WEIGHTS_END, offset, "weight"))

    def write_activation(self, offset: int, value: int) -> None:
        self.write_byte(self._region_check(ACTIVATIONS_BASE, ACTIVATIONS_END, offset, "activation"), value)

    def read_activation(self, offset: int) -> int:
        return self.read_byte(self._region_check(ACTIVATIONS_BASE, ACTIVATIONS_END, offset, "activation"))

    def write_result(self, offset: int, value: int) -> None:
        self.write_byte(self._region_check(RESULTS_BASE, RESULTS_END, offset, "result"), value)

    def read_result(self, offset: int) -> int:
        return self.read_byte(self._region_check(RESULTS_BASE, RESULTS_END, offset, "result"))

    # ---- bulk convenience (not a hardware concept, pure host-side sugar) ----
    def write_weights(self, offset: int, values) -> None:
        for i, v in enumerate(values):
            self.write_weight(offset + i, int(v))

    def read_weights(self, offset: int, count: int):
        return [self.read_weight(offset + i) for i in range(count)]

    def write_activations(self, offset: int, values) -> None:
        for i, v in enumerate(values):
            self.write_activation(offset + i, int(v))

    def read_activations(self, offset: int, count: int):
        return [self.read_activation(offset + i) for i in range(count)]
