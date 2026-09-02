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

    output wire signed [DATA_WIDTH*N_NEURONS-1:0] y_bus,
    output wire busy,
    output wire done
);

    localparam X_BITS = DATA_WIDTH * N_INPUTS;
    localparam W_BITS = DATA_WIDTH * N_INPUTS * N_NEURONS;
    localparam B_BITS = DATA_WIDTH * N_NEURONS;

    /*
     * Deterministic benchmark vectors.
     *
     * These are INTERNAL signals.
     * They are deliberately marked keep so that Yosys does not
     * constant-fold the complete neural datapath away.
     */

    (* keep = "true" *)
    wire signed [X_BITS-1:0] x_bus;

    (* keep = "true" *)
    wire signed [W_BITS-1:0] weights_bus;

    (* keep = "true" *)
    wire signed [B_BITS-1:0] bias_bus;


    /*
     * Generate deterministic non-zero INT8 data.
     *
     * Each byte is a different constant.  The buses remain internal,
     * so nextpnr sees only the 37 real top-level I/Os.
     */

    genvar i;
    genvar n;

    generate

        for (i = 0; i < N_INPUTS; i = i + 1) begin : GEN_X

            localparam integer XV =
                ((i * 17 + 3) % 31) - 15;

            assign x_bus[
                i*DATA_WIDTH +: DATA_WIDTH
            ] = XV;

        end


        for (n = 0; n < N_NEURONS; n = n + 1) begin : GEN_WN

            for (i = 0; i < N_INPUTS; i = i + 1) begin : GEN_WI

                localparam integer WV =
                    ((n * 29 + i * 13 + 5) % 31) - 15;

                assign weights_bus[
                    (n*N_INPUTS+i)*DATA_WIDTH
                    +: DATA_WIDTH
                ] = WV;

            end

        end


        for (n = 0; n < N_NEURONS; n = n + 1) begin : GEN_B

            localparam integer BV =
                ((n * 7 + 1) % 9) - 4;

            assign bias_bus[
                n*DATA_WIDTH
                +: DATA_WIDTH
            ] = BV;

        end

    endgenerate


    /*
     * Real neural-network layer.
     */

    (* keep_hierarchy = "true" *)
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