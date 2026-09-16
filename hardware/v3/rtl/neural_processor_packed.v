// ============================================================
// FPGA-Neural V3 (Artix-7 port) -- Neural Processor, DSP48-packed.
//
// Direct port of hardware/v2/rtl/neural_processor.v (M1), restructured
// for the weight-stationary reuse pattern (layer_weight_buffer.v,
// EXP-0057/0058): ONE resident weight tile is shared by TWO reuse
// positions (job A, job B) processed in lockstep, each tap-lane packing
// its two x*w multiplies into a single DSP48-shaped multiply instead of
// two separate ones (see hardware/v3/rtl/mac2_dsp_packed.v, verified
// exhaustively 16,777,216/16,777,216 bit-exact -- the packing math
// here is the SAME formula, inlined per-lane rather than instantiated,
// to keep this module's own pipeline depth/stage count identical to
// the V2 original for a direct structural comparison).
//
// Pipeline stages match V2's neural_processor.v exactly, just doubled
// on the accumulator side (one accumulate/bias/activation/saturation
// path per job, A and B, sharing the SAME multiply/adder-tree stages
// since they consume the SAME weight stream):
//   Stage 0  input alignment (x0_a, x0_b, w0 -- ONE shared weight)
//   Stage 1  P_IN packed-MAC lanes: p0[i]=x0_a[i]*w0[i], p1[i]=x0_b[i]*w0[i]
//   Stage 2..(1+TREE_LEVELS)  TWO balanced adder trees (A and B)
//   Stage (2+TREE_LEVELS)      TWO accumulators
//   Stage (3+TREE_LEVELS)      bias add (shared bias/activation -- same
//                              neuron/filter, different spatial position)
//                              + activation, per job
//   Stage (4+TREE_LEVELS)      INT8 saturation / output register, per job
//
// job_bias/job_activation are SHARED between A and B (same resident
// neuron), matching this project's own weight-reuse semantics (a
// neuron/filter's bias and activation type don't vary by spatial
// position -- only its accumulated dot product does). node_id differs
// per job (A and B are different output positions).
// ============================================================

module neural_processor_packed #(
    parameter DATA_WIDTH = 8,
    parameter P_IN       = 8,
    parameter ACC_WIDTH  = 32
)(
    input clk,
    input rst,

    // ---- job descriptor (NP_LOAD_JOB) ----
    input                                job_valid,
    output                               job_ready,
    input      [15:0]                    job_node_id_a,
    input      [15:0]                    job_node_id_b,
    input      signed [DATA_WIDTH-1:0]   job_bias,        // shared (same neuron)
    input      [1:0]                     job_activation,  // shared (same neuron)

    // ---- operand stream: ONE shared weight stream, TWO activation streams ----
    input                                 operand_valid,
    output                                operand_ready,
    input      signed [DATA_WIDTH*P_IN-1:0] input_data_a,
    input      signed [DATA_WIDTH*P_IN-1:0] input_data_b,
    input      signed [DATA_WIDTH*P_IN-1:0] weight_data,
    input                                 tile_last,

    // ---- result stream: two results per job pair, same-cycle ----
    output reg                            result_valid,
    input                                 result_ready,
    output reg signed [DATA_WIDTH-1:0]    result_data_a,
    output reg signed [DATA_WIDTH-1:0]    result_data_b,
    output reg [15:0]                     result_node_id_a,
    output reg [15:0]                     result_node_id_b,

    output reg [3:0]                      np_state,
    output reg                            np_error
);

    localparam ACT_NONE = 2'd0;
    localparam ACT_RELU = 2'd1;

    localparam NP_IDLE          = 4'd0;
    localparam NP_LOAD_JOB      = 4'd1;
    localparam NP_WAIT_OPERANDS = 4'd2;
    localparam NP_FINISH        = 4'd3;
    localparam NP_WRITE_RESULT  = 4'd4;
    localparam NP_DONE          = 4'd5;
    localparam NP_ERROR         = 4'd6;

    localparam TREE_LEVELS = $clog2(P_IN);
    localparam PROD_WIDTH  = 2 * DATA_WIDTH;

    reg signed [DATA_WIDTH-1:0] bias_reg;
    reg [1:0]                   activation_reg;
    reg [15:0]                  node_id_a_reg, node_id_b_reg;

    assign operand_ready = (np_state == NP_WAIT_OPERANDS);

    // ============================================================
    // STAGE 0 -- input alignment
    // ============================================================
    reg                                    valid0, last0;
    reg signed [DATA_WIDTH-1:0]            xa0 [0:P_IN-1];
    reg signed [DATA_WIDTH-1:0]            xb0 [0:P_IN-1];
    reg signed [DATA_WIDTH-1:0]            w0  [0:P_IN-1];

    integer gi;

    always @(posedge clk) begin
        if (rst) begin
            valid0 <= 1'b0;
            last0  <= 1'b0;
        end else begin
            valid0 <= operand_valid && operand_ready;
            last0  <= (operand_valid && operand_ready) ? tile_last : 1'b0;
            if (operand_valid && operand_ready) begin
                for (gi = 0; gi < P_IN; gi = gi + 1) begin
                    xa0[gi] <= input_data_a[gi*DATA_WIDTH +: DATA_WIDTH];
                    xb0[gi] <= input_data_b[gi*DATA_WIDTH +: DATA_WIDTH];
                    w0[gi]  <= weight_data[gi*DATA_WIDTH +: DATA_WIDTH];
                end
            end
        end
    end

    // ============================================================
    // STAGE 1 -- P_IN packed-MAC lanes (mac2_dsp_packed.v's own
    // verified combinational formula, inlined per lane)
    // ============================================================
    reg                          valid1, last1;
    reg signed [ACC_WIDTH-1:0]   proda1 [0:P_IN-1];
    reg signed [ACC_WIDTH-1:0]   prodb1 [0:P_IN-1];

    localparam A_WIDTH = 3*DATA_WIDTH + 1;

    wire signed [PROD_WIDTH-1:0] pa_comb [0:P_IN-1];
    wire signed [PROD_WIDTH-1:0] pb_comb [0:P_IN-1];

    genvar gm;
    generate
        for (gm = 0; gm < P_IN; gm = gm + 1) begin : GEN_MAC_PACKED
            wire signed [A_WIDTH-1:0] x0_sext25  = {{(A_WIDTH-DATA_WIDTH){xa0[gm][DATA_WIDTH-1]}}, xa0[gm]};
            wire signed [A_WIDTH-1:0] x1_shifted = $signed(xb0[gm]) <<< (2*DATA_WIDTH);
            wire signed [A_WIDTH-1:0] packed_a   = x1_shifted + x0_sext25;
            wire signed [A_WIDTH+DATA_WIDTH-1:0] product = packed_a * w0[gm];

            assign pa_comb[gm] = product[PROD_WIDTH-1:0];
            wire signed [A_WIDTH+DATA_WIDTH-2*DATA_WIDTH-1:0] pb_raw =
                $signed(product) >>> (2*DATA_WIDTH);
            assign pb_comb[gm] = pb_raw[PROD_WIDTH-1:0] + (pa_comb[gm][PROD_WIDTH-1] ? 1'b1 : 1'b0);
        end
    endgenerate

    always @(posedge clk) begin
        if (rst) begin
            valid1 <= 1'b0;
            last1  <= 1'b0;
        end else begin
            valid1 <= valid0;
            last1  <= last0;
            for (gi = 0; gi < P_IN; gi = gi + 1) begin
                proda1[gi] <= {{(ACC_WIDTH-PROD_WIDTH){pa_comb[gi][PROD_WIDTH-1]}}, pa_comb[gi]};
                prodb1[gi] <= {{(ACC_WIDTH-PROD_WIDTH){pb_comb[gi][PROD_WIDTH-1]}}, pb_comb[gi]};
            end
        end
    end

    // ============================================================
    // STAGES 2..(1+TREE_LEVELS) -- TWO balanced adder trees (A, B)
    // ============================================================
    wire signed [ACC_WIDTH-1:0] level0a [0:P_IN-1];
    wire signed [ACC_WIDTH-1:0] level0b [0:P_IN-1];
    genvar gz;
    generate
        for (gz = 0; gz < P_IN; gz = gz + 1) begin : GEN_TREE_L0
            assign level0a[gz] = proda1[gz];
            assign level0b[gz] = prodb1[gz];
        end
    endgenerate

    reg  [TREE_LEVELS-1:0]                      valid_tree;
    reg  [TREE_LEVELS-1:0]                      last_tree;
    reg signed [ACC_WIDTH-1:0]                  treea [1:TREE_LEVELS][0:P_IN-1];
    reg signed [ACC_WIDTH-1:0]                  treeb [1:TREE_LEVELS][0:P_IN-1];

    genvar gl, gn;
    generate
        for (gl = 0; gl < TREE_LEVELS; gl = gl + 1) begin : GEN_TREE_LEVEL
            always @(posedge clk) begin
                if (rst) begin
                    valid_tree[gl] <= 1'b0;
                    last_tree[gl]  <= 1'b0;
                end else begin
                    valid_tree[gl] <= (gl == 0) ? valid1 : valid_tree[gl-1];
                    last_tree[gl]  <= (gl == 0) ? last1  : last_tree[gl-1];
                end
            end
            for (gn = 0; gn < (P_IN >> (gl+1)); gn = gn + 1) begin : GEN_TREE_NODE
                if (gl == 0) begin : GEN_FROM_LEVEL0
                    always @(posedge clk) begin
                        treea[1][gn] <= level0a[2*gn] + level0a[2*gn+1];
                        treeb[1][gn] <= level0b[2*gn] + level0b[2*gn+1];
                    end
                end else begin : GEN_FROM_TREE
                    always @(posedge clk) begin
                        treea[gl+1][gn] <= treea[gl][2*gn] + treea[gl][2*gn+1];
                        treeb[gl+1][gn] <= treeb[gl][2*gn] + treeb[gl][2*gn+1];
                    end
                end
            end
        end
    endgenerate

    wire                         valid_tree_out = (TREE_LEVELS == 0) ? valid1 : valid_tree[TREE_LEVELS-1];
    wire                         last_tree_out  = (TREE_LEVELS == 0) ? last1  : last_tree[TREE_LEVELS-1];
    wire signed [ACC_WIDTH-1:0]  tile_sum_a     = (TREE_LEVELS == 0) ? proda1[0] : treea[TREE_LEVELS][0];
    wire signed [ACC_WIDTH-1:0]  tile_sum_b     = (TREE_LEVELS == 0) ? prodb1[0] : treeb[TREE_LEVELS][0];

    // ============================================================
    // STAGE (2+TREE_LEVELS) -- TWO accumulators
    // ============================================================
    reg signed [ACC_WIDTH-1:0] acc_reg_a, acc_reg_b;
    reg                        valid5, last5;

    always @(posedge clk) begin
        if (rst) begin
            acc_reg_a <= {ACC_WIDTH{1'b0}};
            acc_reg_b <= {ACC_WIDTH{1'b0}};
            valid5    <= 1'b0;
            last5     <= 1'b0;
        end else begin
            valid5 <= valid_tree_out;
            last5  <= last_tree_out;
            if (np_state == NP_LOAD_JOB) begin
                acc_reg_a <= {ACC_WIDTH{1'b0}};
                acc_reg_b <= {ACC_WIDTH{1'b0}};
            end else if (valid_tree_out) begin
                acc_reg_a <= acc_reg_a + tile_sum_a;
                acc_reg_b <= acc_reg_b + tile_sum_b;
            end
        end
    end

    // ============================================================
    // STAGE (3+TREE_LEVELS) -- bias add + activation (shared bias/act)
    // ============================================================
    wire signed [ACC_WIDTH-1:0] bias_ext =
        {{(ACC_WIDTH-DATA_WIDTH){bias_reg[DATA_WIDTH-1]}}, bias_reg};

    reg                        valid6, last6;
    reg signed [ACC_WIDTH-1:0] final_acc_a, final_acc_b;

    always @(posedge clk) begin
        if (rst) begin
            valid6 <= 1'b0;
            last6  <= 1'b0;
        end else begin
            valid6      <= valid5;
            last6       <= last5;
            final_acc_a <= acc_reg_a + bias_ext;
            final_acc_b <= acc_reg_b + bias_ext;
        end
    end

    function automatic signed [DATA_WIDTH-1:0] saturate_activate(
        input signed [ACC_WIDTH-1:0] final_acc,
        input [1:0] activation
    );
        reg sign;
        reg upper_all0, upper_all1, in_range, le_zero;
        reg signed [DATA_WIDTH-1:0] y_none, y_relu;
        begin
            sign       = final_acc[ACC_WIDTH-1];
            upper_all0 = ~(|final_acc[ACC_WIDTH-1:DATA_WIDTH-1]);
            upper_all1 =  &final_acc[ACC_WIDTH-1:DATA_WIDTH-1];
            in_range   = upper_all0 | upper_all1;
            le_zero    = sign | ~(|final_acc);

            y_none = in_range ? final_acc[DATA_WIDTH-1:0]
                               : (sign ? {1'b1, {(DATA_WIDTH-1){1'b0}}}
                                       : {1'b0, {(DATA_WIDTH-1){1'b1}}});
            y_relu = le_zero ? {DATA_WIDTH{1'b0}}
                              : (upper_all0 ? final_acc[DATA_WIDTH-1:0]
                                            : {1'b0, {(DATA_WIDTH-1){1'b1}}});
            saturate_activate = (activation == ACT_NONE) ? y_none : y_relu;
        end
    endfunction

    // ============================================================
    // STAGE (4+TREE_LEVELS) -- output register / saturation, per job
    // ============================================================
    reg                          valid7;
    reg signed [DATA_WIDTH-1:0]  y7_a, y7_b;

    always @(posedge clk) begin
        if (rst) begin
            valid7 <= 1'b0;
        end else begin
            valid7 <= last6;
            y7_a   <= saturate_activate(final_acc_a, activation_reg);
            y7_b   <= saturate_activate(final_acc_b, activation_reg);
        end
    end

    wire pipeline_busy = valid0 || valid1 || (|valid_tree) || valid5 || valid6 || valid7;
    assign job_ready = (np_state == NP_IDLE) && !pipeline_busy;

    // ============================================================
    // OUTER FSM -- identical shape to V2, both result channels together
    // ============================================================
    always @(posedge clk) begin
        if (rst) begin
            np_state         <= NP_IDLE;
            np_error         <= 1'b0;
            result_valid     <= 1'b0;
            result_data_a    <= {DATA_WIDTH{1'b0}};
            result_data_b    <= {DATA_WIDTH{1'b0}};
            result_node_id_a <= 16'h0;
            result_node_id_b <= 16'h0;
            bias_reg         <= {DATA_WIDTH{1'b0}};
            activation_reg   <= ACT_RELU;
            node_id_a_reg    <= 16'h0;
            node_id_b_reg    <= 16'h0;
        end else begin
            case (np_state)

                NP_IDLE: begin
                    if (job_valid && job_ready) begin
                        bias_reg       <= job_bias;
                        activation_reg <= job_activation;
                        node_id_a_reg  <= job_node_id_a;
                        node_id_b_reg  <= job_node_id_b;
                        np_state       <= NP_LOAD_JOB;
                    end
                end

                NP_LOAD_JOB: begin
                    np_state <= NP_WAIT_OPERANDS;
                end

                NP_WAIT_OPERANDS: begin
                    if (operand_valid && operand_ready && tile_last) begin
                        np_state <= NP_FINISH;
                    end
                end

                NP_FINISH: begin
                    if (valid7) begin
                        result_valid     <= 1'b1;
                        result_data_a    <= y7_a;
                        result_data_b    <= y7_b;
                        result_node_id_a <= node_id_a_reg;
                        result_node_id_b <= node_id_b_reg;
                        np_state         <= NP_WRITE_RESULT;
                    end
                end

                NP_WRITE_RESULT: begin
                    if (result_valid && result_ready) begin
                        result_valid <= 1'b0;
                        np_state     <= NP_DONE;
                    end
                end

                NP_DONE: begin
                    np_state <= NP_IDLE;
                end

                NP_ERROR: begin
                end

                default: np_state <= NP_ERROR;

            endcase
        end
    end

endmodule
