`timescale 1ns/1ps

// ================================================================
// FPGA-Neural V2 -- Neural Multiprocessor top (M8, docs/v2-description.md
// §15/§16: "Integrare il controller V1 senza modificarlo inizialmente.
// Misurare il comportamento reale.")
//
// The real, hardware-facing top-level: dataflow_core.v (M7) with its
// N_SLOTS independent Memory Backend Interface ports funneled through
// a new generic arbiter (slot_mem_arbiter.v, M8) down to the REAL,
// UNMODIFIED hardware/v1 PSRAM backend chain --
//   int8_memory_access -> memory_interface -> psram_controller
// -- exactly the chain hardware/v2/sim/tb_memory_manager.v (M4)
// already proved correct for ONE memory_manager port. This module is
// the first point M3 (per DEC-0009) and M2 (per DEC-0006) BOTH
// deferred to: N_SLOTS memory_manager instances genuinely sharing one
// physical PSRAM port.
//
// dataflow_core.v itself is NOT modified -- its per-slot interface
// (DEC-0009) is exactly what makes it pluggable into an arbiter here
// without touching M7's own file.
// ================================================================

module neural_multiprocessor #(
    parameter DATA_WIDTH  = 8,
    parameter P_IN        = 8,
    parameter ACC_WIDTH   = 32,
    parameter ADDR_WIDTH  = 23,
    parameter N_SLOTS     = 4,
    parameter N_NODES     = 16,
    parameter MAX_DEPS    = 4,
    parameter QUEUE_DEPTH = 8,
    parameter PSRAM_DATA_WIDTH = 16,
    parameter CLK_FREQ_MHZ     = 80
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

    // ---- real PSRAM pins (hardware/v1/rtl/psram_controller.v's own
    // contract, unmodified) ----
    output wire [ADDR_WIDTH-1:0]        psram_a,
    inout  wire [PSRAM_DATA_WIDTH-1:0]  psram_dq,
    output wire                         psram_ce_n,
    output wire                         psram_oe_n,
    output wire                         psram_we_n,
    output wire                         psram_lb_n,
    output wire                         psram_ub_n,
    output wire                         psram_zz_n
);

    // ---- dataflow_core (M7, unmodified) ----
    wire [N_SLOTS-1:0]              slot_mem_req, slot_mem_wr;
    wire [ADDR_WIDTH*N_SLOTS-1:0]   slot_mem_addr;
    wire signed [8*N_SLOTS-1:0]     slot_mem_wdata, slot_mem_rdata;
    wire [N_SLOTS-1:0]              slot_mem_ready;

    dataflow_core #(
        .DATA_WIDTH(DATA_WIDTH), .P_IN(P_IN), .ACC_WIDTH(ACC_WIDTH), .ADDR_WIDTH(ADDR_WIDTH),
        .N_SLOTS(N_SLOTS), .N_NODES(N_NODES), .MAX_DEPS(MAX_DEPS), .QUEUE_DEPTH(QUEUE_DEPTH)
    ) u_dataflow_core (
        .clk(clk), .rst(rst),
        .reg_valid(reg_valid), .reg_ready(reg_ready), .reg_node_id(reg_node_id),
        .reg_required(reg_required), .reg_producer_ids(reg_producer_ids),
        .reg_x_base(reg_x_base), .reg_w_base(reg_w_base), .reg_n_tiles(reg_n_tiles),
        .reg_result_addr(reg_result_addr),
        .slot_mem_req(slot_mem_req), .slot_mem_wr(slot_mem_wr), .slot_mem_addr(slot_mem_addr),
        .slot_mem_wdata(slot_mem_wdata), .slot_mem_rdata(slot_mem_rdata), .slot_mem_ready(slot_mem_ready)
    );

    // ---- N_SLOTS -> 1 arbiter (M8, new) ----
    wire                    arb_m_req, arb_m_wr;
    wire [ADDR_WIDTH-1:0]   arb_m_addr;
    wire signed [7:0]       arb_m_wdata;
    wire signed [7:0]       arb_m_rdata;
    wire                    arb_m_ready;

    slot_mem_arbiter #(
        .ADDR_WIDTH(ADDR_WIDTH), .N_PORTS(N_SLOTS)
    ) u_arbiter (
        .clk(clk), .rst(rst),
        .s_req(slot_mem_req), .s_wr(slot_mem_wr), .s_addr(slot_mem_addr),
        .s_wdata(slot_mem_wdata), .s_rdata(slot_mem_rdata), .s_ready(slot_mem_ready),
        .m_req(arb_m_req), .m_wr(arb_m_wr), .m_addr(arb_m_addr), .m_wdata(arb_m_wdata),
        .m_rdata(arb_m_rdata), .m_ready(arb_m_ready)
    );

    // ---- real, unmodified V1 PSRAM backend chain ----
    wire                          if_mem_req, if_mem_wr;
    wire [ADDR_WIDTH-1:0]         if_mem_addr;
    wire [PSRAM_DATA_WIDTH-1:0]   if_mem_wdata;
    wire                          if_mem_lb_n, if_mem_ub_n;
    wire [PSRAM_DATA_WIDTH-1:0]   if_mem_rdata;
    wire                          if_mem_ready;

    int8_memory_access #(.ADDR_WIDTH(ADDR_WIDTH)) u_int8 (
        .clk(clk), .rst(rst),
        .req(arb_m_req), .wr(arb_m_wr), .addr(arb_m_addr), .wdata(arb_m_wdata),
        .rdata(arb_m_rdata), .ready(arb_m_ready),
        .mem_req(if_mem_req), .mem_wr(if_mem_wr), .mem_addr(if_mem_addr), .mem_wdata(if_mem_wdata),
        .mem_lb_n(if_mem_lb_n), .mem_ub_n(if_mem_ub_n),
        .mem_rdata(if_mem_rdata), .mem_ready(if_mem_ready)
    );

    wire                          pc_mem_req, pc_mem_wr;
    wire [ADDR_WIDTH-1:0]         pc_mem_addr;
    wire [PSRAM_DATA_WIDTH-1:0]   pc_mem_wdata;
    wire                          pc_mem_lb_n, pc_mem_ub_n;
    wire [PSRAM_DATA_WIDTH-1:0]   pc_mem_rdata;
    wire                          pc_mem_ready;

    memory_interface #(.ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(PSRAM_DATA_WIDTH)) u_memif (
        .clk(clk), .rst(rst),
        .req(if_mem_req), .wr(if_mem_wr), .addr(if_mem_addr), .wdata(if_mem_wdata),
        .lb_n(if_mem_lb_n), .ub_n(if_mem_ub_n),
        .rdata(if_mem_rdata), .ready(if_mem_ready),
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
