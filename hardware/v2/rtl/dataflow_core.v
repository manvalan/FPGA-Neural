`timescale 1ns/1ps

// ================================================================
// FPGA-Neural V2 -- Dataflow Core (M7, docs/v2-description.md §17)
//
// First full integration: Dependency Manager (M6) -> Neural Director
// (M5) -> N_SLOTS x (Memory Manager (M4) + Neural Processor (M1)).
//
//                  JOBS (node registration)
//                   |
//          +-----------------+
//          | Dependency      |
//          | Manager (M6)    |
//          +--------+--------+
//                   | ready_valid/ready (a node whose deps resolved)
//          +--------v--------+
//          | Neural Director |
//          | (M5)            |
//          +--------+--------+
//                   | slot_job_start/x_base/w_base/n_tiles/result_addr
//        +----------+----------+
//        v          v          v
//     Memory      Memory      Memory      (one per slot, M4)
//     Manager     Manager     Manager
//        |          |          |
//     Neural      Neural      Neural       (one per slot, M1)
//     Processor   Processor   Processor
//
// A slot's job_done feeds back to the Director (frees the slot) AND,
// via the node_id the Director itself tracked for that slot
// (slot_node_id), becomes a producer_done event fed to the
// Dependency Manager -- closing the loop: a node's completion can now
// wake up every OTHER node that depended on it, without any external
// component gluing the two together.
//
// Scope (see hardware/v2/logs/decisions.log DEC-0009):
// - activation_buffer.v/weight_buffer.v/result_buffer.v (M3) are NOT
//   instantiated inside dataflow_core yet -- they belong on the OTHER
//   side of the Memory Backend Interface (§15's own diagram: Memory
//   Manager -> Memory Backend Interface -> PSRAM Controller), and
//   each memory_manager instance already owns its own prefetch double
//   buffer (M4) for the fast path. Wiring the M3 buffers in as a
//   shared on-chip cache in front of PSRAM is real future work, not
//   done here (no measured need for it yet, §22/§30).
// - each slot's byte-level Memory Backend Interface port is exposed
//   SEPARATELY (N_SLOTS independent ports) rather than arbitrated
//   down to one shared PSRAM master -- real PSRAM integration
//   (including whatever arbitration N_SLOTS>1 requires) is explicitly
//   M8's job, not this one's.
// ================================================================

module dataflow_core #(
    parameter DATA_WIDTH  = 8,
    parameter P_IN        = 8,
    parameter ACC_WIDTH   = 32,
    parameter ADDR_WIDTH  = 23,
    parameter N_SLOTS     = 4,
    parameter N_NODES     = 16,
    parameter MAX_DEPS    = 4,
    parameter QUEUE_DEPTH = 8
)(
    input  wire clk,
    input  wire rst,

    // ---- node registration (host / graph loader -> Dependency Manager) ----
    input  wire                                reg_valid,
    output wire                                 reg_ready,
    input  wire [$clog2(N_NODES)-1:0]          reg_node_id,
    input  wire [$clog2(MAX_DEPS+1)-1:0]       reg_required,
    input  wire [MAX_DEPS*$clog2(N_NODES)-1:0] reg_producer_ids,
    input  wire [ADDR_WIDTH-1:0]                reg_x_base,
    input  wire [ADDR_WIDTH-1:0]                reg_w_base,
    input  wire [15:0]                          reg_n_tiles,
    input  wire [ADDR_WIDTH-1:0]                reg_result_addr,

    // ---- per-slot Memory Backend Interface (arrayed, one per slot --
    // see file header on why arbitration to one shared PSRAM port is
    // NOT done here). WORD-level (16-bit) post-M10 (decisions.log
    // DEC-0015) -- see memory_manager.v/prefetch_engine.v's own
    // headers for why. ----
    output wire [N_SLOTS-1:0]                   slot_mem_req,
    output wire [N_SLOTS-1:0]                   slot_mem_wr,
    output wire [ADDR_WIDTH*N_SLOTS-1:0]        slot_mem_addr,   // WORD address
    output wire [16*N_SLOTS-1:0]                slot_mem_wdata,
    output wire [N_SLOTS-1:0]                   slot_mem_lb_n,
    output wire [N_SLOTS-1:0]                   slot_mem_ub_n,
    input  wire [16*N_SLOTS-1:0]                slot_mem_rdata,
    input  wire [N_SLOTS-1:0]                   slot_mem_ready
);

    localparam NODE_IDW = $clog2(N_NODES);

    // ---- Dependency Manager (M6) ----
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

    // node_id is 16 bits on the Director/Memory Manager side (matches
    // neural_processor.v's own job_node_id width) but NODE_IDW bits on
    // the Dependency Manager side (sized to N_NODES) -- zero-extended
    // crossing the boundary, truncated coming back (safe as long as
    // N_NODES <= 65536, always true for any NODE_IDW <= 16).
    wire [15:0] dm_ready_node_id_ext = {{(16-NODE_IDW){1'b0}}, dm_ready_node_id};

    // ---- Neural Director (M5) ----
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

    // job_out_slot indexes slot_node_id to recover which node just
    // completed -- this becomes the Dependency Manager's own
    // producer_done event, closing the wake-up loop.
    wire [15:0] completed_node_id_16 = dir_slot_node_id[dir_job_out_slot*16 +: 16];
    assign dm_producer_done_valid    = dir_job_out_done;
    assign dm_producer_done_node_id  = completed_node_id_16[NODE_IDW-1:0];

    // ---- N_SLOTS x (Memory Manager (M4) + Neural Processor (M1)) ----
    genvar g;
    generate
        for (g = 0; g < N_SLOTS; g = g + 1) begin : GEN_SLOT

            wire mm_operand_valid, mm_operand_ready;
            wire signed [DATA_WIDTH*P_IN-1:0] mm_input_data, mm_weight_data;
            wire mm_tile_last;
            wire mm_result_valid, mm_result_ready;
            wire signed [DATA_WIDTH-1:0] mm_result_data;

            memory_manager #(
                .DATA_WIDTH(DATA_WIDTH), .P_IN(P_IN), .ADDR_WIDTH(ADDR_WIDTH)
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
