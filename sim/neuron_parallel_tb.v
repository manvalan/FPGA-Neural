`timescale 1ns/1ps

module tb;

    parameter DATA_WIDTH = 16;
    parameter FRAC_BITS  = 8;
    parameter N_INPUTS   = 64;
    parameter PARALLEL   = 8;
    parameter ACC_WIDTH  = 40;

    reg clk;
    reg rst;
    reg start;

    reg signed [DATA_WIDTH*N_INPUTS-1:0] x_bus;
    reg signed [DATA_WIDTH*N_INPUTS-1:0] w_bus;
    reg signed [DATA_WIDTH-1:0] bias;

    wire signed [DATA_WIDTH-1:0] y;
    wire busy;
    wire done;

    integer i;
    integer errors;

    neuron_parallel #(
        .DATA_WIDTH(DATA_WIDTH),
        .FRAC_BITS(FRAC_BITS),
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
    // Helper: convert real value to Q8.8
    // ------------------------------------------------------------
    function signed [15:0] q8_8;
        input real value;
        begin
            q8_8 = $rtoi(value * 256.0);
        end
    endfunction

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
    // x0 = 1.5   w0 = 2.0   -> 3.0
    // x1 = 2.0   w1 = -1.0  -> -2.0
    // x2 = 0.5   w2 = 0.25  -> 0.125
    //
    // bias = 0.609375
    //
    // total = 1.734375
    // Q8.8 = 444
    // ------------------------------------------------------------
    task test_1;
        begin
            $display("");
            $display("TEST 1: DIVERSE VECTOR");

            x_bus = 0;
            w_bus = 0;
            bias  = q8_8(0.609375);

            x_bus[0*16 +: 16] = q8_8(1.5);
            w_bus[0*16 +: 16] = q8_8(2.0);

            x_bus[1*16 +: 16] = q8_8(2.0);
            w_bus[1*16 +: 16] = q8_8(-1.0);

            x_bus[2*16 +: 16] = q8_8(0.5);
            w_bus[2*16 +: 16] = q8_8(0.25);

            run_neuron;

            $display("RTL      = %0d", y);
            $display("EXPECTED = 444");

            if (y !== 16'sd444) begin
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
                x_bus[i*16 +: 16] = q8_8(1.0);
                w_bus[i*16 +: 16] = q8_8(-1.0);
            end

            run_neuron;

            $display("RTL      = %0d", y);
            $display("EXPECTED = 0");

            if (y !== 16'sd0) begin
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
    // Must saturate to +32767.
    // ------------------------------------------------------------
    task test_3;
        begin
            $display("");
            $display("TEST 3: POSITIVE SATURATION");

            x_bus = 0;
            w_bus = 0;
            bias  = 0;

            for (i = 0; i < N_INPUTS; i = i + 1) begin
                x_bus[i*16 +: 16] = q8_8(127.0);
                w_bus[i*16 +: 16] = q8_8(2.0);
            end

            run_neuron;

            $display("RTL      = %0d", y);
            $display("EXPECTED = 32767");

            if (y !== 16'sd32767) begin
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
    // 32 x (+1)
    // 32 x (-1)
    // sum = 0
    // bias = -1
    //
    // ReLU -> 0
    // ------------------------------------------------------------
    task test_4;
        begin
            $display("");
            $display("TEST 4: MIXED VALUES + NEGATIVE BIAS");

            x_bus = 0;
            w_bus = 0;
            bias  = q8_8(-1.0);

            for (i = 0; i < N_INPUTS; i = i + 1) begin
                if ((i % 2) == 0) begin
                    x_bus[i*16 +: 16] = q8_8(2.0);
                    w_bus[i*16 +: 16] = q8_8(0.5);
                end
                else begin
                    x_bus[i*16 +: 16] = q8_8(-1.0);
                    w_bus[i*16 +: 16] = q8_8(1.0);
                end
            end

            run_neuron;

            $display("RTL      = %0d", y);
            $display("EXPECTED = 0");

            if (y !== 16'sd0) begin
                $display("FAIL - TEST 4");
                errors = errors + 1;
            end
            else begin
                $display("PASS - TEST 4");
            end
        end
    endtask

    // ------------------------------------------------------------
    // MAIN
    // ------------------------------------------------------------
    initial begin

        $dumpfile("sim/neuron_parallel.vcd");
        $dumpvars(0, tb);

        rst    = 1;
        start  = 0;
        x_bus  = 0;
        w_bus  = 0;
        bias   = 0;
        errors = 0;

        repeat (2) @(posedge clk);

        rst = 0;

        $display("");
        $display("==============================");
        $display("NEURON_PARALLEL TESTBENCH");
        $display("==============================");

        test_1;
        test_2;
        test_3;
        test_4;

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