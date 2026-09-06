`timescale 1ns/1ps

// ================================================================
// Neural Memory System (NMS) -- STEP9 real hardware-facing top level.
// Mirrors hardware/v2/rtl/neural_multiprocessor.v's own scope exactly
// (M8): nms_dataflow_core.v's N_SLOTS+1 independent Memory Backend
// Interface ports funneled through the SAME, UNMODIFIED
// slot_mem_arbiter.v down to the SAME, UNMODIFIED real V1 PSRAM
// backend chain (memory_interface.v -> psram_controller.v).
//
// Nothing about the arbiter or the real PSRAM chain changes for the
// NMS -- only nms_dataflow_core.v's own internals (the memory
// organization DEC-0019/DEC-0020 decided) differ from the frozen V2
// dataflow_core.v this module's own structure is copied from.
// ================================================================

module nms_neural_multiprocessor_actfix #(
    parameter DATA_WIDTH  = 8,
    parameter P_IN        = 8,
    parameter ACC_WIDTH   = 32,
    parameter ADDR_WIDTH  = 23,
    parameter N_SLOTS     = 2,
    parameter N_NODES     = 16,
    parameter MAX_DEPS    = 4,
    parameter QUEUE_DEPTH = 8,
    parameter MAX_TILES   = 16,
    parameter PREFETCH_DISTANCE = 8,
    parameter PSRAM_DATA_WIDTH = 16,
    parameter CLK_FREQ_MHZ     = 80
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

    output wire [ADDR_WIDTH-1:0]        psram_a,
    inout  wire [PSRAM_DATA_WIDTH-1:0]  psram_dq,
    output wire                         psram_ce_n,
    output wire                         psram_oe_n,
    output wire                         psram_we_n,
    output wire                         psram_lb_n,
    output wire                         psram_ub_n,
    output wire                         psram_zz_n
);

    wire [N_SLOTS:0]                 slot_mem_req, slot_mem_wr;
    wire [ADDR_WIDTH*(N_SLOTS+1)-1:0] slot_mem_addr;
    wire [16*(N_SLOTS+1)-1:0]        slot_mem_wdata, slot_mem_rdata;
    wire [N_SLOTS:0]                 slot_mem_lb_n, slot_mem_ub_n;
    wire [N_SLOTS:0]                 slot_mem_ready;

    nms_dataflow_core_actfix #(
        .DATA_WIDTH(DATA_WIDTH), .P_IN(P_IN), .ACC_WIDTH(ACC_WIDTH), .ADDR_WIDTH(ADDR_WIDTH),
        .N_SLOTS(N_SLOTS), .N_NODES(N_NODES), .MAX_DEPS(MAX_DEPS), .QUEUE_DEPTH(QUEUE_DEPTH),
        .MAX_TILES(MAX_TILES), .PREFETCH_DISTANCE(PREFETCH_DISTANCE)
    ) u_dataflow_core (
        .clk(clk), .rst(rst),
        .reg_valid(reg_valid), .reg_ready(reg_ready), .reg_node_id(reg_node_id),
        .reg_required(reg_required), .reg_producer_ids(reg_producer_ids),
        .reg_x_base(reg_x_base), .reg_w_base(reg_w_base), .reg_n_tiles(reg_n_tiles),
        .reg_result_addr(reg_result_addr),
        .slot_mem_req(slot_mem_req), .slot_mem_wr(slot_mem_wr), .slot_mem_addr(slot_mem_addr),
        .slot_mem_wdata(slot_mem_wdata), .slot_mem_lb_n(slot_mem_lb_n), .slot_mem_ub_n(slot_mem_ub_n),
        .slot_mem_rdata(slot_mem_rdata), .slot_mem_ready(slot_mem_ready)
    );

    wire                    arb_m_req, arb_m_wr;
    wire [ADDR_WIDTH-1:0]   arb_m_addr;
    wire [15:0]             arb_m_wdata;
    wire                    arb_m_lb_n, arb_m_ub_n;
    wire [15:0]             arb_m_rdata;
    wire                    arb_m_ready;

    slot_mem_arbiter #(
        .ADDR_WIDTH(ADDR_WIDTH), .N_PORTS(N_SLOTS+1)
    ) u_arbiter (
        .clk(clk), .rst(rst),
        .s_req(slot_mem_req), .s_wr(slot_mem_wr), .s_addr(slot_mem_addr),
        .s_wdata(slot_mem_wdata), .s_lb_n(slot_mem_lb_n), .s_ub_n(slot_mem_ub_n),
        .s_rdata(slot_mem_rdata), .s_ready(slot_mem_ready),
        .m_req(arb_m_req), .m_wr(arb_m_wr), .m_addr(arb_m_addr), .m_wdata(arb_m_wdata),
        .m_lb_n(arb_m_lb_n), .m_ub_n(arb_m_ub_n),
        .m_rdata(arb_m_rdata), .m_ready(arb_m_ready)
    );

    wire                          pc_mem_req, pc_mem_wr;
    wire [ADDR_WIDTH-1:0]         pc_mem_addr;
    wire [PSRAM_DATA_WIDTH-1:0]   pc_mem_wdata;
    wire                          pc_mem_lb_n, pc_mem_ub_n;
    wire [PSRAM_DATA_WIDTH-1:0]   pc_mem_rdata;
    wire                          pc_mem_ready;

    memory_interface #(.ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(PSRAM_DATA_WIDTH)) u_memif (
        .clk(clk), .rst(rst),
        .req(arb_m_req), .wr(arb_m_wr), .addr(arb_m_addr), .wdata(arb_m_wdata),
        .lb_n(arb_m_lb_n), .ub_n(arb_m_ub_n),
        .rdata(arb_m_rdata), .ready(arb_m_ready),
        .mem_req(pc_mem_req), .mem_wr(pc_mem_wr), .mem_addr(pc_mem_addr), .mem_wdata(pc_mem_wdata),
        .mem_lb_n(pc_mem_lb_n), .mem_ub_n(pc_mem_ub_n),
        .mem_rdata(pc_mem_rdata), .mem_ready(pc_mem_ready)
    );

    psram_controller #(
        .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(PSRAM_DATA_WIDTH), .CLK_FREQ_MHZ(CLK_FREQ_MHZ)
    ) u_psram_ctrl (
        .clk(clk), .rst(rst),
        .mem_req(pc_mem_req), .mem_wr(pc_mem_wr), .mem_addr(pc_mem_addr), .mem_wdata(pc_mem_wdata),
        .mem_lb_n(pc_mem_lb_n), .mem_ub_n(pc_mem_ub_n),
        .mem_rdata(pc_mem_rdata), .mem_ready(pc_mem_ready),
        .psram_a(psram_a), .psram_dq(psram_dq),
        .psram_ce_n(psram_ce_n), .psram_oe_n(psram_oe_n), .psram_we_n(psram_we_n),
        .psram_lb_n(psram_lb_n), .psram_ub_n(psram_ub_n), .psram_zz_n(psram_zz_n)
    );

endmodule
