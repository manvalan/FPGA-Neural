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
//
// STEP16 Phase 5: forked from nms_neural_multiprocessor_dual32.v
// (STEP15's real dual-chip-32-bit weight-fetch variant). The ORIGINAL
// single-chip 16-bit PSRAM activation+writeback path (memory_
// interface.v -> psram_controller.v) is BYTE-FOR-BYTE UNCHANGED --
// STEP15 itself established this path sits at only 4.4% utilization
// and was never the bandwidth bottleneck under test. ONLY the wide
// weight-fetch backend changes: nms_dataflow_core_sdram.v (64-bit
// wide port) -> slot_mem_arbiter_wide.v (reused unchanged at
// DATA_WIDTH=64) -> sdram_weight_backend.v (the real, isolated-and-
// validated AS4C4M16SA-6TIN SDRAM controller, BURST_LEN=4), replacing
// psram_controller_dual32.v exactly at this one point in the design.
// ================================================================

module nms_neural_multiprocessor_sdram_pack128 #(
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
    output wire                         psram_zz_n,

    // ---- STEP16 Phase 5: real single-chip SDRAM physical weight-
    // fetch interface (AS4C4M16SA-6TIN, x16, real JEDEC SDR SDRAM
    // command pins). Real pin count: 2(BA)+12(A)+1(CKE)+1(CS#)+1(RAS#)
    // +1(CAS#)+1(WE#)+2(DQM)+16(DQ) = 37 pins, confirmed by real P&R
    // in Phase 6 (see the STEP16 report's own I/O analysis section) --
    // far fewer than the dual32 baseline's own 61-pin weight-fetch
    // interface, since this is a single chip, not two.
    output wire        sdram_cke,
    output wire        sdram_cs_n,
    output wire        sdram_ras_n,
    output wire        sdram_cas_n,
    output wire        sdram_we_n,
    output wire [1:0]  sdram_ba,
    output wire [11:0] sdram_a,
    inout  wire [15:0] sdram_dq,
    output wire [1:0]  sdram_dqm
);

    wire [N_SLOTS:0]                 slot_mem_req, slot_mem_wr;
    wire [ADDR_WIDTH*(N_SLOTS+1)-1:0] slot_mem_addr;
    wire [16*(N_SLOTS+1)-1:0]        slot_mem_wdata, slot_mem_rdata;
    wire [N_SLOTS:0]                 slot_mem_lb_n, slot_mem_ub_n;
    wire [N_SLOTS:0]                 slot_mem_ready;

    wire [N_SLOTS-1:0]               wide_slot_mem_req;
    wire [ADDR_WIDTH*N_SLOTS-1:0]    wide_slot_mem_addr;
    wire [64*N_SLOTS-1:0]            wide_slot_mem_rdata;
    wire [N_SLOTS-1:0]               wide_slot_mem_ready;

    nms_dataflow_core_sdram #(
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
        .slot_mem_rdata(slot_mem_rdata), .slot_mem_ready(slot_mem_ready),
        .wide_slot_mem_req(wide_slot_mem_req), .wide_slot_mem_addr(wide_slot_mem_addr),
        .wide_slot_mem_rdata(wide_slot_mem_rdata), .wide_slot_mem_ready(wide_slot_mem_ready)
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

    // ================================================================
    // STEP16 Phase 5: real single-chip SDRAM weight-fetch backend --
    // a SEPARATE arbiter (slot_mem_arbiter_wide.v, N_PORTS=N_SLOTS, no
    // activation-fill port sharing this one, reused UNCHANGED from the
    // dual32 baseline at DATA_WIDTH=64) feeding sdram_weight_backend.v
    // (the real, isolated-and-validated AS4C4M16SA-6TIN controller).
    // Weight fetch never writes: mem_wr/mem_wdata tied to 0 at the
    // arbiter's own per-port inputs, matching weight_prefetch_engine_
    // wide.v's own always-full-word read behavior exactly (same
    // convention as the dual32 baseline).
    // ================================================================
    wire [N_SLOTS-1:0]         wide_s_wr = {N_SLOTS{1'b0}};
    wire [64*N_SLOTS-1:0]      wide_s_wdata = {(64*N_SLOTS){1'b0}};
    wire [N_SLOTS-1:0]         wide_s_lb_n = {N_SLOTS{1'b0}};
    wire [N_SLOTS-1:0]         wide_s_ub_n = {N_SLOTS{1'b0}};

    wire                    wide_arb_m_req, wide_arb_m_wr;
    wire [ADDR_WIDTH-1:0]  wide_arb_m_addr;
    wire [63:0]             wide_arb_m_wdata;
    wire                    wide_arb_m_lb_n, wide_arb_m_ub_n;
    wire [63:0]             wide_arb_m_rdata;
    wire                    wide_arb_m_ready;

    slot_mem_arbiter_wide #(
        .ADDR_WIDTH(ADDR_WIDTH), .N_PORTS(N_SLOTS), .DATA_WIDTH(64)
    ) u_arbiter_wide (
        .clk(clk), .rst(rst),
        .s_req(wide_slot_mem_req), .s_wr(wide_s_wr), .s_addr(wide_slot_mem_addr),
        .s_wdata(wide_s_wdata), .s_lb_n(wide_s_lb_n), .s_ub_n(wide_s_ub_n),
        .s_rdata(wide_slot_mem_rdata), .s_ready(wide_slot_mem_ready),
        .m_req(wide_arb_m_req), .m_wr(wide_arb_m_wr), .m_addr(wide_arb_m_addr), .m_wdata(wide_arb_m_wdata),
        .m_lb_n(wide_arb_m_lb_n), .m_ub_n(wide_arb_m_ub_n),
        .m_rdata(wide_arb_m_rdata), .m_ready(wide_arb_m_ready)
    );

    sdram_weight_backend_pack128 #(
        .ADDR_WIDTH(ADDR_WIDTH), .CLK_FREQ_MHZ(CLK_FREQ_MHZ)
    ) u_sdram_backend (
        .clk(clk), .rst(rst),
        .mem_req(wide_arb_m_req), .mem_wr(1'b0), .mem_addr(wide_arb_m_addr), .mem_wdata(64'h0),
        .mem_rdata(wide_arb_m_rdata), .mem_ready(wide_arb_m_ready),
        .sdram_cke(sdram_cke), .sdram_cs_n(sdram_cs_n), .sdram_ras_n(sdram_ras_n),
        .sdram_cas_n(sdram_cas_n), .sdram_we_n(sdram_we_n),
        .sdram_ba(sdram_ba), .sdram_a(sdram_a), .sdram_dq(sdram_dq), .sdram_dqm(sdram_dqm)
    );

endmodule
