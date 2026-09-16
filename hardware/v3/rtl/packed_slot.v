`timescale 1ns/1ps

// ============================================================
// V3 -- packed_slot.v: real synthesizable per-slot sequencer, the
// piece that promotes EXP-0062's own PROCEDURAL testbench sequence
// (prefetch -> swap -> job dispatch -> tile-by-tile operand feed ->
// result capture) into real RTL, exactly the same class of promotion
// weight_tile_gather.v already did for the byte-gather step
// (EXP-0061).
//
// Wraps: layer_prefetch_ctrl.v -> layer_weight_buffer.v ->
// weight_tile_gather.v -> neural_processor_packed.v, driven by a new
// sequencing FSM, presenting the external contract neural_director_
// packed.v already expects (job_start/x_base_a/b/w_base/n_tiles/
// node_id_a/b -> job_done/result_data_a/b/result_node_id_a/b).
//
// SCOPE LIMITATION (disclosed, matches this project's own established
// precedent -- EXP-0058/0062's own header comments: "activation data
// ... representing the activation/sliding-window path, which is a
// separate, already-existing memory path not the subject of this
// test"): activations are read through a WIDE, per-tile, combinational
// stand-in port (act_tile_addr_a/b -> act_tile_data_a/b), mirroring
// this project's own earlier ideal_memory_model.v-style staging
// (establish the architectural contract before committing to a
// specific real fetch engine). A real activation fetch engine
// (analogous to weight_tile_gather.v, but for the sliding-window/
// activation path) is a separate, later deliverable, NOT built here.
//
// Also disclosed: no result-writeback engine exists yet either --
// result_addr_a/b are passed through unused, for a future writeback
// stage to consume.
//
// EVERY job re-fetches its layer from SDRAM (no resident-weight-skip
// optimization) -- correctness first; EXP-0057's own measured
// prefetch/reuse PERFORMANCE benefit is a property of the buffer
// being read MANY times per fetch (many reuse positions per Director-
// dispatched pair's own tile loop is NOT what's being reused here --
// see note in the FSM below), not of skipping fetches across
// DIFFERENT Director dispatches; adding that optimization is future
// work, not a correctness requirement.
// ============================================================
module packed_slot #(
    parameter DATA_WIDTH  = 8,
    parameter P_IN        = 8,
    parameter ACC_WIDTH   = 32,
    parameter BURST_LEN   = 8,
    parameter ADDR_WIDTH  = 26,
    parameter LAYER_BYTES = 128,
    parameter BUFADDRW    = $clog2(LAYER_BYTES)
)(
    input  wire clk,
    input  wire rst,

    // ---- Director interface (matches neural_director_packed.v's own
    // per-slot output ports exactly) ----
    input  wire                   job_start,
    input  wire [ADDR_WIDTH-1:0]  x_base_a,
    input  wire [ADDR_WIDTH-1:0]  x_base_b,
    input  wire [ADDR_WIDTH-1:0]  w_base,
    input  wire [15:0]            n_tiles,
    input  wire [ADDR_WIDTH-1:0]  result_addr_a,
    input  wire [ADDR_WIDTH-1:0]  result_addr_b,
    input  wire [15:0]            node_id_a,
    input  wire [15:0]            node_id_b,
    output reg                    job_done,      // one-cycle pulse

    output reg  signed [DATA_WIDTH-1:0] result_data_a,
    output reg  signed [DATA_WIDTH-1:0] result_data_b,
    output reg  [15:0]                  result_node_id_a,
    output reg  [15:0]                  result_node_id_b,
    output reg  [ADDR_WIDTH-1:0]        result_addr_a_out,
    output reg  [ADDR_WIDTH-1:0]        result_addr_b_out,

    // high exactly while this slot needs exclusive access to the
    // shared SDRAM controller (its own weight-fetch phase) -- a
    // shared-controller arbiter uses this to lock a grant for the
    // whole multi-burst fetch, not just one transaction.
    output wire                    mem_active,

    // ---- activation stand-in port (see header -- real fetch engine
    // deferred) ----
    output reg  [ADDR_WIDTH-1:0]            act_tile_addr_a,
    output reg  [ADDR_WIDTH-1:0]            act_tile_addr_b,
    input  wire signed [DATA_WIDTH*P_IN-1:0] act_tile_data_a,
    input  wire signed [DATA_WIDTH*P_IN-1:0] act_tile_data_b,

    // grant from a shared-controller arbiter (see mem_active's own
    // comment): must be asserted before this slot may pulse its own
    // layer_prefetch_ctrl.v start, since that module's ctrl_req is a
    // one-shot pulse with no retry -- issuing it before the arbiter
    // has actually granted this slot the bus loses it permanently
    // (found empirically integrating N=2 slots behind sdram_slot_
    // arbiter2.v: a slot could hang forever in S_WAIT with ctrl_req
    // already dropped and ctrl_ready never coming). Tie high for a
    // single-slot (N=1, no arbiter) system.
    input  wire                    mem_grant,

    // ---- SDRAM controller port (connects directly, or through a
    // shared arbiter for N>1 slots) ----
    output wire                    ctrl_req,
    output wire                    ctrl_wr,
    output wire [ADDR_WIDTH-2:0]   ctrl_addr,
    output wire [16*BURST_LEN-1:0] ctrl_wdata,
    output wire [2*BURST_LEN-1:0]  ctrl_wmask,
    input  wire [16*BURST_LEN-1:0] ctrl_rdata,
    input  wire                    ctrl_ready,
    input  wire                    ctrl_busy
);
    localparam S_IDLE      = 4'd0,
               S_MEMWAIT   = 4'd1,
               S_PREFETCH  = 4'd2,
               S_SWAP      = 4'd3,
               S_JOBSTART  = 4'd4,
               S_TILEREQ   = 4'd5,
               S_TILEWAIT  = 4'd6,
               S_OPERAND   = 4'd7,
               S_RESULT    = 4'd8,
               S_DONE      = 4'd9;

    reg [3:0] state;
    assign mem_active = (state == S_MEMWAIT) || (state == S_PREFETCH);
    reg [ADDR_WIDTH-1:0] w_base_lat, x_base_a_lat, x_base_b_lat;
    reg [15:0]            n_tiles_lat;
    reg [ADDR_WIDTH-1:0]  result_addr_a_lat, result_addr_b_lat;
    reg [15:0]            node_id_a_lat, node_id_b_lat;
    reg [15:0]            tcnt;

    // ---- layer_prefetch_ctrl.v ----
    reg  pf_start;
    wire pf_busy, pf_done;
    wire pf_fill_we;
    wire [BUFADDRW-1:0] pf_fill_addr;
    wire [DATA_WIDTH-1:0] pf_fill_data;

    layer_prefetch_ctrl #(
        .DATA_WIDTH(DATA_WIDTH), .LAYER_BYTES(LAYER_BYTES), .BURST_LEN(BURST_LEN), .ADDR_WIDTH(ADDR_WIDTH-1)
    ) u_pf (
        .clk(clk), .rst(rst),
        .start(pf_start), .layer_base(w_base_lat[ADDR_WIDTH-2:0]), .busy(pf_busy), .done(pf_done),
        .fill_we(pf_fill_we), .fill_addr(pf_fill_addr), .fill_data(pf_fill_data),
        .ctrl_req(ctrl_req), .ctrl_wr(ctrl_wr), .ctrl_addr(ctrl_addr),
        .ctrl_wdata(ctrl_wdata), .ctrl_wmask(ctrl_wmask),
        .ctrl_rdata(ctrl_rdata), .ctrl_ready(ctrl_ready), .ctrl_busy(ctrl_busy)
    );

    // ---- layer_weight_buffer.v ----
    wire [BUFADDRW-1:0]   lwb_rd_addr;
    wire [DATA_WIDTH-1:0] lwb_rd_data;
    reg                   consume_done;

    layer_weight_buffer #(.DATA_WIDTH(DATA_WIDTH), .LAYER_DEPTH(LAYER_BYTES)) u_lwb (
        .clk(clk), .rst(rst),
        .fill_we(pf_fill_we), .fill_addr(pf_fill_addr), .fill_data(pf_fill_data), .fill_done(pf_done),
        .rd_addr(lwb_rd_addr), .rd_data(lwb_rd_data), .consume_done(consume_done),
        .active_sel(), .swapped()
    );

    // ---- weight_tile_gather.v ----
    reg                        tile_req;
    reg  [BUFADDRW-1:0]        tile_base;
    wire                       tile_valid;
    wire [DATA_WIDTH*P_IN-1:0] tile_data;

    weight_tile_gather #(
        .DATA_WIDTH(DATA_WIDTH), .P_IN(P_IN), .BUFADDRW(BUFADDRW)
    ) u_gather (
        .clk(clk), .rst(rst),
        .tile_req(tile_req), .tile_base(tile_base),
        .tile_valid(tile_valid), .tile_data(tile_data),
        .rd_addr(lwb_rd_addr), .rd_data(lwb_rd_data)
    );

    // ---- neural_processor_packed.v ----
    reg job_valid_np;
    wire job_ready_np;
    reg [1:0] job_activation;
    reg signed [DATA_WIDTH-1:0] job_bias;

    reg operand_valid;
    wire operand_ready;
    reg signed [DATA_WIDTH*P_IN-1:0] input_data_a_r, input_data_b_r;
    reg [DATA_WIDTH*P_IN-1:0] weight_data_r;
    reg tile_last;

    wire result_valid_np;
    reg  result_ready;
    wire signed [DATA_WIDTH-1:0] result_data_a_np, result_data_b_np;
    wire [15:0] result_node_id_a_np, result_node_id_b_np;
    wire [3:0] np_state;
    wire np_error;

    neural_processor_packed #(
        .DATA_WIDTH(DATA_WIDTH), .P_IN(P_IN), .ACC_WIDTH(ACC_WIDTH)
    ) u_np (
        .clk(clk), .rst(rst),
        .job_valid(job_valid_np), .job_ready(job_ready_np),
        .job_node_id_a(node_id_a_lat), .job_node_id_b(node_id_b_lat),
        .job_bias(job_bias), .job_activation(job_activation),
        .operand_valid(operand_valid), .operand_ready(operand_ready),
        .input_data_a(input_data_a_r), .input_data_b(input_data_b_r),
        .weight_data(weight_data_r), .tile_last(tile_last),
        .result_valid(result_valid_np), .result_ready(result_ready),
        .result_data_a(result_data_a_np), .result_data_b(result_data_b_np),
        .result_node_id_a(result_node_id_a_np), .result_node_id_b(result_node_id_b_np),
        .np_state(np_state), .np_error(np_error)
    );

    localparam ACT_RELU = 2'd1;

    always @(posedge clk) begin
        if (rst) begin
            state        <= S_IDLE;
            job_done     <= 1'b0;
            pf_start     <= 1'b0;
            consume_done <= 1'b0;
            tile_req     <= 1'b0;
            job_valid_np <= 1'b0;
            operand_valid<= 1'b0;
            tile_last    <= 1'b0;
            result_ready <= 1'b0;
            job_bias     <= {DATA_WIDTH{1'b0}};
            job_activation <= ACT_RELU;
            tcnt         <= 16'd0;
        end else begin
            job_done     <= 1'b0;
            pf_start     <= 1'b0;
            consume_done <= 1'b0;
            tile_req     <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (job_start) begin
                        w_base_lat         <= w_base;
                        x_base_a_lat       <= x_base_a;
                        x_base_b_lat       <= x_base_b;
                        n_tiles_lat        <= n_tiles;
                        result_addr_a_lat  <= result_addr_a;
                        result_addr_b_lat  <= result_addr_b;
                        node_id_a_lat      <= node_id_a;
                        node_id_b_lat      <= node_id_b;
                        job_bias           <= {DATA_WIDTH{1'b0}};
                        job_activation     <= ACT_RELU;
                        state              <= S_MEMWAIT;
                    end
                end

                S_MEMWAIT: begin
                    if (mem_grant) begin
                        pf_start <= 1'b1;
                        state    <= S_PREFETCH;
                    end
                end

                S_PREFETCH: begin
                    if (pf_done) begin
                        consume_done <= 1'b1;
                        state        <= S_SWAP;
                    end
                end

                S_SWAP: begin
                    // one settle cycle for layer_weight_buffer.v's own
                    // do_swap (fill_done_latched already set from
                    // pf_done above; consume_done pulsed this cycle) --
                    // matches EXP-0058/0062's own tested sequencing.
                    job_valid_np <= 1'b1;
                    state        <= S_JOBSTART;
                end

                S_JOBSTART: begin
                    if (job_valid_np && job_ready_np) begin
                        job_valid_np <= 1'b0;
                        tcnt         <= 16'd0;
                        state        <= S_TILEREQ;
                    end
                end

                S_TILEREQ: begin
                    tile_req  <= 1'b1;
                    tile_base <= tcnt[BUFADDRW-1:0]*P_IN[BUFADDRW-1:0];
                    act_tile_addr_a <= x_base_a_lat + {{(ADDR_WIDTH-16){1'b0}}, tcnt};
                    act_tile_addr_b <= x_base_b_lat + {{(ADDR_WIDTH-16){1'b0}}, tcnt};
                    state     <= S_TILEWAIT;
                end

                S_TILEWAIT: begin
                    if (tile_valid) begin
                        weight_data_r  <= tile_data;
                        input_data_a_r <= act_tile_data_a;
                        input_data_b_r <= act_tile_data_b;
                        tile_last      <= (tcnt == n_tiles_lat - 16'd1);
                        operand_valid  <= 1'b1;
                        state          <= S_OPERAND;
                    end
                end

                S_OPERAND: begin
                    if (operand_valid && operand_ready) begin
                        operand_valid <= 1'b0;
                        tile_last     <= 1'b0;
                        if (tcnt == n_tiles_lat - 16'd1) begin
                            result_ready <= 1'b1;
                            state        <= S_RESULT;
                        end else begin
                            tcnt  <= tcnt + 16'd1;
                            state <= S_TILEREQ;
                        end
                    end
                end

                S_RESULT: begin
                    if (result_valid_np) begin
                        result_data_a      <= result_data_a_np;
                        result_data_b      <= result_data_b_np;
                        result_node_id_a   <= result_node_id_a_np;
                        result_node_id_b   <= result_node_id_b_np;
                        result_addr_a_out  <= result_addr_a_lat;
                        result_addr_b_out  <= result_addr_b_lat;
                        result_ready       <= 1'b0;
                        job_done            <= 1'b1;
                        state                <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
