`timescale 1ns/1ps

// ================================================================
// BUG-002 REGRESSION TEST (certification campaign, aspect C.1,
// docs/validation/bugs.md) -- N_INPUTS=0, now FIXED.
//
// Originally: rtl/neuron_parallel.v:71's guard was a single condition
// (`N_INPUTS % PARALLEL != 0`) that did NOT fire for N_INPUTS=0 (since
// `0 % PARALLEL == 0` for any PARALLEL != 0), yet GROUPS =
// N_INPUTS/PARALLEL = 0 -- the exact degenerate condition the guard's
// own header comment says causes a hang. Confirmed hang on both
// verification planes at the time (200-cycle simulation watchdog,
// `x_bus`/`w_bus` left undriven under real `yosys synth_ecp5`).
//
// Fix (rtl/neuron_parallel.v): the elaboration-time guard now also
// rejects N_INPUTS==0 explicitly:
//     if (N_INPUTS == 0 || N_INPUTS % PARALLEL != 0) ...
// This file must now FAIL TO COMPILE/ELABORATE -- same pattern as the
// two deliberate negative tests, neuron_parallel_guard_negative_*_tb.v
// -- that failure IS the test, proving N_INPUTS=0 is rejected before
// it can ever reach runtime and hang.
//
// Verify with:
//   iverilog -g2012 -o /tmp/out rtl/*.v \
//       sim/neuron_parallel_bug002_n_inputs_zero_tb.v
//
// Expected: nonzero exit status and
//   "error: Unknown module type:
//    neuron_parallel_requires_N_INPUTS_multiple_of_PARALLEL"
//
// If BUG-002's guard is ever weakened or removed, this file will start
// compiling again -- do not "fix" that by deleting this test; restore
// the guard instead.
// ================================================================

module tb;

    localparam DATA_WIDTH = 8;
    localparam PARALLEL   = 2;
    localparam ACC_WIDTH  = 32;

    neuron_parallel #(
        .DATA_WIDTH(DATA_WIDTH), .N_INPUTS(0), .PARALLEL(PARALLEL), .ACC_WIDTH(ACC_WIDTH)
    ) u_invalid (
        .clk(1'b0), .rst(1'b0), .start(1'b0),
        .x_bus(), .w_bus(), .bias(8'sd0),
        .y(), .busy(), .done()
    );

endmodule
