#!/usr/bin/env python3
"""
Independent host-side oracle for the flash-subsystem catalog (Phase F4).

Per WORKLOG.md's verification standard (§A.1, "regola d'oro"): CRC and
catalog-layout expected values used by the RTL testbenches must come from
a source INDEPENDENT of the RTL/testbench author's own understanding, not
be re-derived from the same design intent that produced the hardware. This
script is that source -- it uses Python's stdlib `zlib.crc32` (a
widely-used, pre-existing, independently-implemented CRC32 -- not
hand-derived here to match the RTL) and a from-scratch description of the
catalog byte layout, written by reading the byte offsets directly rather
than importing anything from rtl/flash_slot_manager.v.

Catalog entry layout (16 bytes, matches rtl/flash_slot_manager.v's own
header comment -- kept in sync by hand, cross-checked by the testbenches
comparing actual hardware output against THIS script's output byte-for-
byte, not by either side trusting the other's prose description):

    offset[0:3)   -- 24-bit flash byte offset of the slot's data, MSB first
    offset[3:6)   -- 24-bit slot length in bytes, MSB first
    offset[6]     -- 8-bit slot type (opaque, host-defined)
    offset[7]     -- valid flag: 0x01 = valid, anything else = invalid
                     (a freshly-erased catalog sector is all-0xFF, so an
                     unwritten slot is invalid by construction, no format
                     step needed)
    offset[8:12)  -- CRC32 (IEEE 802.3 / zlib) of the slot's data payload,
                     MSB first
    offset[12:16) -- reserved, always 0x00000000

16 slots x 16 bytes = 256 bytes = one flash page, comfortably inside the
4KB catalog sector (sector 0, address 0x000000 -- reserved, never used for
slot data, per rtl/flash_slot_manager.v's CATALOG_SECTOR_ADDR).
"""

import zlib
import struct

ENTRY_SIZE = 16
N_SLOTS = 16
CATALOG_BYTES = ENTRY_SIZE * N_SLOTS  # 256

VALID_MARK = 0x01


def crc32(data: bytes) -> int:
    """IEEE 802.3 CRC32 (same polynomial/reflection/init as zlib.crc32),
    the independent oracle value the RTL's crc32 module (rtl/crc32.v)
    must match bit-for-bit."""
    return zlib.crc32(data) & 0xFFFFFFFF


def pack_entry(offset: int, length: int, slot_type: int, valid: bool, data: bytes) -> bytes:
    """Build one 16-byte catalog entry exactly as rtl/flash_slot_manager.v
    is expected to persist it. `data` is the slot's actual payload bytes
    (used only to compute the CRC field here -- the RTL computes the same
    CRC by streaming the payload through rtl/crc32.v as it moves the
    bytes, not by re-reading this function's output)."""
    if not (0 <= offset < (1 << 24)):
        raise ValueError("offset out of 24-bit range")
    if not (0 <= length < (1 << 24)):
        raise ValueError("length out of 24-bit range")
    if not (0 <= slot_type < 256):
        raise ValueError("type out of 8-bit range")

    crc = crc32(data)
    valid_byte = VALID_MARK if valid else 0x00

    return (
        offset.to_bytes(3, "big")
        + length.to_bytes(3, "big")
        + bytes([slot_type])
        + bytes([valid_byte])
        + crc.to_bytes(4, "big")
        + b"\x00\x00\x00\x00"
    )


def unpack_entry(entry: bytes):
    """Inverse of pack_entry -- parses a raw 16-byte catalog entry (e.g.
    read back from the RTL's own catalog register file / persisted flash
    sector) into its fields, for testbench comparison."""
    if len(entry) != ENTRY_SIZE:
        raise ValueError(f"entry must be exactly {ENTRY_SIZE} bytes, got {len(entry)}")
    offset = int.from_bytes(entry[0:3], "big")
    length = int.from_bytes(entry[3:6], "big")
    slot_type = entry[6]
    valid = entry[7] == VALID_MARK
    crc = int.from_bytes(entry[8:12], "big")
    reserved = entry[12:16]
    return dict(offset=offset, length=length, type=slot_type, valid=valid, crc=crc, reserved=reserved)


def build_catalog(entries: dict) -> bytes:
    """entries: {slot_id: (offset, length, type, valid, data)} -> full
    256-byte catalog table (unwritten slots left as 0xFF, matching a
    freshly-erased sector -- see module docstring)."""
    table = bytearray(b"\xff" * CATALOG_BYTES)
    for slot_id, (offset, length, slot_type, valid, data) in entries.items():
        if not (0 <= slot_id < N_SLOTS):
            raise ValueError("slot_id out of range")
        entry = pack_entry(offset, length, slot_type, valid, data)
        table[slot_id * ENTRY_SIZE:(slot_id + 1) * ENTRY_SIZE] = entry
    return bytes(table)


if __name__ == "__main__":
    # Self-check / example: printed so a Verilog testbench's $display
    # output can be diffed against this by eye during bring-up.
    payload = bytes([0x10 + i for i in range(32)])
    entry = pack_entry(offset=0x001000, length=len(payload), slot_type=0x01, valid=True, data=payload)
    print("payload CRC32          =", hex(crc32(payload)))
    print("packed entry (hex)     =", entry.hex())
    print("unpacked                =", unpack_entry(entry))
