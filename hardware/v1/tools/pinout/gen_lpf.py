#!/usr/bin/env python3
"""
Generates synth/ecp5/spi_neuron_top.lpf (LOCATE/IOBUF constraints) for
spi_neuron_top's SPI + PSRAM ports on the real LFE5U-45F-8BG381C part,
using Project Trellis's own device database as the source of ball/bank/
dual-function data (the same data nextpnr-ecp5 itself uses) -- not
invented numbers.

Requires prjtrellis installed (Homebrew: `brew install prjtrellis`) and
its iodb.json for LFE5U-45F. See docs/FPGA-Neural-Hardware-Design.md §7
for the full placement rationale (bank/die-edge geometry, why banks 2+3
hold the PSRAM bus and bank 7 holds SPI/clock/reset).

Re-run this whenever the port list of rtl/spi_neuron_top.v's top-level
SPI/PSRAM interface changes (ADDR_WIDTH, MEM_DATA_WIDTH, etc.) -- it does
NOT try to read the RTL; the port list/widths are hardcoded below and
must be kept in sync by hand.
"""

import json
import re
import glob
import sys

CLK_BALL = "H5"  # GR_PCLK7_0, bank 7 -- dedicated global clock pad
ADDR_BITS = 23   # ADDR_WIDTH (byte address); only [21:0] carry real address, see §3
DATA_BITS = 16   # MEM_DATA_WIDTH

def find_iodb():
    candidates = glob.glob(
        "/opt/homebrew/Cellar/prjtrellis/*/share/trellis/database/ECP5/LFE5U-45F/iodb.json"
    ) + glob.glob(
        "/usr/share/trellis/database/ECP5/LFE5U-45F/iodb.json"
    )
    if not candidates:
        sys.exit("prjtrellis iodb.json not found -- install prjtrellis (brew install prjtrellis)")
    return candidates[0]


def load_balls(iodb_path, package="CABGA381"):
    d = json.load(open(iodb_path))
    pkg = d["packages"][package]
    meta_idx = {}
    for m in d["pio_metadata"]:
        meta_idx.setdefault((m["col"], m["row"], m["pio"]), []).append(m)
    out = {}
    for ball, info in pkg.items():
        key = (info["col"], info["row"], info["pio"])
        metas = meta_idx.get(key, [])
        bank = metas[0]["bank"] if metas else None
        funcs = sorted(set(m.get("function", "") for m in metas if m.get("function")))
        out[ball] = dict(col=info["col"], row=info["row"], bank=bank, funcs=funcs)
    return out


def bank_balls(rows, bank, exclude=()):
    items = [(b, v) for b, v in rows.items() if v["bank"] == bank and b not in exclude]
    plain = sorted((x for x in items if not x[1]["funcs"]), key=lambda x: (x[1]["row"], x[1]["col"], x[0]))
    special = sorted((x for x in items if x[1]["funcs"]), key=lambda x: (x[1]["row"], x[1]["col"], x[0]))
    return plain + special


def assign(rows):
    psram_pool = bank_balls(rows, 2) + bank_balls(rows, 3)
    ctrl_pool = bank_balls(rows, 7, exclude={CLK_BALL})

    a = {}
    for i, (ball, _) in enumerate(psram_pool[0:ADDR_BITS - 1]):
        a[f"psram_a[{i}]"] = ball
    for i, (ball, _) in enumerate(psram_pool[ADDR_BITS - 1:ADDR_BITS - 1 + DATA_BITS]):
        a[f"psram_dq[{i}]"] = ball
    ctrl_names = ["psram_ce_n", "psram_oe_n", "psram_we_n", "psram_lb_n", "psram_ub_n", "psram_zz_n"]
    for name, (ball, _) in zip(ctrl_names, psram_pool[ADDR_BITS - 1 + DATA_BITS:ADDR_BITS - 1 + DATA_BITS + 6]):
        a[name] = ball
    a[f"psram_a[{ADDR_BITS - 1}]"] = psram_pool[ADDR_BITS - 1 + DATA_BITS + 6][0]  # always-0 spare bit

    # Application SPI + reset + host attention pins (irq_n/data_ready_n,
    # added 2026-09-03), all in bank 7 alongside clk -- kept away from
    # the PSRAM bus (banks 2+3) per the same "opposite edges" rationale
    # as the SPI signals. flash_sclk/flash_mosi/flash_miso/flash_cs_n
    # (added 2026-09-04, revised same day to drop the USRMCLK/CCLK
    # coupling -- see rtl/spi_flash_master.v's header) join the same
    # pool for the same reason -- this is a fully independent,
    # ordinary-GPIO SPI bus toward the boot/persistence flash
    # (rtl/spi_flash_master.v), physically distinct from both the host
    # SPI above and the dedicated config-SPI pins (never touched by
    # user logic, see docs/FPGA-Neural-Hardware-Design.md §6). No pin
    # is shared with any ECP5 config primitive.
    # flash_sclk appended LAST (not inserted among the other flash
    # signals) so this regeneration stays additive: flash_mosi/
    # flash_miso/flash_cs_n keep the exact balls already committed to
    # the datasheet/schematic notes, only one genuinely new ball is
    # allocated for flash_sclk.
    spi_names = ["sclk", "mosi", "miso", "cs_n", "rst", "irq_n", "data_ready_n",
                 "flash_mosi", "flash_miso", "flash_cs_n", "flash_sclk"]
    for name, (ball, _) in zip(spi_names, ctrl_pool[0:11]):
        a[name] = ball
    a["clk"] = CLK_BALL
    return a


def write_lpf(assignment, path):
    lines = ["BLOCK ASYNCPATHS;", "BLOCK RESETPATHS;", ""]
    for sig, ball in sorted(assignment.items()):
        lines.append(f'LOCATE COMP "{sig}" SITE "{ball}";')
        lines.append(f'IOBUF PORT "{sig}" IO_TYPE=LVCMOS33;')
        lines.append("")
    open(path, "w").write("\n".join(lines))


if __name__ == "__main__":
    out_path = sys.argv[1] if len(sys.argv) > 1 else "synth/ecp5/spi_neuron_top.lpf"
    rows = load_balls(find_iodb())
    assignment = assign(rows)
    write_lpf(assignment, out_path)
    print(f"wrote {len(assignment)} signal constraints to {out_path}")
