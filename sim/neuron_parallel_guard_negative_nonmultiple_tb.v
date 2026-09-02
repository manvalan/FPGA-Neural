`timescale 1ns/1ps

// ================================================================
// NEGATIVE TEST - intentionally invalid parameter combination.
//
// This file must FAIL TO COMPILE/ELABORATE. That failure is the
// test: it proves the PARAMETER_ERROR_N_INPUTS_NOT_MULTIPLE_OF_PARALLEL
// guard in rtl/neuron_parallel.v rejects configurations where
// N_INPUTS is not an exact multiple of PARALLEL (Phase 2 finding:
// N_INPUTS=30, PARALLEL=8 used to silently drop the last 6 inputs
// instead of erroring).
//
// Verify with:
//   iverilog -g2012 -o /tmp/out rtl/*.v \
//       sim/neuron_parallel_guard_negative_nonmultiple_tb.v
//
// Expected: nonzero exit status and
//   "error: Unknown module type:
//    neuron_parallel_requires_N_INPUTS_multiple_of_PARALLEL"
// ================================================================

module tb;

    neuron_parallel #(
        .DATA_WIDTH(8),
        .N_INPUTS(30),
        .PARALLEL(8),
        .ACC_WIDTH(32)
    ) u_invalid (
        .clk(1'b0),
        .rst(1'b0),
        .start(1'b0),
        .x_bus(240'b0),
        .w_bus(240'b0),
        .bias(8'sd0),
        .y(),
        .busy(),
        .done()
    );

endmodule
