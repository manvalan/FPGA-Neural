#!/usr/bin/env python3

import csv
import json
import re
import subprocess
import sys
from pathlib import Path


# ============================================================
# PATHS
# ============================================================

ROOT = Path(__file__).resolve().parents[1]

RTL_DIR = ROOT / "rtl"
SYNTH_ROOT = ROOT / "synth" / "ecp5"
RESULT_ROOT = ROOT / "benchmark_results"

YOSYS = "/opt/homebrew/bin/yosys"
NEXTPNR = "/tmp/nextpnr/build/nextpnr-ecp5"


# ============================================================
# FPGA
# ============================================================

DEVICE = "LFE5U-45F-8BG381"
NEXT_PNR_DEVICE = "45k"
PACKAGE = "CABGA381"
SPEED_GRADE = "8"

TARGET_FREQ_MHZ = 80.0


# ============================================================
# NEURAL NETWORK
# ============================================================

DATA_WIDTH = 8
ACC_WIDTH = 32

N_INPUTS = 256
N_NEURONS = 4

PARALLELS = [8, 4, 2]


# ============================================================
# RTL
#
# Same source list as the validated ECP5 synthesis flow.
# ============================================================

RTL_FILES = [
    RTL_DIR / "mac_unit.v",
    RTL_DIR / "mac8.v",
    RTL_DIR / "neuron_parallel.v",
    RTL_DIR / "layer.v",
]


# ============================================================
# COMMAND
# ============================================================

def run_command(cmd, cwd=None, log_file=None):
    print()
    print("-" * 80)
    print("COMMAND:")
    print(" ".join(str(x) for x in cmd))
    print("-" * 80)

    result = subprocess.run(
        [str(x) for x in cmd],
        cwd=str(cwd) if cwd else None,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )

    output = result.stdout

    if log_file is not None:
        log_file.parent.mkdir(parents=True, exist_ok=True)
        log_file.write_text(output)

    print(output)

    if result.returncode != 0:
        raise RuntimeError(
            f"Command failed with exit code {result.returncode}"
        )

    return output


# ============================================================
# CHECK TOOLS
# ============================================================

def check_tools():
    if not Path(YOSYS).exists():
        raise RuntimeError(f"Yosys not found: {YOSYS}")

    if not Path(NEXTPNR).exists():
        raise RuntimeError(f"nextpnr-ecp5 not found: {NEXTPNR}")

    for path in RTL_FILES:
        if not path.exists():
            raise RuntimeError(f"RTL file not found: {path}")


# ============================================================
# GENERATE TOP
# ============================================================

def generate_top(parallel, top_v):
    """
    Benchmark wrapper.

    IMPORTANT:
    - Do NOT expose x_bus / weights_bus / bias_bus as top-level I/O.
    - The ECP5 has only 245 physical I/O.
    - The neural-network vectors are generated internally.
    - clk/reset/start remain real inputs so the sequential datapath
      cannot be reduced to constants.
    - y_bus is a real output so the result remains observable.
    """

    x_bits = DATA_WIDTH * N_INPUTS
    w_bits = DATA_WIDTH * N_INPUTS * N_NEURONS
    b_bits = DATA_WIDTH * N_NEURONS
    y_bits = DATA_WIDTH * N_NEURONS

    text = f"""
module top #(
    parameter DATA_WIDTH = {DATA_WIDTH},
    parameter N_INPUTS   = {N_INPUTS},
    parameter N_NEURONS  = {N_NEURONS},
    parameter PARALLEL   = {parallel},
    parameter ACC_WIDTH  = {ACC_WIDTH}
)(
    input  wire clk,
    input  wire rst,
    input  wire start,

    output wire signed [{y_bits - 1}:0] y_bus,
    output wire busy,
    output wire done
);

    localparam X_BITS = DATA_WIDTH * N_INPUTS;
    localparam W_BITS = DATA_WIDTH * N_INPUTS * N_NEURONS;
    localparam B_BITS = DATA_WIDTH * N_NEURONS;

    /*
     * Internal neural-network data.
     *
     * These are deliberately registers, not parameters/constants.
     * This prevents the complete datapath from disappearing during
     * synthesis.
     */

    reg signed [X_BITS-1:0] x_bus;
    reg signed [W_BITS-1:0] weights_bus;
    reg signed [B_BITS-1:0] bias_bus;

    integer i;
    integer n;

    /*
     * Deterministic initialization.
     *
     * The actual datapath remains present because the vectors are
     * stored in registers and loaded through the clocked process.
     */

    always @(posedge clk) begin
        if (rst) begin

            x_bus       <= '0;
            weights_bus <= '0;
            bias_bus    <= '0;

        end
        else if (start) begin

            /*
             * INT8 input vector.
             *
             * Pattern:
             *   -16 ... +15
             */

            for (i = 0; i < N_INPUTS; i = i + 1) begin
                x_bus[i*DATA_WIDTH +: DATA_WIDTH]
                    <= ((i * 17 + 3) % 31) - 15;
            end

            /*
             * INT8 weights.
             */

            for (n = 0; n < N_NEURONS; n = n + 1) begin

                for (i = 0; i < N_INPUTS; i = i + 1) begin

                    weights_bus[
                        (n*N_INPUTS+i)*DATA_WIDTH
                        +: DATA_WIDTH
                    ]
                        <= ((n * 29 + i * 13 + 5) % 31) - 15;

                end

            end

            /*
             * INT8 biases.
             */

            for (n = 0; n < N_NEURONS; n = n + 1) begin

                bias_bus[
                    n*DATA_WIDTH
                    +: DATA_WIDTH
                ]
                    <= ((n * 7 + 1) % 9) - 4;

            end

        end
    end


    /*
     * Real neural-network layer.
     */

    layer #(
        .DATA_WIDTH(DATA_WIDTH),
        .N_INPUTS(N_INPUTS),
        .N_NEURONS(N_NEURONS),
        .PARALLEL(PARALLEL),
        .ACC_WIDTH(ACC_WIDTH)
    ) dut (
        .clk(clk),
        .rst(rst),
        .start(start),

        .x_bus(x_bus),
        .weights_bus(weights_bus),
        .bias_bus(bias_bus),

        .y_bus(y_bus),
        .busy(busy),
        .done(done)
    );

endmodule
"""

    top_v.parent.mkdir(parents=True, exist_ok=True)
    top_v.write_text(text.strip() + "\n")


# ============================================================
# SYNTHESIS SCRIPT
# ============================================================

def generate_synth_script(top_v, synth_ys, top_json):

    rtl_paths = [
        str(path)
        for path in RTL_FILES
    ]

    lines = []

    lines.append("read_verilog -sv \\")

    for index, rtl in enumerate(rtl_paths):
        lines.append(f"{rtl} \\")

    lines.append(str(top_v))
    lines.append("")
    lines.append("hierarchy -top top")
    lines.append("")
    lines.append("proc")
    lines.append("flatten")
    lines.append("opt")
    lines.append("memory")
    lines.append("opt")
    lines.append("techmap")
    lines.append("opt")
    lines.append("abc -g simple")
    lines.append("clean")
    lines.append("")
    lines.append(
        f'synth_ecp5 -top top -json {top_json}'
    )

    synth_ys.parent.mkdir(
        parents=True,
        exist_ok=True
    )

    synth_ys.write_text(
        "\n".join(lines) + "\n"
    )


# ============================================================
# LPF
# ============================================================

def generate_lpf(lpf):
    """
    No physical pin constraints.

    nextpnr will automatically place the small number of
    top-level I/Os.
    """

    lpf.parent.mkdir(
        parents=True,
        exist_ok=True
    )

    lpf.write_text("")


# ============================================================
# NEXTPNR
# ============================================================

def run_nextpnr(
    top_json,
    lpf,
    config,
    log
):

    cmd = [
        NEXTPNR,
        f"--{NEXT_PNR_DEVICE}",
        "--package",
        PACKAGE,
        "--speed",
        SPEED_GRADE,
        "--json",
        str(top_json),
        "--lpf",
        str(lpf),
        "--lpf-allow-unconstrained",
        "--freq",
        str(TARGET_FREQ_MHZ),
        "--textcfg",
        str(config),
    ]

    return run_command(
        cmd,
        cwd=ROOT,
        log_file=log
    )


# ============================================================
# PARSER
# ============================================================

def parse_nextpnr_report(text):

    # --------------------------------------------------------
    # LUT4
    # --------------------------------------------------------

    lut_matches = re.findall(
        r"Total LUT4s:\s*([0-9]+)\s*/",
        text
    )

    lut4 = (
        int(lut_matches[-1])
        if lut_matches
        else None
    )

    # --------------------------------------------------------
    # DFF
    # --------------------------------------------------------

    ff_matches = re.findall(
        r"Total DFFs:\s*([0-9]+)\s*/",
        text
    )

    dff = (
        int(ff_matches[-1])
        if ff_matches
        else None
    )

    # --------------------------------------------------------
    # DSP
    # --------------------------------------------------------

    dsp_matches = re.findall(
        r"MULT18X18D:\s*([0-9]+)\s*/",
        text
    )

    dsp = (
        int(dsp_matches[-1])
        if dsp_matches
        else None
    )

    # --------------------------------------------------------
    # RAM
    # --------------------------------------------------------

    ram_matches = re.findall(
        r"DP16KD:\s*([0-9]+)\s*/",
        text
    )

    dp16kd = (
        int(ram_matches[-1])
        if ram_matches
        else None
    )

    # --------------------------------------------------------
    # IO
    # --------------------------------------------------------

    io_matches = re.findall(
        r"TRELLIS_IO:\s*([0-9]+)\s*/",
        text
    )

    io = (
        int(io_matches[-1])
        if io_matches
        else None
    )

    # --------------------------------------------------------
    # TRELLIS FF
    # --------------------------------------------------------

    trellis_ff_matches = re.findall(
        r"TRELLIS_FF:\s*([0-9]+)\s*/",
        text
    )

    trellis_ff = (
        int(trellis_ff_matches[-1])
        if trellis_ff_matches
        else None
    )

    # --------------------------------------------------------
    # TRELLIS COMB
    # --------------------------------------------------------

    trellis_comb_matches = re.findall(
        r"TRELLIS_COMB:\s*([0-9]+)\s*/",
        text
    )

    trellis_comb = (
        int(trellis_comb_matches[-1])
        if trellis_comb_matches
        else None
    )

    # --------------------------------------------------------
    # FMAX
    #
    # nextpnr can print more than one Fmax.
    # The LAST one is the final post-route result.
    # --------------------------------------------------------

    freq_matches = re.findall(
        r"Max frequency for clock .*?:\s*"
        r"([0-9]+(?:\.[0-9]+)?)\s*MHz",
        text
    )

    fmax = (
        float(freq_matches[-1])
        if freq_matches
        else None
    )

    # --------------------------------------------------------
    # LOGIC / ROUTING
    #
    # Again use the final occurrence.
    # --------------------------------------------------------

    timing_matches = re.findall(
        r"([0-9]+(?:\.[0-9]+)?)\s*ns\s+logic,\s*"
        r"([0-9]+(?:\.[0-9]+)?)\s*ns\s+routing",
        text
    )

    if timing_matches:

        logic_ns = float(
            timing_matches[-1][0]
        )

        routing_ns = float(
            timing_matches[-1][1]
        )

    else:

        logic_ns = None
        routing_ns = None

    # --------------------------------------------------------
    # TCRIT
    # --------------------------------------------------------

    if (
        logic_ns is not None
        and routing_ns is not None
    ):

        tcrit_ns = (
            logic_ns +
            routing_ns
        )

    elif fmax is not None and fmax > 0:

        tcrit_ns = 1000.0 / fmax

    else:

        tcrit_ns = None

    return {
        "lut4": lut4,
        "ff": dff,
        "dsp": dsp,
        "dp16kd": dp16kd,
        "io": io,
        "trellis_ff": trellis_ff,
        "trellis_comb": trellis_comb,

        "fmax_mhz": fmax,

        "logic_ns": logic_ns,
        "routing_ns": routing_ns,
        "tcrit_ns": tcrit_ns,
    }


# ============================================================
# BENCHMARK ONE PARALLEL
# ============================================================

def benchmark_parallel(parallel):

    print()
    print("=" * 80)
    print(f"BENCHMARK P = {parallel}")
    print("=" * 80)

    out_dir = (
        SYNTH_ROOT /
        f"p{parallel}"
    )

    out_dir.mkdir(
        parents=True,
        exist_ok=True
    )

    top_v = out_dir / "top.v"
    synth_ys = out_dir / "synth.ys"
    top_json = out_dir / "top.json"
    lpf = out_dir / "top.lpf"
    config = out_dir / "top.config"

    yosys_log = out_dir / "yosys.log"
    nextpnr_log = out_dir / "nextpnr.log"

    # --------------------------------------------------------
    # TOP
    # --------------------------------------------------------

    generate_top(
        parallel,
        top_v
    )

    # --------------------------------------------------------
    # SYNTH SCRIPT
    # --------------------------------------------------------

    generate_synth_script(
        top_v,
        synth_ys,
        top_json
    )

    # --------------------------------------------------------
    # LPF
    # --------------------------------------------------------

    generate_lpf(lpf)

    # --------------------------------------------------------
    # YOSYS
    # --------------------------------------------------------

    run_command(
        [
            YOSYS,
            "-s",
            str(synth_ys)
        ],
        cwd=ROOT,
        log_file=yosys_log
    )

    if not top_json.exists():

        raise RuntimeError(
            f"Yosys did not generate {top_json}"
        )

    # --------------------------------------------------------
    # NEXTPNR
    # --------------------------------------------------------

    output = run_nextpnr(
        top_json,
        lpf,
        config,
        nextpnr_log
    )

    # --------------------------------------------------------
    # PARSE
    # --------------------------------------------------------

    metrics = parse_nextpnr_report(
        output
    )

    # --------------------------------------------------------
    # VALIDATION
    # --------------------------------------------------------

    required = [
        "fmax_mhz",
        "lut4",
        "ff",
        "dsp",
    ]

    for key in required:

        if metrics[key] is None:

            raise RuntimeError(
                f"Unable to parse {key} "
                f"for P={parallel}"
            )

    # --------------------------------------------------------
    # MAC COUNT
    # --------------------------------------------------------

    mac_total = (
        N_NEURONS *
        parallel
    )

    # --------------------------------------------------------
    # THROUGHPUT
    # --------------------------------------------------------

    mac_per_sec = (
        mac_total *
        metrics["fmax_mhz"] *
        1_000_000.0
    )

    mac_per_sec_m = (
        mac_per_sec /
        1_000_000.0
    )

    mac_per_sec_g = (
        mac_per_sec /
        1_000_000_000.0
    )

    # --------------------------------------------------------
    # TARGET
    # --------------------------------------------------------

    pass_80 = (
        metrics["fmax_mhz"] >=
        TARGET_FREQ_MHZ
    )

    # --------------------------------------------------------
    # RESULT
    # --------------------------------------------------------

    result = {

        "fpga": DEVICE,
        "package": PACKAGE,
        "speed_grade": SPEED_GRADE,

        "n_inputs": N_INPUTS,
        "n_neurons": N_NEURONS,

        "data_width": DATA_WIDTH,
        "acc_width": ACC_WIDTH,

        "parallel": parallel,

        "mac": mac_total,

        "fmax_mhz":
            metrics["fmax_mhz"],

        "lut4":
            metrics["lut4"],

        "ff":
            metrics["ff"],

        "dsp":
            metrics["dsp"],

        "dp16kd":
            metrics["dp16kd"],

        "io":
            metrics["io"],

        "trellis_ff":
            metrics["trellis_ff"],

        "trellis_comb":
            metrics["trellis_comb"],

        "logic_ns":
            metrics["logic_ns"],

        "routing_ns":
            metrics["routing_ns"],

        "tcrit_ns":
            metrics["tcrit_ns"],

        "mac_per_sec_m":
            mac_per_sec_m,

        "mac_per_sec_g":
            mac_per_sec_g,

        "pass_80mhz":
            pass_80,
    }

    # --------------------------------------------------------
    # PRINT
    # --------------------------------------------------------

    print()
    print("RESULT")
    print("-" * 50)

    print(
        f"PARALLEL       : {parallel}"
    )

    print(
        f"MAC            : {mac_total}"
    )

    print(
        f"Fmax           : "
        f"{metrics['fmax_mhz']:.2f} MHz"
    )

    print(
        f"LUT4           : "
        f"{metrics['lut4']}"
    )

    print(
        f"DFF            : "
        f"{metrics['ff']}"
    )

    print(
        f"DSP            : "
        f"{metrics['dsp']}"
    )

    if metrics["logic_ns"] is not None:

        print(
            f"Logic          : "
            f"{metrics['logic_ns']:.2f} ns"
        )

    if metrics["routing_ns"] is not None:

        print(
            f"Routing        : "
            f"{metrics['routing_ns']:.2f} ns"
        )

    if metrics["tcrit_ns"] is not None:

        print(
            f"Tcrit          : "
            f"{metrics['tcrit_ns']:.2f} ns"
        )

    print(
        f"Throughput     : "
        f"{mac_per_sec_g:.3f} GMAC/s"
    )

    print(
        f"80 MHz         : "
        f"{'PASS' if pass_80 else 'FAIL'}"
    )

    return result


# ============================================================
# WRITE RESULTS
# ============================================================

def write_results(results):

    RESULT_ROOT.mkdir(
        parents=True,
        exist_ok=True
    )

    json_path = (
        RESULT_ROOT /
        "fpga_benchmark.json"
    )

    csv_path = (
        RESULT_ROOT /
        "fpga_benchmark.csv"
    )

    data = {

        "benchmark": {

            "fpga": DEVICE,
            "package": PACKAGE,
            "speed_grade": SPEED_GRADE,

            "n_inputs": N_INPUTS,
            "n_neurons": N_NEURONS,

            "data_width": DATA_WIDTH,
            "acc_width": ACC_WIDTH,

            "target_freq_mhz":
                TARGET_FREQ_MHZ,

            "parallel_values":
                PARALLELS,
        },

        "results": results,
    }

    json_path.write_text(
        json.dumps(
            data,
            indent=2
        )
    )

    fieldnames = list(
        results[0].keys()
    )

    with csv_path.open(
        "w",
        newline=""
    ) as f:

        writer = csv.DictWriter(
            f,
            fieldnames=fieldnames
        )

        writer.writeheader()
        writer.writerows(results)

    return (
        json_path,
        csv_path
    )


# ============================================================
# SUMMARY
# ============================================================

def print_summary(results):

    print()
    print()
    print("=" * 105)
    print("FPGA-NEURAL BENCHMARK RESULTS")
    print("=" * 105)

    print(
        f"{'FPGA':24}"
        f"{'P':>4}"
        f"{'MAC':>7}"
        f"{'Fmax':>10}"
        f"{'LUT':>8}"
        f"{'FF':>8}"
        f"{'DSP':>8}"
        f"{'MAC/s':>14}"
        f"{'80MHz':>9}"
    )

    print("-" * 105)

    for r in results:

        print(
            f"{r['fpga']:24}"
            f"{r['parallel']:>4}"
            f"{r['mac']:>7}"
            f"{r['fmax_mhz']:>9.2f}"
            f"{r['lut4']:>8}"
            f"{r['ff']:>8}"
            f"{r['dsp']:>8}"
            f"{r['mac_per_sec_g']:>12.3f}G"
            f"{'PASS' if r['pass_80mhz'] else 'FAIL':>9}"
        )

    print("-" * 105)

    best_fmax = max(
        results,
        key=lambda r:
            r["fmax_mhz"]
    )

    best_throughput = max(
        results,
        key=lambda r:
            r["mac_per_sec_g"]
    )

    print()

    print(
        "BEST FMAX: "
        f"P={best_fmax['parallel']} "
        f"-> "
        f"{best_fmax['fmax_mhz']:.2f} MHz"
    )

    print(
        "BEST THROUGHPUT: "
        f"P={best_throughput['parallel']} "
        f"-> "
        f"{best_throughput['mac_per_sec_g']:.3f} GMAC/s"
    )

    print()


# ============================================================
# MAIN
# ============================================================

def main():

    print()
    print("=" * 80)
    print("FPGA-NEURAL ECP5 PARAMETRIC BENCHMARK")
    print("=" * 80)

    print(
        f"FPGA       : {DEVICE}"
    )

    print(
        f"Package    : {PACKAGE}"
    )

    print(
        f"Speed      : -{SPEED_GRADE}"
    )

    print(
        f"N_INPUTS   : {N_INPUTS}"
    )

    print(
        f"N_NEURONS  : {N_NEURONS}"
    )

    print(
        f"DATA_WIDTH : {DATA_WIDTH}"
    )

    print(
        f"ACC_WIDTH  : {ACC_WIDTH}"
    )

    print(
        f"PARALLEL   : {PARALLELS}"
    )

    print(
        f"TARGET     : "
        f"{TARGET_FREQ_MHZ:.0f} MHz"
    )

    check_tools()

    results = []

    for parallel in PARALLELS:

        result = benchmark_parallel(
            parallel
        )

        results.append(result)

    json_path, csv_path = (
        write_results(results)
    )

    print_summary(results)

    print(
        f"JSON: {json_path}"
    )

    print(
        f"CSV : {csv_path}"
    )


# ============================================================
# ENTRY POINT
# ============================================================

if __name__ == "__main__":

    try:

        main()

    except KeyboardInterrupt:

        print(
            "\nInterrupted."
        )

        sys.exit(130)

    except Exception as e:

        print()
        print("=" * 80)
        print("ERROR")
        print("=" * 80)
        print(str(e))

        sys.exit(1)