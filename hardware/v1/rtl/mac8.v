module mac8 #(
    parameter DATA_WIDTH = 16,
    parameter ACC_WIDTH  = 40,
    parameter PARALLEL   = 8
)(
    input signed [DATA_WIDTH*PARALLEL-1:0] x_bus,
    input signed [DATA_WIDTH*PARALLEL-1:0] w_bus,
    input signed [ACC_WIDTH-1:0] acc_in,
    output signed [ACC_WIDTH-1:0] acc_out
);

    /*
     * Each MAC produces one sign-extended product.
     */
    wire signed [ACC_WIDTH-1:0] products [0:PARALLEL-1];

    genvar i;

    generate
        for (i = 0; i < PARALLEL; i = i + 1) begin : GEN_MAC

            mac_unit #(
                .DATA_WIDTH(DATA_WIDTH),
                .ACC_WIDTH(ACC_WIDTH)
            ) u_mac (
                .x(
                    x_bus[
                        i*DATA_WIDTH
                        +:
                        DATA_WIDTH
                    ]
                ),
                .w(
                    w_bus[
                        i*DATA_WIDTH
                        +:
                        DATA_WIDTH
                    ]
                ),
                .acc_in({ACC_WIDTH{1'b0}}),
                .acc_out(products[i])
            );

        end
    endgenerate


    /*
     * Balanced binary adder tree.
     *
     * PARALLEL is intended to be a power of two:
     *   8  -> 3 levels
     *   16 -> 4 levels
     *   32 -> 5 levels
     *
     * This replaces the previous linear accumulator:
     *
     *   (((p0+p1)+p2)+p3)+...
     *
     * with:
     *
     *             sum
     *           /     \
     *        ...       ...
     *
     * reducing the combinational depth from O(PARALLEL)
     * to O(log2(PARALLEL)).
     */

    localparam TREE_LEVELS = $clog2(PARALLEL);

    wire signed [ACC_WIDTH-1:0]
        tree [0:TREE_LEVELS][0:PARALLEL-1];

    generate

        /*
         * Level 0 = individual products
         */
        for (i = 0; i < PARALLEL; i = i + 1) begin : GEN_TREE_INPUT
            assign tree[0][i] = products[i];
        end

    endgenerate


    genvar level;
    genvar node;

    generate

        for (level = 0; level < TREE_LEVELS; level = level + 1) begin : GEN_TREE_LEVEL

            for (
                node = 0;
                node < (PARALLEL >> (level + 1));
                node = node + 1
            ) begin : GEN_TREE_NODE

                assign tree[level + 1][node] =
                    tree[level][2*node] +
                    tree[level][2*node + 1];

            end

        end

    endgenerate


    /*
     * Add the partial sum to the accumulator.
     */
    assign acc_out =
        acc_in + tree[TREE_LEVELS][0];

endmodule