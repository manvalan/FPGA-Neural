`timescale 1ns/1ps

// ============================================================
// EXP-0056 -- isolated correctness check for priority_encoder_lsb.v
// against a trivial behavioral reference (linear scan, allowed to be
// slow since it is testbench-only), at both a small width (16,
// dependency_manager.v's own module default) and the real large width
// this fix targets (1024, the real N_NODES this project actually
// uses for D-Stress). Exhaustive at WIDTH=16 (65536 patterns), random
// at WIDTH=1024 (exhaustive is infeasible: 2^1024 patterns).
// ============================================================
module tb;
    localparam W_SMALL = 16;
    localparam IDXW_SMALL = $clog2(W_SMALL);

    reg  [W_SMALL-1:0] in_small;
    wire [IDXW_SMALL-1:0] idx_small;
    wire valid_small;

    priority_encoder_lsb #(.WIDTH(W_SMALL)) dut_small (
        .in(in_small), .idx(idx_small), .valid(valid_small)
    );

    localparam W_BIG = 1024;
    localparam IDXW_BIG = $clog2(W_BIG);

    reg  [W_BIG-1:0] in_big;
    wire [IDXW_BIG-1:0] idx_big;
    wire valid_big;

    priority_encoder_lsb #(.WIDTH(W_BIG)) dut_big (
        .in(in_big), .idx(idx_big), .valid(valid_big)
    );

    function automatic integer ref_lowest_set_bit(input [W_BIG-1:0] v, input integer width);
        integer k;
        begin
            ref_lowest_set_bit = -1;
            for (k = width-1; k >= 0; k = k - 1)
                if (v[k]) ref_lowest_set_bit = k;
        end
    endfunction

    integer errors, tests;
    integer i, ref_idx;
    integer seed;

    initial begin
        errors = 0; tests = 0; seed = 32'hDEC0DE;

        $display("=== TEST 1: WIDTH=16, exhaustive (65536 patterns) ===");
        for (i = 0; i < 65536; i = i + 1) begin
            in_small = i[W_SMALL-1:0];
            #1;
            ref_idx = ref_lowest_set_bit(i[W_BIG-1:0], W_SMALL);
            tests = tests + 1;
            if (ref_idx == -1) begin
                if (valid_small !== 1'b0) begin
                    $display("FAIL pattern=%b: expected valid=0, got valid=%b", in_small, valid_small);
                    errors = errors + 1;
                end
            end else begin
                if (valid_small !== 1'b1 || idx_small !== ref_idx[IDXW_SMALL-1:0]) begin
                    $display("FAIL pattern=%b: expected idx=%0d valid=1, got idx=%0d valid=%b",
                        in_small, ref_idx, idx_small, valid_small);
                    errors = errors + 1;
                end
            end
        end
        $display("  TEST 1: %0d/%0d passed", tests-errors, tests);

        $display("=== TEST 2: WIDTH=1024, targeted + random (10000 patterns) ===");
        // targeted: all-zero, single-bit at every position, all-ones
        in_big = {W_BIG{1'b0}};
        #1;
        tests = tests + 1;
        if (valid_big !== 1'b0) begin
            $display("FAIL all-zero: expected valid=0, got valid=%b", valid_big);
            errors = errors + 1;
        end
        for (i = 0; i < W_BIG; i = i + 1) begin
            in_big = {W_BIG{1'b0}};
            in_big[i] = 1'b1;
            #1;
            tests = tests + 1;
            if (valid_big !== 1'b1 || idx_big !== i[IDXW_BIG-1:0]) begin
                $display("FAIL single-bit@%0d: expected idx=%0d valid=1, got idx=%0d valid=%b",
                    i, i, idx_big, valid_big);
                errors = errors + 1;
            end
        end
        in_big = {W_BIG{1'b1}};
        #1;
        ref_idx = ref_lowest_set_bit(in_big, W_BIG);
        tests = tests + 1;
        if (valid_big !== 1'b1 || idx_big !== ref_idx[IDXW_BIG-1:0]) begin
            $display("FAIL all-ones: expected idx=%0d valid=1, got idx=%0d valid=%b",
                ref_idx, idx_big, valid_big);
            errors = errors + 1;
        end
        // random
        for (i = 0; i < 10000; i = i + 1) begin
            in_big = {$random(seed), $random(seed), $random(seed), $random(seed),
                      $random(seed), $random(seed), $random(seed), $random(seed),
                      $random(seed), $random(seed), $random(seed), $random(seed),
                      $random(seed), $random(seed), $random(seed), $random(seed),
                      $random(seed), $random(seed), $random(seed), $random(seed),
                      $random(seed), $random(seed), $random(seed), $random(seed),
                      $random(seed), $random(seed), $random(seed), $random(seed),
                      $random(seed), $random(seed), $random(seed), $random(seed)};
            #1;
            ref_idx = ref_lowest_set_bit(in_big, W_BIG);
            tests = tests + 1;
            if (ref_idx == -1) begin
                if (valid_big !== 1'b0) begin
                    $display("FAIL random iter=%0d: expected valid=0, got valid=%b", i, valid_big);
                    errors = errors + 1;
                end
            end else begin
                if (valid_big !== 1'b1 || idx_big !== ref_idx[IDXW_BIG-1:0]) begin
                    $display("FAIL random iter=%0d: expected idx=%0d valid=1, got idx=%0d valid=%b",
                        i, ref_idx, idx_big, valid_big);
                    errors = errors + 1;
                end
            end
        end
        $display("  TEST 2: %0d/%0d passed", tests-errors, tests);

        $display("=== %0d/%0d total, %0d errors ===", tests-errors, tests, errors);
        if (errors == 0) $display("ALL TESTS PASSED (tb_priority_encoder_lsb)");
        $finish;
    end
endmodule
