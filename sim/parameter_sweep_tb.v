`timescale 1ns/1ps

// ================================================================
// PHASE 2 - PARAMETER SWEEP
//
// Roadmap requirement (docs/FPGA-NeuralNetwork-Engine.md, Phase 2):
// validate multiple combinations of N_INPUTS / N_NEURONS / PARALLEL.
//
// HISTORY:
// The original version of this bench included non-exact-multiple
// configs (N_INPUTS=30/PARALLEL=8, N_INPUTS=20/PARALLEL=16) and a
// degenerate PARALLEL>N_INPUTS config (N_INPUTS=4/PARALLEL=8). Those
// exposed two silent-failure modes in rtl/neuron_parallel.v:
//   - non-exact multiples: remainder inputs silently dropped (wrong
//     result, no error).
//   - PARALLEL > N_INPUTS: GROUPS=0, controller never asserts done
//     (permanent hang).
// Both are now rejected at elaboration time by the
// PARAMETER_ERROR_N_INPUTS_NOT_MULTIPLE_OF_PARALLEL guard added to
// rtl/neuron_parallel.v, so those three configs would no longer
// compile -- which is the intended fix. Their negative-test coverage
// (proving the guard actually fires) lives in:
//   sim/neuron_parallel_guard_negative_nonmultiple_tb.v
//   sim/neuron_parallel_guard_negative_degenerate_tb.v
//
// This bench now sweeps only VALID (exact-multiple) configurations,
// including PARALLEL=2 and PARALLEL=4 -- the two best-performing
// parallelism values found in docs/FPGA-Neural-Datapatch-Benchmark.md
// (PARALLEL=2 is the only tested config that meets 80 MHz; PARALLEL=4
// is a close second).
// ================================================================

module tb;

    reg clk;
    reg rst;

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    integer errors;

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
    // CONFIG F - PARALLEL=2 (best timing per benchmark)
    // N_INPUTS=32 PARALLEL=2 -> GROUPS=16
    // ============================================================

    localparam F_DATA_WIDTH = 8;
    localparam F_N_INPUTS   = 32;
    localparam F_PARALLEL   = 2;
    localparam F_ACC_WIDTH  = 32;

    reg start_f;
    reg signed [F_DATA_WIDTH*F_N_INPUTS-1:0] x_bus_f;
    reg signed [F_DATA_WIDTH*F_N_INPUTS-1:0] w_bus_f;
    reg signed [F_DATA_WIDTH-1:0] bias_f;
    wire signed [F_DATA_WIDTH-1:0] y_f;
    wire busy_f, done_f;

    neuron_parallel #(
        .DATA_WIDTH(F_DATA_WIDTH),
        .N_INPUTS(F_N_INPUTS),
        .PARALLEL(F_PARALLEL),
        .ACC_WIDTH(F_ACC_WIDTH)
    ) u_f (
        .clk(clk), .rst(rst), .start(start_f),
        .x_bus(x_bus_f), .w_bus(w_bus_f), .bias(bias_f),
        .y(y_f), .busy(busy_f), .done(done_f)
    );

    // ============================================================
    // CONFIG G - PARALLEL=4 (close second per benchmark)
    // N_INPUTS=32 PARALLEL=4 -> GROUPS=8
    // ============================================================

    localparam G_DATA_WIDTH = 8;
    localparam G_N_INPUTS   = 32;
    localparam G_PARALLEL   = 4;
    localparam G_ACC_WIDTH  = 32;

    reg start_g;
    reg signed [G_DATA_WIDTH*G_N_INPUTS-1:0] x_bus_g;
    reg signed [G_DATA_WIDTH*G_N_INPUTS-1:0] w_bus_g;
    reg signed [G_DATA_WIDTH-1:0] bias_g;
    wire signed [G_DATA_WIDTH-1:0] y_g;
    wire busy_g, done_g;

    neuron_parallel #(
        .DATA_WIDTH(G_DATA_WIDTH),
        .N_INPUTS(G_N_INPUTS),
        .PARALLEL(G_PARALLEL),
        .ACC_WIDTH(G_ACC_WIDTH)
    ) u_g (
        .clk(clk), .rst(rst), .start(start_g),
        .x_bus(x_bus_g), .w_bus(w_bus_g), .bias(bias_g),
        .y(y_g), .busy(busy_g), .done(done_g)
    );

    // ============================================================
    // MAIN
    //
    // Every config here is a VALID (exact-multiple) parameter
    // combination, so a plain blocking `wait(done)` is safe -- the
    // elaboration guard already rejects anything that could hang.
    // ============================================================

    integer count;

    initial begin

        $dumpfile("sim/parameter_sweep.vcd");
        $dumpvars(0, tb);

        rst = 1;
        errors = 0;

        start_a = 0; x_bus_a = 0; w_bus_a = 0; bias_a = 0;
        start_d = 0; x_bus_d = 0; w_bus_d = 0; bias_d = 0;
        start_f = 0; x_bus_f = 0; w_bus_f = 0; bias_f = 0;
        start_g = 0; x_bus_g = 0; w_bus_g = 0; bias_g = 0;

        repeat (2) @(posedge clk);
        rst = 0;

        $display("");
        $display("========================================");
        $display("PHASE 2 - PARAMETER SWEEP (guarded, valid configs only)");
        $display("========================================");

        // --------------------------------------------------------
        // CONFIG A: all x=1, all w=1, bias=0 -> expect 32
        // --------------------------------------------------------
        for (count = 0; count < A_N_INPUTS; count = count + 1) begin
            x_bus_a[count*A_DATA_WIDTH +: A_DATA_WIDTH] = 8'sd1;
            w_bus_a[count*A_DATA_WIDTH +: A_DATA_WIDTH] = 8'sd1;
        end
        bias_a = 0;

        @(posedge clk); start_a <= 1'b1;
        @(posedge clk); start_a <= 1'b0;
        wait (done_a);
        @(posedge clk);

        $display("");
        $display("CONFIG A: N_INPUTS=%0d PARALLEL=%0d (GROUPS=%0d)",
                  A_N_INPUTS, A_PARALLEL, A_N_INPUTS/A_PARALLEL);
        $display("  y = %0d   expected = 32", y_a);
        if (y_a !== 8'sd32) begin
            $display("  FAIL");
            errors = errors + 1;
        end else begin
            $display("  PASS");
        end

        // --------------------------------------------------------
        // CONFIG D: all x=1, all w=1, bias=0 -> expect 64
        // --------------------------------------------------------
        for (count = 0; count < D_N_INPUTS; count = count + 1) begin
            x_bus_d[count*D_DATA_WIDTH +: D_DATA_WIDTH] = 8'sd1;
            w_bus_d[count*D_DATA_WIDTH +: D_DATA_WIDTH] = 8'sd1;
        end
        bias_d = 0;

        @(posedge clk); start_d <= 1'b1;
        @(posedge clk); start_d <= 1'b0;
        wait (done_d);
        @(posedge clk);

        $display("");
        $display("CONFIG D: N_INPUTS=%0d PARALLEL=%0d (GROUPS=%0d)",
                  D_N_INPUTS, D_PARALLEL, D_N_INPUTS/D_PARALLEL);
        $display("  y = %0d   expected = 64", y_d);
        if (y_d !== 8'sd64) begin
            $display("  FAIL");
            errors = errors + 1;
        end else begin
            $display("  PASS");
        end

        // --------------------------------------------------------
        // CONFIG F: PARALLEL=2, all x=1, all w=1, bias=0 -> expect 32
        // --------------------------------------------------------
        for (count = 0; count < F_N_INPUTS; count = count + 1) begin
            x_bus_f[count*F_DATA_WIDTH +: F_DATA_WIDTH] = 8'sd1;
            w_bus_f[count*F_DATA_WIDTH +: F_DATA_WIDTH] = 8'sd1;
        end
        bias_f = 0;

        @(posedge clk); start_f <= 1'b1;
        @(posedge clk); start_f <= 1'b0;
        wait (done_f);
        @(posedge clk);

        $display("");
        $display("CONFIG F: N_INPUTS=%0d PARALLEL=%0d (GROUPS=%0d) -- best timing per benchmark",
                  F_N_INPUTS, F_PARALLEL, F_N_INPUTS/F_PARALLEL);
        $display("  y = %0d   expected = 32", y_f);
        if (y_f !== 8'sd32) begin
            $display("  FAIL");
            errors = errors + 1;
        end else begin
            $display("  PASS");
        end

        // --------------------------------------------------------
        // CONFIG G: PARALLEL=4, all x=1, all w=1, bias=0 -> expect 32
        // --------------------------------------------------------
        for (count = 0; count < G_N_INPUTS; count = count + 1) begin
            x_bus_g[count*G_DATA_WIDTH +: G_DATA_WIDTH] = 8'sd1;
            w_bus_g[count*G_DATA_WIDTH +: G_DATA_WIDTH] = 8'sd1;
        end
        bias_g = 0;

        @(posedge clk); start_g <= 1'b1;
        @(posedge clk); start_g <= 1'b0;
        wait (done_g);
        @(posedge clk);

        $display("");
        $display("CONFIG G: N_INPUTS=%0d PARALLEL=%0d (GROUPS=%0d) -- close second per benchmark",
                  G_N_INPUTS, G_PARALLEL, G_N_INPUTS/G_PARALLEL);
        $display("  y = %0d   expected = 32", y_g);
        if (y_g !== 8'sd32) begin
            $display("  FAIL");
            errors = errors + 1;
        end else begin
            $display("  PASS");
        end

        $display("");
        $display("========================================");
        if (errors == 0)
            $display("PARAMETER SWEEP: PASSED (%0d valid configs)", 4);
        else
            $display("PARAMETER SWEEP: FAILED (%0d errors)", errors);
        $display("========================================");
        $display("");

        $finish;
    end

endmodule
