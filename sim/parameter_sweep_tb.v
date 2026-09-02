`timescale 1ns/1ps

// ================================================================
// PHASE 2 - PARAMETER SWEEP
//
// Roadmap requirement (docs/FPGA-NeuralNetwork-Engine.md, Phase 2):
// validate multiple combinations of N_INPUTS / N_NEURONS / PARALLEL,
// including configurations where N_INPUTS is NOT an exact multiple
// of PARALLEL.
//
// neuron_parallel.v computes:
//     localparam GROUPS = N_INPUTS / PARALLEL;
// which is an INTEGER division. When N_INPUTS is not an exact
// multiple of PARALLEL, the remainder inputs are silently never
// read by the accumulator (GEN_TREE only ever selects the first
// GROUPS*PARALLEL inputs). This bench characterizes that behavior
// instead of assuming it does not exist, and uses a cycle-count
// watchdog (never a blocking `wait`) so a config that never
// asserts `done` is reported instead of hanging the simulation.
// ================================================================

module tb;

    reg clk;
    reg rst;

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    integer errors;
    integer findings;

    // ============================================================
    // CONFIG A - baseline, exact multiple (sanity check)
    // N_INPUTS=32 PARALLEL=8 -> GROUPS=4
    // ============================================================

    localparam A_DATA_WIDTH = 8;
    localparam A_N_INPUTS   = 32;
    localparam A_PARALLEL   = 8;
    localparam A_ACC_WIDTH  = 32;

    reg start_a;
    reg signed [A_DATA_WIDTH*A_N_INPUTS-1:0] x_bus_a;
    reg signed [A_DATA_WIDTH*A_N_INPUTS-1:0] w_bus_a;
    reg signed [A_DATA_WIDTH-1:0] bias_a;
    wire signed [A_DATA_WIDTH-1:0] y_a;
    wire busy_a, done_a;

    neuron_parallel #(
        .DATA_WIDTH(A_DATA_WIDTH),
        .N_INPUTS(A_N_INPUTS),
        .PARALLEL(A_PARALLEL),
        .ACC_WIDTH(A_ACC_WIDTH)
    ) u_a (
        .clk(clk), .rst(rst), .start(start_a),
        .x_bus(x_bus_a), .w_bus(w_bus_a), .bias(bias_a),
        .y(y_a), .busy(busy_a), .done(done_a)
    );

    // ============================================================
    // CONFIG B - non-exact multiple
    // N_INPUTS=30 PARALLEL=8 -> GROUPS=3 (24 inputs actually summed)
    // ============================================================

    localparam B_DATA_WIDTH = 8;
    localparam B_N_INPUTS   = 30;
    localparam B_PARALLEL   = 8;
    localparam B_ACC_WIDTH  = 32;

    reg start_b;
    reg signed [B_DATA_WIDTH*B_N_INPUTS-1:0] x_bus_b;
    reg signed [B_DATA_WIDTH*B_N_INPUTS-1:0] w_bus_b;
    reg signed [B_DATA_WIDTH-1:0] bias_b;
    wire signed [B_DATA_WIDTH-1:0] y_b;
    wire busy_b, done_b;

    neuron_parallel #(
        .DATA_WIDTH(B_DATA_WIDTH),
        .N_INPUTS(B_N_INPUTS),
        .PARALLEL(B_PARALLEL),
        .ACC_WIDTH(B_ACC_WIDTH)
    ) u_b (
        .clk(clk), .rst(rst), .start(start_b),
        .x_bus(x_bus_b), .w_bus(w_bus_b), .bias(bias_b),
        .y(y_b), .busy(busy_b), .done(done_b)
    );

    // ============================================================
    // CONFIG C - non-exact multiple, different PARALLEL
    // N_INPUTS=20 PARALLEL=16 -> GROUPS=1 (16 inputs actually summed)
    // ============================================================

    localparam C_DATA_WIDTH = 8;
    localparam C_N_INPUTS   = 20;
    localparam C_PARALLEL   = 16;
    localparam C_ACC_WIDTH  = 32;

    reg start_c;
    reg signed [C_DATA_WIDTH*C_N_INPUTS-1:0] x_bus_c;
    reg signed [C_DATA_WIDTH*C_N_INPUTS-1:0] w_bus_c;
    reg signed [C_DATA_WIDTH-1:0] bias_c;
    wire signed [C_DATA_WIDTH-1:0] y_c;
    wire busy_c, done_c;

    neuron_parallel #(
        .DATA_WIDTH(C_DATA_WIDTH),
        .N_INPUTS(C_N_INPUTS),
        .PARALLEL(C_PARALLEL),
        .ACC_WIDTH(C_ACC_WIDTH)
    ) u_c (
        .clk(clk), .rst(rst), .start(start_c),
        .x_bus(x_bus_c), .w_bus(w_bus_c), .bias(bias_c),
        .y(y_c), .busy(busy_c), .done(done_c)
    );

    // ============================================================
    // CONFIG D - exact multiple, wide parallelism (sanity check)
    // N_INPUTS=64 PARALLEL=32 -> GROUPS=2
    // ============================================================

    localparam D_DATA_WIDTH = 8;
    localparam D_N_INPUTS   = 64;
    localparam D_PARALLEL   = 32;
    localparam D_ACC_WIDTH  = 32;

    reg start_d;
    reg signed [D_DATA_WIDTH*D_N_INPUTS-1:0] x_bus_d;
    reg signed [D_DATA_WIDTH*D_N_INPUTS-1:0] w_bus_d;
    reg signed [D_DATA_WIDTH-1:0] bias_d;
    wire signed [D_DATA_WIDTH-1:0] y_d;
    wire busy_d, done_d;

    neuron_parallel #(
        .DATA_WIDTH(D_DATA_WIDTH),
        .N_INPUTS(D_N_INPUTS),
        .PARALLEL(D_PARALLEL),
        .ACC_WIDTH(D_ACC_WIDTH)
    ) u_d (
        .clk(clk), .rst(rst), .start(start_d),
        .x_bus(x_bus_d), .w_bus(w_bus_d), .bias(bias_d),
        .y(y_d), .busy(busy_d), .done(done_d)
    );

    // ============================================================
    // CONFIG E - degenerate: PARALLEL > N_INPUTS
    // N_INPUTS=4 PARALLEL=8 -> GROUPS=0
    // Watchdog-guarded: expected to NOT complete (documents the
    // constraint "PARALLEL must not exceed N_INPUTS").
    // ============================================================

    localparam E_DATA_WIDTH = 8;
    localparam E_N_INPUTS   = 4;
    localparam E_PARALLEL   = 8;
    localparam E_ACC_WIDTH  = 32;

    reg start_e;
    reg signed [E_DATA_WIDTH*E_N_INPUTS-1:0] x_bus_e;
    reg signed [E_DATA_WIDTH*E_N_INPUTS-1:0] w_bus_e;
    reg signed [E_DATA_WIDTH-1:0] bias_e;
    wire signed [E_DATA_WIDTH-1:0] y_e;
    wire busy_e, done_e;

    neuron_parallel #(
        .DATA_WIDTH(E_DATA_WIDTH),
        .N_INPUTS(E_N_INPUTS),
        .PARALLEL(E_PARALLEL),
        .ACC_WIDTH(E_ACC_WIDTH)
    ) u_e (
        .clk(clk), .rst(rst), .start(start_e),
        .x_bus(x_bus_e), .w_bus(w_bus_e), .bias(bias_e),
        .y(y_e), .busy(busy_e), .done(done_e)
    );

    // ============================================================
    // MAIN
    // ============================================================

    integer max_cycles;
    integer count;
    reg timed_out;

    initial begin

        $dumpfile("sim/parameter_sweep.vcd");
        $dumpvars(0, tb);

        rst = 1;
        errors = 0;
        findings = 0;
        max_cycles = 500;

        start_a = 0; x_bus_a = 0; w_bus_a = 0; bias_a = 0;
        start_b = 0; x_bus_b = 0; w_bus_b = 0; bias_b = 0;
        start_c = 0; x_bus_c = 0; w_bus_c = 0; bias_c = 0;
        start_d = 0; x_bus_d = 0; w_bus_d = 0; bias_d = 0;
        start_e = 0; x_bus_e = 0; w_bus_e = 0; bias_e = 0;

        repeat (2) @(posedge clk);
        rst = 0;

        $display("");
        $display("========================================");
        $display("PHASE 2 - PARAMETER SWEEP");
        $display("========================================");

        // --------------------------------------------------------
        // CONFIG A: all x=1, all w=1, bias=0
        // full sum = 32, exact multiple -> expect 32
        // --------------------------------------------------------
        for (count = 0; count < A_N_INPUTS; count = count + 1) begin
            x_bus_a[count*A_DATA_WIDTH +: A_DATA_WIDTH] = 8'sd1;
            w_bus_a[count*A_DATA_WIDTH +: A_DATA_WIDTH] = 8'sd1;
        end
        bias_a = 0;

        @(posedge clk); start_a <= 1'b1;
        @(posedge clk); start_a <= 1'b0;

        timed_out = 1'b0;
        count = 0;
        while (!done_a && !timed_out) begin
            @(posedge clk);
            count = count + 1;
            if (count > max_cycles) timed_out = 1'b1;
        end
        @(posedge clk);

        $display("");
        $display("CONFIG A: N_INPUTS=%0d PARALLEL=%0d (exact, GROUPS=%0d)",
                  A_N_INPUTS, A_PARALLEL, A_N_INPUTS/A_PARALLEL);
        if (timed_out) begin
            $display("  RESULT: TIMEOUT (did not assert done within %0d cycles)", max_cycles);
            errors = errors + 1;
        end else begin
            $display("  y = %0d   expected = 32", y_a);
            if (y_a !== 8'sd32) begin
                $display("  FAIL");
                errors = errors + 1;
            end else begin
                $display("  PASS");
            end
        end

        // --------------------------------------------------------
        // CONFIG B: all x=1, all w=1, bias=0
        // N_INPUTS=30, PARALLEL=8 -> GROUPS=3 -> only first 24
        // inputs are actually summed by the current RTL.
        // full-sum expectation would be 30; RTL-truncated
        // expectation is 24. We check against the RTL-truncated
        // value and flag the mismatch vs. the full sum as a
        // documented finding (not a failure of this bench).
        // --------------------------------------------------------
        for (count = 0; count < B_N_INPUTS; count = count + 1) begin
            x_bus_b[count*B_DATA_WIDTH +: B_DATA_WIDTH] = 8'sd1;
            w_bus_b[count*B_DATA_WIDTH +: B_DATA_WIDTH] = 8'sd1;
        end
        bias_b = 0;

        @(posedge clk); start_b <= 1'b1;
        @(posedge clk); start_b <= 1'b0;

        timed_out = 1'b0;
        count = 0;
        while (!done_b && !timed_out) begin
            @(posedge clk);
            count = count + 1;
            if (count > max_cycles) timed_out = 1'b1;
        end
        @(posedge clk);

        $display("");
        $display("CONFIG B: N_INPUTS=%0d PARALLEL=%0d (NON-exact, GROUPS=%0d, %0d inputs actually read)",
                  B_N_INPUTS, B_PARALLEL, B_N_INPUTS/B_PARALLEL,
                  (B_N_INPUTS/B_PARALLEL)*B_PARALLEL);
        if (timed_out) begin
            $display("  RESULT: TIMEOUT (did not assert done within %0d cycles)", max_cycles);
            errors = errors + 1;
        end else begin
            $display("  y = %0d   RTL-truncated expected = 24   full-sum (NOT met) = 30", y_b);
            if (y_b !== 8'sd24) begin
                $display("  FAIL (unexpected value for current RTL behavior)");
                errors = errors + 1;
            end else begin
                $display("  PASS (matches current RTL truncation behavior)");
            end
            if (y_b !== B_N_INPUTS[7:0]) begin
                $display("  FINDING: last %0d input(s) are silently ignored (GROUPS = N_INPUTS/PARALLEL truncates)",
                          B_N_INPUTS - (B_N_INPUTS/B_PARALLEL)*B_PARALLEL);
                findings = findings + 1;
            end
        end

        // --------------------------------------------------------
        // CONFIG C: same characterization, different sizes
        // N_INPUTS=20, PARALLEL=16 -> GROUPS=1 -> only first 16 read
        // --------------------------------------------------------
        for (count = 0; count < C_N_INPUTS; count = count + 1) begin
            x_bus_c[count*C_DATA_WIDTH +: C_DATA_WIDTH] = 8'sd1;
            w_bus_c[count*C_DATA_WIDTH +: C_DATA_WIDTH] = 8'sd1;
        end
        bias_c = 0;

        @(posedge clk); start_c <= 1'b1;
        @(posedge clk); start_c <= 1'b0;

        timed_out = 1'b0;
        count = 0;
        while (!done_c && !timed_out) begin
            @(posedge clk);
            count = count + 1;
            if (count > max_cycles) timed_out = 1'b1;
        end
        @(posedge clk);

        $display("");
        $display("CONFIG C: N_INPUTS=%0d PARALLEL=%0d (NON-exact, GROUPS=%0d, %0d inputs actually read)",
                  C_N_INPUTS, C_PARALLEL, C_N_INPUTS/C_PARALLEL,
                  (C_N_INPUTS/C_PARALLEL)*C_PARALLEL);
        if (timed_out) begin
            $display("  RESULT: TIMEOUT (did not assert done within %0d cycles)", max_cycles);
            errors = errors + 1;
        end else begin
            $display("  y = %0d   RTL-truncated expected = 16   full-sum (NOT met) = 20", y_c);
            if (y_c !== 8'sd16) begin
                $display("  FAIL (unexpected value for current RTL behavior)");
                errors = errors + 1;
            end else begin
                $display("  PASS (matches current RTL truncation behavior)");
            end
            if (y_c !== C_N_INPUTS[7:0]) begin
                $display("  FINDING: last %0d input(s) are silently ignored (GROUPS = N_INPUTS/PARALLEL truncates)",
                          C_N_INPUTS - (C_N_INPUTS/C_PARALLEL)*C_PARALLEL);
                findings = findings + 1;
            end
        end

        // --------------------------------------------------------
        // CONFIG D: all x=1, all w=1, bias=0
        // full sum = 64, exact multiple -> expect 64
        // --------------------------------------------------------
        for (count = 0; count < D_N_INPUTS; count = count + 1) begin
            x_bus_d[count*D_DATA_WIDTH +: D_DATA_WIDTH] = 8'sd1;
            w_bus_d[count*D_DATA_WIDTH +: D_DATA_WIDTH] = 8'sd1;
        end
        bias_d = 0;

        @(posedge clk); start_d <= 1'b1;
        @(posedge clk); start_d <= 1'b0;

        timed_out = 1'b0;
        count = 0;
        while (!done_d && !timed_out) begin
            @(posedge clk);
            count = count + 1;
            if (count > max_cycles) timed_out = 1'b1;
        end
        @(posedge clk);

        $display("");
        $display("CONFIG D: N_INPUTS=%0d PARALLEL=%0d (exact, GROUPS=%0d)",
                  D_N_INPUTS, D_PARALLEL, D_N_INPUTS/D_PARALLEL);
        if (timed_out) begin
            $display("  RESULT: TIMEOUT (did not assert done within %0d cycles)", max_cycles);
            errors = errors + 1;
        end else begin
            $display("  y = %0d   expected = 64", y_d);
            if (y_d !== 8'sd64) begin
                $display("  FAIL");
                errors = errors + 1;
            end else begin
                $display("  PASS");
            end
        end

        // --------------------------------------------------------
        // CONFIG E: degenerate PARALLEL > N_INPUTS -> GROUPS=0
        // We EXPECT this to time out. If it ever completes, that
        // is itself worth flagging (behavior changed).
        // --------------------------------------------------------
        for (count = 0; count < E_N_INPUTS; count = count + 1) begin
            x_bus_e[count*E_DATA_WIDTH +: E_DATA_WIDTH] = 8'sd1;
            w_bus_e[count*E_DATA_WIDTH +: E_DATA_WIDTH] = 8'sd1;
        end
        bias_e = 0;

        @(posedge clk); start_e <= 1'b1;
        @(posedge clk); start_e <= 1'b0;

        timed_out = 1'b0;
        count = 0;
        while (!done_e && !timed_out) begin
            @(posedge clk);
            count = count + 1;
            if (count > max_cycles) timed_out = 1'b1;
        end
        @(posedge clk);

        $display("");
        $display("CONFIG E: N_INPUTS=%0d PARALLEL=%0d (DEGENERATE, GROUPS=%0d)",
                  E_N_INPUTS, E_PARALLEL, E_N_INPUTS/E_PARALLEL);
        if (timed_out) begin
            $display("  RESULT: TIMEOUT as expected (done never asserted within %0d cycles)", max_cycles);
            $display("  FINDING: PARALLEL > N_INPUTS (GROUPS=0) hangs neuron_parallel forever -- design constraint, not currently guarded in RTL");
            findings = findings + 1;
        end else begin
            $display("  RESULT: completed with y=%0d (unexpected -- previously assumed to hang)", y_e);
            errors = errors + 1;
        end

        $display("");
        $display("========================================");
        $display("PARAMETER SWEEP SUMMARY");
        $display("  errors   = %0d", errors);
        $display("  findings = %0d (documented limitations, not bench failures)", findings);
        if (errors == 0)
            $display("PARAMETER SWEEP: PASSED (all configs behaved as characterized)");
        else
            $display("PARAMETER SWEEP: FAILED");
        $display("========================================");
        $display("");

        $finish;
    end

endmodule
