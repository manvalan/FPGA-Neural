module tb;

    parameter DATA_WIDTH = 16;
    parameter FRAC_BITS  = 8;
    parameter N_INPUTS   = 64;
    parameter N_NEURONS  = 8;
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
         * all inputs = 1.0
         */
        for (i = 0; i < N_INPUTS; i = i + 1)
            x_bus[i*DATA_WIDTH +: DATA_WIDTH] = q8_8(1.0);

        /*
         * Neuron 0:
         * weights = 1.0
         * bias = 0
         * result = 64
         */
        for (i = 0; i < N_INPUTS; i = i + 1)
            weights_bus[
                0*N_INPUTS*DATA_WIDTH +
                i*DATA_WIDTH +:
                DATA_WIDTH
            ] = q8_8(1.0);

        bias_bus[0*DATA_WIDTH +: DATA_WIDTH] = q8_8(0.0);

        /*
         * Neuron 1:
         * weights = 0.5
         * result = 32
         */
        for (i = 0; i < N_INPUTS; i = i + 1)
            weights_bus[
                1*N_INPUTS*DATA_WIDTH +
                i*DATA_WIDTH +:
                DATA_WIDTH
            ] = q8_8(0.5);

        /*
         * Neuron 2:
         * weights = -0.5
         * result = -32 -> ReLU = 0
         */
        for (i = 0; i < N_INPUTS; i = i + 1)
            weights_bus[
                2*N_INPUTS*DATA_WIDTH +
                i*DATA_WIDTH +:
                DATA_WIDTH
            ] = q8_8(-0.5);

        /*
         * Neuron 3:
         * weights = 2.0
         * result = 128 -> saturation = 127.996...
         */
        for (i = 0; i < N_INPUTS; i = i + 1)
            weights_bus[
                3*N_INPUTS*DATA_WIDTH +
                i*DATA_WIDTH +:
                DATA_WIDTH
            ] = q8_8(2.0);

        /*
         * Neuron 4:
         * weights = 0
         * bias = +1
         * result = 1
         */
        bias_bus[4*DATA_WIDTH +: DATA_WIDTH] = q8_8(1.0);

        /*
         * Neuron 5:
         * weights = 0
         * bias = -1
         * ReLU = 0
         */
        bias_bus[5*DATA_WIDTH +: DATA_WIDTH] = q8_8(-1.0);

        /*
         * Neuron 6:
         * weights = 1.0
         * bias = -1.0
         * result = 63
         */
        for (i = 0; i < N_INPUTS; i = i + 1)
            weights_bus[
                6*N_INPUTS*DATA_WIDTH +
                i*DATA_WIDTH +:
                DATA_WIDTH
            ] = q8_8(1.0);

        bias_bus[6*DATA_WIDTH +: DATA_WIDTH] = q8_8(-1.0);

        /*
         * Neuron 7:
         * weights = 0.25
         * bias = +1
         * result = 16 + 1 = 17
         */
        for (i = 0; i < N_INPUTS; i = i + 1)
            weights_bus[
                7*N_INPUTS*DATA_WIDTH +
                i*DATA_WIDTH +:
                DATA_WIDTH
            ] = q8_8(0.25);

        bias_bus[7*DATA_WIDTH +: DATA_WIDTH] = q8_8(1.0);

        $display("");
        $display("==============================");
        $display("LAYER TEST");
        $display("==============================");

        run_layer;

        $display("Neuron 0 = %5d   expected = 16384", y_bus[0*16 +: 16]);
        $display("Neuron 1 = %5d   expected =  8192", y_bus[1*16 +: 16]);
        $display("Neuron 2 = %5d   expected =     0", y_bus[2*16 +: 16]);
        $display("Neuron 3 = %5d   expected = 32767", y_bus[3*16 +: 16]);
        $display("Neuron 4 = %5d   expected =   256", y_bus[4*16 +: 16]);
        $display("Neuron 5 = %5d   expected =     0", y_bus[5*16 +: 16]);
        $display("Neuron 6 = %5d   expected = 16128", y_bus[6*16 +: 16]);
        $display("Neuron 7 = %5d   expected =  4352", y_bus[7*16 +: 16]);

        if (y_bus[0*16 +: 16] !== 16'sd16384) errors = errors + 1;
        if (y_bus[1*16 +: 16] !== 16'sd8192)  errors = errors + 1;
        if (y_bus[2*16 +: 16] !== 16'sd0)     errors = errors + 1;
        if (y_bus[3*16 +: 16] !== 16'sd32767) errors = errors + 1;
        if (y_bus[4*16 +: 16] !== 16'sd256)   errors = errors + 1;
        if (y_bus[5*16 +: 16] !== 16'sd0)     errors = errors + 1;
        if (y_bus[6*16 +: 16] !== 16'sd16128) errors = errors + 1;
        if (y_bus[7*16 +: 16] !== 16'sd4352)  errors = errors + 1;

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