`timescale 1ns/1ps

// ============================================================
// EXP-0059 follow-up -- N independent neural_processor_packed.v
// cores, flat array, NO Director/arbiter/memory path yet.
//
// PURPOSE: isolate exactly one variable -- what real P&R placement/
// routing congestion does to Fmax once N copies of the DSP48-packed
// core sit side by side on XC7A100T -- before adding any new
// (unverified) integration RTL (Director, arbiter, memory path).
// Each core keeps its own independent, unshared I/O (flattened to
// N*WIDTH buses, sliced per-instance below); there is deliberately NO
// interconnect logic here to conflate with the placement-density
// question this experiment is asking. Matches this project's own
// "one variable at a time" convention (see decisions.log).
// ============================================================
module np_packed_array #(
    parameter DATA_WIDTH = 8,
    parameter P_IN       = 8,
    parameter ACC_WIDTH  = 32,
    parameter N_CORES    = 8
)(
    input  wire clk,
    input  wire rst,

    input  wire [N_CORES-1:0]                       job_valid,
    output wire [N_CORES-1:0]                       job_ready,
    input  wire [N_CORES*16-1:0]                     job_node_id_a,
    input  wire [N_CORES*16-1:0]                     job_node_id_b,
    input  wire [N_CORES*DATA_WIDTH-1:0]             job_bias,
    input  wire [N_CORES*2-1:0]                      job_activation,

    input  wire [N_CORES-1:0]                        operand_valid,
    output wire [N_CORES-1:0]                        operand_ready,
    input  wire [N_CORES*DATA_WIDTH*P_IN-1:0]        input_data_a,
    input  wire [N_CORES*DATA_WIDTH*P_IN-1:0]        input_data_b,
    input  wire [N_CORES*DATA_WIDTH*P_IN-1:0]        weight_data,
    input  wire [N_CORES-1:0]                        tile_last,

    output wire [N_CORES-1:0]                        result_valid,
    input  wire [N_CORES-1:0]                        result_ready,
    output wire [N_CORES*DATA_WIDTH-1:0]             result_data_a,
    output wire [N_CORES*DATA_WIDTH-1:0]             result_data_b,
    output wire [N_CORES*16-1:0]                     result_node_id_a,
    output wire [N_CORES*16-1:0]                     result_node_id_b,

    output wire [N_CORES*4-1:0]                      np_state,
    output wire [N_CORES-1:0]                        np_error
);
    genvar gc;
    generate
        for (gc = 0; gc < N_CORES; gc = gc + 1) begin : GEN_CORE
            neural_processor_packed #(
                .DATA_WIDTH(DATA_WIDTH), .P_IN(P_IN), .ACC_WIDTH(ACC_WIDTH)
            ) u_core (
                .clk(clk), .rst(rst),
                .job_valid(job_valid[gc]),
                .job_ready(job_ready[gc]),
                .job_node_id_a(job_node_id_a[gc*16 +: 16]),
                .job_node_id_b(job_node_id_b[gc*16 +: 16]),
                .job_bias(job_bias[gc*DATA_WIDTH +: DATA_WIDTH]),
                .job_activation(job_activation[gc*2 +: 2]),
                .operand_valid(operand_valid[gc]),
                .operand_ready(operand_ready[gc]),
                .input_data_a(input_data_a[gc*DATA_WIDTH*P_IN +: DATA_WIDTH*P_IN]),
                .input_data_b(input_data_b[gc*DATA_WIDTH*P_IN +: DATA_WIDTH*P_IN]),
                .weight_data(weight_data[gc*DATA_WIDTH*P_IN +: DATA_WIDTH*P_IN]),
                .tile_last(tile_last[gc]),
                .result_valid(result_valid[gc]),
                .result_ready(result_ready[gc]),
                .result_data_a(result_data_a[gc*DATA_WIDTH +: DATA_WIDTH]),
                .result_data_b(result_data_b[gc*DATA_WIDTH +: DATA_WIDTH]),
                .result_node_id_a(result_node_id_a[gc*16 +: 16]),
                .result_node_id_b(result_node_id_b[gc*16 +: 16]),
                .np_state(np_state[gc*4 +: 4]),
                .np_error(np_error[gc])
            );
        end
    endgenerate
endmodule
