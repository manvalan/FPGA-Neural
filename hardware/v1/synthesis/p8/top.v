module top #(
    parameter DATA_WIDTH = 8,
    parameter N_INPUTS   = 256,
    parameter N_NEURONS  = 4,
    parameter PARALLEL   = 8,
    parameter ACC_WIDTH  = 32
)(
    input  wire clk,
    input  wire rst,
    input  wire start,

    output wire signed [31:0] y_bus,
    output wire busy,
    output wire done
);

    localparam X_BITS = DATA_WIDTH * N_INPUTS;
    localparam W_BITS = DATA_WIDTH * N_INPUTS * N_NEURONS;
    localparam B_BITS = DATA_WIDTH * N_NEURONS;

    /*
     * Internal neural-network data.
     *
     * These are deliberately registers, not parameters/constants.
     * This prevents the complete datapath from disappearing during
     * synthesis.
     */

    reg signed [X_BITS-1:0] x_bus;
    reg signed [W_BITS-1:0] weights_bus;
    reg signed [B_BITS-1:0] bias_bus;

    integer i;
    integer n;

    /*
     * Deterministic initialization.
     *
     * The actual datapath remains present because the vectors are
     * stored in registers and loaded through the clocked process.
     */

    always @(posedge clk) begin
        if (rst) begin

            x_bus       <= '0;
            weights_bus <= '0;
            bias_bus    <= '0;

        end
        else if (start) begin

            /*
             * INT8 input vector.
             *
             * Pattern:
             *   -16 ... +15
             */

            for (i = 0; i < N_INPUTS; i = i + 1) begin
                x_bus[i*DATA_WIDTH +: DATA_WIDTH]
                    <= ((i * 17 + 3) % 31) - 15;
            end

            /*
             * INT8 weights.
             */

            for (n = 0; n < N_NEURONS; n = n + 1) begin

                for (i = 0; i < N_INPUTS; i = i + 1) begin

                    weights_bus[
                        (n*N_INPUTS+i)*DATA_WIDTH
                        +: DATA_WIDTH
                    ]
                        <= ((n * 29 + i * 13 + 5) % 31) - 15;

                end

            end

            /*
             * INT8 biases.
             */

            for (n = 0; n < N_NEURONS; n = n + 1) begin

                bias_bus[
                    n*DATA_WIDTH
                    +: DATA_WIDTH
                ]
                    <= ((n * 7 + 1) % 9) - 4;

            end

        end
    end


    /*
     * Real neural-network layer.
     */

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

endmodule
