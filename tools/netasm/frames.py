"""
SPI frame encoding matching rtl/spi_engine.v's opcode set (§5 of the
spec). A "frame" is the exact sequence of bytes shifted over MOSI
during one CS-low transaction -- opcode byte first, then whatever
fixed-size payload that opcode expects. This module only builds
byte sequences; it does not talk to real hardware.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import List

OP_NOP = 0x00
OP_WRITE_RAM = 0x01
OP_READ_RAM = 0x02
OP_RESET = 0x0F
OP_SET_BASE = 0x10
OP_SET_NET_TYPE = 0x11
OP_START = 0x20
OP_STATUS = 0x21
OP_READ_OUTPUT = 0x22
OP_RUN_NETWORK = 0x23
OP_READ_CONFIG = 0x30

SEL_X_BASE = 0x00
SEL_W_BASE = 0x01
SEL_BIAS_ADDR = 0x02
SEL_TABLE_BASE = 0x03
SEL_BUF_A_BASE = 0x04
SEL_BUF_B_BASE = 0x05
SEL_ACTIVATION = 0x06
SEL_N_INPUTS = 0x07
SEL_N_NEURONS = 0x08
SEL_NUM_NEURONS_GRAPH = 0x09
SEL_N_OUT = 0x0A

NET_TYPE_DENSE = 0x01
NET_TYPE_GRAPH = 0x02

ACT_NONE = 0
ACT_RELU = 1


def _u24(v: int) -> bytes:
    if not (0 <= v < (1 << 24)):
        raise ValueError(f"address 0x{v:x} does not fit in 24 bits")
    return bytes([(v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF])


def _u16(v: int) -> bytes:
    if not (0 <= v < (1 << 16)):
        raise ValueError(f"value 0x{v:x} does not fit in 16 bits")
    return bytes([(v >> 8) & 0xFF, v & 0xFF])


def _i8(v: int) -> int:
    if not (-128 <= v <= 127):
        raise ValueError(f"value {v} does not fit in a signed byte")
    return v & 0xFF


@dataclass
class Frame:
    label: str
    data: bytes


def reset() -> Frame:
    return Frame("RESET", bytes([OP_RESET]))


def set_net_type(net_type: int) -> Frame:
    return Frame(f"SET_NET_TYPE({net_type:#04x})", bytes([OP_SET_NET_TYPE, net_type & 0xFF]))


def set_base(sel: int, addr: int) -> Frame:
    return Frame(
        f"SET_BASE(sel={sel:#04x}, addr={addr:#08x})",
        bytes([OP_SET_BASE, sel & 0xFF]) + _u24(addr),
    )


def write_ram(addr: int, data: bytes) -> Frame:
    return Frame(
        f"WRITE_RAM(addr={addr:#08x}, len={len(data)})",
        bytes([OP_WRITE_RAM]) + _u24(addr) + _u16(len(data)) + bytes(data),
    )


def read_ram(addr: int, length: int) -> Frame:
    return Frame(
        f"READ_RAM(addr={addr:#08x}, len={length})",
        bytes([OP_READ_RAM]) + _u24(addr) + _u16(length),
    )


def run_network(payload_byte: int = 0) -> Frame:
    return Frame(f"RUN_NETWORK(payload={payload_byte:#04x})", bytes([OP_RUN_NETWORK, payload_byte & 0xFF]))


def start() -> Frame:
    return Frame("START", bytes([OP_START]))


def status() -> Frame:
    return Frame("STATUS", bytes([OP_STATUS, 0x00]))


def read_config() -> Frame:
    return Frame("READ_CONFIG", bytes([OP_READ_CONFIG] + [0x00] * 10))


def dump_frames(frames: List[Frame], path: str) -> None:
    """Length-prefixed binary dump: for each frame, a 2-byte
    big-endian length followed by that many payload bytes. A simple
    host driver replays this by, for each record, asserting CS,
    shifting out the bytes, then deasserting CS."""
    with open(path, "wb") as f:
        for fr in frames:
            n = len(fr.data)
            f.write(bytes([(n >> 8) & 0xFF, n & 0xFF]))
            f.write(fr.data)


def frames_as_hex(frames: List[Frame]) -> str:
    lines = []
    for fr in frames:
        hexbytes = " ".join(f"{b:02x}" for b in fr.data)
        lines.append(f"{fr.label:40s} : {hexbytes}")
    return "\n".join(lines)
