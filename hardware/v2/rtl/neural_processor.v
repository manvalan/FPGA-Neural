// ============================================================
// FPGA-Neural V2 -- Neural Processor (M1, docs/v2-description.md §5/§6/§7)
//
// Autonomous, pipelined perceptron unit. Processes ONE neuron (job) at a
// time, but the internal MAC datapath is a genuine 8-stage pipeline
// (P_IN=8 baseline): a new tile of P_IN inputs/weights can be accepted
// every cycle while the previous tiles are still draining through the
// adder tree/accumulator/activation stages -- throughput-oriented per
// §5 ("l'obiettivo principale e' il throughput, non la minima latenza").
//
// Arithmetic is bit-exact with hardware/v1/rtl/neuron_parallel.v +
// mac8.v + mac_unit.v (same MAC order, same sign-extended INT32-style
// accumulation, same bias/activation/saturation logic) -- verified in
// sim/tb_neural_processor.v against the frozen V1 reference. See
// hardware/v2/logs/decisions.log DEC-0002 for why the outer FSM merges
// the LOAD_TILE/MAC/ACCUM/NEXT_TILE states from §6's baseline list into
// a single pipelined NP_WAIT_OPERANDS state.
//
// Stage pipeline (P_IN=8, TREE_LEVELS=log2(P_IN)=3):
//   Stage 0  input alignment/register
//   Stage 1  P_IN multipliers (INT8 x INT8)
//   Stage 2..(1+TREE_LEVELS)  balanced adder tree, one level per stage
//   Stage (2+TREE_LEVELS)      accumulator (running sum across tiles)
//   Stage (3+TREE_LEVELS)      bias add + activation
//   Stage (4+TREE_LEVELS)      INT8 saturation / output register
// For P_IN=8 this is stages 0..7 (8 stages total), matching §5 exactly.
// ============================================================

module neural_processor #(
    parameter DATA_WIDTH = 8,
    parameter P_IN       = 8,
    parameter ACC_WIDTH  = 32
)(
    input clk,
    input rst,

    // ---- job descriptor (NP_LOAD_JOB) ----
    // Address fields (input/weight/bias base addresses) from §6's
    // baseline job descriptor are intentionally NOT part of this
    // interface yet -- M1 has no Memory Manager (§v2-description.md
    // roadmap M4), operands are streamed directly by the testbench.
    // They will be added when the Memory Manager (M4) is integrated.
    input                                job_valid,
    output                               job_ready,
    input      [15:0]                    job_node_id,
    input      signed [DATA_WIDTH-1:0]   job_bias,
    input      [1:0]                     job_activation,

    // ---- operand stream (valid/ready/data/last, §7) ----
    input                                 operand_valid,
    output                                operand_ready,
    input      signed [DATA_WIDTH*P_IN-1:0] input_data,
    input      signed [DATA_WIDTH*P_IN-1:0] weight_data,
    input                                 tile_last,

    // ---- result stream (valid/ready/data, §7) ----
    output reg                            result_valid,
    input                                 result_ready,
    output reg signed [DATA_WIDTH-1:0]    result_data,
    output reg [15:0]                     result_node_id,

    // observability (testbench/debug, not part of the handshake contract)
    output reg [3:0]                      np_state,
    output reg                            np_error
);

    // ============================================================
    // ACTIVATION ENCODING -- identical to hardware/v1/rtl/neuron_parallel.v
    // ============================================================
    localparam ACT_NONE = 2'd0;
    localparam ACT_RELU = 2'd1;

    // ============================================================
    // OUTER FSM STATE ENCODING (§6 baseline, see DEC-0002 for the
    // 4-state merge)
    // ============================================================
    localparam NP_IDLE          = 4'd0;
    localparam NP_LOAD_JOB      = 4'd1;
    localparam NP_WAIT_OPERANDS = 4'd2; // absorbs LOAD_TILE/MAC/ACCUM/NEXT_TILE
    localparam NP_FINISH        = 4'd3; // draining pipeline after tile_last
    localparam NP_WRITE_RESULT  = 4'd4;
    localparam NP_DONE          = 4'd5;
    localparam NP_ERROR         = 4'd6;

    localparam TREE_LEVELS = $clog2(P_IN);
    localparam PROD_WIDTH  = 2 * DATA_WIDTH;

    // ---- job context (latched at NP_LOAD_JOB, held for the whole job) ----
    reg signed [DATA_WIDTH-1:0] bias_reg;
    reg [1:0]                   activation_reg;
    reg [15:0]                  node_id_reg;

    assign operand_ready = (np_state == NP_WAIT_OPERANDS);

    // ============================================================
    // STAGE 0 -- input alignment/register
    // ============================================================
    reg                                    valid0, last0;
    reg signed [DATA_WIDTH-1:0]            x0 [0:P_IN-1];
    reg signed [DATA_WIDTH-1:0]            w0 [0:P_IN-1];

    integer gi;

    always @(posedge clk) begin
        if (rst) begin
            valid0 <= 1'b0;
            last0  <= 1'b0;
        end else begin
            valid0 <= operand_valid && operand_ready;
            // last0 must be gated exactly like valid0 -- otherwise a
            // tile_last asserted by the master before operand_ready
            // rises (ordinary valid-before-ready behavior, see
            // operand_ready's own comment above) leaks a "last" tag
            // into the pipeline with no corresponding valid tile,
            // racing ahead of the real one and corrupting the
            // valid5/last5-derived capture at stage 6/7 (see
            // hardware/v2/logs/errors.log ERR-0003).
            last0  <= (operand_valid && operand_ready) ? tile_last : 1'b0;
            if (operand_valid && operand_ready) begin
                for (gi = 0; gi < P_IN; gi = gi + 1) begin
                    x0[gi] <= input_data[gi*DATA_WIDTH +: DATA_WIDTH];
                    w0[gi] <= weight_data[gi*DATA_WIDTH +: DATA_WIDTH];
                end
            end
        end
    end

    // ============================================================
    // STAGE 1 -- P_IN multipliers, sign-extended to ACC_WIDTH
    // (same per-lane product as hardware/v1/rtl/mac_unit.v)
    // ============================================================
    reg                          valid1, last1;
    reg signed [ACC_WIDTH-1:0]   prod1 [0:P_IN-1];

    wire signed [PROD_WIDTH-1:0] product_comb [0:P_IN-1];
    genvar gm;
    generate
        for (gm = 0; gm < P_IN; gm = gm + 1) begin : GEN_MUL
            assign product_comb[gm] = x0[gm] * w0[gm];
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
                prod1[gi] <= {{(ACC_WIDTH-PROD_WIDTH){product_comb[gi][PROD_WIDTH-1]}}, product_comb[gi]};
            end
        end
    end

    // ============================================================
    // STAGES 2..(1+TREE_LEVELS) -- balanced adder tree, one level/stage
    // (same tree order as hardware/v1/rtl/mac8.v)
    // ============================================================
    // Level 0 (combinational view of the registered products) is kept
    // as plain wires, never written by an always block -- only levels
    // 1..TREE_LEVELS are real registers, each with exactly one driver
    // (its own GEN_TREE_NODE always block), avoiding any reg array
    // with mixed combinational/sequential drivers across generate
    // blocks.
    wire signed [ACC_WIDTH-1:0] level0 [0:P_IN-1];
    genvar gz;
    generate
        for (gz = 0; gz < P_IN; gz = gz + 1) begin : GEN_TREE_L0
            assign level0[gz] = prod1[gz];
        end
    endgenerate

    reg  [TREE_LEVELS-1:0]                      valid_tree;
    reg  [TREE_LEVELS-1:0]                      last_tree;
    reg signed [ACC_WIDTH-1:0]                  tree [1:TREE_LEVELS][0:P_IN-1];

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
                        tree[1][gn] <= level0[2*gn] + level0[2*gn+1];
                    end
                end else begin : GEN_FROM_TREE
                    always @(posedge clk) begin
                        tree[gl+1][gn] <= tree[gl][2*gn] + tree[gl][2*gn+1];
                    end
                end
            end
        end
    endgenerate

    wire                         valid_tree_out = (TREE_LEVELS == 0) ? valid1 : valid_tree[TREE_LEVELS-1];
    wire                         last_tree_out  = (TREE_LEVELS == 0) ? last1  : last_tree[TREE_LEVELS-1];
    wire signed [ACC_WIDTH-1:0]  tile_sum       = (TREE_LEVELS == 0) ? prod1[0] : tree[TREE_LEVELS][0];

    // ============================================================
    // STAGE (2+TREE_LEVELS) -- accumulator (running sum across tiles
    // of the SAME job; cleared at NP_LOAD_JOB)
    // ============================================================
    reg signed [ACC_WIDTH-1:0] acc_reg;
    reg                        valid5, last5;

    always @(posedge clk) begin
        if (rst) begin
            acc_reg <= {ACC_WIDTH{1'b0}};
            valid5  <= 1'b0;
            last5   <= 1'b0;
        end else begin
            valid5 <= valid_tree_out;
            last5  <= last_tree_out;
            if (np_state == NP_LOAD_JOB) begin
                acc_reg <= {ACC_WIDTH{1'b0}};
            end else if (valid_tree_out) begin
                acc_reg <= acc_reg + tile_sum;
            end
        end
    end

    // ============================================================
    // STAGE (3+TREE_LEVELS) -- bias add + activation
    // (same encoding/logic as hardware/v1/rtl/neuron_parallel.v)
    // ============================================================
    wire signed [ACC_WIDTH-1:0] bias_ext =
        {{(ACC_WIDTH-DATA_WIDTH){bias_reg[DATA_WIDTH-1]}}, bias_reg};

    // acc_reg already reflects THIS cycle's update (non-blocking), so
    // when last5 is set the just-updated acc_reg (available next
    // cycle) is the complete sum -- final_acc is therefore computed
    // one cycle after last5/valid5 using the settled acc_reg value.
    reg                        valid6, last6;
    reg signed [ACC_WIDTH-1:0] final_acc_reg;

    always @(posedge clk) begin
        if (rst) begin
            valid6 <= 1'b0;
            last6  <= 1'b0;
        end else begin
            valid6        <= valid5;
            last6         <= last5;
            final_acc_reg <= acc_reg + bias_ext;
        end
    end

    wire final_acc_sign       = final_acc_reg[ACC_WIDTH-1];
    wire final_acc_upper_all0 = ~(|final_acc_reg[ACC_WIDTH-1:DATA_WIDTH-1]);
    wire final_acc_upper_all1 =  &final_acc_reg[ACC_WIDTH-1:DATA_WIDTH-1];
    wire final_acc_in_range   = final_acc_upper_all0 | final_acc_upper_all1;
    wire final_acc_le_zero    = final_acc_sign | ~(|final_acc_reg);

    wire signed [DATA_WIDTH-1:0] y_none =
        final_acc_in_range ? final_acc_reg[DATA_WIDTH-1:0]
                            : (final_acc_sign ? {1'b1, {(DATA_WIDTH-1){1'b0}}}
                                               : {1'b0, {(DATA_WIDTH-1){1'b1}}});

    wire signed [DATA_WIDTH-1:0] y_relu =
        final_acc_le_zero ? {DATA_WIDTH{1'b0}}
                           : (final_acc_upper_all0 ? final_acc_reg[DATA_WIDTH-1:0]
                                                    : {1'b0, {(DATA_WIDTH-1){1'b1}}});

    // ============================================================
    // STAGE (4+TREE_LEVELS) -- output register / saturation result
    // ============================================================
    reg                          valid7;
    reg signed [DATA_WIDTH-1:0]  y7;

    always @(posedge clk) begin
        if (rst) begin
            valid7 <= 1'b0;
        end else begin
            valid7 <= last6;
            case (activation_reg)
                ACT_NONE: y7 <= y_none;
                default:  y7 <= y_relu;
            endcase
        end
    end

    // A new job must not be accepted (and acc_reg must not be cleared)
    // while any tile from a PREVIOUS job is still draining through the
    // datapath -- otherwise a back-to-back job launched immediately
    // after NP_DONE could have its own first tile(s) race a stale
    // in-flight tile still working through stages 0..7, or have
    // NP_LOAD_JOB clear acc_reg while it still holds a not-yet-read
    // partial sum. job_ready is gated on this so NP_IDLE simply holds
    // one extra cycle when needed -- transparent to the job handshake,
    // no protocol change.
    wire pipeline_busy = valid0 || valid1 || (|valid_tree) || valid5 || valid6 || valid7;
    assign job_ready = (np_state == NP_IDLE) && !pipeline_busy;

    // ============================================================
    // OUTER FSM (§6) -- job/result handshake around the pipeline above
    // ============================================================
    always @(posedge clk) begin
        if (rst) begin
            np_state       <= NP_IDLE;
            np_error       <= 1'b0;
            result_valid   <= 1'b0;
            result_data    <= {DATA_WIDTH{1'b0}};
            result_node_id <= 16'h0;
            bias_reg       <= {DATA_WIDTH{1'b0}};
            activation_reg <= ACT_RELU;
            node_id_reg    <= 16'h0;
        end else begin
            case (np_state)

                NP_IDLE: begin
                    if (job_valid && job_ready) begin
                        bias_reg       <= job_bias;
                        activation_reg <= job_activation;
                        node_id_reg    <= job_node_id;
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
                    // Draining: wait for the tagged-last tile's result
                    // to reach the output stage (valid7).
                    if (valid7) begin
                        result_valid   <= 1'b1;
                        result_data    <= y7;
                        result_node_id <= node_id_reg;
                        np_state       <= NP_WRITE_RESULT;
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
                    // Recoverable only via rst -- documented in
                    // hardware/v2/logs/architecture.log: an error must
                    // not block the rest of the Neural Processor
                    // Array (§34), only this one processor.
                end

                // Reachable only if np_state ever holds a value outside
                // 0..6 (a genuine encoding corruption -- not exercised
                // in normal operation). Upstream protocol misuse
                // (an operand arriving when this processor cannot
                // consume it) is NOT policed here -- see
                // hardware/v2/logs/decisions.log DEC-0003: that
                // responsibility belongs to the Neural Director (M5),
                // which is the actual issuer of operand traffic and
                // the only component that can otherwise arbitrate
                // among multiple Neural Processors.
                default: np_state <= NP_ERROR;

            endcase
        end
    end

endmodule
