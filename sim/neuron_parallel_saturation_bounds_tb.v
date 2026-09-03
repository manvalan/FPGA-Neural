`timescale 1ns/1ps

// ================================================================
// NEURON_PARALLEL SATURATION/ACTIVATION BOUNDARY TESTBENCH
//
// Timing-closure task: the saturation/ReLU comparisons in
// rtl/neuron_parallel.v were rewritten from arithmetic comparisons
// (`> 127`, `< -128`, `<= 0` -- a second 32-bit carry chain in
// series with the accumulator's own adder, the measured critical
// path) to bit-test form (wide AND/OR reductions). This testbench
// exists specifically to prove bit-exact equivalence at every
// saturation boundary called out in the task brief: final_acc =
// 126, 127, 128, 129, -128, -129, -1, 0, for BOTH ACT_NONE and
// ACT_RELU.
//
// N_INPUTS=PARALLEL=1 (single MAC lane) so final_acc = x*w + bias
// exactly, letting each test case hit its target accumulator value
// directly via a hand-picked (x, w, bias) triple -- no need to sum
// multiple groups.
// ================================================================

module tb;

    localparam DATA_WIDTH = 8;
    localparam N_INPUTS   = 1;
    localparam PARALLEL   = 1;
    localparam ACC_WIDTH  = 32;
    localparam CLK_PERIOD = 10.0;

    localparam ACT_NONE = 2'd0;
    localparam ACT_RELU = 2'd1;

    reg clk;
    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD / 2.0) clk = ~clk;
    end

    reg rst;
    reg start;
    reg signed [DATA_WIDTH-1:0] x_val, w_val, bias_val;
    reg [1:0] activation;

    wire signed [DATA_WIDTH-1:0] y;
    wire busy, done;

    neuron_parallel #(
        .DATA_WIDTH(DATA_WIDTH),
        .N_INPUTS(N_INPUTS),
        .PARALLEL(PARALLEL),
        .ACC_WIDTH(ACC_WIDTH)
    ) dut (
        .clk(clk), .rst(rst), .start(start),
        .x_bus(x_val), .w_bus(w_val), .bias(bias_val),
        .activation(activation),
        .n_inputs_real(N_INPUTS[15:0]),
        .y(y), .busy(busy), .done(done)
    );

    integer errors;

    task run_case(
        input signed [DATA_WIDTH-1:0] x,
        input signed [DATA_WIDTH-1:0] w,
        input signed [DATA_WIDTH-1:0] b,
        input [1:0] act,
        input signed [DATA_WIDTH-1:0] expected,
        input [255:0] name
    );
        begin
            @(negedge clk);
            x_val = x; w_val = w; bias_val = b; activation = act;
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
            wait (done);
            if (y !== expected) begin
                $display("FAIL %0s: x=%0d w=%0d bias=%0d act=%0d expected=%0d got=%0d",
                    name, x, w, b, act, expected, y);
                errors = errors + 1;
            end else begin
                $display("PASS %0s: x=%0d w=%0d bias=%0d act=%0d -> y=%0d",
                    name, x, w, b, act, y);
            end
            @(negedge clk);
        end
    endtask

    initial begin
        errors = 0;
        rst = 1'b1; start = 1'b0;
        x_val = 0; w_val = 0; bias_val = 0; activation = ACT_RELU;
        repeat (3) @(negedge clk);
        rst = 1'b0;
        @(negedge clk);

        $display("");
        $display("========================================");
        $display("NEURON_PARALLEL SATURATION BOUNDARY TEST");
        $display("========================================");

        // final_acc = 126 (x=1,w=126,bias=0)
        run_case(8'sd1, 8'sd126, 8'sd0,   ACT_NONE, 8'sd126, "acc=126 NONE");
        run_case(8'sd1, 8'sd126, 8'sd0,   ACT_RELU, 8'sd126, "acc=126 RELU");

        // final_acc = 127 (exact positive boundary, must NOT saturate)
        run_case(8'sd1, 8'sd127, 8'sd0,   ACT_NONE, 8'sd127, "acc=127 NONE");
        run_case(8'sd1, 8'sd127, 8'sd0,   ACT_RELU, 8'sd127, "acc=127 RELU");

        // final_acc = 128 (one past positive boundary, must saturate to 127)
        run_case(8'sd2, 8'sd64,  8'sd0,   ACT_NONE, 8'sd127, "acc=128 NONE");
        run_case(8'sd2, 8'sd64,  8'sd0,   ACT_RELU, 8'sd127, "acc=128 RELU");

        // final_acc = 129
        run_case(8'sd2, 8'sd64,  8'sd1,   ACT_NONE, 8'sd127, "acc=129 NONE");
        run_case(8'sd2, 8'sd64,  8'sd1,   ACT_RELU, 8'sd127, "acc=129 RELU");

        // final_acc = -128 (exact negative boundary, must NOT saturate under NONE)
        run_case(8'sd1, -8'sd128, 8'sd0,  ACT_NONE, -8'sd128, "acc=-128 NONE");
        run_case(8'sd1, -8'sd128, 8'sd0,  ACT_RELU, 8'sd0,    "acc=-128 RELU");

        // final_acc = -129 (one past negative boundary, must saturate to -128 under NONE)
        run_case(8'sd2, -8'sd64, -8'sd1,  ACT_NONE, -8'sd128, "acc=-129 NONE");
        run_case(8'sd2, -8'sd64, -8'sd1,  ACT_RELU, 8'sd0,    "acc=-129 RELU");

        // final_acc = -1
        run_case(8'sd1, -8'sd1,  8'sd0,   ACT_NONE, -8'sd1,   "acc=-1 NONE");
        run_case(8'sd1, -8'sd1,  8'sd0,   ACT_RELU, 8'sd0,    "acc=-1 RELU");

        // final_acc = 0
        run_case(8'sd0, 8'sd0,   8'sd0,   ACT_NONE, 8'sd0,    "acc=0 NONE");
        run_case(8'sd0, 8'sd0,   8'sd0,   ACT_RELU, 8'sd0,    "acc=0 RELU");

        $display("");
        if (errors == 0) begin
            $display("========================================");
            $display("SATURATION BOUNDARY TEST PASSED (0 errors)");
            $display("========================================");
        end else begin
            $display("========================================");
            $display("SATURATION BOUNDARY TEST FAILED (%0d errors)", errors);
            $display("========================================");
            $fatal;
        end

        $finish;
    end

endmodule
