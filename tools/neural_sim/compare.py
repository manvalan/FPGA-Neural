"""
FPGA-vs-Python comparison utility (B10). Loads FPGA-generated results
and compares them against this package's own Python golden results.
The primary pass/fail criterion is 0 mismatches -- exact bit-exact
match, never a tolerance-based "close enough" comparison (per this
project's own explicit "for the true bit-exact model, do not hide
numerical differences behind tolerances" instruction).
"""
from __future__ import annotations

import json
from dataclasses import dataclass
from typing import List, Optional


@dataclass
class ComparisonReport:
    exact_match: bool
    total: int
    num_mismatches: int
    first_mismatch_index: Optional[int]
    first_mismatch_expected: Optional[int]
    first_mismatch_actual: Optional[int]
    max_abs_diff: int

    def summary(self) -> str:
        if self.exact_match:
            return f"EXACT MATCH: {self.total}/{self.total} outputs bit-exact, 0 mismatches"
        return (
            f"MISMATCH: {self.num_mismatches}/{self.total} outputs differ "
            f"(first at index {self.first_mismatch_index}: "
            f"expected={self.first_mismatch_expected} actual={self.first_mismatch_actual}, "
            f"max_abs_diff={self.max_abs_diff})"
        )


def compare_results(expected: List[int], actual: List[int]) -> ComparisonReport:
    if len(expected) != len(actual):
        raise ValueError(
            f"length mismatch: expected has {len(expected)} outputs, "
            f"actual has {len(actual)} -- cannot compare index-by-index"
        )

    total = len(expected)
    num_mismatches = 0
    first_idx = None
    first_exp = None
    first_act = None
    max_abs_diff = 0

    for i, (e, a) in enumerate(zip(expected, actual)):
        if e != a:
            num_mismatches += 1
            if first_idx is None:
                first_idx, first_exp, first_act = i, e, a
            max_abs_diff = max(max_abs_diff, abs(e - a))

    return ComparisonReport(
        exact_match=(num_mismatches == 0),
        total=total,
        num_mismatches=num_mismatches,
        first_mismatch_index=first_idx,
        first_mismatch_expected=first_exp,
        first_mismatch_actual=first_act,
        max_abs_diff=max_abs_diff,
    )


def load_fpga_results(path: str) -> List[int]:
    """Loads FPGA-generated results from either a JSON list of ints, or
    a plain text file with one (whitespace-separated) integer per
    line -- a common shape for an RTL testbench's own $display/
    $writememh-style dump."""
    with open(path) as f:
        text = f.read()
    try:
        data = json.loads(text)
        if isinstance(data, dict) and "results" in data:
            data = data["results"]
        return [int(v) for v in data]
    except json.JSONDecodeError:
        return [int(tok) for tok in text.split()]
