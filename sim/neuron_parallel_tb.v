`timescale 1ns/1ps

module tb;

    parameter DATA_WIDTH = 8;
    parameter N_INPUTS   = 32;
    parameter PARALLEL   = 8;
    parameter ACC_WIDTH  = 32;

    reg clk;
    reg rst;
    reg start;

    reg signed [DATA_WIDTH*N_INPUTS-1:0] x_bus;
    reg signed [DATA_WIDTH*N_INPUTS-1:0] w_bus;
    reg signed [DATA_WIDTH-1:0] bias;
    reg [1:0] activation;
    reg [15:0] n_inputs_real;

    wire signed [DATA_WIDTH-1:0] y;
    wire busy;
    wire done;

    integer i;
    integer errors;

    localparam ACT_NONE = 2'd0;
    localparam ACT_RELU = 2'd1;

    neuron_parallel #(
        .DATA_WIDTH(DATA_WIDTH),
        .N_INPUTS(N_INPUTS),
        .PARALLEL(PARALLEL),
        .ACC_WIDTH(ACC_WIDTH)
    ) dut (
        .clk(clk),
        .rst(rst),
        .start(start),
        .x_bus(x_bus),
        .w_bus(w_bus),
        .bias(bias),
        .activation(activation),
        .n_inputs_real(n_inputs_real),
        .y(y),
        .busy(busy),
        .done(done)
    );

    // Clock: 10 ns
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // ------------------------------------------------------------
    // Start neuron and wait for completion
    // ------------------------------------------------------------
    task run_neuron;
        begin
            @(posedge clk);
            start = 1;

            @(posedge clk);
            start = 0;

            wait(done == 1);

            @(posedge clk);
        end
    endtask

    // ------------------------------------------------------------
    // TEST 1
    //
    // Diverse vector:
    //
    // x0 = 3   w0 = 2   -> 6
    // x1 = 4   w1 = -1  -> -4
    // x2 = 2   w2 = 1   -> 2
    //
    // bias = 1
    //
    // total = 6 - 4 + 2 + 1 = 5
    // ------------------------------------------------------------
    task test_1;
        begin
            $display("");
            $display("TEST 1: DIVERSE VECTOR");

            x_bus = 0;
            w_bus = 0;
            bias  = 8'sd1;

            x_bus[0*DATA_WIDTH +: DATA_WIDTH] = 8'sd3;
            w_bus[0*DATA_WIDTH +: DATA_WIDTH] = 8'sd2;

            x_bus[1*DATA_WIDTH +: DATA_WIDTH] = 8'sd4;
            w_bus[1*DATA_WIDTH +: DATA_WIDTH] = -8'sd1;

            x_bus[2*DATA_WIDTH +: DATA_WIDTH] = 8'sd2;
            w_bus[2*DATA_WIDTH +: DATA_WIDTH] = 8'sd1;

            run_neuron;

            $display("RTL      = %0d", y);
            $display("EXPECTED = 5");

            if (y !== 8'sd5) begin
                $display("FAIL - TEST 1");
                errors = errors + 1;
            end
            else begin
                $display("PASS - TEST 1");
            end
        end
    endtask

    // ------------------------------------------------------------
    // TEST 2
    //
    // All products negative.
    // ReLU must force output to zero.
    // ------------------------------------------------------------
    task test_2;
        begin
            $display("");
            $display("TEST 2: RELU");

            x_bus = 0;
            w_bus = 0;
            bias  = 0;

            for (i = 0; i < N_INPUTS; i = i + 1) begin
                x_bus[i*DATA_WIDTH +: DATA_WIDTH] = 8'sd1;
                w_bus[i*DATA_WIDTH +: DATA_WIDTH] = -8'sd1;
            end

            run_neuron;

            $display("RTL      = %0d", y);
            $display("EXPECTED = 0");

            if (y !== 8'sd0) begin
                $display("FAIL - TEST 2");
                errors = errors + 1;
            end
            else begin
                $display("PASS - TEST 2");
            end
        end
    endtask

    // ------------------------------------------------------------
    // TEST 3
    //
    // Large positive result.
    // Must saturate to +127 (INT8).
    // ------------------------------------------------------------
    task test_3;
        begin
            $display("");
            $display("TEST 3: POSITIVE SATURATION");

            x_bus = 0;
            w_bus = 0;
            bias  = 0;

            for (i = 0; i < N_INPUTS; i = i + 1) begin
                x_bus[i*DATA_WIDTH +: DATA_WIDTH] = 8'sd100;
                w_bus[i*DATA_WIDTH +: DATA_WIDTH] = 8'sd2;
            end

            run_neuron;

            $display("RTL      = %0d", y);
            $display("EXPECTED = 127");

            if (y !== 8'sd127) begin
                $display("FAIL - TEST 3");
                errors = errors + 1;
            end
            else begin
                $display("PASS - TEST 3");
            end
        end
    endtask

    // ------------------------------------------------------------
    // TEST 4
    //
    // Mixed positive/negative products.
    //
    // 16 x (2 * 1)  = 32
    // 16 x (-1 * 1) = -16
    // sum = 16
    // bias = -16
    //
    // total = 0 -> ReLU boundary -> 0
    // ------------------------------------------------------------
    task test_4;
        begin
            $display("");
            $display("TEST 4: MIXED VALUES + NEGATIVE BIAS");

            x_bus = 0;
            w_bus = 0;
            bias  = -8'sd16;

            for (i = 0; i < N_INPUTS; i = i + 1) begin
                if ((i % 2) == 0) begin
                    x_bus[i*DATA_WIDTH +: DATA_WIDTH] = 8'sd2;
                    w_bus[i*DATA_WIDTH +: DATA_WIDTH] = 8'sd1;
                end
                else begin
                    x_bus[i*DATA_WIDTH +: DATA_WIDTH] = -8'sd1;
                    w_bus[i*DATA_WIDTH +: DATA_WIDTH] = 8'sd1;
                end
            end

            run_neuron;

            $display("RTL      = %0d", y);
            $display("EXPECTED = 0");

            if (y !== 8'sd0) begin
                $display("FAIL - TEST 4");
                errors = errors + 1;
            end
            else begin
                $display("PASS - TEST 4");
            end
        end
    endtask

    // ------------------------------------------------------------
    // TEST 5: activation=ACT_NONE (linear)
    //
    // Same "all products negative" vector as TEST 2, where ReLU
    // forces y=0. Under ACT_NONE the negative result must pass
    // through unclamped instead.
    //
    // 4 lanes active: x=1, w=-1 -> -4 total, bias=-3 -> -7
    // ------------------------------------------------------------
    task test_5;
        begin
            $display("");
            $display("TEST 5: ACT_NONE (linear, negative passes through)");

            x_bus      = 0;
            w_bus      = 0;
            bias       = -8'sd3;
            activation = ACT_NONE;

            for (i = 0; i < 4; i = i + 1) begin
                x_bus[i*DATA_WIDTH +: DATA_WIDTH] = 8'sd1;
                w_bus[i*DATA_WIDTH +: DATA_WIDTH] = -8'sd1;
            end

            run_neuron;

            $display("RTL      = %0d", y);
            $display("EXPECTED = -7");

            if (y !== -8'sd7) begin
                $display("FAIL - TEST 5");
                errors = errors + 1;
            end
            else begin
                $display("PASS - TEST 5");
            end

            activation = ACT_RELU;
        end
    endtask

    // ------------------------------------------------------------
    // TEST 6: activation=ACT_NONE, negative saturation
    //
    // Large negative accumulator must saturate to -128, not wrap.
    // ------------------------------------------------------------
    task test_6;
        begin
            $display("");
            $display("TEST 6: ACT_NONE, NEGATIVE SATURATION");

            x_bus      = 0;
            w_bus      = 0;
            bias       = 0;
            activation = ACT_NONE;

            for (i = 0; i < N_INPUTS; i = i + 1) begin
                x_bus[i*DATA_WIDTH +: DATA_WIDTH] = 8'sd100;
                w_bus[i*DATA_WIDTH +: DATA_WIDTH] = -8'sd2;
            end

            run_neuron;

            $display("RTL      = %0d", y);
            $display("EXPECTED = -128");

            if (y !== -8'sd128) begin
                $display("FAIL - TEST 6");
                errors = errors + 1;
            end
            else begin
                $display("PASS - TEST 6");
            end

            activation = ACT_RELU;
        end
    endtask

    // ------------------------------------------------------------
    // TEST 7: n_inputs_real < N_INPUTS (runtime early termination)
    //
    // Only lanes 0..7 carry real data (x=1, w=1 -> 8 total); lanes
    // 8..31 are deliberately loaded with garbage (x=99, w=99) that
    // would swamp the sum if read. n_inputs_real=8 with PARALLEL=8
    // means groups_real=1 group instead of the full GROUPS=4 --
    // both the correct RESULT (garbage lanes never read) and a
    // shorter RUNTIME (fewer cycles than a full-width run) are
    // checked.
    // ------------------------------------------------------------
    integer t_start, t_done;
    integer cycles_full, cycles_reduced;

    task test_7;
        reg pass_7;
        begin
            $display("");
            $display("TEST 7: n_inputs_real < N_INPUTS (early termination)");
            pass_7 = 1;

            // -- baseline: full-width run (32 lanes, x=1 w=1 -> 32) --
            x_bus         = 0;
            w_bus         = 0;
            bias          = 0;
            activation    = ACT_RELU;
            n_inputs_real = N_INPUTS;

            for (i = 0; i < N_INPUTS; i = i + 1) begin
                x_bus[i*DATA_WIDTH +: DATA_WIDTH] = 8'sd1;
                w_bus[i*DATA_WIDTH +: DATA_WIDTH] = 8'sd1;
            end

            t_start = $time;
            run_neuron;
            t_done = $time;
            cycles_full = (t_done - t_start) / 10;

            if (y !== 8'sd32) begin
                $display("  FAIL: full-width result = %0d, expected 32", y);
                errors = errors + 1;
                pass_7 = 0;
            end

            // -- reduced: only 8 real lanes, rest garbage --
            x_bus = 0;
            w_bus = 0;

            for (i = 0; i < 8; i = i + 1) begin
                x_bus[i*DATA_WIDTH +: DATA_WIDTH] = 8'sd1;
                w_bus[i*DATA_WIDTH +: DATA_WIDTH] = 8'sd1;
            end
            for (i = 8; i < N_INPUTS; i = i + 1) begin
                x_bus[i*DATA_WIDTH +: DATA_WIDTH] = 8'sd99;
                w_bus[i*DATA_WIDTH +: DATA_WIDTH] = 8'sd99;
            end

            n_inputs_real = 16'd8;

            t_start = $time;
            run_neuron;
            t_done = $time;
            cycles_reduced = (t_done - t_start) / 10;

            $display("  full-width : y=%0d, %0d cycles", 32, cycles_full);
            $display("  reduced    : y=%0d, %0d cycles (expected y=8)", y, cycles_reduced);

            if (y !== 8'sd8) begin
                $display("  FAIL: reduced-width result = %0d, expected 8 (garbage lanes must not be read)", y);
                errors = errors + 1;
                pass_7 = 0;
            end

            if (cycles_reduced >= cycles_full) begin
                $display("  FAIL: reduced run (%0d cycles) did not complete faster than full-width run (%0d cycles)", cycles_reduced, cycles_full);
                errors = errors + 1;
                pass_7 = 0;
            end

            n_inputs_real = N_INPUTS;

            if (pass_7)
                $display("PASS - TEST 7");
            else
                $display("FAIL - TEST 7");
        end
    endtask

    // ------------------------------------------------------------
    // MAIN
    // ------------------------------------------------------------
    initial begin

        $dumpfile("sim/neuron_parallel.vcd");
        $dumpvars(0, tb);

        rst           = 1;
        start         = 0;
        x_bus         = 0;
        w_bus         = 0;
        bias          = 0;
        activation    = ACT_RELU;
        n_inputs_real = N_INPUTS;
        errors        = 0;

        repeat (2) @(posedge clk);

        rst = 0;

        $display("");
        $display("==============================");
        $display("NEURON_PARALLEL TESTBENCH (INT8)");
        $display("==============================");

        test_1;
        test_2;
        test_3;
        test_4;
        test_5;
        test_6;
        test_7;

        $display("");
        $display("==============================");

        if (errors == 0) begin
            $display("ALL TESTS PASSED");
        end
        else begin
            $display("FAILURES = %0d", errors);
        end

        $display("==============================");
        $display("");

        $finish;
    end

endmodule
