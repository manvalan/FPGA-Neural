module neuron_parallel #(
    parameter DATA_WIDTH = 8,
    parameter N_INPUTS   = 32,
    parameter PARALLEL   = 8,
    parameter ACC_WIDTH  = 32
)(
    input clk,
    input rst,
    input start,

    input signed [DATA_WIDTH*N_INPUTS-1:0] x_bus,
    input signed [DATA_WIDTH*N_INPUTS-1:0] w_bus,
    input signed [DATA_WIDTH-1:0] bias,

    output reg signed [DATA_WIDTH-1:0] y,
    output reg busy,
    output reg done
);

    localparam GROUPS = N_INPUTS / PARALLEL;
    localparam GROUP_INDEX_WIDTH =
        (GROUPS <= 1) ? 1 : $clog2(GROUPS);

    reg [GROUP_INDEX_WIDTH-1:0] group_index;

    reg signed [ACC_WIDTH-1:0] acc;

    wire signed [DATA_WIDTH*PARALLEL-1:0] x_group;
    wire signed [DATA_WIDTH*PARALLEL-1:0] w_group;

    wire signed [ACC_WIDTH-1:0] acc_next;

    wire signed [ACC_WIDTH-1:0] bias_ext;
    wire signed [ACC_WIDTH-1:0] final_acc;

    assign x_group =
        x_bus[
            group_index*PARALLEL*DATA_WIDTH
            +: PARALLEL*DATA_WIDTH
        ];

    assign w_group =
        w_bus[
            group_index*PARALLEL*DATA_WIDTH
            +: PARALLEL*DATA_WIDTH
        ];

    mac8 #(
        .DATA_WIDTH(DATA_WIDTH),
        .ACC_WIDTH(ACC_WIDTH),
        .PARALLEL(PARALLEL)
    ) u_mac8 (
        .x_bus(x_group),
        .w_bus(w_group),
        .acc_in(acc),
        .acc_out(acc_next)
    );

    // Sign extension INT8 -> INT32
    assign bias_ext =
        {{(ACC_WIDTH-DATA_WIDTH){bias[DATA_WIDTH-1]}}, bias};

    // Accumulazione finale + bias
    assign final_acc = acc_next + bias_ext;

    always @(posedge clk) begin

        if (rst) begin

            group_index <= 0;
            acc         <= 0;
            y           <= 0;
            busy        <= 0;
            done        <= 0;

        end else begin

            done <= 0;

            if (start && !busy) begin

                group_index <= 0;
                acc         <= 0;
                busy        <= 1;

            end else if (busy) begin

                if (group_index == GROUPS-1) begin

                    acc <= final_acc;

                    // ReLU
                    if (final_acc <= 0) begin
                        y <= 0;
                    end

                    // Saturazione INT32 -> INT8
                    else if (final_acc > 127) begin
                        y <= 8'sd127;
                    end

                    else begin
                        y <= final_acc[DATA_WIDTH-1:0];
                    end

                    busy <= 0;
                    done <= 1;

                end else begin

                    acc <= acc_next;
                    group_index <= group_index + 1'b1;

                end
            end
        end
    end

endmodule