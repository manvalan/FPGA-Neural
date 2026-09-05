`timescale 1ns/1ps

module tb;

    parameter DATA_WIDTH = 8;
    parameter N_INPUTS   = 256;
    parameter N_NEURONS  = 4;
    parameter PARALLEL   = 32;
    parameter ACC_WIDTH  = 32;

    reg clk;
    reg rst;
    reg start;

    reg signed [DATA_WIDTH*N_INPUTS-1:0] x_bus;

    reg signed [DATA_WIDTH*N_INPUTS*N_NEURONS-1:0]
        weights_bus;

    reg signed [DATA_WIDTH*N_NEURONS-1:0]
        bias_bus;

    wire signed [DATA_WIDTH*N_NEURONS-1:0] y_bus;

    wire busy;
    wire done;

    integer i;
    integer errors;
    integer expected;

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
 * Tutti gli input = 1
 */
for (i = 0; i < N_INPUTS; i = i + 1)
    x_bus[i*DATA_WIDTH +: DATA_WIDTH] = 8'sd1;

/*
 * N0:
 * primi 32 pesi = 1
 * restanti 224 = 0
 *
 * Risultato = 32
 *
 * Questo verifica che l'accumulatore
 * attraversi correttamente tutti gli 8 gruppi.
 */
for (i = 0; i < N_INPUTS; i = i + 1)
    weights_bus[
        0*N_INPUTS*DATA_WIDTH +
        i*DATA_WIDTH +:
        DATA_WIDTH
    ] = (i < 32) ? 8'sd1 : 8'sd0;

/*
 * N1:
 * tutti i 256 pesi = 0
 * bias = 10
 *
 * Risultato = 10
 */
for (i = 0; i < N_INPUTS; i = i + 1)
    weights_bus[
        1*N_INPUTS*DATA_WIDTH +
        i*DATA_WIDTH +:
        DATA_WIDTH
    ] = 8'sd0;

bias_bus[1*DATA_WIDTH +: DATA_WIDTH] = 8'sd10;

/*
 * N2:
 * tutti i pesi = -1
 *
 * Risultato = -256
 * ReLU -> 0
 */
for (i = 0; i < N_INPUTS; i = i + 1)
    weights_bus[
        2*N_INPUTS*DATA_WIDTH +
        i*DATA_WIDTH +:
        DATA_WIDTH
    ] = -8'sd1;

/*
 * N3:
 * primi 32 pesi = 4
 * restanti = 0
 *
 * Risultato = 128
 * Saturazione INT8 -> 127
 */
for (i = 0; i < N_INPUTS; i = i + 1)
    weights_bus[
        3*N_INPUTS*DATA_WIDTH +
        i*DATA_WIDTH +:
        DATA_WIDTH
    ] = (i < 32) ? 8'sd4 : 8'sd0;

        $display("");
        $display("========================================");
        $display("INT8 / INT32 PARAMETRIC LAYER TEST");
        $display("N_INPUTS  = %0d", N_INPUTS);
        $display("N_NEURONS = %0d", N_NEURONS);
        $display("PARALLEL  = %0d", PARALLEL);
        $display("DATA_WIDTH = %0d", DATA_WIDTH);
        $display("ACC_WIDTH  = %0d", ACC_WIDTH);
        $display("========================================");

        run_layer;

        /*
         * Neuron 0
         */
        expected = 32;

        if ($signed(y_bus[0*DATA_WIDTH +: DATA_WIDTH]) !== expected) begin
            $display("FAIL N0: got %0d expected %0d",
                     $signed(y_bus[0*DATA_WIDTH +: DATA_WIDTH]),
                     expected);
            errors = errors + 1;
        end
        else
            $display("PASS N0: %0d", $signed(y_bus[0*DATA_WIDTH +: DATA_WIDTH]));

        /*
         * Neuron 1
         */
        if (N_NEURONS > 1) begin

            expected = 10;

            if ($signed(y_bus[1*DATA_WIDTH +: DATA_WIDTH]) !== expected) begin
                $display("FAIL N1: got %0d expected %0d",
                         $signed(y_bus[1*DATA_WIDTH +: DATA_WIDTH]),
                         expected);
                errors = errors + 1;
            end
            else
                $display("PASS N1: %0d",
                         $signed(y_bus[1*DATA_WIDTH +: DATA_WIDTH]));
        end

        /*
         * Neuron 2
         */
        if (N_NEURONS > 2) begin

            expected = 0;

            if ($signed(y_bus[2*DATA_WIDTH +: DATA_WIDTH]) !== 0) begin
                $display("FAIL N2: got %0d expected 0",
                         $signed(y_bus[2*DATA_WIDTH +: DATA_WIDTH]));
                errors = errors + 1;
            end
            else
                $display("PASS N2: 0 (ReLU)");
        end

        /*
         * Neuron 3
         *
         * 32 * 4 = 128
         * INT8 positive saturation -> 127
         */
        if (N_NEURONS > 3) begin

            expected = 127;

            if ($signed(y_bus[3*DATA_WIDTH +: DATA_WIDTH]) !== expected) begin
                $display("FAIL N3: got %0d expected %0d",
                         $signed(y_bus[3*DATA_WIDTH +: DATA_WIDTH]),
                         expected);
                errors = errors + 1;
            end
            else
                $display("PASS N3: %0d (saturation)",
                         $signed(y_bus[3*DATA_WIDTH +: DATA_WIDTH]));
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
            $display("INT8 PARAMETRIC TEST PASSED");
        else
            $display("INT8 PARAMETRIC TEST FAILED: %0d errors", errors);

        $display("========================================");
        $display("");

        $finish;
    end

endmodule