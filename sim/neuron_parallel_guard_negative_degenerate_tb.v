`timescale 1ns/1ps

// ================================================================
// NEGATIVE TEST - intentionally invalid parameter combination.
//
// This file must FAIL TO COMPILE/ELABORATE. That failure is the
// test: it proves the PARAMETER_ERROR_N_INPUTS_NOT_MULTIPLE_OF_PARALLEL
// guard in rtl/neuron_parallel.v rejects the degenerate case
// PARALLEL > N_INPUTS (Phase 2 finding: N_INPUTS=4, PARALLEL=8 used
// to leave GROUPS=0, causing the controller to hang forever instead
// of erroring).
//
// Verify with:
//   iverilog -g2012 -o /tmp/out rtl/*.v \
//       sim/neuron_parallel_guard_negative_degenerate_tb.v
//
// Expected: nonzero exit status and
//   "error: Unknown module type:
//    neuron_parallel_requires_N_INPUTS_multiple_of_PARALLEL"
// ================================================================

module tb;

    neuron_parallel #(
        .DATA_WIDTH(8),
        .N_INPUTS(4),
        .PARALLEL(8),
        .ACC_WIDTH(32)
    ) u_invalid (
        .clk(1'b0),
        .rst(1'b0),
        .start(1'b0),
        .x_bus(32'b0),
        .w_bus(32'b0),
        .bias(8'sd0),
        .y(),
        .busy(),
        .done()
    );

endmodule
