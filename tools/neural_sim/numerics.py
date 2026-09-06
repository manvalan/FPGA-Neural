"""
Bit-exact numeric semantics of hardware/v2/rtl/neural_processor.v.

The RTL is authoritative. Every function here was derived by reading
neural_processor.v directly (not assumed), specifically:

  Stage 1 (line ~139): product_comb[gm] = x0[gm] * w0[gm]
      INT8 x INT8 signed multiply. PROD_WIDTH = 2*DATA_WIDTH = 16 bits
      is always sufficient (min product -128*127=-16256, max
      -128*-128=16384, both fit in signed 16 bits) -- the multiply
      itself can NEVER overflow for DATA_WIDTH=8. Each product is then
      sign-extended to ACC_WIDTH=32 bits (line ~151).

  Stages 2..(1+TREE_LEVELS) (line ~166-206): a balanced binary adder
      tree reduces the P_IN products to one `tile_sum`, entirely in
      ACC_WIDTH=32-bit signed arithmetic. For P_IN=8 this can never
      overflow either (max magnitude 8*16384=131072 << 2^31).

  Stage (2+TREE_LEVELS) (line ~212-229): `acc_reg <= acc_reg +
      tile_sum` -- a RUNNING accumulator across ALL TILES of one job
      (cleared only at NP_LOAD_JOB), using plain Verilog `+` on a
      32-bit signed reg. This is WRAPAROUND (modulo 2^32) arithmetic,
      NOT saturating -- Verilog silently wraps a fixed-width `+`.
      Practically never triggered for realistic tile counts (a job
      would need on the order of 2^17 tiles for the running sum to
      approach the 32-bit signed range), but modeled as true wraparound
      here anyway, per this project's own explicit "do not let overflow
      hide behind Python's arbitrary precision" requirement, and
      because an adversarial/stress test vector may deliberately probe
      this boundary.

  Stage (3+TREE_LEVELS) (line ~235-260): `final_acc_reg <= acc_reg +
      bias_ext` -- bias (sign-extended from an INT8 job_bias field) is
      ALSO added with 32-bit wraparound semantics. NOTE: the real,
      currently-exposed V2 SPI job protocol (spi_host_bridge.v's own
      WRITE_JOB opcode) has no bias field at all -- bias is a
      neural_processor.v MODULE-LEVEL capability, not something the
      real V2 host can currently set. This model defaults bias=0 to
      match the real, currently-exposed system behaviour, while still
      implementing nonzero bias faithfully for anyone driving
      neural_processor.v directly.

  Stage (4+TREE_LEVELS) (line ~262-288): the ONLY saturating stage.
      Two activation encodings exist in the RTL: ACT_NONE (a two-sided
      saturating clamp to the full signed INT8 range [-128, 127]) and
      ACT_RELU (the Verilog `case` statement's `default` branch, so
      ANY activation code other than exactly ACT_NONE=0 also produces
      ReLU behaviour). The real, currently-exposed V2 SPI job protocol
      has no activation-selection field either -- ReLU is the only
      activation the real system currently applies (matches the V2
      LaTeX datasheet's own "Activation: ReLU + INT8 saturate, fixed").

Overflow/signedness summary (as explicitly requested):
  - multiplication: exact, cannot overflow for INT8 operands
  - per-tile adder tree: exact for P_IN<=8, WRAPAROUND semantics modeled
  - cross-tile accumulator: WRAPAROUND (32-bit, two's complement)
  - bias add: WRAPAROUND (32-bit, two's complement)
  - final activation/output: SATURATING (to INT8, either two-sided for
    ACT_NONE or ReLU-then-saturate for ACT_RELU)

Reuses tools/validation/mac_oracle.py's own independently-derived
two's-complement primitives (`to_signed`, `mac8_tree`) rather than
duplicating them -- that file is this project's own pre-existing,
already-hand-verified oracle for the identical wraparound-add
semantics (rtl/mac_unit.v / rtl/mac8.v), and neural_processor.v's own
header states its accumulation is "same sign-extended INT32-style
accumulation" as that same MAC lineage.
"""
from __future__ import annotations

from tools.validation.mac_oracle import to_signed, to_unsigned, mac8_tree

INT8_MIN = -128
INT8_MAX = 127
DEFAULT_DATA_WIDTH = 8
DEFAULT_ACC_WIDTH = 32
DEFAULT_P_IN = 8

ACT_NONE = "none"
ACT_RELU = "relu"


def check_int8(val: int, name: str = "value") -> int:
    """Assert `val` is a valid signed INT8 and return it unchanged."""
    if not (INT8_MIN <= val <= INT8_MAX):
        raise ValueError(f"{name}={val} out of signed INT8 range [{INT8_MIN}, {INT8_MAX}]")
    return val


def wrap_acc(val: int, acc_width: int = DEFAULT_ACC_WIDTH) -> int:
    """Wrap a Python int to signed acc_width-bit two's complement -- the
    exact semantics of a fixed-width Verilog `reg signed [acc_width-1:0]`
    after a `+` that would otherwise overflow."""
    return to_signed(val, acc_width)


def tile_product_sum(x_tile, w_tile, acc_width: int = DEFAULT_ACC_WIDTH,
                      data_width: int = DEFAULT_DATA_WIDTH) -> int:
    """
    One P_IN-wide tile: P_IN independent INT8xINT8 products, reduced by
    the balanced adder tree (mac8_tree, acc_in=0). Matches
    neural_processor.v's `tile_sum` (stages 1..1+TREE_LEVELS) exactly.
    """
    if len(x_tile) != len(w_tile):
        raise ValueError("x_tile and w_tile must have the same length (P_IN)")
    n = len(x_tile)
    if n == 0 or (n & (n - 1)) != 0:
        raise ValueError(f"tile length {n} must be a power of two (P_IN), matching the RTL's tree")
    products = []
    for x, w in zip(x_tile, w_tile):
        check_int8(x, "input")
        check_int8(w, "weight")
        products.append(x * w)  # exact, INT8xINT8 never overflows PROD_WIDTH=16
    return mac8_tree(products, acc_in=0, acc_width=acc_width)


def accumulate_tile(acc_reg: int, tile_sum: int, acc_width: int = DEFAULT_ACC_WIDTH) -> int:
    """`acc_reg <= acc_reg + tile_sum` -- one running-accumulator update
    across tiles of the SAME job. WRAPAROUND, matching the RTL's plain
    fixed-width `+` exactly (not saturating)."""
    return wrap_acc(acc_reg + tile_sum, acc_width)


def add_bias(acc_reg: int, bias: int, acc_width: int = DEFAULT_ACC_WIDTH,
             data_width: int = DEFAULT_DATA_WIDTH) -> int:
    """`final_acc_reg <= acc_reg + bias_ext` -- bias is sign-extended from
    an INT8 value, then added with WRAPAROUND semantics (same as
    accumulate_tile)."""
    check_int8(bias, "bias")
    return wrap_acc(acc_reg + bias, acc_width)


def activate_and_saturate(final_acc: int, activation: str = ACT_RELU,
                           data_width: int = DEFAULT_DATA_WIDTH) -> int:
    """
    The ONE saturating stage in the whole datapath -- neural_processor.v
    lines ~256-288, reproduced exactly (not approximated):

    ACT_NONE: two-sided saturating clamp to [INT8_MIN, INT8_MAX] -- if
      final_acc fits in signed data_width bits, pass its exact truncated
      value through; otherwise clamp to INT8_MIN (if negative) or
      INT8_MAX (if positive).

    ACT_RELU (default, and the RTL's own `case` default for ANY
      activation code other than exactly ACT_NONE): final_acc<=0 -> 0;
      0 < final_acc <= INT8_MAX -> final_acc exactly; final_acc >
      INT8_MAX -> saturate to INT8_MAX. There is no negative saturation
      branch for ReLU since negative values are already zeroed.
    """
    lo, hi = -(1 << (data_width - 1)), (1 << (data_width - 1)) - 1

    if activation == ACT_NONE:
        if lo <= final_acc <= hi:
            return final_acc
        return lo if final_acc < 0 else hi

    # ACT_RELU (and, matching the RTL's `default:` case branch, any
    # activation value that isn't exactly ACT_NONE)
    if final_acc <= 0:
        return 0
    if final_acc > hi:
        return hi
    return final_acc


def neuron_reference(inputs, weights, bias: int = 0, activation: str = ACT_RELU,
                      p_in: int = DEFAULT_P_IN, acc_width: int = DEFAULT_ACC_WIDTH,
                      data_width: int = DEFAULT_DATA_WIDTH) -> int:
    """
    Full, tile-by-tile, bit-exact reference for one neuron_processor.v
    job: y = activation(bias + sum(x[i]*w[i] for i in 0..N_INPUTS-1)),
    computed the SAME WAY the RTL computes it -- P_IN-wide tiles, each
    reduced by the adder tree, accumulated across tiles with 32-bit
    wraparound, THEN bias-added (also wraparound), THEN activated/
    saturated exactly once at the end (matching tile_last/NP_FINISH).

    len(inputs) must be a multiple of p_in (one real tile per group of
    p_in inputs -- matches n_tiles*P_IN in the real WRITE_JOB protocol).
    """
    if len(inputs) != len(weights):
        raise ValueError("inputs and weights must have the same length")
    if len(inputs) == 0 or len(inputs) % p_in != 0:
        raise ValueError(f"len(inputs)={len(inputs)} must be a nonzero multiple of p_in={p_in}")

    acc = 0
    for t in range(0, len(inputs), p_in):
        x_tile = inputs[t:t + p_in]
        w_tile = weights[t:t + p_in]
        tile_sum = tile_product_sum(x_tile, w_tile, acc_width=acc_width, data_width=data_width)
        acc = accumulate_tile(acc, tile_sum, acc_width=acc_width)

    final_acc = add_bias(acc, bias, acc_width=acc_width, data_width=data_width)
    return activate_and_saturate(final_acc, activation=activation, data_width=data_width)
