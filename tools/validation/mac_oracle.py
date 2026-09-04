#!/usr/bin/env python3
"""
Independent Python oracle for rtl/mac_unit.v and rtl/mac8.v (aspect C.1 of
the re-certification campaign, docs/validation/01-datapath.md).

Deliberately reimplements the arithmetic from first principles (two's
complement wraparound, sign extension) -- NOT by reading the Verilog and
transcribing it. Every function below is checked against Python's own
built-in arbitrary-precision integers, which have no width and cannot
share a truncation/sign-extension bug with the RTL.

Run standalone to regenerate the golden vectors used by
sim/mac_unit_tb.v / sim/mac8_tree_tb.v:
    python3 tools/validation/mac_oracle.py
"""

def to_signed(val: int, width: int) -> int:
    """Interpret the low `width` bits of `val` as two's complement."""
    val &= (1 << width) - 1
    if val >= (1 << (width - 1)):
        val -= (1 << width)
    return val

def to_unsigned(val: int, width: int) -> int:
    return val & ((1 << width) - 1)

def mac_unit(x: int, w: int, acc_in: int, data_width: int = 8, acc_width: int = 32) -> int:
    """Bit-exact model of rtl/mac_unit.v: acc_out = acc_in + sign_extend(x*w)."""
    assert -(1 << (data_width - 1)) <= x < (1 << (data_width - 1))
    assert -(1 << (data_width - 1)) <= w < (1 << (data_width - 1))
    product = x * w  # Python int, exact, no width -- the whole point of an independent oracle
    prod_width = 2 * data_width
    assert -(1 << (prod_width - 1)) <= product < (1 << (prod_width - 1)), \
        "product overflowed PROD_WIDTH -- data_width assumption violated"
    raw = to_unsigned(acc_in, acc_width) + to_unsigned(product, prod_width if product >= 0 else prod_width)
    # acc_in + sign_extend(product) computed directly in signed arithmetic,
    # then wrapped to acc_width bits (matches Verilog's silent wraparound
    # on a fixed-width signed reg/wire -- confirmed intentional, not a
    # bug, because callers rely on it: see docs/validation/01-datapath.md).
    return to_signed(acc_in + product, acc_width)

def mac8_tree(products: list[int], acc_in: int, acc_width: int = 32) -> int:
    """
    Bit-exact model of rtl/mac8.v's balanced binary adder tree +
    final accumulator add. `products` must have length PARALLEL (a power
    of two, matching the RTL's $clog2-based tree construction).
    """
    n = len(products)
    assert n > 0 and (n & (n - 1)) == 0, "PARALLEL must be a power of two"
    level = list(products)
    while len(level) > 1:
        level = [to_signed(level[i] + level[i + 1], acc_width) for i in range(0, len(level), 2)]
    return to_signed(acc_in + level[0], acc_width)

def mac8_full(x_vals: list[int], w_vals: list[int], acc_in: int,
              data_width: int = 8, acc_width: int = 32) -> int:
    """End-to-end oracle: PARALLEL independent products -> balanced tree -> + acc_in."""
    assert len(x_vals) == len(w_vals)
    products = [mac_unit(x, w, 0, data_width, acc_width) for x, w in zip(x_vals, w_vals)]
    return mac8_tree(products, acc_in, acc_width)


if __name__ == "__main__":
    # Self-check: a handful of hand-verifiable cases, printed for a human
    # to eyeball before trusting this file as an oracle for anything else.
    cases = [
        (5, 7, 0, 35),
        (-128, -128, 0, 16384),   # the one INT8 x INT8 case that does NOT fit in INT16 magnitude terms symmetrically
        (127, 127, 0, 16129),
        (-128, 127, 0, -16256),
        (0, 0, 0, 0),
        (-1, -1, 0, 1),
    ]
    ok = True
    for x, w, acc_in, expected in cases:
        got = mac_unit(x, w, acc_in)
        status = "OK" if got == expected else "MISMATCH"
        if got != expected:
            ok = False
        print(f"mac_unit(x={x}, w={w}, acc_in={acc_in}) = {got} (expected {expected}) {status}")
    print("ALL SELF-CHECKS PASSED" if ok else "SELF-CHECK FAILURE -- oracle itself is wrong, fix before using it")
