`timescale 1ns/1ps

module tb;

    parameter DATA_WIDTH = 8;
    parameter N_INPUTS   = 32;
    parameter N_NEURONS  = 8;
    parameter PARALLEL   = 8;
    parameter ACC_WIDTH  = 32;

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
    integer errors;

    layer #(
        .DATA_WIDTH(DATA_WIDTH),
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

        $dumpfile("sim/layer.vcd");
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
         * Input vector:
         * all inputs = 1
         */
        for (i = 0; i < N_INPUTS; i = i + 1)
            x_bus[i*DATA_WIDTH +: DATA_WIDTH] = 8'sd1;

        /*
         * Neuron 0:
         * weights = 1
         * bias = 0
         * result = 32
         */
        for (i = 0; i < N_INPUTS; i = i + 1)
            weights_bus[
                0*N_INPUTS*DATA_WIDTH +
                i*DATA_WIDTH +:
                DATA_WIDTH
            ] = 8'sd1;

        bias_bus[0*DATA_WIDTH +: DATA_WIDTH] = 8'sd0;

        /*
         * Neuron 1:
         * weights = 3
         * result = 96
         */
        for (i = 0; i < N_INPUTS; i = i + 1)
            weights_bus[
                1*N_INPUTS*DATA_WIDTH +
                i*DATA_WIDTH +:
                DATA_WIDTH
            ] = 8'sd3;

        /*
         * Neuron 2:
         * weights = -1
         * result = -32 -> ReLU = 0
         */
        for (i = 0; i < N_INPUTS; i = i + 1)
            weights_bus[
                2*N_INPUTS*DATA_WIDTH +
                i*DATA_WIDTH +:
                DATA_WIDTH
            ] = -8'sd1;

        /*
         * Neuron 3:
         * weights = 8
         * result = 256 -> INT8 saturation = 127
         */
        for (i = 0; i < N_INPUTS; i = i + 1)
            weights_bus[
                3*N_INPUTS*DATA_WIDTH +
                i*DATA_WIDTH +:
                DATA_WIDTH
            ] = 8'sd8;

        /*
         * Neuron 4:
         * weights = 0
         * bias = +5
         * result = 5
         */
        bias_bus[4*DATA_WIDTH +: DATA_WIDTH] = 8'sd5;

        /*
         * Neuron 5:
         * weights = 0
         * bias = -5
         * ReLU = 0
         */
        bias_bus[5*DATA_WIDTH +: DATA_WIDTH] = -8'sd5;

        /*
         * Neuron 6:
         * weights = 1
         * bias = -10
         * result = 32 - 10 = 22
         */
        for (i = 0; i < N_INPUTS; i = i + 1)
            weights_bus[
                6*N_INPUTS*DATA_WIDTH +
                i*DATA_WIDTH +:
                DATA_WIDTH
            ] = 8'sd1;

        bias_bus[6*DATA_WIDTH +: DATA_WIDTH] = -8'sd10;

        /*
         * Neuron 7:
         * first 16 weights = 1, remaining 16 = 0
         * bias = +5
         * result = 16 + 5 = 21
         *
         * Exercises a sparse weight pattern across groups
         * (PARALLEL = 8 -> GROUPS = 4).
         */
        for (i = 0; i < N_INPUTS; i = i + 1)
            weights_bus[
                7*N_INPUTS*DATA_WIDTH +
                i*DATA_WIDTH +:
                DATA_WIDTH
            ] = (i < 16) ? 8'sd1 : 8'sd0;

        bias_bus[7*DATA_WIDTH +: DATA_WIDTH] = 8'sd5;

        $display("");
        $display("==============================");
        $display("LAYER TEST (INT8)");
        $display("==============================");

        run_layer;

        $display("Neuron 0 = %5d   expected =  32", $signed(y_bus[0*DATA_WIDTH +: DATA_WIDTH]));
        $display("Neuron 1 = %5d   expected =  96", $signed(y_bus[1*DATA_WIDTH +: DATA_WIDTH]));
        $display("Neuron 2 = %5d   expected =   0", $signed(y_bus[2*DATA_WIDTH +: DATA_WIDTH]));
        $display("Neuron 3 = %5d   expected = 127", $signed(y_bus[3*DATA_WIDTH +: DATA_WIDTH]));
        $display("Neuron 4 = %5d   expected =   5", $signed(y_bus[4*DATA_WIDTH +: DATA_WIDTH]));
        $display("Neuron 5 = %5d   expected =   0", $signed(y_bus[5*DATA_WIDTH +: DATA_WIDTH]));
        $display("Neuron 6 = %5d   expected =  22", $signed(y_bus[6*DATA_WIDTH +: DATA_WIDTH]));
        $display("Neuron 7 = %5d   expected =  21", $signed(y_bus[7*DATA_WIDTH +: DATA_WIDTH]));

        if ($signed(y_bus[0*DATA_WIDTH +: DATA_WIDTH]) !== 8'sd32)  errors = errors + 1;
        if ($signed(y_bus[1*DATA_WIDTH +: DATA_WIDTH]) !== 8'sd96)  errors = errors + 1;
        if ($signed(y_bus[2*DATA_WIDTH +: DATA_WIDTH]) !== 8'sd0)   errors = errors + 1;
        if ($signed(y_bus[3*DATA_WIDTH +: DATA_WIDTH]) !== 8'sd127) errors = errors + 1;
        if ($signed(y_bus[4*DATA_WIDTH +: DATA_WIDTH]) !== 8'sd5)   errors = errors + 1;
        if ($signed(y_bus[5*DATA_WIDTH +: DATA_WIDTH]) !== 8'sd0)   errors = errors + 1;
        if ($signed(y_bus[6*DATA_WIDTH +: DATA_WIDTH]) !== 8'sd22)  errors = errors + 1;
        if ($signed(y_bus[7*DATA_WIDTH +: DATA_WIDTH]) !== 8'sd21)  errors = errors + 1;

        $display("busy = %0d", busy);
        $display("done = %0d", done);

        $display("");
        $display("==============================");

        if (errors == 0)
            $display("PASS - ALL 8 NEURONS");
        else
            $display("FAIL - %0d ERRORS", errors);

        $display("==============================");
        $display("LAYER TEST FINISHED");
        $display("");

        $finish;
    end

endmodule
