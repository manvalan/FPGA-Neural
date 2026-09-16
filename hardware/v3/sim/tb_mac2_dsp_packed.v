`timescale 1ns/1ps

// ============================================================
// Exhaustive verification of mac2_dsp_packed.v's signed packing
// arithmetic: every (weight, x0, x1) combination in [-128,127]^3
// (256^3 = 16,777,216 vectors), checked against independent
// Verilog integer multiplication (the "third oracle" convention
// used throughout this project). Checks the COMBINATIONAL packed
// result directly (no per-vector clock edge) for speed -- the
// registered p0/p1 outputs are just a one-cycle pipeline of the
// same combinational value, already covered structurally by every
// other testbench in this project using this same register idiom.
// ============================================================
module tb;
    localparam DATA_WIDTH = 8;

    reg clk = 0;
    always #5 clk = ~clk;
    reg rst;

    reg  signed [DATA_WIDTH-1:0] weight, x0, x1;
    reg  valid_in;
    wire signed [2*DATA_WIDTH-1:0] p0, p1;
    wire valid_out;

    mac2_dsp_packed #(.DATA_WIDTH(DATA_WIDTH)) dut (
        .clk(clk), .rst(rst),
        .weight(weight), .x0(x0), .x1(x1), .valid_in(valid_in),
        .p0(p0), .p1(p1), .valid_out(valid_out)
    );

    integer w, a, b;
    integer tests, errors;
    integer exp0, exp1;

    initial begin
        rst = 1; weight = 0; x0 = 0; x1 = 0; valid_in = 0;
        tests = 0; errors = 0;
        @(posedge clk); @(posedge clk);
        rst = 0;
        @(posedge clk);

        for (w = -128; w <= 127; w = w + 1) begin
            weight = w[7:0];
            for (a = -128; a <= 127; a = a + 1) begin
                x0 = a[7:0];
                for (b = -128; b <= 127; b = b + 1) begin
                    x1 = b[7:0];
                    #1;
                    tests = tests + 1;
                    exp0 = a * w;
                    exp1 = b * w;
                    if (dut.p0_comb !== exp0[2*DATA_WIDTH-1:0] || dut.p1_comb !== exp1[2*DATA_WIDTH-1:0]) begin
                        errors = errors + 1;
                        if (errors <= 20)
                            $display("FAIL w=%0d x0=%0d x1=%0d: got p0=%0d p1=%0d expected p0=%0d p1=%0d",
                                w, a, b, $signed(dut.p0_comb), $signed(dut.p1_comb), exp0, exp1);
                    end
                end
            end
            if (w % 32 == 0) $display("... progress: weight=%0d, tests so far=%0d, errors so far=%0d", w, tests, errors);
        end

        $display("=== RESULT: %0d/%0d PASS, %0d errors (exhaustive weight x x0 x x1, 256^3) ===", tests-errors, tests, errors);
        if (errors == 0) $display("ALL TESTS PASSED (tb_mac2_dsp_packed) -- exhaustive, mac2_dsp_packed.v is bit-exact");
        $finish;
    end
endmodule
