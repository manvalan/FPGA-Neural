`timescale 1ns/1ps

module tb;

    parameter DATA_WIDTH = 16;
    parameter FRAC_BITS  = 8;
    parameter N_INPUTS   = 32;
    parameter N_NEURONS  = 4;
    parameter PARALLEL   = 8;
    parameter ACC_WIDTH  = 40;

    reg clk;
    reg rst;
    reg start;

    reg signed [DATA_WIDTH*N_INPUTS-1:0] x_bus;

    reg signed [DATA_WIDTH*N_INPUTS*N_NEURONS-1:0]
        weights_bus;

    reg signed [DATA_WIDTH*N_NEURONS-1:0]
        bias_bus;

    wire signed [DATA_WIDTH*N_NEURONS-1:0]
        y_bus;

    wire busy;
    wire done;

    integer i;
    integer n;
    integer errors;
    integer expected;

    layer #(
        .DATA_WIDTH(DATA_WIDTH),
        .FRAC_BITS(FRAC_BITS),
        .N_INPUTS(N_INPUTS),
        .N_NEURONS(N_NEURONS),
        .PARALLEL(PARALLEL),
        .ACC_WIDTH(ACC_WIDTH)
    ) dut (
        .clk(clk),
        .rst(rst),
        .start(start),
        .x_bus(x_bus),
        .weights_bus(weights_bus),
        .bias_bus(bias_bus),
        .y_bus(y_bus),
        .busy(busy),
        .done(done)
    );

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    function signed [15:0] q8_8;
        input real value;
        begin
            q8_8 = $rtoi(value * 256.0);
        end
    endfunction

    task run_layer;
        begin
            @(posedge clk);
            start = 1;

            @(posedge clk);
            start = 0;

            wait(done == 1);

            @(posedge clk);
        end
    endtask

    initial begin

        $dumpfile("sim/parametric.vcd");
        $dumpvars(0, tb);

        rst = 1;
        start = 0;
        x_bus = 0;
        weights_bus = 0;
        bias_bus = 0;
        errors = 0;

        repeat (2) @(posedge clk);

        rst = 0;

        /*
         * All inputs = 1.0
         */
        for (i = 0; i < N_INPUTS; i = i + 1)
            x_bus[i*DATA_WIDTH +: DATA_WIDTH] = q8_8(1.0);

        /*
         * Neuron 0: weight = 1.0
         * result = N_INPUTS
         */
        for (i = 0; i < N_INPUTS; i = i + 1)
            weights_bus[
                0*N_INPUTS*DATA_WIDTH +
                i*DATA_WIDTH +:
                DATA_WIDTH
            ] = q8_8(1.0);

        /*
         * Neuron 1: weight = 0.5
         * result = N_INPUTS / 2
         */
        if (N_NEURONS > 1)
            for (i = 0; i < N_INPUTS; i = i + 1)
                weights_bus[
                    1*N_INPUTS*DATA_WIDTH +
                    i*DATA_WIDTH +:
                    DATA_WIDTH
                ] = q8_8(0.5);

        /*
         * Neuron 2: weight = -0.5
         * ReLU -> 0
         */
        if (N_NEURONS > 2)
            for (i = 0; i < N_INPUTS; i = i + 1)
                weights_bus[
                    2*N_INPUTS*DATA_WIDTH +
                    i*DATA_WIDTH +:
                    DATA_WIDTH
                ] = q8_8(-0.5);

        /*
         * Neuron 3: weight = 2.0
         * Large positive result -> saturation
         */
        if (N_NEURONS > 3)
            for (i = 0; i < N_INPUTS; i = i + 1)
                weights_bus[
                    3*N_INPUTS*DATA_WIDTH +
                    i*DATA_WIDTH +:
                    DATA_WIDTH
                ] = q8_8(2.0);

        /*
         * Neuron 4: zero weights + bias +1
         */
        if (N_NEURONS > 4)
            bias_bus[4*DATA_WIDTH +: DATA_WIDTH] = q8_8(1.0);

        /*
         * Neuron 5: zero weights + bias -1
         * ReLU -> 0
         */
        if (N_NEURONS > 5)
            bias_bus[5*DATA_WIDTH +: DATA_WIDTH] = q8_8(-1.0);

        /*
         * Neuron 6: weight 1.0 + bias -1.0
         * result = N_INPUTS - 1
         */
        if (N_NEURONS > 6) begin
            for (i = 0; i < N_INPUTS; i = i + 1)
                weights_bus[
                    6*N_INPUTS*DATA_WIDTH +
                    i*DATA_WIDTH +:
                    DATA_WIDTH
                ] = q8_8(1.0);

            bias_bus[6*DATA_WIDTH +: DATA_WIDTH] = q8_8(-1.0);
        end

        /*
         * Neuron 7: weight 0.25 + bias 1
         * result = N_INPUTS/4 + 1
         */
        if (N_NEURONS > 7) begin
            for (i = 0; i < N_INPUTS; i = i + 1)
                weights_bus[
                    7*N_INPUTS*DATA_WIDTH +
                    i*DATA_WIDTH +:
                    DATA_WIDTH
                ] = q8_8(0.25);

            bias_bus[7*DATA_WIDTH +: DATA_WIDTH] = q8_8(1.0);
        end

        $display("");
        $display("========================================");
        $display("PARAMETRIC LAYER TEST");
        $display("N_INPUTS  = %0d", N_INPUTS);
        $display("N_NEURONS = %0d", N_NEURONS);
        $display("PARALLEL  = %0d", PARALLEL);
        $display("========================================");

        run_layer;

        /*
         * Neuron 0
         */
        expected = N_INPUTS * 256;

        if (y_bus[0*16 +: 16] !== expected[15:0]) begin
            $display("FAIL N0: got %0d expected %0d",
                     y_bus[0*16 +: 16], expected);
            errors = errors + 1;
        end
        else
            $display("PASS N0: %0d", y_bus[0*16 +: 16]);

        /*
         * Neuron 1
         */
        if (N_NEURONS > 1) begin
            expected = (N_INPUTS * 128);

            if (y_bus[1*16 +: 16] !== expected[15:0]) begin
                $display("FAIL N1: got %0d expected %0d",
                         y_bus[1*16 +: 16], expected);
                errors = errors + 1;
            end
            else
                $display("PASS N1: %0d", y_bus[1*16 +: 16]);
        end

        /*
         * Neuron 2
         */
        if (N_NEURONS > 2) begin
            expected = 0;

            if (y_bus[2*16 +: 16] !== 16'sd0) begin
                $display("FAIL N2: got %0d expected 0",
                         y_bus[2*16 +: 16]);
                errors = errors + 1;
            end
            else
                $display("PASS N2: 0 (ReLU)");
        end

        /*
        * Neuron 3:
        * weight = 2.0
        * result = N_INPUTS * 2.0
        *
        * Saturation only occurs when result > 127.996...
        */
        if (N_NEURONS > 3) begin

            expected = N_INPUTS * 2 * 256;

        if (expected > 32767)
            expected = 32767;

        if (y_bus[3*16 +: 16] !== expected[15:0]) begin
            $display("FAIL N3: got %0d expected %0d",
                 y_bus[3*16 +: 16], expected);
            errors = errors + 1;
        end
        else begin
            if (expected == 32767)
                $display("PASS N3: %0d (saturation)", y_bus[3*16 +: 16]);
            else
                $display("PASS N3: %0d", y_bus[3*16 +: 16]);
        end
    end

        /*
         * Neuron 4
         */
        if (N_NEURONS > 4) begin
            if (y_bus[4*16 +: 16] !== 16'sd256) begin
                $display("FAIL N4: got %0d expected 256",
                         y_bus[4*16 +: 16]);
                errors = errors + 1;
            end
            else
                $display("PASS N4: 256 (bias)");
        end

        /*
         * Neuron 5
         */
        if (N_NEURONS > 5) begin
            if (y_bus[5*16 +: 16] !== 16'sd0) begin
                $display("FAIL N5: got %0d expected 0",
                         y_bus[5*16 +: 16]);
                errors = errors + 1;
            end
            else
                $display("PASS N5: 0 (negative bias + ReLU)");
        end

        /*
         * Neuron 6
         */
        if (N_NEURONS > 6) begin
            expected = (N_INPUTS - 1) * 256;

            if (y_bus[6*16 +: 16] !== expected[15:0]) begin
                $display("FAIL N6: got %0d expected %0d",
                         y_bus[6*16 +: 16], expected);
                errors = errors + 1;
            end
            else
                $display("PASS N6: %0d", y_bus[6*16 +: 16]);
        end

        /*
         * Neuron 7
         */
        if (N_NEURONS > 7) begin
            expected = (N_INPUTS / 4 + 1) * 256;

            if (y_bus[7*16 +: 16] !== expected[15:0]) begin
                $display("FAIL N7: got %0d expected %0d",
                         y_bus[7*16 +: 16], expected);
                errors = errors + 1;
            end
            else
                $display("PASS N7: %0d", y_bus[7*16 +: 16]);
        end

        if (busy !== 0) begin
            $display("FAIL: busy still active");
            errors = errors + 1;
        end

        if (done !== 1) begin
            $display("FAIL: done not asserted");
            errors = errors + 1;
        end

        $display("");
        $display("========================================");

        if (errors == 0)
            $display("PARAMETRIC TEST PASSED");
        else
            $display("PARAMETRIC TEST FAILED: %0d errors", errors);

        $display("========================================");
        $display("");

        $finish;
    end

endmodule
