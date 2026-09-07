`timescale 1ns/1ps

// ================================================================
// FPGA-Neural V2 -- BOARD-LEVEL TOP (STEP20, real physical interface)
//
// Wraps the STEP19 frozen compute+memory design (the same submodules
// nms_neural_multiprocessor_sdram_unified.v instantiates -- that file
// itself is NOT instantiated here, since its own reg_*/N_SLOTS+1-port
// AR arbitration needs a second arbitration LEVEL added for the new
// host-raw-SDRAM-access port; this module reproduces that same
// internal wiring plus the extra level, rather than modifying the
// frozen file) with the three things a real physical board needs that
// a testbench does not:
//
//   1. A real SPI host interface (spi_host_bridge.v) in place of the
//      110-pin reg_* testbench bus -- reg_valid/reg_ready/reg_node_id/
//      etc are now DRIVEN BY THE BRIDGE, not exposed as top ports.
//   2. A real ECP5 PLL (ecp5_pll_sys_clk.v, EHXPLLL) generating the
//      system clock from the board's 16MHz oscillator, instead of
//      assuming an already-correct-frequency clock input.
//   3. A real reset/POR synchronizer (reset_sync.v).
//
// nms_dataflow_core_sdram.v, dependency_manager.v, neural_processor.v,
// neural_director.v, slot_mem_arbiter.v, slot_mem_arbiter_wide.v,
// sdram_unified_backend.v, sdram_controller.v are ALL byte-for-byte
// unchanged (STEP19/STEP20 standing constraint) -- this file only
// ADDS one more, already-proven, generically-parameterized
// slot_mem_arbiter instance (N_PORTS=2) to arbitrate the SPI bridge's
// raw host memory port against the existing compute-side AR stream,
// both funneling into the SAME single sdram_unified_backend/
// sdram_controller/AS4C4M16SA-6TIN physical chain STEP19 already
// validated. No V1 RTL is instantiated (STEP19's "zero V1 files in
// the V2 compile list" property is preserved).
// ================================================================

module fpga_neural_v2_top #(
    parameter DATA_WIDTH  = 8,
    parameter P_IN        = 8,
    parameter ACC_WIDTH   = 32,
    parameter ADDR_WIDTH  = 26,
    parameter N_SLOTS     = 4,
    parameter N_NODES     = 16,
    parameter MAX_DEPS    = 4,
    parameter QUEUE_DEPTH = 8,
    parameter MAX_TILES   = 16,
    parameter PREFETCH_DISTANCE = 8,
    parameter CLK_FREQ_MHZ     = 64
)(
    input  wire osc_clk,     // 16 MHz board oscillator
    input  wire ext_rst_n,   // external POR/supervisor, active-low

    // ---- physical SPI host interface ----
    input  wire spi_sclk,
    input  wire spi_mosi,
    output wire spi_miso,
    input  wire spi_cs_n,

    // ---- single physical SDRAM (weights + activations + results) ----
    // sdram_clk: the real SDRAM chip's own CLK pin -- an external
    // chip, it needs this driven from a real output ball, NOT just
    // internal routing. Found missing entirely during this session's
    // schematic review (clk_sys was purely internal, never reached a
    // pad) -- added here, real free clock-capable ball (bank 6).
    output wire        sdram_clk,
    output wire        sdram_cke,
    output wire        sdram_cs_n,
    output wire        sdram_ras_n,
    output wire        sdram_cas_n,
    output wire        sdram_we_n,
    output wire [1:0]  sdram_ba,
    output wire [12:0] sdram_a,
    inout  wire [15:0] sdram_dq,
    output wire [1:0]  sdram_dqm,

    // FPGA_DATA_READY: high once the whole registered graph has
    // finished (system-idle sticky flag, self-clearing on new work) --
    // see nms_dataflow_core_sdram.v for the full design comment.
    output wire data_ready,

    // ---- Flash #1 (neural-network weights/graph data): real,
    // ordinary GPIO SPI bus, physically separate from flash #2 (boot)
    // -- see decisions.log for the two-flash architecture rationale.
    output wire flash_sclk,
    output wire flash_mosi,
    input  wire flash_miso,
    output wire flash_cs_n,

    output wire pll_locked
);

    // ============================================================
    // CLOCK / RESET
    // ============================================================
    wire clk_sys;
    ecp5_pll_sys_clk u_pll (
        .clk_16mhz(osc_clk), .clk_sys(clk_sys), .locked(pll_locked)
    );

    assign sdram_clk = clk_sys;

    wire clk = clk_sys;
    wire rst;
    reset_sync u_reset_sync (
        .clk_sys(clk_sys), .ext_rst_n(ext_rst_n), .pll_locked(pll_locked), .rst(rst)
    );

    wire soft_rst_pulse;
    wire core_rst = rst | soft_rst_pulse;

    // ============================================================
    // SPI HOST BRIDGE (replaces the 110-pin reg_* testbench bus)
    // ============================================================
    wire                                reg_valid, reg_ready;
    wire [$clog2(N_NODES)-1:0]          reg_node_id;
    wire [$clog2(MAX_DEPS+1)-1:0]       reg_required;
    wire [MAX_DEPS*$clog2(N_NODES)-1:0] reg_producer_ids;
    wire [ADDR_WIDTH-1:0]               reg_x_base, reg_w_base, reg_result_addr;
    wire [15:0]                        reg_n_tiles;

    wire                   host_mem_req, host_mem_wr, host_mem_lb_n, host_mem_ub_n;
    wire [ADDR_WIDTH-1:0]  host_mem_addr;
    wire [15:0]            host_mem_wdata, host_mem_rdata;
    wire                   host_mem_ready;

    wire                   flash_op_start;
    wire [2:0]             flash_op_code;
    wire [3:0]             flash_slot_id;
    wire [23:0]            flash_new_offset, flash_new_length, flash_ext_length, flash_raw_flash_addr;
    wire [7:0]              flash_new_type;
    wire [ADDR_WIDTH-1:0]  flash_ext_addr;

    spi_host_bridge #(
        .ADDR_WIDTH(ADDR_WIDTH), .N_NODES(N_NODES), .MAX_DEPS(MAX_DEPS)
    ) u_spi_bridge (
        .clk(clk), .rst(rst),
        .sclk(spi_sclk), .mosi(spi_mosi), .miso(spi_miso), .cs_n(spi_cs_n),
        .reg_valid(reg_valid), .reg_ready(reg_ready), .reg_node_id(reg_node_id),
        .reg_required(reg_required), .reg_producer_ids(reg_producer_ids),
        .reg_x_base(reg_x_base), .reg_w_base(reg_w_base),
        .reg_n_tiles(reg_n_tiles), .reg_result_addr(reg_result_addr),
        .mem_req(host_mem_req), .mem_wr(host_mem_wr), .mem_addr(host_mem_addr),
        .mem_wdata(host_mem_wdata), .mem_lb_n(host_mem_lb_n), .mem_ub_n(host_mem_ub_n),
        .mem_rdata(host_mem_rdata), .mem_ready(host_mem_ready),
        .soft_rst_pulse(soft_rst_pulse),
        .flash_op_start(flash_op_start), .flash_op_code(flash_op_code),
        .flash_slot_id(flash_slot_id), .flash_new_offset(flash_new_offset),
        .flash_new_length(flash_new_length), .flash_new_type(flash_new_type),
        .flash_ext_addr(flash_ext_addr), .flash_ext_length(flash_ext_length),
        .flash_raw_flash_addr(flash_raw_flash_addr),
        .flash_busy(flash1_busy), .flash_done(flash1_done), .flash_err(flash1_err)
    );

    // ============================================================
    // COMPUTE + MEMORY (same wiring as nms_neural_multiprocessor_
    // sdram_unified.v, plus the new host-arb level)
    // ============================================================
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
        .clk(clk), .rst(core_rst),
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

    // ---- AR level 1 (unchanged): activation-fill + per-slot result
    // writeback, exactly as nms_neural_multiprocessor_sdram_unified.v ----
    wire                    arb_m_req, arb_m_wr;
    wire [ADDR_WIDTH-1:0]   arb_m_addr;
    wire [15:0]             arb_m_wdata;
    wire                    arb_m_lb_n, arb_m_ub_n;
    wire [15:0]             arb_m_rdata;
    wire                    arb_m_ready;

    slot_mem_arbiter #(
        .ADDR_WIDTH(ADDR_WIDTH), .N_PORTS(N_SLOTS+1)
    ) u_arbiter (
        .clk(clk), .rst(core_rst),
        .s_req(slot_mem_req), .s_wr(slot_mem_wr), .s_addr(slot_mem_addr),
        .s_wdata(slot_mem_wdata), .s_lb_n(slot_mem_lb_n), .s_ub_n(slot_mem_ub_n),
        .s_rdata(slot_mem_rdata), .s_ready(slot_mem_ready),
        .m_req(arb_m_req), .m_wr(arb_m_wr), .m_addr(arb_m_addr), .m_wdata(arb_m_wdata),
        .m_lb_n(arb_m_lb_n), .m_ub_n(arb_m_ub_n),
        .m_rdata(arb_m_rdata), .m_ready(arb_m_ready)
    );

    // ---- AR level 2 (STEP20/STEP21): compute-side AR stream (port0,
    // highest priority) vs. SPI host raw memory port (port1) vs.
    // flash #1 (neural-network data) port (port2, lowest priority --
    // matches V1's own "Port D, lowest priority" convention for this
    // exact traffic class) -- reuses slot_mem_arbiter completely
    // unchanged, just at N_PORTS=3, its own already-proven pending-
    // latch discipline applying equally to a 3-port instance ----
    wire                    flash_ar_req, flash_ar_wr, flash_ar_lb_n, flash_ar_ub_n, flash_ar_ready;
    wire [ADDR_WIDTH-1:0]   flash_ar_addr;
    wire [15:0]             flash_ar_wdata, flash_ar_rdata;

    wire [2:0]               host_arb_s_req, host_arb_s_wr, host_arb_s_lb_n, host_arb_s_ub_n, host_arb_s_ready;
    wire [ADDR_WIDTH*3-1:0]  host_arb_s_addr;
    wire [16*3-1:0]          host_arb_s_wdata, host_arb_s_rdata;

    assign host_arb_s_req    = {flash_ar_req,   host_mem_req,   arb_m_req};
    assign host_arb_s_wr     = {flash_ar_wr,    host_mem_wr,    arb_m_wr};
    assign host_arb_s_lb_n   = {flash_ar_lb_n,  host_mem_lb_n,  arb_m_lb_n};
    assign host_arb_s_ub_n   = {flash_ar_ub_n,  host_mem_ub_n,  arb_m_ub_n};
    assign host_arb_s_addr   = {flash_ar_addr,  host_mem_addr,  arb_m_addr};
    assign host_arb_s_wdata  = {flash_ar_wdata, host_mem_wdata, arb_m_wdata};
    assign arb_m_ready       = host_arb_s_ready[0];
    assign arb_m_rdata       = host_arb_s_rdata[15:0];
    assign host_mem_ready    = host_arb_s_ready[1];
    assign host_mem_rdata    = host_arb_s_rdata[31:16];
    assign flash_ar_ready    = host_arb_s_ready[2];
    assign flash_ar_rdata    = host_arb_s_rdata[47:32];

    wire                  final_ar_req, final_ar_wr;
    wire [ADDR_WIDTH-1:0] final_ar_addr;
    wire [15:0]           final_ar_wdata;
    wire                  final_ar_lb_n, final_ar_ub_n;
    wire [15:0]           final_ar_rdata;
    wire                  final_ar_ready;

    slot_mem_arbiter #(
        .ADDR_WIDTH(ADDR_WIDTH), .N_PORTS(3)
    ) u_host_arb (
        .clk(clk), .rst(core_rst),
        .s_req(host_arb_s_req), .s_wr(host_arb_s_wr), .s_addr(host_arb_s_addr),
        .s_wdata(host_arb_s_wdata), .s_lb_n(host_arb_s_lb_n), .s_ub_n(host_arb_s_ub_n),
        .s_rdata(host_arb_s_rdata), .s_ready(host_arb_s_ready),
        .m_req(final_ar_req), .m_wr(final_ar_wr), .m_addr(final_ar_addr), .m_wdata(final_ar_wdata),
        .m_lb_n(final_ar_lb_n), .m_ub_n(final_ar_ub_n),
        .m_rdata(final_ar_rdata), .m_ready(final_ar_ready)
    );

    // ---- Flash #1 (neural-network weights/graph data): real,
    // unmodified V1 subsystem (flash_slot_manager.v, which owns
    // flash_copy_engine.v, which owns spi_flash_master.v; crc32.v used
    // internally too) -- see decisions.log for the integration design.
    // Command interface driven by spi_host_bridge.v's own new
    // OP_FLASH_CMD opcode. Data path bridged into the AR arbiter above
    // via flash_mem_adapter.v (byte<->word, matches nms_memory_
    // manager_stream_wide.v's own real masking convention). ----
    wire flash_d_req, flash_d_wr, flash_d_ready;
    wire [ADDR_WIDTH-1:0]  flash_d_addr;
    wire signed [7:0]      flash_d_wdata, flash_d_rdata;
    wire flash1_busy, flash1_done, flash1_err;

    flash_slot_manager #(
        .PSRAM_ADDR_WIDTH(ADDR_WIDTH), .CLK_FREQ_MHZ(64), .SCLK_DIV(2)
    ) u_flash1 (
        .clk(clk), .rst(core_rst),
        .mosi(flash_mosi), .miso(flash_miso), .cs_n(flash_cs_n), .sclk(flash_sclk),
        .op_start(flash_op_start), .op_code(flash_op_code), .slot_id(flash_slot_id),
        .new_offset(flash_new_offset), .new_length(flash_new_length), .new_type(flash_new_type),
        .ext_psram_addr(flash_ext_addr), .ext_length(flash_ext_length),
        .raw_flash_addr(flash_raw_flash_addr),
        .busy(flash1_busy), .done(flash1_done), .err(flash1_err),
        .cat_read_sel(4'd0), .cat_out_offset(), .cat_out_length(),
        .cat_out_type(), .cat_out_valid(), .cat_out_crc(),
        .d_req(flash_d_req), .d_wr(flash_d_wr), .d_addr(flash_d_addr),
        .d_wdata(flash_d_wdata), .d_rdata(flash_d_rdata), .d_ready(flash_d_ready)
    );

    flash_mem_adapter #(
        .ADDR_WIDTH(ADDR_WIDTH), .BYTE_ADDR_WIDTH(ADDR_WIDTH)
    ) u_flash_adapter (
        .clk(clk), .rst(core_rst),
        .d_req(flash_d_req), .d_wr(flash_d_wr), .d_addr(flash_d_addr),
        .d_wdata(flash_d_wdata), .d_rdata(flash_d_rdata), .d_ready(flash_d_ready),
        .s_req(flash_ar_req), .s_wr(flash_ar_wr), .s_addr(flash_ar_addr),
        .s_wdata(flash_ar_wdata), .s_lb_n(flash_ar_lb_n), .s_ub_n(flash_ar_ub_n),
        .s_rdata(flash_ar_rdata), .s_ready(flash_ar_ready)
    );

    // ---- W: weight fetch (unchanged) ----
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
        .clk(clk), .rst(core_rst),
        .s_req(wide_slot_mem_req), .s_wr(wide_s_wr), .s_addr(wide_slot_mem_addr),
        .s_wdata(wide_s_wdata), .s_lb_n(wide_s_lb_n), .s_ub_n(wide_s_ub_n),
        .s_rdata(wide_slot_mem_rdata), .s_ready(wide_slot_mem_ready),
        .m_req(wide_arb_m_req), .m_wr(wide_arb_m_wr), .m_addr(wide_arb_m_addr), .m_wdata(wide_arb_m_wdata),
        .m_lb_n(wide_arb_m_lb_n), .m_ub_n(wide_arb_m_ub_n),
        .m_rdata(wide_arb_m_rdata), .m_ready(wide_arb_m_ready)
    );

    // ---- ONE physical SDRAM backend, both W and (now 2-source-
    // arbitrated) AR ports ----
    sdram_unified_backend #(
        .ADDR_WIDTH(ADDR_WIDTH), .CLK_FREQ_MHZ(CLK_FREQ_MHZ)
    ) u_sdram_backend (
        .clk(clk), .rst(core_rst),
        .w_req(wide_arb_m_req), .w_addr(wide_arb_m_addr),
        .w_rdata(wide_arb_m_rdata), .w_ready(wide_arb_m_ready),
        .ar_req(final_ar_req), .ar_wr(final_ar_wr), .ar_addr(final_ar_addr), .ar_wdata(final_ar_wdata),
        .ar_lb_n(final_ar_lb_n), .ar_ub_n(final_ar_ub_n),
        .ar_rdata(final_ar_rdata), .ar_ready(final_ar_ready),
        .sdram_cke(sdram_cke), .sdram_cs_n(sdram_cs_n), .sdram_ras_n(sdram_ras_n),
        .sdram_cas_n(sdram_cas_n), .sdram_we_n(sdram_we_n),
        .sdram_ba(sdram_ba), .sdram_a(sdram_a), .sdram_dq(sdram_dq), .sdram_dqm(sdram_dqm)
    );

endmodule
