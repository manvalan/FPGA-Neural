`timescale 1ns/1ps

// ============================================================
// EXP-0056 -- isolated correctness check for the N_SLOTS==16
// balanced max-tree added to nms_activation_fill_ctrl_v3_n16.v,
// against the SAME flat-scan reference the original module's own
// GEN_MAXTREE_FALLBACK uses (the two must always agree -- that
// fallback path is explicitly documented as "correct but not
// optimized", i.e. the golden reference for what ANY replacement
// must compute). Random 16-way max over 10000 vectors.
// ============================================================
module tb;
    reg [15:0] v [0:15];
    integer i, k, seed, errors, tests;
    reg [15:0] ref_max;

    // exact mirror of nms_activation_fill_ctrl_v3_n16.v's own
    // GEN_MAXTREE_N16 combinational tree
    wire [15:0] m0 = (v[0]  > v[1])  ? v[0]  : v[1];
    wire [15:0] m1 = (v[2]  > v[3])  ? v[2]  : v[3];
    wire [15:0] m2 = (v[4]  > v[5])  ? v[4]  : v[5];
    wire [15:0] m3 = (v[6]  > v[7])  ? v[6]  : v[7];
    wire [15:0] m4 = (v[8]  > v[9])  ? v[8]  : v[9];
    wire [15:0] m5 = (v[10] > v[11]) ? v[10] : v[11];
    wire [15:0] m6 = (v[12] > v[13]) ? v[12] : v[13];
    wire [15:0] m7 = (v[14] > v[15]) ? v[14] : v[15];
    wire [15:0] m01   = (m0  > m1)  ? m0  : m1;
    wire [15:0] m23   = (m2  > m3)  ? m2  : m3;
    wire [15:0] m45   = (m4  > m5)  ? m4  : m5;
    wire [15:0] m67   = (m6  > m7)  ? m6  : m7;
    wire [15:0] m0123 = (m01 > m23) ? m01 : m23;
    wire [15:0] m4567 = (m45 > m67) ? m45 : m67;
    wire [15:0] max_final = (m0123 > m4567) ? m0123 : m4567;

    initial begin
        errors = 0; tests = 0; seed = 32'hA5A5F00D;

        // targeted: all-zero, max at every single position
        for (k = 0; k < 16; k = k + 1) v[k] = 16'h0;
        #1; tests = tests + 1;
        if (max_final !== 16'h0) begin
            $display("FAIL all-zero: got %0d", max_final); errors = errors + 1;
        end
        for (i = 0; i < 16; i = i + 1) begin
            for (k = 0; k < 16; k = k + 1) v[k] = 16'h1;
            v[i] = 16'hFFFF;
            #1; tests = tests + 1;
            if (max_final !== 16'hFFFF) begin
                $display("FAIL max-at-%0d: got %0d", i, max_final); errors = errors + 1;
            end
        end

        // random
        for (i = 0; i < 10000; i = i + 1) begin
            ref_max = 16'h0;
            for (k = 0; k < 16; k = k + 1) begin
                v[k] = $random(seed);
                if (v[k] > ref_max) ref_max = v[k];
            end
            #1;
            tests = tests + 1;
            if (max_final !== ref_max) begin
                $display("FAIL random iter=%0d: expected %0d got %0d", i, ref_max, max_final);
                errors = errors + 1;
            end
        end

        $display("=== %0d/%0d passed, %0d errors ===", tests-errors, tests, errors);
        if (errors == 0) $display("ALL TESTS PASSED (tb_maxtree_n16)");
        $finish;
    end
endmodule
