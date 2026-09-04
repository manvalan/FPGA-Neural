`timescale 1ns/1ps

// ================================================================
// MAC8 TESTBENCH -- balanced binary adder tree (certification
// campaign, aspect C.1)
//
// rtl/mac8.v had NO dedicated unit-level testbench before this
// (docs/validation/00-inventario.md §0.4/§0.5): only indirect coverage
// through neuron_parallel_tb.v, always at whatever single PARALLEL that
// testbench happens to use. A tree-wiring bug (swapped/duplicated/
// dropped lane) at a DIFFERENT PARALLEL than what neuron_parallel_tb.v
// exercises would go completely undetected.
//
// Checked at PARALLEL=2, 8 (the module's own default/namesake), and 32
// -- the extremes actually used across this project's own benchmarks
// (docs/FPGA-Neural-Datapatch-Benchmark.md), not just the one value a
// single higher-level test happens to pick.
//
// Oracle: tools/validation/mac_oracle.py's mac8_full() -- an
// independent Python model (two's complement tree-sum from first
// principles). Vectors pre-generated per PARALLEL
// (tools/validation/mac8_tree_p{2,8,32}.hex), three families each:
//   1. Structural (x=[1..PARALLEL], w=1, ascending AND reversed lane
//      order): the expected sum PARALLEL*(PARALLEL+1)/2 only comes out
//      right if every lane is summed EXACTLY once -- catches a
//      swapped/duplicated/dropped tree input that random testing could
//      miss by chance (a duplicate+drop pair can cancel out on some
//      random inputs but never on this exact structural pattern).
//   2. 300 realistic random INT8 (x,w) pairs per PARALLEL with a
//      boundary-swept acc_in -- matches the REAL wiring in
//      neuron_parallel.v (acc_in = running accumulator across
//      previous MAC groups, NOT hardwired to 0).
//   3. Adversarial worst-case product magnitude
//      (x=w=-128 -> +16384/lane, or x=-128,w=127 -> -16256/lane) at
//      every lane simultaneously, with boundary acc_in near the
//      ACC_WIDTH=32 edge -- confirms the tree's wraparound behavior is
//      well-defined two's complement, not X/undefined, even though
//      this magnitude is far beyond what any realistic N_INPUTS<=256
//      layer would ever accumulate to (documented, not asserted as a
//      real operating condition).
// ================================================================

module tb;

    localparam DATA_WIDTH = 8;
    localparam ACC_WIDTH  = 32;

    integer total_errors;
    integer total_checked;

    // ------------------------------------------------------------
    // PARALLEL = 2
    // ------------------------------------------------------------
    localparam P2 = 2;
    localparam W2 = 16*P2 + 64;
    reg  [W2-1:0] vec2 [0:312];
    reg  signed [DATA_WIDTH*P2-1:0] x_bus2, w_bus2;
    reg  signed [ACC_WIDTH-1:0] acc_in2;
    wire signed [ACC_WIDTH-1:0] acc_out2;
    reg  signed [ACC_WIDTH-1:0] expected2;
    integer li2;

    mac8 #(.DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH), .PARALLEL(P2)) dut2 (
        .x_bus(x_bus2), .w_bus(w_bus2), .acc_in(acc_in2), .acc_out(acc_out2)
    );

    // ------------------------------------------------------------
    // PARALLEL = 8 (mac8's own namesake default)
    // ------------------------------------------------------------
    localparam P8 = 8;
    localparam W8 = 16*P8 + 64;
    reg  [W8-1:0] vec8 [0:312];
    reg  signed [DATA_WIDTH*P8-1:0] x_bus8, w_bus8;
    reg  signed [ACC_WIDTH-1:0] acc_in8;
    wire signed [ACC_WIDTH-1:0] acc_out8;
    reg  signed [ACC_WIDTH-1:0] expected8;
    integer li8;

    mac8 #(.DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH), .PARALLEL(P8)) dut8 (
        .x_bus(x_bus8), .w_bus(w_bus8), .acc_in(acc_in8), .acc_out(acc_out8)
    );

    // ------------------------------------------------------------
    // PARALLEL = 32
    // ------------------------------------------------------------
    localparam P32 = 32;
    localparam W32 = 16*P32 + 64;
    reg  [W32-1:0] vec32 [0:312];
    reg  signed [DATA_WIDTH*P32-1:0] x_bus32, w_bus32;
    reg  signed [ACC_WIDTH-1:0] acc_in32;
    wire signed [ACC_WIDTH-1:0] acc_out32;
    reg  signed [ACC_WIDTH-1:0] expected32;
    integer li32;

    mac8 #(.DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH), .PARALLEL(P32)) dut32 (
        .x_bus(x_bus32), .w_bus(w_bus32), .acc_in(acc_in32), .acc_out(acc_out32)
    );

    initial begin
        total_errors  = 0;
        total_checked = 0;

        // ---- PARALLEL = 2 ----
        $readmemh("tools/validation/mac8_tree_p2.hex", vec2);
        $display("--- PARALLEL=2: 313 vectors ---");
        for (li2 = 0; li2 < 313; li2 = li2 + 1) begin
            for (integer lane = 0; lane < P2; lane = lane + 1) begin
                x_bus2[lane*8 +: 8] = vec2[li2][W2-1-16*lane -: 8];
                w_bus2[lane*8 +: 8] = vec2[li2][W2-1-16*lane-8 -: 8];
            end
            acc_in2   = vec2[li2][63:32];
            expected2 = vec2[li2][31:0];
            #1;
            total_checked = total_checked + 1;
            if (acc_out2 !== expected2) begin
                total_errors = total_errors + 1;
                $display("MISMATCH P2 idx=%0d: got=%0d expected=%0d", li2, acc_out2, expected2);
            end
        end

        // ---- PARALLEL = 8 ----
        $readmemh("tools/validation/mac8_tree_p8.hex", vec8);
        $display("--- PARALLEL=8: 313 vectors ---");
        for (li8 = 0; li8 < 313; li8 = li8 + 1) begin
            for (integer lane = 0; lane < P8; lane = lane + 1) begin
                x_bus8[lane*8 +: 8] = vec8[li8][W8-1-16*lane -: 8];
                w_bus8[lane*8 +: 8] = vec8[li8][W8-1-16*lane-8 -: 8];
            end
            acc_in8   = vec8[li8][63:32];
            expected8 = vec8[li8][31:0];
            #1;
            total_checked = total_checked + 1;
            if (acc_out8 !== expected8) begin
                total_errors = total_errors + 1;
                $display("MISMATCH P8 idx=%0d: got=%0d expected=%0d", li8, acc_out8, expected8);
            end
        end

        // ---- PARALLEL = 32 ----
        $readmemh("tools/validation/mac8_tree_p32.hex", vec32);
        $display("--- PARALLEL=32: 313 vectors ---");
        for (li32 = 0; li32 < 313; li32 = li32 + 1) begin
            for (integer lane = 0; lane < P32; lane = lane + 1) begin
                x_bus32[lane*8 +: 8] = vec32[li32][W32-1-16*lane -: 8];
                w_bus32[lane*8 +: 8] = vec32[li32][W32-1-16*lane-8 -: 8];
            end
            acc_in32   = vec32[li32][63:32];
            expected32 = vec32[li32][31:0];
            #1;
            total_checked = total_checked + 1;
            if (acc_out32 !== expected32) begin
                total_errors = total_errors + 1;
                $display("MISMATCH P32 idx=%0d: got=%0d expected=%0d", li32, acc_out32, expected32);
            end
        end

        $display("--- TOTAL: checked=%0d errors=%0d ---", total_checked, total_errors);
        if (total_errors == 0)
            $display("ALL TESTS PASSED (%0d vectors across PARALLEL=2/8/32, 0 mismatches against independent Python oracle)", total_checked);
        else
            $display("FAILED: %0d/%0d vectors mismatched", total_errors, total_checked);
        $finish;
    end

endmodule
