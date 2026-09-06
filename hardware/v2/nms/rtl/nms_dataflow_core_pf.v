`timescale 1ns/1ps

// ================================================================
// Neural Memory System (NMS) -- STEP8 full integration, mirrors
// hardware/v2/rtl/dataflow_core.v's own scope exactly (M6 Dependency
// Manager -> M5 Neural Director -> N_SLOTS x (memory manager + neural
// processor)), but replaces the M4 memory_manager.v +
// activation_cache.v cluster with the NMS's own decided pieces
// (DEC-0019/DEC-0020):
//   - nms_activation_replicated.v: N_SLOTS private full-vector
//     activation copies, broadcast-filled by...
//   - nms_activation_fill_ctrl.v: the shared dedup/fetch controller
//     (single logical tag, same honest thrash-under-interleaved-
//     different-x_base limitation as the superseded activation_cache.v)
//   - nms_weight_packed.v: N_SLOTS private, per-MAC-lane packed weight
//     copies (never shared, no arbitration needed)
//   - nms_memory_manager.v: per-slot job FSM, reads directly from the
//     two SRAMs above instead of double-buffering 2 banks (the whole
//     vector is resident, not just 2 tiles worth)
//
// hardware/v2/rtl/dependency_manager.v and neural_director.v are
// REUSED VERBATIM, unmodified -- the node-registration and slot-
// dispatch protocol did not change at all; only what happens between
// "job dispatched to a slot" and "job_done" changed.
//
// Memory Backend Interface: exposed N_SLOTS+1 wide exactly like
// dataflow_core.v (indices [0,N_SLOTS) = per-slot memory managers'
// own weight-fetch+result-write port, index [N_SLOTS] = the shared
// activation fill controller's own port) -- arbitrated one level up,
// reusing hardware/v2/rtl/slot_mem_arbiter.v unchanged.
// ================================================================

module nms_dataflow_core_pf #(
    parameter DATA_WIDTH  = 8,
    parameter P_IN        = 8,
    parameter ACC_WIDTH   = 32,
    parameter ADDR_WIDTH  = 23,
    parameter N_SLOTS     = 4,
    parameter N_NODES     = 16,
    parameter MAX_DEPS    = 4,
    parameter QUEUE_DEPTH = 8,
    parameter MAX_TILES   = 16,
    parameter PREFETCH_DISTANCE = 8,
    parameter TIW         = (MAX_TILES <= 1) ? 1 : $clog2(MAX_TILES),
    // Must match nms_memory_manager.v's/nms_activation_fill_ctrl.v's
    // own CNTW exactly -- this top-level wire connecting the two was
    // left at the narrower TIW after those modules were widened,
    // silently truncating resident_count's real value (16) back down
    // to 0 right when it should have reached MAX_TILES, deadlocking
    // the very last tile of any n_tiles==MAX_TILES job forever (found
    // via simulation: D-Stress's real 16-tile neurons hung 1 tile
    // short, act_resident_count visibly reset to 0 the exact cycle it
    // should have become 16).
    parameter CNTW        = $clog2(MAX_TILES+1)
)(
    input  wire clk,
    input  wire rst,

    input  wire                                reg_valid,
    output wire                                 reg_ready,
    input  wire [$clog2(N_NODES)-1:0]          reg_node_id,
    input  wire [$clog2(MAX_DEPS+1)-1:0]       reg_required,
    input  wire [MAX_DEPS*$clog2(N_NODES)-1:0] reg_producer_ids,
    input  wire [ADDR_WIDTH-1:0]                reg_x_base,
    input  wire [ADDR_WIDTH-1:0]                reg_w_base,
    input  wire [15:0]                          reg_n_tiles,
    input  wire [ADDR_WIDTH-1:0]                reg_result_addr,

    output wire [N_SLOTS:0]                     slot_mem_req,
    output wire [N_SLOTS:0]                      slot_mem_wr,
    output wire [ADDR_WIDTH*(N_SLOTS+1)-1:0]     slot_mem_addr,
    output wire [16*(N_SLOTS+1)-1:0]             slot_mem_wdata,
    output wire [N_SLOTS:0]                      slot_mem_lb_n,
    output wire [N_SLOTS:0]                      slot_mem_ub_n,
    input  wire [16*(N_SLOTS+1)-1:0]             slot_mem_rdata,
    input  wire [N_SLOTS:0]                      slot_mem_ready
);

    localparam NODE_IDW = $clog2(N_NODES);

    wire                    dm_ready_valid;
    wire                    dm_ready_ready;
    wire [NODE_IDW-1:0]     dm_ready_node_id;
    wire [ADDR_WIDTH-1:0]   dm_ready_x_base, dm_ready_w_base, dm_ready_result_addr;
    wire [15:0]             dm_ready_n_tiles;

    wire                    dm_producer_done_valid;
    wire [NODE_IDW-1:0]     dm_producer_done_node_id;

    dependency_manager #(
        .N_NODES(N_NODES), .MAX_DEPS(MAX_DEPS), .ADDR_WIDTH(ADDR_WIDTH)
    ) u_dep_mgr (
        .clk(clk), .rst(rst),
        .reg_valid(reg_valid), .reg_ready(reg_ready), .reg_node_id(reg_node_id),
        .reg_required(reg_required), .reg_producer_ids(reg_producer_ids),
        .reg_x_base(reg_x_base), .reg_w_base(reg_w_base), .reg_n_tiles(reg_n_tiles),
        .reg_result_addr(reg_result_addr),
        .producer_done_valid(dm_producer_done_valid), .producer_done_node_id(dm_producer_done_node_id),
        .ready_valid(dm_ready_valid), .ready_ready(dm_ready_ready), .ready_node_id(dm_ready_node_id),
        .ready_x_base(dm_ready_x_base), .ready_w_base(dm_ready_w_base),
        .ready_n_tiles(dm_ready_n_tiles), .ready_result_addr(dm_ready_result_addr)
    );

    wire [15:0] dm_ready_node_id_ext = {{(16-NODE_IDW){1'b0}}, dm_ready_node_id};

    wire [N_SLOTS-1:0]              dir_slot_job_start;
    wire [ADDR_WIDTH*N_SLOTS-1:0]   dir_slot_x_base, dir_slot_w_base, dir_slot_result_addr;
    wire [16*N_SLOTS-1:0]           dir_slot_n_tiles, dir_slot_node_id;
    wire [N_SLOTS-1:0]              dir_slot_job_done;
    wire                            dir_job_out_done;
    wire [$clog2(N_SLOTS)-1:0]      dir_job_out_slot;
    wire [3:0]                      dir_state;
    wire                            dir_error;

    neural_director #(
        .ADDR_WIDTH(ADDR_WIDTH), .N_SLOTS(N_SLOTS), .QUEUE_DEPTH(QUEUE_DEPTH)
    ) u_director (
        .clk(clk), .rst(rst),
        .job_in_valid(dm_ready_valid), .job_in_ready(dm_ready_ready),
        .job_in_x_base(dm_ready_x_base), .job_in_w_base(dm_ready_w_base),
        .job_in_n_tiles(dm_ready_n_tiles), .job_in_result_addr(dm_ready_result_addr),
        .job_in_node_id(dm_ready_node_id_ext),
        .slot_job_start(dir_slot_job_start), .slot_x_base(dir_slot_x_base), .slot_w_base(dir_slot_w_base),
        .slot_n_tiles(dir_slot_n_tiles), .slot_result_addr(dir_slot_result_addr),
        .slot_node_id(dir_slot_node_id), .slot_job_done(dir_slot_job_done),
        .job_out_done(dir_job_out_done), .job_out_slot(dir_job_out_slot),
        .dir_state(dir_state), .dir_error(dir_error)
    );

    wire [15:0] completed_node_id_16 = dir_slot_node_id[dir_job_out_slot*16 +: 16];
    assign dm_producer_done_valid    = dir_job_out_done;
    assign dm_producer_done_node_id  = completed_node_id_16[NODE_IDW-1:0];

    // ---- NMS memory: shared Activation SRAM (replicated) + private
    // Weight SRAM (packed), per DEC-0019/DEC-0020 ----
    wire                                fill_we;
    wire [TIW-1:0]                      fill_addr;
    wire signed [DATA_WIDTH*P_IN-1:0]   fill_data;
    wire [ADDR_WIDTH-1:0]               act_resident_tag;
    wire [CNTW-1:0]                     act_resident_count;

    wire [N_SLOTS-1:0]            act_rd_en;
    wire [N_SLOTS*TIW-1:0]        act_rd_addr_flat;
    wire signed [DATA_WIDTH*P_IN*N_SLOTS-1:0] act_rd_data_flat;

    nms_activation_replicated #(
        .DATA_WIDTH(DATA_WIDTH), .P_IN(P_IN), .N_SLOTS(N_SLOTS), .MAX_TILES(MAX_TILES)
    ) u_act_mem (
        .clk(clk), .rst(rst),
        .fill_we(fill_we), .fill_addr(fill_addr), .fill_data(fill_data),
        .rd_en(act_rd_en), .rd_addr_flat(act_rd_addr_flat), .rd_data_flat(act_rd_data_flat)
    );

    wire [N_SLOTS-1:0]                 job_active;
    wire [ADDR_WIDTH*N_SLOTS-1:0]       job_x_base_flat;
    wire [16*N_SLOTS-1:0]               job_n_tiles_flat;

    nms_activation_fill_ctrl #(
        .DATA_WIDTH(DATA_WIDTH), .P_IN(P_IN), .N_SLOTS(N_SLOTS), .ADDR_WIDTH(ADDR_WIDTH), .MAX_TILES(MAX_TILES)
    ) u_act_fill (
        .clk(clk), .rst(rst),
        .job_active(job_active), .x_base_flat(job_x_base_flat), .n_tiles_flat(job_n_tiles_flat),
        .resident_tag(act_resident_tag), .resident_count(act_resident_count),
        .fill_we(fill_we), .fill_addr(fill_addr), .fill_data(fill_data),
        .mem_req(slot_mem_req[N_SLOTS]), .mem_wr(slot_mem_wr[N_SLOTS]),
        .mem_addr(slot_mem_addr[N_SLOTS*ADDR_WIDTH +: ADDR_WIDTH]),
        .mem_wdata(slot_mem_wdata[N_SLOTS*16 +: 16]),
        .mem_lb_n(slot_mem_lb_n[N_SLOTS]), .mem_ub_n(slot_mem_ub_n[N_SLOTS]),
        .mem_rdata(slot_mem_rdata[N_SLOTS*16 +: 16]), .mem_ready(slot_mem_ready[N_SLOTS])
    );

    wire [N_SLOTS-1:0]                 wgt_fill_we;
    wire [N_SLOTS*TIW-1:0]             wgt_fill_addr_flat;
    wire signed [DATA_WIDTH*P_IN*N_SLOTS-1:0] wgt_fill_data_flat;
    wire [N_SLOTS-1:0]                 wgt_rd_en;
    wire [N_SLOTS*TIW-1:0]             wgt_rd_addr_flat;
    wire signed [DATA_WIDTH*P_IN*N_SLOTS-1:0] wgt_rd_data_flat;

    nms_weight_packed #(
        .DATA_WIDTH(DATA_WIDTH), .P_IN(P_IN), .N_SLOTS(N_SLOTS), .MAX_TILES(MAX_TILES)
    ) u_wgt_mem (
        .clk(clk), .rst(rst),
        .fill_we(wgt_fill_we), .fill_addr_flat(wgt_fill_addr_flat), .fill_data_flat(wgt_fill_data_flat),
        .rd_en(wgt_rd_en), .rd_addr_flat(wgt_rd_addr_flat), .rd_data_flat(wgt_rd_data_flat)
    );

    genvar g;
    generate
        for (g = 0; g < N_SLOTS; g = g + 1) begin : GEN_SLOT

            wire mm_operand_valid, mm_operand_ready;
            wire signed [DATA_WIDTH*P_IN-1:0] mm_input_data, mm_weight_data;
            wire mm_tile_last;
            wire mm_result_valid, mm_result_ready;
            wire signed [DATA_WIDTH-1:0] mm_result_data;

            nms_memory_manager_pf #(
                .DATA_WIDTH(DATA_WIDTH), .P_IN(P_IN), .ADDR_WIDTH(ADDR_WIDTH), .MAX_TILES(MAX_TILES),
                .PREFETCH_DISTANCE(PREFETCH_DISTANCE)
            ) u_mm (
                .clk(clk), .rst(rst),
                .job_start(dir_slot_job_start[g]),
                .x_base(dir_slot_x_base[g*ADDR_WIDTH +: ADDR_WIDTH]),
                .w_base(dir_slot_w_base[g*ADDR_WIDTH +: ADDR_WIDTH]),
                .n_tiles(dir_slot_n_tiles[g*16 +: 16]),
                .result_addr(dir_slot_result_addr[g*ADDR_WIDTH +: ADDR_WIDTH]),
                .job_done(dir_slot_job_done[g]),
                .operand_valid(mm_operand_valid), .operand_ready(mm_operand_ready),
                .input_data(mm_input_data), .weight_data(mm_weight_data), .tile_last(mm_tile_last),
                .result_valid(mm_result_valid), .result_ready(mm_result_ready), .result_data(mm_result_data),
                .job_active(job_active[g]),
                .job_x_base(job_x_base_flat[g*ADDR_WIDTH +: ADDR_WIDTH]),
                .job_n_tiles(job_n_tiles_flat[g*16 +: 16]),
                .act_resident_tag(act_resident_tag), .act_resident_count(act_resident_count),
                .act_rd_en(act_rd_en[g]),
                .act_rd_addr(act_rd_addr_flat[g*TIW +: TIW]),
                .act_rd_data(act_rd_data_flat[g*DATA_WIDTH*P_IN +: DATA_WIDTH*P_IN]),
                .wgt_fill_we(wgt_fill_we[g]),
                .wgt_fill_addr(wgt_fill_addr_flat[g*TIW +: TIW]),
                .wgt_fill_data(wgt_fill_data_flat[g*DATA_WIDTH*P_IN +: DATA_WIDTH*P_IN]),
                .wgt_rd_en(wgt_rd_en[g]),
                .wgt_rd_addr(wgt_rd_addr_flat[g*TIW +: TIW]),
                .wgt_rd_data(wgt_rd_data_flat[g*DATA_WIDTH*P_IN +: DATA_WIDTH*P_IN]),
                .mem_req(slot_mem_req[g]), .mem_wr(slot_mem_wr[g]),
                .mem_addr(slot_mem_addr[g*ADDR_WIDTH +: ADDR_WIDTH]),
                .mem_wdata(slot_mem_wdata[g*16 +: 16]),
                .mem_lb_n(slot_mem_lb_n[g]), .mem_ub_n(slot_mem_ub_n[g]),
                .mem_rdata(slot_mem_rdata[g*16 +: 16]), .mem_ready(slot_mem_ready[g])
            );

            reg job_valid_np;
            wire job_ready_np;
            wire result_valid_np;
            wire signed [DATA_WIDTH-1:0] result_data_np;
            wire [3:0] np_state;
            wire np_error;

            neural_processor #(
                .DATA_WIDTH(DATA_WIDTH), .P_IN(P_IN), .ACC_WIDTH(ACC_WIDTH)
            ) u_np (
                .clk(clk), .rst(rst),
                .job_valid(job_valid_np), .job_ready(job_ready_np),
                .job_node_id(16'h0), .job_bias(8'sd0), .job_activation(2'd1),
                .operand_valid(mm_operand_valid), .operand_ready(mm_operand_ready),
                .input_data(mm_input_data), .weight_data(mm_weight_data), .tile_last(mm_tile_last),
                .result_valid(result_valid_np), .result_ready(mm_result_ready),
                .result_data(result_data_np), .result_node_id(),
                .np_state(np_state), .np_error(np_error)
            );
            assign mm_result_valid = result_valid_np;
            assign mm_result_data  = result_data_np;

            always @(posedge clk) begin
                if (rst) job_valid_np <= 1'b0;
                else if (dir_slot_job_start[g]) job_valid_np <= 1'b1;
                else if (job_valid_np && job_ready_np) job_valid_np <= 1'b0;
            end

        end
    endgenerate

endmodule
