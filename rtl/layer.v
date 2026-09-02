module layer #(
    parameter DATA_WIDTH = 16,
    parameter FRAC_BITS  = 8,
    parameter N_INPUTS   = 64,
    parameter N_NEURONS  = 8,
    parameter PARALLEL   = 8,
    parameter ACC_WIDTH  = 40
)(
    input clk,
    input rst,
    input start,

    input signed [DATA_WIDTH*N_INPUTS-1:0] x_bus,

    input signed [DATA_WIDTH*N_INPUTS*N_NEURONS-1:0]
        weights_bus,

    input signed [DATA_WIDTH*N_NEURONS-1:0]
        bias_bus,

    output signed [DATA_WIDTH*N_NEURONS-1:0]
        y_bus,

    output busy,
    output done
);

    wire [N_NEURONS-1:0] neuron_busy;
    wire [N_NEURONS-1:0] neuron_done;

    genvar n;

    generate

        for (n = 0; n < N_NEURONS; n = n + 1) begin : GEN_NEURON

            neuron_parallel #(
                .DATA_WIDTH(DATA_WIDTH),
                .FRAC_BITS(FRAC_BITS),
                .N_INPUTS(N_INPUTS),
                .PARALLEL(PARALLEL),
                .ACC_WIDTH(ACC_WIDTH)
            ) u_neuron (

                .clk(clk),
                .rst(rst),
                .start(start),

                .x_bus(x_bus),

                .w_bus(
                    weights_bus[
                        n*N_INPUTS*DATA_WIDTH
                        +: N_INPUTS*DATA_WIDTH
                    ]
                ),

                .bias(
                    bias_bus[
                        n*DATA_WIDTH
                        +: DATA_WIDTH
                    ]
                ),

                .y(
                    y_bus[
                        n*DATA_WIDTH
                        +: DATA_WIDTH
                    ]
                ),

                .busy(neuron_busy[n]),
                .done(neuron_done[n])
            );

        end

    endgenerate

    assign busy = |neuron_busy;
    assign done = &neuron_done;

endmodule