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

module nms_neural_multiprocessor_dual32 #(
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

    // ---- STEP15 (continuation): real dual-chip 32-bit physical
    // weight-fetch interface, TWO independent 16-bit PSRAM chips.
    //
    // Address and control (CE#/OE#/WE#/LB#/UB#/ZZ#) are SHARED, ONE
    // set of real FPGA pins, not duplicated per chip: both
    // psram_controller.v instances inside psram_controller_dual32.v
    // are fed byte-for-byte IDENTICAL mem_req/mem_wr/mem_addr/
    // mem_lb_n/mem_ub_n every cycle (that IS the whole synchronization
    // mechanism, EXP-0037/DEC-0029), so their own address/control
    // OUTPUTS are, by construction, always identical too -- a real
    // PCB ties ONE FPGA pin's own net to BOTH chips' corresponding
    // input pin (a simple fan-out trace, not a bus-contention
    // concern, since these are FPGA OUTPUTS driving PASSIVE chip
    // inputs). Only DQ (bidirectional, chip-specific data) genuinely
    // needs independent pins per chip.
    //
    // An earlier draft exposed FULLY separate psram0_*/psram1_*
    // address+control pins (90 total pins for this interface) --
    // real synthesis+P&R (EXP-0039) found this EXCEEDS the real
    // package's own I/O budget by exactly 2 pins (245 total
    // TRELLIS_IO on the LFE5U-45F-8CABGA381; 157 already committed by
    // the existing registration+single-chip-PSRAM interface, leaving
    // 88 free; 90 needed). Sharing address/control (a real, valid
    // PCB technique, not a synthesis trick) drops the requirement to
    // 23(addr)+6(ctrl)+16(chip0 dq)+16(chip1 dq) = 61 pins, which
    // fits comfortably (61 < 88).
    output wire [ADDR_WIDTH-1:0]        psram01_a,
    output wire                         psram01_ce_n,
    output wire                         psram01_oe_n,
    output wire                         psram01_we_n,
    output wire                         psram01_lb_n,
    output wire                         psram01_ub_n,
    output wire                         psram01_zz_n,
    inout  wire [15:0]                  psram0_dq,
    inout  wire [15:0]                  psram1_dq
);

    wire [N_SLOTS:0]                 slot_mem_req, slot_mem_wr;
    wire [ADDR_WIDTH*(N_SLOTS+1)-1:0] slot_mem_addr;
    wire [16*(N_SLOTS+1)-1:0]        slot_mem_wdata, slot_mem_rdata;
    wire [N_SLOTS:0]                 slot_mem_lb_n, slot_mem_ub_n;
    wire [N_SLOTS:0]                 slot_mem_ready;

    wire [N_SLOTS-1:0]               wide_slot_mem_req;
    wire [ADDR_WIDTH*N_SLOTS-1:0]    wide_slot_mem_addr;
    wire [32*N_SLOTS-1:0]            wide_slot_mem_rdata;
    wire [N_SLOTS-1:0]               wide_slot_mem_ready;

    nms_dataflow_core_dual32 #(
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
    // STEP15 (continuation): real dual-chip 32-bit weight-fetch
    // backend -- a SEPARATE arbiter (slot_mem_arbiter_wide.v, N_PORTS=
    // N_SLOTS, no activation-fill port sharing this one) feeding the
    // real psram_controller_dual32.v (two independent, real,
    // UNMODIFIED psram_controller.v instances, DEC-0029's own
    // selected architecture). Weight fetch never writes: mem_wr/
    // mem_wdata tied to 0 at the arbiter's own per-port inputs, and
    // the dual32 controller's own 2-bit lane-enables tied to
    // "always both bytes of both chips" (2'b00), matching
    // weight_prefetch_engine_wide.v's own always-full-word read
    // behavior exactly (same convention as its real 16-bit
    // counterpart, weight_prefetch_engine.v).
    // ================================================================
    wire [N_SLOTS-1:0]         wide_s_wr = {N_SLOTS{1'b0}};
    wire [32*N_SLOTS-1:0]      wide_s_wdata = {(32*N_SLOTS){1'b0}};
    wire [N_SLOTS-1:0]         wide_s_lb_n = {N_SLOTS{1'b0}};
    wire [N_SLOTS-1:0]         wide_s_ub_n = {N_SLOTS{1'b0}};

    wire                    wide_arb_m_req, wide_arb_m_wr;
    wire [ADDR_WIDTH-1:0]  wide_arb_m_addr;
    wire [31:0]             wide_arb_m_wdata;
    wire                    wide_arb_m_lb_n, wide_arb_m_ub_n;
    wire [31:0]             wide_arb_m_rdata;
    wire                    wide_arb_m_ready;

    slot_mem_arbiter_wide #(
        .ADDR_WIDTH(ADDR_WIDTH), .N_PORTS(N_SLOTS), .DATA_WIDTH(32)
    ) u_arbiter_wide (
        .clk(clk), .rst(rst),
        .s_req(wide_slot_mem_req), .s_wr(wide_s_wr), .s_addr(wide_slot_mem_addr),
        .s_wdata(wide_s_wdata), .s_lb_n(wide_s_lb_n), .s_ub_n(wide_s_ub_n),
        .s_rdata(wide_slot_mem_rdata), .s_ready(wide_slot_mem_ready),
        .m_req(wide_arb_m_req), .m_wr(wide_arb_m_wr), .m_addr(wide_arb_m_addr), .m_wdata(wide_arb_m_wdata),
        .m_lb_n(wide_arb_m_lb_n), .m_ub_n(wide_arb_m_ub_n),
        .m_rdata(wide_arb_m_rdata), .m_ready(wide_arb_m_ready)
    );

    wire dual32_lane_sync_error;
    // chip1's own address/control outputs (identical in value to
    // chip0's, per the shared-input synchronization argument above) --
    // deliberately left unconnected to any top-level pin.
    wire [ADDR_WIDTH-1:0] unused_psram1_a;
    wire unused_psram1_ce_n, unused_psram1_oe_n, unused_psram1_we_n;
    wire unused_psram1_lb_n, unused_psram1_ub_n, unused_psram1_zz_n;

    psram_controller_dual32 #(
        .ADDR_WIDTH(ADDR_WIDTH), .CLK_FREQ_MHZ(CLK_FREQ_MHZ)
    ) u_psram_dual32 (
        .clk(clk), .rst(rst),
        .mem_req(wide_arb_m_req), .mem_wr(1'b0), .mem_addr(wide_arb_m_addr), .mem_wdata(32'h0),
        .mem_lb_n(2'b00), .mem_ub_n(2'b00),
        .mem_rdata(wide_arb_m_rdata), .mem_ready(wide_arb_m_ready),
        .lane_sync_error(dual32_lane_sync_error),
        .psram0_a(psram01_a), .psram0_dq(psram0_dq),
        .psram0_ce_n(psram01_ce_n), .psram0_oe_n(psram01_oe_n), .psram0_we_n(psram01_we_n),
        .psram0_lb_n(psram01_lb_n), .psram0_ub_n(psram01_ub_n), .psram0_zz_n(psram01_zz_n),
        // chip1's own address/control outputs are byte-for-byte
        // identical to chip0's (EXP-0037/DEC-0029) -- left as
        // internal-only wires here, not exposed as separate top-level
        // pins; a real PCB fans the SAME psram01_* net out to both
        // chips' corresponding input pin instead.
        .psram1_a(unused_psram1_a), .psram1_dq(psram1_dq),
        .psram1_ce_n(unused_psram1_ce_n), .psram1_oe_n(unused_psram1_oe_n), .psram1_we_n(unused_psram1_we_n),
        .psram1_lb_n(unused_psram1_lb_n), .psram1_ub_n(unused_psram1_ub_n), .psram1_zz_n(unused_psram1_zz_n)
    );

endmodule
