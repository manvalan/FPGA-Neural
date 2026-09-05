// ============================================================
// SYNTHESIS-ONLY TIMING HARNESS -- NOT a functional deliverable.
//
// neural_processor_array.v's real ports (per-processor wide
// input_data/weight_data buses, per-processor job/result fields) are
// meant to be driven on-chip by the Memory Manager (M4) and Neural
// Director (M5), which do not exist yet. Synthesizing the array
// standalone with every one of those bits exposed as a real
// TRELLIS_IO pin exhausts the ECP5's ~245 available I/O well before
// N_PROCESSORS=2 (see hardware/v2/logs/errors.log ERR-0005) -- a
// packaging artifact of this specific isolated measurement, NOT a
// logic/timing limit of the array itself.
//
// This harness replaces the wide external buses with an internal
// free-running LFSR (so the data ports are not synthesized away as
// constants) and reduces the outputs to a small XOR-reduced checksum,
// keeping only clk/rst/seed/checksum as real top-level pins. This
// gives a representative Fmax for the array's OWN logic/routing
// congestion, uninflated and unconstrained by an artificial pin
// budget that will not exist once M4/M5 land.
// ============================================================

module harness_neural_processor_array #(
    parameter DATA_WIDTH   = 8,
    parameter P_IN         = 8,
    parameter ACC_WIDTH    = 32,
    parameter N_PROCESSORS = 4
)(
    input  clk,
    input  rst,
    input  [7:0] seed,
    output [7:0] checksum
);

    reg [31:0] lfsr;
    always @(posedge clk) begin
        if (rst) lfsr <= {24'h0, seed} | 32'h1;
        else     lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
    end

    // Each processor gets a DISTINCT data slice (LFSR rotated by its
    // own index) so Yosys cannot common-subexpression-eliminate
    // N_PROCESSORS identical instances down to one -- that would
    // silently defeat the point of the N_PROCESSORS sweep.
    genvar hgi;
    wire [N_PROCESSORS-1:0]                       job_valid;
    wire [16*N_PROCESSORS-1:0]                    job_node_id;
    wire signed [DATA_WIDTH*N_PROCESSORS-1:0]     job_bias;
    wire [2*N_PROCESSORS-1:0]                     job_activation;
    wire [N_PROCESSORS-1:0]                       operand_valid;
    wire signed [DATA_WIDTH*P_IN*N_PROCESSORS-1:0] input_data;
    wire signed [DATA_WIDTH*P_IN*N_PROCESSORS-1:0] weight_data;
    wire [N_PROCESSORS-1:0]                       tile_last;
    wire [N_PROCESSORS-1:0]                       result_ready;
    genvar hgk;
    generate
        for (hgi = 0; hgi < N_PROCESSORS; hgi = hgi + 1) begin : GEN_HARNESS_LANE
            wire [31:0] rot = {lfsr[hgi:0], lfsr[31:hgi+1]};
            assign job_valid[hgi]                                  = rot[0];
            assign job_node_id[hgi*16 +: 16]                       = rot[15:0];
            assign job_bias[hgi*DATA_WIDTH +: DATA_WIDTH]          = rot[7:0];
            assign job_activation[hgi*2 +: 2]                      = rot[1:0];
            assign operand_valid[hgi]                              = rot[2];
            assign tile_last[hgi]                                  = rot[3];
            assign result_ready[hgi]                               = rot[4];
            // Each of the P_IN MAC lanes WITHIN this processor also
            // needs a distinct value -- otherwise all P_IN
            // multiplications are identical and Yosys collapses them
            // to a single shared MULT18X18D (observed: N=1 synthesized
            // to just 1 multiplier instead of P_IN=8).
            for (hgk = 0; hgk < P_IN; hgk = hgk + 1) begin : GEN_HARNESS_MAC_LANE
                wire [31:0] lane_rot = {rot[hgk:0], rot[31:hgk+1]};
                assign input_data[hgi*DATA_WIDTH*P_IN + hgk*DATA_WIDTH +: DATA_WIDTH]  = lane_rot[7:0];
                assign weight_data[hgi*DATA_WIDTH*P_IN + hgk*DATA_WIDTH +: DATA_WIDTH] = lane_rot[15:8];
            end
        end
    endgenerate

    wire [N_PROCESSORS-1:0]                       job_ready;
    wire [N_PROCESSORS-1:0]                       operand_ready;
    wire [N_PROCESSORS-1:0]                       result_valid;
    wire signed [DATA_WIDTH*N_PROCESSORS-1:0]     result_data;
    wire [16*N_PROCESSORS-1:0]                    result_node_id;
    wire [4*N_PROCESSORS-1:0]                     np_state;
    wire [N_PROCESSORS-1:0]                       np_error;

    neural_processor_array #(
        .DATA_WIDTH(DATA_WIDTH), .P_IN(P_IN), .ACC_WIDTH(ACC_WIDTH),
        .N_PROCESSORS(N_PROCESSORS)
    ) dut (
        .clk(clk), .rst(rst),
        .job_valid(job_valid), .job_ready(job_ready),
        .job_node_id(job_node_id), .job_bias(job_bias), .job_activation(job_activation),
        .operand_valid(operand_valid), .operand_ready(operand_ready),
        .input_data(input_data), .weight_data(weight_data), .tile_last(tile_last),
        .result_valid(result_valid), .result_ready(result_ready),
        .result_data(result_data), .result_node_id(result_node_id),
        .np_state(np_state), .np_error(np_error)
    );

    // Fold in a real bit from EVERY processor's wide outputs
    // (result_data/result_node_id/np_state), not just processor 0's
    // slice -- otherwise the arithmetic datapath of every processor
    // but one has no observable path to any output at all, and Yosys
    // correctly (from a pure logic-equivalence standpoint) strips it
    // out as dead logic, silently defeating the N_PROCESSORS sweep.
    wire [N_PROCESSORS-1:0] result_data_lsb;
    wire [N_PROCESSORS-1:0] result_node_id_lsb;
    wire [N_PROCESSORS-1:0] np_state_lsb;
    generate
        for (hgi = 0; hgi < N_PROCESSORS; hgi = hgi + 1) begin : GEN_CHK_LANE
            assign result_data_lsb[hgi]    = result_data[hgi*DATA_WIDTH];
            assign result_node_id_lsb[hgi] = result_node_id[hgi*16];
            assign np_state_lsb[hgi]       = np_state[hgi*4];
        end
    endgenerate

    reg [7:0] chk;
    always @(posedge clk) begin
        if (rst) chk <= 8'h0;
        else chk <= chk ^ job_ready ^ operand_ready ^ result_valid ^ np_error
                        ^ result_data_lsb ^ result_node_id_lsb ^ np_state_lsb;
    end
    assign checksum = chk;

endmodule
