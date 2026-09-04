`timescale 1ns/1ps

// ================================================================
// BUG-002 REGRESSION TRAP (certification campaign, aspect C.1,
// docs/validation/bugs.md) -- N_INPUTS=0 bypasses the elaboration-
// time guard and produces a confirmed, real hang.
//
// rtl/neuron_parallel.v:71's guard is a single condition:
//     if (N_INPUTS % PARALLEL != 0) ... force elaboration failure
// For N_INPUTS=0, `0 % PARALLEL == 0` for any PARALLEL != 0 -- the
// guard does NOT fire, yet GROUPS = N_INPUTS/PARALLEL = 0, the exact
// condition the guard's own header comment (lines 55-58) says causes
// a hang. This module DOES compile/elaborate (unlike the two
// deliberate negative tests, neuron_parallel_guard_negative_*_tb.v)
// -- that is itself part of the bug: no elaboration-time protection
// exists for this specific boundary value.
//
// CONFIRMED on BOTH verification planes (§A.4):
//   - Simulation (this file): `start` never causes `busy` to assert;
//     `done` never pulses. Checked cycle-by-cycle for 200 cycles, not
//     a one-shot late check (an early investigation attempt used a
//     one-shot check-at-the-end and produced a methodologically
//     invalid "hang" verdict even for a KNOWN-GOOD N_INPUTS=2 sanity
//     config, because `done` is a documented single-cycle pulse,
//     rtl/neuron_parallel.v:207/227 -- see docs/validation/01-datapath.md
//     for the full self-correction narrative).
//   - Real synthesis: `yosys synth_ecp5` elaborates this exact
//     configuration with 0 reported problems. Root cause visible in
//     Yosys's own warnings: `x_bus`/`w_bus`, declared
//     `[DATA_WIDTH*N_INPUTS-1:0]` = `[-1:0]` for N_INPUTS=0, do NOT
//     collapse to a true zero-width bus -- Yosys (and, per this
//     simulation, Icarus) interpret a `[-1:0]` range as a genuine
//     2-bit vector (width = |MSB-LSB|+1 = |-1-0|+1 = 2), left
//     completely undriven ("Wire ... is used but has no driver").
//
// This test currently PASSES by confirming the bug's exact symptom is
// still present and unchanged -- it is a regression trap for the
// CURRENT, documented-as-open, unfixed behavior (docs/validation/
// bugs.md BUG-002), not a correctness assertion that this behavior is
// desirable. If/when BUG-002 is fixed (e.g. an explicit `N_INPUTS==0`
// elaboration guard is added), THIS test must be rewritten to expect
// the new, fixed behavior instead -- do not "fix" it by loosening the
// check.
// ================================================================

module tb;

    localparam DATA_WIDTH = 8;
    localparam PARALLEL   = 2;
    localparam ACC_WIDTH  = 32;

    reg clk;
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    reg rst, start;
    wire busy, done;
    wire signed [DATA_WIDTH-1:0] y;

    integer cyc;
    integer errors;

    neuron_parallel #(
        .DATA_WIDTH(DATA_WIDTH), .N_INPUTS(0), .PARALLEL(PARALLEL), .ACC_WIDTH(ACC_WIDTH)
    ) dut (
        .clk(clk), .rst(rst), .start(start),
        .x_bus(), .w_bus(), .bias(8'sd0),
        .y(y), .busy(busy), .done(done)
    );

    initial begin
        errors = 0;

        $display("--- TEST 1: N_INPUTS=0 elaborates without error (confirms guard gap) ---");
        // If this file failed to compile/elaborate, the guard would
        // have started covering N_INPUTS=0 too -- that would be a fix
        // landing, not a regression. This $display only runs if
        // elaboration succeeded, which it must, for the test below to
        // even execute.
        $display("  elaborated successfully -- guard did NOT fire for N_INPUTS=0 (as of this writing)");

        $display("--- TEST 2: start is accepted (busy asserts) within 200 cycles? ---");
        rst = 1; start = 0;
        repeat(3) @(posedge clk);
        rst = 0;
        @(posedge clk);
        start = 1;
        @(posedge clk);
        start = 0;

        cyc = 0;
        while (!done && !busy && cyc < 200) begin
            @(posedge clk);
            cyc = cyc + 1;
        end

        if (busy || done) begin
            // Behavior CHANGED from the confirmed-broken state -- this
            // is the "fix landed" case, not expected today.
            $display("  UNEXPECTED (relative to BUG-002 as currently documented): busy=%b done=%b at cycle %0d -- if this is a deliberate fix, update this test's expectations, don't just delete the check.", busy, done, cyc);
            errors = errors + 1;
        end else begin
            $display("  CONFIRMED (matches BUG-002, docs/validation/bugs.md): busy never asserted, done never pulsed in 200 cycles -- start was silently ineffective.");
        end

        if (errors == 0)
            $display("ALL TESTS PASSED (BUG-002 symptom reproduced exactly as documented -- this is a KNOWN, OPEN bug, not a clean bill of health for N_INPUTS=0)");
        else
            $display("FAILED: %0d unexpected result(s) -- see messages above", errors);
        $finish;
    end

endmodule
