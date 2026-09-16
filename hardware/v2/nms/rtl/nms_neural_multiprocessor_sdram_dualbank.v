`timescale 1ns/1ps

// ================================================================
// Neural Memory System (NMS) -- EXPERIMENTAL two-physical-SDRAM-bank
// variant, forked from nms_neural_multiprocessor_sdram_unified.v
// (STEP19) to test one specific hypothesis before committing to
// Phase 2/3 of the N=8-timing/85F-retarget/SDRAM-bank-sweep brief:
// is this system's real bottleneck external-memory BANDWIDTH (one
// shared physical SDRAM chip serialising ALL weight+activation+
// result traffic through one sdram_controller.v instance), or
// something else? See hardware/v2/logs/decisions.log (search
// "memory-bound") and errors.log ERR-0030/ERR-0031 for the
// measurement (tb_nms_dstress_sdram_unified.v: SDRAM controller port
// busy ~81.6% of all cycles at BOTH N_SLOTS=4 and N_SLOTS=8) this
// variant exists to stress-test.
//
// NOT a proposal to change the real V2 board (hardware/v2/constraints/
// v2_board_top.lpf wires exactly ONE physical AS4C4M16SA-6TIN chip --
// unchanged, untouched). This module is SIMULATION-side exploration
// only: it duplicates sdram_unified_backend.v (byte-for-byte reused,
// zero modification) into TWO independent instances --
//   u_sdram_backend_w  : services ONLY the W (weight-fetch) port,
//                        ar_req permanently tied low
//   u_sdram_backend_ar : services ONLY the AR (activation-fill +
//                        result-writeback) port, w_req permanently
//                        tied low
// -- each with its OWN sdram_controller.v instance and its OWN set of
// physical SDRAM pins, i.e. what a real two-physical-chip board
// revision would look like. Tying ar_req/w_req permanently to 0 on
// the respective instance is safe by inspection of sdram_unified_
// backend.v's own state machine: with ar_req/ar_req_pending always 0,
// S_AR_RD_WAIT/S_AR_WR_WAIT are simply never entered (and symmetrically
// for w_req/S_W_WAIT) -- no dead-state risk, no latch ever set from a
// permanently-0 input.
//
// u_dataflow_core, u_arbiter (AR, N_SLOTS+1 ports), and u_arbiter_wide
// (W, N_SLOTS ports) are ALL byte-for-byte unchanged from the single-
// bank wrapper -- only the final memory-side fanout changes.
// ================================================================

module nms_neural_multiprocessor_sdram_dualbank #(
    parameter DATA_WIDTH  = 8,
    parameter P_IN        = 8,
    parameter ACC_WIDTH   = 32,
    parameter ADDR_WIDTH  = 26,
    parameter N_SLOTS     = 2,
    parameter N_NODES     = 16,
    parameter MAX_DEPS    = 4,
    parameter QUEUE_DEPTH = 8,
    parameter MAX_TILES   = 16,
    parameter PREFETCH_DISTANCE = 8,
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

    output wire                                 data_ready,

    // ---- Bank W: weight-fetch-only physical SDRAM chip ----
    output wire        sdram_w_cke,
    output wire        sdram_w_cs_n,
    output wire        sdram_w_ras_n,
    output wire        sdram_w_cas_n,
    output wire        sdram_w_we_n,
    output wire [1:0]  sdram_w_ba,
    output wire [12:0] sdram_w_a,
    inout  wire [15:0] sdram_w_dq,
    output wire [1:0]  sdram_w_dqm,

    // ---- Bank AR: activation-fill + result-writeback-only physical
    // SDRAM chip ----
    output wire        sdram_ar_cke,
    output wire        sdram_ar_cs_n,
    output wire        sdram_ar_ras_n,
    output wire        sdram_ar_cas_n,
    output wire        sdram_ar_we_n,
    output wire [1:0]  sdram_ar_ba,
    output wire [12:0] sdram_ar_a,
    inout  wire [15:0] sdram_ar_dq,
    output wire [1:0]  sdram_ar_dqm
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
        .data_ready(data_ready),
        .slot_mem_req(slot_mem_req), .slot_mem_wr(slot_mem_wr), .slot_mem_addr(slot_mem_addr),
        .slot_mem_wdata(slot_mem_wdata), .slot_mem_lb_n(slot_mem_lb_n), .slot_mem_ub_n(slot_mem_ub_n),
        .slot_mem_rdata(slot_mem_rdata), .slot_mem_ready(slot_mem_ready),
        .wide_slot_mem_req(wide_slot_mem_req), .wide_slot_mem_addr(wide_slot_mem_addr),
        .wide_slot_mem_rdata(wide_slot_mem_rdata), .wide_slot_mem_ready(wide_slot_mem_ready)
    );

    // ---- AR: activation-fill (shared, 1 port) + per-slot result
    // writeback (N_SLOTS ports), arbitrated exactly as before ----
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

    // ---- W: weight fetch (N_SLOTS ports), arbitrated exactly as
    // before -- weight fetch never writes, same tie-off convention
    // as STEP16-19 ----
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

    // ---- Bank W: dedicated physical SDRAM backend, W port only, AR
    // port permanently idle (tied off -- never issues an AR-side
    // physical transaction, see header note on why this is safe) ----
    sdram_unified_backend #(
        .ADDR_WIDTH(ADDR_WIDTH), .CLK_FREQ_MHZ(CLK_FREQ_MHZ)
    ) u_sdram_backend_w (
        .clk(clk), .rst(rst),
        .w_req(wide_arb_m_req), .w_addr(wide_arb_m_addr),
        .w_rdata(wide_arb_m_rdata), .w_ready(wide_arb_m_ready),
        .ar_req(1'b0), .ar_wr(1'b0), .ar_addr({ADDR_WIDTH{1'b0}}),
        .ar_wdata(16'h0), .ar_lb_n(1'b1), .ar_ub_n(1'b1),
        .ar_rdata(), .ar_ready(),
        .sdram_cke(sdram_w_cke), .sdram_cs_n(sdram_w_cs_n), .sdram_ras_n(sdram_w_ras_n),
        .sdram_cas_n(sdram_w_cas_n), .sdram_we_n(sdram_w_we_n),
        .sdram_ba(sdram_w_ba), .sdram_a(sdram_w_a), .sdram_dq(sdram_w_dq), .sdram_dqm(sdram_w_dqm)
    );

    // ---- Bank AR: dedicated physical SDRAM backend, AR port only, W
    // port permanently idle ----
    sdram_unified_backend #(
        .ADDR_WIDTH(ADDR_WIDTH), .CLK_FREQ_MHZ(CLK_FREQ_MHZ)
    ) u_sdram_backend_ar (
        .clk(clk), .rst(rst),
        .w_req(1'b0), .w_addr({ADDR_WIDTH{1'b0}}),
        .w_rdata(), .w_ready(),
        .ar_req(arb_m_req), .ar_wr(arb_m_wr), .ar_addr(arb_m_addr), .ar_wdata(arb_m_wdata),
        .ar_lb_n(arb_m_lb_n), .ar_ub_n(arb_m_ub_n),
        .ar_rdata(arb_m_rdata), .ar_ready(arb_m_ready),
        .sdram_cke(sdram_ar_cke), .sdram_cs_n(sdram_ar_cs_n), .sdram_ras_n(sdram_ar_ras_n),
        .sdram_cas_n(sdram_ar_cas_n), .sdram_we_n(sdram_ar_we_n),
        .sdram_ba(sdram_ar_ba), .sdram_a(sdram_ar_a), .sdram_dq(sdram_ar_dq), .sdram_dqm(sdram_ar_dqm)
    );

endmodule
