`timescale 1ns/1ps

// ============================================================
// V3 -- synthesis top for the EXP-0066 verified N=2 multi-core
// system: neural_director_packed.v + 2 real packed_slot.v instances
// + sdram_slot_arbiter2.v + real sdram_controller.v, flat structural
// wiring, for a real P&R resource/timing check (same out-of-context
// methodology as EXP-0059/0063).
//
// Activation stand-in ports (see packed_slot.v's own header) are
// exposed per-slot at the top level, matching this module's own
// still-declared scope limit (no real activation fetch engine yet).
// ============================================================
module n2_system_top #(
    parameter DATA_WIDTH  = 8,
    parameter P_IN        = 8,
    parameter ACC_WIDTH   = 32,
    parameter BURST_LEN   = 8,
    parameter ROW_BITS    = 13,
    parameter COL_BITS    = 10,
    parameter BANK_BITS   = 2,
    parameter SDRAM_ADDR_WIDTH = BANK_BITS + ROW_BITS + COL_BITS,
    parameter ADDR_WIDTH  = 26,
    parameter LAYER_BYTES = 128,
    parameter N_SLOTS     = 2,
    parameter QUEUE_DEPTH = 8
)(
    input  wire clk,
    input  wire rst,

    // ---- Director job submission ----
    input  wire                   job_in_valid,
    output wire                   job_in_ready,
    input  wire [ADDR_WIDTH-1:0]  job_in_x_base,
    input  wire [ADDR_WIDTH-1:0]  job_in_w_base,
    input  wire [15:0]            job_in_n_tiles,
    input  wire [ADDR_WIDTH-1:0]  job_in_result_addr,
    input  wire [15:0]            job_in_node_id,
    output wire                   job_out_done,
    output wire [$clog2(N_SLOTS)-1:0] job_out_slot,

    // ---- activation stand-ins, slot 0 ----
    output wire [ADDR_WIDTH-1:0]            s0_act_addr_a,
    output wire [ADDR_WIDTH-1:0]            s0_act_addr_b,
    input  wire signed [DATA_WIDTH*P_IN-1:0] s0_act_data_a,
    input  wire signed [DATA_WIDTH*P_IN-1:0] s0_act_data_b,
    output wire signed [DATA_WIDTH-1:0]      s0_result_data_a,
    output wire signed [DATA_WIDTH-1:0]      s0_result_data_b,

    // ---- activation stand-ins, slot 1 ----
    output wire [ADDR_WIDTH-1:0]            s1_act_addr_a,
    output wire [ADDR_WIDTH-1:0]            s1_act_addr_b,
    input  wire signed [DATA_WIDTH*P_IN-1:0] s1_act_data_a,
    input  wire signed [DATA_WIDTH*P_IN-1:0] s1_act_data_b,
    output wire signed [DATA_WIDTH-1:0]      s1_result_data_a,
    output wire signed [DATA_WIDTH-1:0]      s1_result_data_b,

    // ---- real SDRAM pins ----
    output wire        sdram_cke,
    output wire        sdram_cs_n,
    output wire        sdram_ras_n,
    output wire        sdram_cas_n,
    output wire        sdram_we_n,
    output wire [BANK_BITS-1:0] sdram_ba,
    output wire [ROW_BITS-1:0]  sdram_a,
    inout  wire [15:0] sdram_dq,
    output wire [1:0]  sdram_dqm
);
    localparam BUFADDRW = $clog2(LAYER_BYTES);

    wire [N_SLOTS-1:0]              slot_job_start;
    wire [ADDR_WIDTH*N_SLOTS-1:0]   slot_x_base_a, slot_x_base_b, slot_w_base;
    wire [ADDR_WIDTH*N_SLOTS-1:0]   slot_result_addr_a, slot_result_addr_b;
    wire [16*N_SLOTS-1:0]           slot_n_tiles, slot_node_id_a, slot_node_id_b;
    wire [N_SLOTS-1:0]              slot_job_done;
    wire [3:0] dir_state;
    wire       dir_error;
    wire       queue_empty;

    neural_director_packed #(
        .ADDR_WIDTH(ADDR_WIDTH), .N_SLOTS(N_SLOTS), .QUEUE_DEPTH(QUEUE_DEPTH)
    ) u_dir (
        .clk(clk), .rst(rst),
        .job_in_valid(job_in_valid), .job_in_ready(job_in_ready),
        .job_in_x_base(job_in_x_base), .job_in_w_base(job_in_w_base),
        .job_in_n_tiles(job_in_n_tiles), .job_in_result_addr(job_in_result_addr),
        .job_in_node_id(job_in_node_id),
        .slot_job_start(slot_job_start),
        .slot_x_base_a(slot_x_base_a), .slot_x_base_b(slot_x_base_b),
        .slot_w_base(slot_w_base), .slot_n_tiles(slot_n_tiles),
        .slot_result_addr_a(slot_result_addr_a), .slot_result_addr_b(slot_result_addr_b),
        .slot_node_id_a(slot_node_id_a), .slot_node_id_b(slot_node_id_b),
        .slot_job_done(slot_job_done),
        .job_out_done(job_out_done), .job_out_slot(job_out_slot),
        .dir_state(dir_state), .dir_error(dir_error), .queue_empty(queue_empty)
    );

    wire [1:0] mem_active, mem_grant;
    wire [1:0] s_ctrl_req, s_ctrl_wr;
    wire [SDRAM_ADDR_WIDTH-1:0] s0_ctrl_addr, s1_ctrl_addr;
    wire [16*BURST_LEN-1:0] s0_ctrl_wdata, s1_ctrl_wdata;
    wire [2*BURST_LEN-1:0]  s0_ctrl_wmask, s1_ctrl_wmask;
    wire [16*BURST_LEN-1:0] s0_ctrl_rdata, s1_ctrl_rdata;
    wire [1:0] s_ctrl_ready, s_ctrl_busy;

    wire ctrl_req, ctrl_wr;
    wire [SDRAM_ADDR_WIDTH-1:0] ctrl_addr;
    wire [16*BURST_LEN-1:0] ctrl_wdata, ctrl_rdata;
    wire [2*BURST_LEN-1:0]  ctrl_wmask;
    wire ctrl_ready, ctrl_busy;

    sdram_slot_arbiter2 #(.ADDR_WIDTH(SDRAM_ADDR_WIDTH), .BURST_LEN(BURST_LEN)) u_arb (
        .clk(clk), .rst(rst),
        .slot0_active(mem_active[0]), .slot0_grant(mem_grant[0]),
        .slot0_req(s_ctrl_req[0]), .slot0_wr(s_ctrl_wr[0]),
        .slot0_addr(s0_ctrl_addr), .slot0_wdata(s0_ctrl_wdata), .slot0_wmask(s0_ctrl_wmask),
        .slot0_rdata(s0_ctrl_rdata), .slot0_ready(s_ctrl_ready[0]), .slot0_busy(s_ctrl_busy[0]),
        .slot1_active(mem_active[1]), .slot1_grant(mem_grant[1]),
        .slot1_req(s_ctrl_req[1]), .slot1_wr(s_ctrl_wr[1]),
        .slot1_addr(s1_ctrl_addr), .slot1_wdata(s1_ctrl_wdata), .slot1_wmask(s1_ctrl_wmask),
        .slot1_rdata(s1_ctrl_rdata), .slot1_ready(s_ctrl_ready[1]), .slot1_busy(s_ctrl_busy[1]),
        .ctrl_req(ctrl_req), .ctrl_wr(ctrl_wr), .ctrl_addr(ctrl_addr),
        .ctrl_wdata(ctrl_wdata), .ctrl_wmask(ctrl_wmask),
        .ctrl_rdata(ctrl_rdata), .ctrl_ready(ctrl_ready), .ctrl_busy(ctrl_busy)
    );

    sdram_controller #(
        .CLK_FREQ_MHZ(64), .BURST_LEN(BURST_LEN),
        .ROW_BITS(ROW_BITS), .COL_BITS(COL_BITS), .BANK_BITS(BANK_BITS)
    ) u_ctrl (
        .clk(clk), .rst(rst),
        .req(ctrl_req), .wr(ctrl_wr), .addr(ctrl_addr),
        .wdata(ctrl_wdata), .wmask(ctrl_wmask),
        .rdata(ctrl_rdata), .ready(ctrl_ready), .busy(ctrl_busy),
        .sdram_cke(sdram_cke), .sdram_cs_n(sdram_cs_n), .sdram_ras_n(sdram_ras_n),
        .sdram_cas_n(sdram_cas_n), .sdram_we_n(sdram_we_n),
        .sdram_ba(sdram_ba), .sdram_a(sdram_a), .sdram_dq(sdram_dq), .sdram_dqm(sdram_dqm)
    );

    wire [15:0] s0_nid_a, s0_nid_b, s1_nid_a, s1_nid_b;
    wire [ADDR_WIDTH-1:0] s0_raddr_a, s0_raddr_b, s1_raddr_a, s1_raddr_b;

    packed_slot #(
        .DATA_WIDTH(DATA_WIDTH), .P_IN(P_IN), .ACC_WIDTH(ACC_WIDTH),
        .BURST_LEN(BURST_LEN), .ADDR_WIDTH(ADDR_WIDTH), .LAYER_BYTES(LAYER_BYTES)
    ) u_slot0 (
        .clk(clk), .rst(rst),
        .job_start(slot_job_start[0]),
        .x_base_a(slot_x_base_a[0*ADDR_WIDTH +: ADDR_WIDTH]),
        .x_base_b(slot_x_base_b[0*ADDR_WIDTH +: ADDR_WIDTH]),
        .w_base(slot_w_base[0*ADDR_WIDTH +: ADDR_WIDTH]),
        .n_tiles(slot_n_tiles[0*16 +: 16]),
        .result_addr_a(slot_result_addr_a[0*ADDR_WIDTH +: ADDR_WIDTH]),
        .result_addr_b(slot_result_addr_b[0*ADDR_WIDTH +: ADDR_WIDTH]),
        .node_id_a(slot_node_id_a[0*16 +: 16]), .node_id_b(slot_node_id_b[0*16 +: 16]),
        .job_done(slot_job_done[0]),
        .result_data_a(s0_result_data_a), .result_data_b(s0_result_data_b),
        .result_node_id_a(s0_nid_a), .result_node_id_b(s0_nid_b),
        .result_addr_a_out(s0_raddr_a), .result_addr_b_out(s0_raddr_b),
        .mem_active(mem_active[0]), .mem_grant(mem_grant[0]),
        .act_tile_addr_a(s0_act_addr_a), .act_tile_addr_b(s0_act_addr_b),
        .act_tile_data_a(s0_act_data_a), .act_tile_data_b(s0_act_data_b),
        .ctrl_req(s_ctrl_req[0]), .ctrl_wr(s_ctrl_wr[0]), .ctrl_addr(s0_ctrl_addr),
        .ctrl_wdata(s0_ctrl_wdata), .ctrl_wmask(s0_ctrl_wmask),
        .ctrl_rdata(s0_ctrl_rdata), .ctrl_ready(s_ctrl_ready[0]), .ctrl_busy(s_ctrl_busy[0])
    );

    packed_slot #(
        .DATA_WIDTH(DATA_WIDTH), .P_IN(P_IN), .ACC_WIDTH(ACC_WIDTH),
        .BURST_LEN(BURST_LEN), .ADDR_WIDTH(ADDR_WIDTH), .LAYER_BYTES(LAYER_BYTES)
    ) u_slot1 (
        .clk(clk), .rst(rst),
        .job_start(slot_job_start[1]),
        .x_base_a(slot_x_base_a[1*ADDR_WIDTH +: ADDR_WIDTH]),
        .x_base_b(slot_x_base_b[1*ADDR_WIDTH +: ADDR_WIDTH]),
        .w_base(slot_w_base[1*ADDR_WIDTH +: ADDR_WIDTH]),
        .n_tiles(slot_n_tiles[1*16 +: 16]),
        .result_addr_a(slot_result_addr_a[1*ADDR_WIDTH +: ADDR_WIDTH]),
        .result_addr_b(slot_result_addr_b[1*ADDR_WIDTH +: ADDR_WIDTH]),
        .node_id_a(slot_node_id_a[1*16 +: 16]), .node_id_b(slot_node_id_b[1*16 +: 16]),
        .job_done(slot_job_done[1]),
        .result_data_a(s1_result_data_a), .result_data_b(s1_result_data_b),
        .result_node_id_a(s1_nid_a), .result_node_id_b(s1_nid_b),
        .result_addr_a_out(s1_raddr_a), .result_addr_b_out(s1_raddr_b),
        .mem_active(mem_active[1]), .mem_grant(mem_grant[1]),
        .act_tile_addr_a(s1_act_addr_a), .act_tile_addr_b(s1_act_addr_b),
        .act_tile_data_a(s1_act_data_a), .act_tile_data_b(s1_act_data_b),
        .ctrl_req(s_ctrl_req[1]), .ctrl_wr(s_ctrl_wr[1]), .ctrl_addr(s1_ctrl_addr),
        .ctrl_wdata(s1_ctrl_wdata), .ctrl_wmask(s1_ctrl_wmask),
        .ctrl_rdata(s1_ctrl_rdata), .ctrl_ready(s_ctrl_ready[1]), .ctrl_busy(s_ctrl_busy[1])
    );
endmodule
