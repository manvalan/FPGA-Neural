// ============================================================
// FPGA-Neural V2 -- Neural Processor Array (M2, docs/v2-description.md §8)
//
// Instantiates N_PROCESSORS independent neural_processor units (M1),
// each with its OWN dedicated point-to-point job/operand/result
// interface -- no shared bus, no arbitration, no mux at this level
// (§7: "evitare grandi mux dinamici come quelli dell'architettura
// V1"). Arbitrating which processor gets which job is explicitly the
// Neural Director's job (M5) and the Memory Manager's job (M4), not
// this array's -- at M2 the array is purely a resource/scaling
// vehicle: does the design synthesize, route, and run correctly with
// N independent copies, and how do LUT/FF/DSP/Fmax scale with N.
//
// Per-processor ports are flattened buses (port[i] occupies bits
// [i*WIDTH +: WIDTH]), the same convention used throughout V1's own
// multi-lane interfaces (e.g. x_bus/weights_bus).
//
// A blocked/errored processor (NP_ERROR, M1) never affects any other
// processor's ports -- each is wired independently, confirmed in
// tb_neural_processor_array.v by running N_PROCESSORS concurrently
// with staggered start times and one deliberately-slower job.
// ============================================================

module neural_processor_array #(
    parameter DATA_WIDTH    = 8,
    parameter P_IN          = 8,
    parameter ACC_WIDTH     = 32,
    parameter N_PROCESSORS  = 4
)(
    input clk,
    input rst,

    input      [N_PROCESSORS-1:0]                      job_valid,
    output     [N_PROCESSORS-1:0]                       job_ready,
    input      [16*N_PROCESSORS-1:0]                    job_node_id,
    input      signed [DATA_WIDTH*N_PROCESSORS-1:0]     job_bias,
    input      [2*N_PROCESSORS-1:0]                     job_activation,

    input      [N_PROCESSORS-1:0]                       operand_valid,
    output     [N_PROCESSORS-1:0]                        operand_ready,
    input      signed [DATA_WIDTH*P_IN*N_PROCESSORS-1:0] input_data,
    input      signed [DATA_WIDTH*P_IN*N_PROCESSORS-1:0] weight_data,
    input      [N_PROCESSORS-1:0]                       tile_last,

    output     [N_PROCESSORS-1:0]                       result_valid,
    input      [N_PROCESSORS-1:0]                       result_ready,
    output     signed [DATA_WIDTH*N_PROCESSORS-1:0]     result_data,
    output     [16*N_PROCESSORS-1:0]                    result_node_id,

    output     [4*N_PROCESSORS-1:0]                     np_state,
    output     [N_PROCESSORS-1:0]                       np_error
);

    genvar p;
    generate
        for (p = 0; p < N_PROCESSORS; p = p + 1) begin : GEN_NP

            neural_processor #(
                .DATA_WIDTH(DATA_WIDTH),
                .P_IN(P_IN),
                .ACC_WIDTH(ACC_WIDTH)
            ) u_np (
                .clk(clk),
                .rst(rst),

                .job_valid      (job_valid[p]),
                .job_ready      (job_ready[p]),
                .job_node_id    (job_node_id[p*16 +: 16]),
                .job_bias       (job_bias[p*DATA_WIDTH +: DATA_WIDTH]),
                .job_activation (job_activation[p*2 +: 2]),

                .operand_valid  (operand_valid[p]),
                .operand_ready  (operand_ready[p]),
                .input_data     (input_data[p*DATA_WIDTH*P_IN +: DATA_WIDTH*P_IN]),
                .weight_data    (weight_data[p*DATA_WIDTH*P_IN +: DATA_WIDTH*P_IN]),
                .tile_last      (tile_last[p]),

                .result_valid   (result_valid[p]),
                .result_ready   (result_ready[p]),
                .result_data    (result_data[p*DATA_WIDTH +: DATA_WIDTH]),
                .result_node_id (result_node_id[p*16 +: 16]),

                .np_state       (np_state[p*4 +: 4]),
                .np_error       (np_error[p])
            );

        end
    endgenerate

endmodule
