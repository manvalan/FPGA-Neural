module mac_unit #(
    parameter DATA_WIDTH = 16,
    parameter ACC_WIDTH  = 40
)(
    input  signed [DATA_WIDTH-1:0] x,
    input  signed [DATA_WIDTH-1:0] w,
    input  signed [ACC_WIDTH-1:0] acc_in,
    output signed [ACC_WIDTH-1:0] acc_out
);

    localparam PROD_WIDTH = 2 * DATA_WIDTH;

    wire signed [PROD_WIDTH-1:0] product;
    wire signed [ACC_WIDTH-1:0] product_ext;

    assign product = x * w;

    assign product_ext =
        {{(ACC_WIDTH-PROD_WIDTH){product[PROD_WIDTH-1]}}, product};

    assign acc_out = acc_in + product_ext;

endmodule