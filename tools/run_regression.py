#!/usr/bin/env python3
"""
Fase 0 (docs/validation/00-inventario.md) regression runner.

No such script existed in the repo before this -- every prior "N testbenches,
all pass" claim in WORKLOG.md was produced by manually assembling per-test
iverilog command lines, never re-run from a single reproducible harness. This
script builds the module dependency graph directly from the source (regex
over instantiation sites), not from memory/WORKLOG claims, then compiles and
runs every sim/*_tb.v fresh with `iverilog -g2012` + `vvp`.

Usage: python3 tools/run_regression.py [--keep] [pattern]
  --keep     keep the compiled .out files in /tmp/regression (default: cleaned)
  pattern    only run testbenches whose filename contains this substring
"""
import glob
import os
import re
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Testbenches that are DELIBERATELY meant to fail elaboration (they verify a
# compile-time guard by trying to violate it -- see each file's own header
# comment for the citation). A naive PASS/FAIL-marker scan misclassifies
# these as broken; confirmed by reading the source, not assumed.
EXPECTED_COMPILE_FAIL = {
    "neuron_parallel_guard_negative_degenerate",
    "neuron_parallel_guard_negative_nonmultiple",
}
# Benchmarks: print measured numbers, no PASS/FAIL verdict by design (see
# each file's own header -- same category as sim/flash_latency_bench.v,
# which isn't even named *_tb.v and so isn't picked up by this glob at all,
# an inconsistent naming convention worth flagging in the inventory).
BENCHMARK_NO_VERDICT = {
    "graph_engine_bandwidth",
}

# Every module-defining file under rtl/ and the sim/ behavioral models used
# as test doubles (flash_model.v, psram_model.v) -- sim/top.v is EXCLUDED
# deliberately: it's dead code (references a FRAC_BITS parameter that no
# longer exists on neuron_parallel.v, confirmed failing to elaborate on its
# own, see docs/validation/00-inventario.md).
SOURCE_FILES = sorted(
    glob.glob(os.path.join(REPO, "rtl", "*.v"))
    + [os.path.join(REPO, "sim", "flash_model.v"), os.path.join(REPO, "sim", "psram_model.v")]
)

MODULE_RE = re.compile(r"^\s*module\s+([A-Za-z_][A-Za-z0-9_]*)", re.MULTILINE)
# Matches "modname instname (" or "modname #(" instantiation sites, not
# "module modname" definitions and not plain calls/keywords.
INST_RE = re.compile(
    r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s+(?:#\s*\(|[A-Za-z_][A-Za-z0-9_]*\s*\()",
    re.MULTILINE,
)
KEYWORDS = {
    "if", "else", "for", "while", "case", "begin", "end", "assign", "wire",
    "reg", "input", "output", "inout", "parameter", "localparam", "function",
    "task", "always", "initial", "module", "endmodule", "generate",
    "endgenerate", "genvar", "integer", "real", "signed", "unsigned",
}

def module_defined_in(path):
    txt = open(path, encoding="utf-8", errors="replace").read()
    return MODULE_RE.findall(txt)

def instantiated_modules(path):
    txt = open(path, encoding="utf-8", errors="replace").read()
    found = set(INST_RE.findall(txt)) - KEYWORDS
    return found

def build_module_map():
    m = {}
    for f in SOURCE_FILES:
        for name in module_defined_in(f):
            m.setdefault(name, f)
    return m

def resolve_deps(tb_path, module_map):
    needed_files = {tb_path}
    frontier = instantiated_modules(tb_path)
    seen_files = set()
    while frontier:
        mod = frontier.pop()
        if mod not in module_map:
            continue
        f = module_map[mod]
        if f in needed_files:
            continue
        needed_files.add(f)
        if f in seen_files:
            continue
        seen_files.add(f)
        frontier |= instantiated_modules(f)
    return sorted(needed_files)

def main():
    keep = "--keep" in sys.argv
    args = [a for a in sys.argv[1:] if a != "--keep"]
    pattern = args[0] if args else ""

    module_map = build_module_map()
    tbs = sorted(glob.glob(os.path.join(REPO, "sim", "*_tb.v")))
    tbs = [t for t in tbs if pattern in os.path.basename(t)]

    results = []
    workdir = tempfile.mkdtemp(prefix="regression_")
    for tb in tbs:
        name = os.path.basename(tb)[:-len("_tb.v")]
        files = resolve_deps(tb, module_map)
        out = os.path.join(workdir, name + ".out")
        cc = subprocess.run(
            ["iverilog", "-g2012", "-o", out] + files,
            cwd=REPO, capture_output=True, text=True,
        )
        if cc.returncode != 0:
            if name in EXPECTED_COMPILE_FAIL:
                results.append((name, "PASS (compile-time guard fired as designed)", cc.stderr.strip().splitlines()[-2:], files))
            else:
                results.append((name, "COMPILE_FAIL", cc.stderr.strip(), files))
            continue
        elif name in EXPECTED_COMPILE_FAIL:
            results.append((name, "FAIL (was expected to NOT compile, but it compiled)", [], files))
            continue
        run = subprocess.run(["vvp", out], cwd=REPO, capture_output=True, text=True, timeout=120)
        combined = run.stdout + run.stderr
        low = combined.lower()
        if name in BENCHMARK_NO_VERDICT:
            status = "BENCHMARK (no pass/fail verdict by design)" if run.returncode == 0 else f"RUNTIME_ERROR(rc={run.returncode})"
        elif "fail" in low and "PASSED" not in combined and "PASS" not in combined:
            status = "FAIL"
        elif run.returncode != 0:
            status = f"RUNTIME_ERROR(rc={run.returncode})"
        elif "PASSED" in combined or "PASS" in combined or "ALL TESTS" in combined:
            status = "PASS"
        else:
            status = "UNKNOWN (no PASS/FAIL marker found)"
        results.append((name, status, combined.strip().splitlines()[-3:], files))

    print(f"{'TESTBENCH':45s} {'RESULT'}")
    print("-" * 70)
    n_pass = n_fail = n_other = 0
    for name, status, tail, files in results:
        print(f"{name:45s} {status}")
        if status.startswith("PASS"):
            n_pass += 1
        elif status.startswith("BENCHMARK"):
            n_other += 1
            for line in (tail if isinstance(tail, list) else [tail]):
                print(f"    | {line}")
        elif status.startswith("FAIL") or status.startswith("COMPILE_FAIL") or status.startswith("RUNTIME_ERROR"):
            n_fail += 1
            for line in (tail if isinstance(tail, list) else [tail]):
                print(f"    | {line}")
        else:
            n_other += 1
            for line in (tail if isinstance(tail, list) else [tail]):
                print(f"    | {line}")

    print("-" * 70)
    print(f"TOTAL: {len(results)}  PASS: {n_pass}  FAIL/ERROR: {n_fail}  OTHER/UNKNOWN: {n_other}")

    if not keep:
        import shutil
        shutil.rmtree(workdir, ignore_errors=True)
    else:
        print(f"Compiled binaries kept in {workdir}")

    sys.exit(1 if (n_fail or n_other) else 0)

if __name__ == "__main__":
    main()
