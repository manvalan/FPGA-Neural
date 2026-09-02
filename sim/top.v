module top;

    reg clk;
    reg rst;
    reg start;

    reg signed [1023:0] x_bus;
    reg signed [1023:0] w_bus;
    reg signed [15:0] bias;

    wire signed [15:0] y;
    wire busy;
    wire done;

    neuron_parallel #(
        .DATA_WIDTH(16),
        .FRAC_BITS(8),
        .N_INPUTS(64),
        .PARALLEL(8),
        .ACC_WIDTH(40)
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

endmodule