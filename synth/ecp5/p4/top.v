module top (
    input clk,
    input rst,
    input start,

    output signed [31:0] y_bus,
    output busy,
    output done
);

    localparam DATA_WIDTH = 8;
    localparam N_INPUTS   = 256;
    localparam N_NEURONS  = 4;
    localparam PARALLEL   = 4;
    localparam ACC_WIDTH  = 32;

    reg signed [DATA_WIDTH*N_INPUTS-1:0] x_bus;
    reg signed [DATA_WIDTH*N_INPUTS*N_NEURONS-1:0] weights_bus;
    reg signed [DATA_WIDTH*N_NEURONS-1:0] bias_bus;

    integer i;

    initial begin
        x_bus       = 0;
        weights_bus = 0;
        bias_bus    = 0;

        // X = 1
        for (i = 0; i < N_INPUTS; i = i + 1)
            x_bus[i*DATA_WIDTH +: DATA_WIDTH] = 8'sd1;

        // Neuron 0: first 32 weights = +1
        for (i = 0; i < 32; i = i + 1)
            weights_bus[
                0*N_INPUTS*DATA_WIDTH +
                i*DATA_WIDTH +:
                DATA_WIDTH
            ] = 8'sd1;

        // Neuron 1: all zero, bias = 10
        bias_bus[1*DATA_WIDTH +: DATA_WIDTH] = 8'sd10;

        // Neuron 2: all weights = -1
        for (i = 0; i < N_INPUTS; i = i + 1)
            weights_bus[
                2*N_INPUTS*DATA_WIDTH +
                i*DATA_WIDTH +:
                DATA_WIDTH
            ] = -8'sd1;

        // Neuron 3: first 32 weights = +4
        for (i = 0; i < 32; i = i + 1)
            weights_bus[
                3*N_INPUTS*DATA_WIDTH +
                i*DATA_WIDTH +:
                DATA_WIDTH
            ] = 8'sd4;
    end

    layer #(
        .DATA_WIDTH(DATA_WIDTH),
        .N_INPUTS(N_INPUTS),
        .N_NEURONS(N_NEURONS),
        .PARALLEL(PARALLEL),
        .ACC_WIDTH(ACC_WIDTH)
    ) u_layer (
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

endmodule
