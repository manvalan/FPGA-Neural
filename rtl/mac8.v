module mac8 #(
    parameter DATA_WIDTH = 16,
    parameter ACC_WIDTH  = 40
)(
    input signed [DATA_WIDTH*8-1:0] x_bus,
    input signed [DATA_WIDTH*8-1:0] w_bus,
    input signed [ACC_WIDTH-1:0] acc_in,
    output signed [ACC_WIDTH-1:0] acc_out
);

    wire signed [ACC_WIDTH-1:0] m0;
    wire signed [ACC_WIDTH-1:0] m1;
    wire signed [ACC_WIDTH-1:0] m2;
    wire signed [ACC_WIDTH-1:0] m3;
    wire signed [ACC_WIDTH-1:0] m4;
    wire signed [ACC_WIDTH-1:0] m5;
    wire signed [ACC_WIDTH-1:0] m6;
    wire signed [ACC_WIDTH-1:0] m7;

    wire signed [ACC_WIDTH-1:0] s0;
    wire signed [ACC_WIDTH-1:0] s1;
    wire signed [ACC_WIDTH-1:0] s2;
    wire signed [ACC_WIDTH-1:0] s3;

    wire signed [ACC_WIDTH-1:0] s4;
    wire signed [ACC_WIDTH-1:0] s5;

    wire signed [ACC_WIDTH-1:0] sum;

    mac_unit #(
        .DATA_WIDTH(DATA_WIDTH),
        .ACC_WIDTH(ACC_WIDTH)
    ) mac0 (
        .x(x_bus[0*DATA_WIDTH +: DATA_WIDTH]),
        .w(w_bus[0*DATA_WIDTH +: DATA_WIDTH]),
        .acc_in({ACC_WIDTH{1'b0}}),
        .acc_out(m0)
    );

    mac_unit #(
        .DATA_WIDTH(DATA_WIDTH),
        .ACC_WIDTH(ACC_WIDTH)
    ) mac1 (
        .x(x_bus[1*DATA_WIDTH +: DATA_WIDTH]),
        .w(w_bus[1*DATA_WIDTH +: DATA_WIDTH]),
        .acc_in({ACC_WIDTH{1'b0}}),
        .acc_out(m1)
    );

    mac_unit #(
        .DATA_WIDTH(DATA_WIDTH),
        .ACC_WIDTH(ACC_WIDTH)
    ) mac2 (
        .x(x_bus[2*DATA_WIDTH +: DATA_WIDTH]),
        .w(w_bus[2*DATA_WIDTH +: DATA_WIDTH]),
        .acc_in({ACC_WIDTH{1'b0}}),
        .acc_out(m2)
    );

    mac_unit #(
        .DATA_WIDTH(DATA_WIDTH),
        .ACC_WIDTH(ACC_WIDTH)
    ) mac3 (
        .x(x_bus[3*DATA_WIDTH +: DATA_WIDTH]),
        .w(w_bus[3*DATA_WIDTH +: DATA_WIDTH]),
        .acc_in({ACC_WIDTH{1'b0}}),
        .acc_out(m3)
    );

    mac_unit #(
        .DATA_WIDTH(DATA_WIDTH),
        .ACC_WIDTH(ACC_WIDTH)
    ) mac4 (
        .x(x_bus[4*DATA_WIDTH +: DATA_WIDTH]),
        .w(w_bus[4*DATA_WIDTH +: DATA_WIDTH]),
        .acc_in({ACC_WIDTH{1'b0}}),
        .acc_out(m4)
    );

    mac_unit #(
        .DATA_WIDTH(DATA_WIDTH),
        .ACC_WIDTH(ACC_WIDTH)
    ) mac5 (
        .x(x_bus[5*DATA_WIDTH +: DATA_WIDTH]),
        .w(w_bus[5*DATA_WIDTH +: DATA_WIDTH]),
        .acc_in({ACC_WIDTH{1'b0}}),
        .acc_out(m5)
    );

    mac_unit #(
        .DATA_WIDTH(DATA_WIDTH),
        .ACC_WIDTH(ACC_WIDTH)
    ) mac6 (
        .x(x_bus[6*DATA_WIDTH +: DATA_WIDTH]),
        .w(w_bus[6*DATA_WIDTH +: DATA_WIDTH]),
        .acc_in({ACC_WIDTH{1'b0}}),
        .acc_out(m6)
    );

    mac_unit #(
        .DATA_WIDTH(DATA_WIDTH),
        .ACC_WIDTH(ACC_WIDTH)
    ) mac7 (
        .x(x_bus[7*DATA_WIDTH +: DATA_WIDTH]),
        .w(w_bus[7*DATA_WIDTH +: DATA_WIDTH]),
        .acc_in({ACC_WIDTH{1'b0}}),
        .acc_out(m7)
    );

    assign s0 = m0 + m1;
    assign s1 = m2 + m3;
    assign s2 = m4 + m5;
    assign s3 = m6 + m7;

    assign s4 = s0 + s1;
    assign s5 = s2 + s3;

    assign sum = s4 + s5;

    assign acc_out = acc_in + sum;

endmodule