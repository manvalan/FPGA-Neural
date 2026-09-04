`timescale 1ns/1ps

// ================================================================
// SPI_NEURON_TOP
//
// Full Phase 3 + Phase 4 integration: SPI host interface (spi_slave
// + spi_engine, docs §8.1) driving neuron_memory.v (Phase 3,
// N_NEURONS>=1) through a shared PSRAM (memory_interface +
// psram_controller), arbitrated between spi_engine's own RAM access
// (WRITE_RAM/READ_RAM opcodes) and neuron_memory's own X/W/bias
// reads during a run.
//
// neuron_memory's own `rst` is the global reset OR'd with the
// RESET opcode's soft-reset pulse from spi_engine, so a host can
// recover the compute engine over SPI without a physical reset
// (RAM contents are untouched either way).
// ================================================================

module spi_neuron_top #(
    parameter ADDR_WIDTH     = 23,
    parameter DATA_WIDTH     = 8,
    parameter N_INPUTS       = 32,
    parameter N_NEURONS      = 1,
    parameter PARALLEL       = 8,
    parameter ACC_WIDTH      = 32,
    parameter MEM_DATA_WIDTH = 16,
    parameter CLK_FREQ_MHZ   = 80,
    parameter N_LAYERS       = 4,   // Phase 5: RUN_NETWORK, requires N_INPUTS==N_NEURONS
    parameter GRAPH_MAX_CONN = 32,  // Phase G5: graph_engine's build-time max connections/neuron
    parameter GRAPH_N_TOTAL  = 4096 // Phase G5: graph_engine's activation buffer depth
)(
    input wire clk,
    input wire rst,

    // ------------------------------------------------------------
    // SPI host interface
    // ------------------------------------------------------------

    input  wire sclk,
    input  wire mosi,
    output wire miso,
    input  wire cs_n,

    // ------------------------------------------------------------
    // Host attention pins, active-LOW (open-drain-style naming, but
    // driven push-pull here -- no other master shares these lines).
    //
    //   irq_n         -- low while graph_engine's `err` is set (the
    //                     §7 load-time guard tripped; STATUS.bit2).
    //                     Stays low until RESET or a fresh graph
    //                     run_start clears it, exactly like the
    //                     STATUS bit it mirrors.
    //   data_ready_n  -- low while a run's result is waiting to be
    //                     read (STATUS.bit1, done/sticky). Goes back
    //                     high the moment the host reads STATUS (or
    //                     on RESET) -- same flip-flop as the SPI
    //                     status byte, just also wired to a pin so
    //                     the host does not have to poll SPI to find
    //                     out a result is ready.
    //
    // Both are level signals from already-registered sticky bits
    // (spi_engine.v's status_done_sticky, graph_engine.v's err), so
    // driving them straight onto a pin (just an inversion) needs no
    // extra pipeline stage / debounce.
    // ------------------------------------------------------------

    output wire irq_n,
    output wire data_ready_n,

    // ------------------------------------------------------------
    // Flash physical interface (Phase F5) -- separate pins from the
    // host SPI above, per docs/FPGA-Neural-Hardware-Design.md's own
    // §6 lesson ("must land on separate, ordinary I/O pins -- never
    // the config-SPI pins"): this is the APPLICATION-side master
    // toward the boot/persistence flash (rtl/spi_flash_master.v,
    // owned internally by flash_slot_manager), a completely
    // different physical bus from the host-facing sclk/mosi/miso/
    // cs_n above. No sclk pin here in real synthesis -- CCLK-
    // equivalent timing is generated internally via USRMCLK (see
    // rtl/spi_flash_master.v's header for the full ECP5 rationale);
    // `flash_sclk_sim` only exists under SIMULATION, to feed
    // sim/flash_model.v in testbenches.
    // ------------------------------------------------------------

    output wire flash_mosi,
    input  wire flash_miso,
    output wire flash_cs_n,
`ifdef SIMULATION
    output wire flash_sclk_sim,
`endif

    // ------------------------------------------------------------
    // PSRAM physical interface
    // ------------------------------------------------------------

    output wire [ADDR_WIDTH-1:0]     psram_a,
    inout  wire [MEM_DATA_WIDTH-1:0] psram_dq,
    output wire                      psram_ce_n,
    output wire                      psram_oe_n,
    output wire                      psram_we_n,
    output wire                      psram_lb_n,
    output wire                      psram_ub_n,
    output wire                      psram_zz_n
);

    // ============================================================
    // SPI PHYSICAL LAYER
    // ============================================================

    wire [7:0] rx_byte;
    wire       rx_valid;
    wire       cs_start;
    wire       cs_end;
    wire [7:0] tx_byte;
    wire       tx_byte_req;

    spi_slave u_spi_slave (
        .clk(clk), .rst(rst),

        .sclk(sclk), .mosi(mosi), .miso(miso), .cs_n(cs_n),

        .rx_byte(rx_byte), .rx_valid(rx_valid),
        .tx_byte(tx_byte), .tx_byte_req(tx_byte_req),

        .cs_active(), .cs_start(cs_start), .cs_end(cs_end)
    );

    // ============================================================
    // SPI PROTOCOL ENGINE
    // ============================================================

    wire                   spi_ram_req;
    wire                   spi_ram_wr;
    wire [ADDR_WIDTH-1:0]  spi_ram_addr;
    wire signed [7:0]      spi_ram_wdata;
    wire signed [7:0]      spi_ram_rdata;
    wire                   spi_ram_ready;

    wire [ADDR_WIDTH-1:0] x_base;
    wire [ADDR_WIDTH-1:0] w_base;
    wire [ADDR_WIDTH-1:0] bias_addr;
    wire [1:0]            activation;
    wire [15:0]           n_inputs_real;
    wire [15:0]           n_neurons_real;

    wire nm_start;
    wire nm_busy;
    wire nm_done;

    wire signed [DATA_WIDTH*N_NEURONS-1:0] y_bus;

    wire nm_soft_rst;

    // Phase 5: layer_sequencer control/status, driven by spi_engine's
    // RUN_NETWORK opcode.
    wire [ADDR_WIDTH-1:0] table_base;
    wire [ADDR_WIDTH-1:0] buf_a_base;
    wire [ADDR_WIDTH-1:0] buf_b_base;
    wire                  run_start;
    wire [7:0]             run_num_layers;
    wire                   seq_busy;
    wire                   seq_done;

    // Phase G5: net_type dispatch + graph_engine control/status.
    wire [7:0]  net_type;
    wire [15:0] num_neurons_graph;
    wire [15:0] n_out;
    wire        graph_busy;
    wire        graph_done;
    wire        graph_err;
    wire        data_ready;

    // Phase F5: flash_slot_manager command interface, driven by
    // spi_engine's flash-subsystem opcodes.
    wire         flash_op_start;
    wire [2:0]   flash_op_code;
    wire [3:0]   flash_slot_id;
    wire [23:0]  flash_new_offset;
    wire [23:0]  flash_new_length;
    wire [7:0]   flash_new_type;
    wire [ADDR_WIDTH-1:0] flash_ext_psram_addr;
    wire [23:0]  flash_ext_length;
    wire [23:0]  flash_raw_flash_addr;
    wire         flash_busy;
    wire         flash_done;
    wire         flash_err;
    wire [3:0]   flash_cat_read_sel;
    wire [23:0]  flash_cat_out_offset;
    wire [23:0]  flash_cat_out_length;
    wire [7:0]   flash_cat_out_type;
    wire         flash_cat_out_valid;
    wire [31:0]  flash_cat_out_crc;

    spi_engine #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .N_INPUTS(N_INPUTS),
        .N_NEURONS(N_NEURONS),
        .PARALLEL(PARALLEL),
        .N_TOTAL(GRAPH_N_TOTAL)
    ) u_spi_engine (
        .clk(clk), .rst(rst),

        .rx_byte(rx_byte), .rx_valid(rx_valid),
        .cs_start(cs_start), .cs_end(cs_end),
        .tx_byte(tx_byte), .tx_byte_req(tx_byte_req),

        .ram_req(spi_ram_req), .ram_wr(spi_ram_wr),
        .ram_addr(spi_ram_addr), .ram_wdata(spi_ram_wdata),
        .ram_rdata(spi_ram_rdata), .ram_ready(spi_ram_ready),

        .x_base(x_base), .w_base(w_base), .bias_addr(bias_addr),
        .activation(activation),
        .n_inputs_real(n_inputs_real), .n_neurons_real(n_neurons_real),

        .nm_start(nm_start), .nm_busy(nm_busy), .nm_done(nm_done),
        .y_bus(y_bus),

        .nm_soft_rst(nm_soft_rst),

        .table_base(table_base), .buf_a_base(buf_a_base), .buf_b_base(buf_b_base),
        .run_start(run_start), .run_num_layers(run_num_layers),
        .seq_busy(seq_busy), .seq_done(seq_done),

        .net_type(net_type),
        .num_neurons_graph(num_neurons_graph), .n_out(n_out),
        .graph_busy(graph_busy), .graph_done(graph_done), .graph_err(graph_err),

        .flash_op_start(flash_op_start), .flash_op_code(flash_op_code),
        .flash_slot_id(flash_slot_id),
        .flash_new_offset(flash_new_offset), .flash_new_length(flash_new_length),
        .flash_new_type(flash_new_type),
        .flash_ext_psram_addr(flash_ext_psram_addr), .flash_ext_length(flash_ext_length),
        .flash_raw_flash_addr(flash_raw_flash_addr),
        .flash_busy(flash_busy), .flash_done(flash_done), .flash_err(flash_err),
        .flash_cat_read_sel(flash_cat_read_sel),
        .flash_cat_out_offset(flash_cat_out_offset), .flash_cat_out_length(flash_cat_out_length),
        .flash_cat_out_type(flash_cat_out_type), .flash_cat_out_valid(flash_cat_out_valid),
        .flash_cat_out_crc(flash_cat_out_crc),

        .data_ready(data_ready)
    );

    // ============================================================
    // FLASH_SLOT_MANAGER (Phase F5): owns the flash-facing SPI
    // master (rtl/spi_flash_master.v) internally through
    // rtl/flash_copy_engine.v; PSRAM access goes through
    // mem_arbiter's Port D below.
    // ============================================================

    wire                   flash_d_req;
    wire                   flash_d_wr;
    wire [ADDR_WIDTH-1:0]  flash_d_addr;
    wire signed [7:0]      flash_d_wdata;
    wire signed [7:0]      flash_d_rdata;
    wire                   flash_d_ready;

    flash_slot_manager #(
        .PSRAM_ADDR_WIDTH(ADDR_WIDTH),
        .CLK_FREQ_MHZ(CLK_FREQ_MHZ)
    ) u_flash_slot_manager (
        .clk(clk), .rst(rst),

        .mosi(flash_mosi), .miso(flash_miso), .cs_n(flash_cs_n),
`ifdef SIMULATION
        .sclk_sim(flash_sclk_sim),
`endif

        .op_start(flash_op_start), .op_code(flash_op_code), .slot_id(flash_slot_id),
        .new_offset(flash_new_offset), .new_length(flash_new_length), .new_type(flash_new_type),
        .ext_psram_addr(flash_ext_psram_addr), .ext_length(flash_ext_length),
        .raw_flash_addr(flash_raw_flash_addr),
        .busy(flash_busy), .done(flash_done), .err(flash_err),

        .cat_read_sel(flash_cat_read_sel),
        .cat_out_offset(flash_cat_out_offset), .cat_out_length(flash_cat_out_length),
        .cat_out_type(flash_cat_out_type), .cat_out_valid(flash_cat_out_valid),
        .cat_out_crc(flash_cat_out_crc),

        .d_req(flash_d_req), .d_wr(flash_d_wr), .d_addr(flash_d_addr), .d_wdata(flash_d_wdata),
        .d_rdata(flash_d_rdata), .d_ready(flash_d_ready)
    );

    // Physical attention pins: active-low, driven straight from the
    // already-registered sticky bits (see the port declarations
    // above for the full rationale).
    assign data_ready_n = ~data_ready;
    assign irq_n         = ~graph_err;

    // ============================================================
    // LAYER SEQUENCER (Phase 5: RUN_NETWORK)
    //
    // Requires N_INPUTS == N_NEURONS (both equal N_WIDTH below) --
    // see rtl/layer_sequencer.v header for why. neuron_memory is
    // shared with the legacy single-layer path: the two mux_nm_*
    // wires below select which master drives it, based on seq_busy.
    // ============================================================

    wire [ADDR_WIDTH-1:0] seq_nm_x_base;
    wire [ADDR_WIDTH-1:0] seq_nm_w_base;
    wire [ADDR_WIDTH-1:0] seq_nm_bias_addr;
    wire [1:0]            seq_nm_activation;
    wire [15:0]           seq_nm_n_inputs;
    wire [15:0]           seq_nm_n_neurons;
    wire                  seq_nm_start;

    wire                   seq_ram_req;
    wire                   seq_ram_wr;
    wire [ADDR_WIDTH-1:0]  seq_ram_addr;
    wire signed [7:0]      seq_ram_wdata;
    wire signed [7:0]      seq_ram_rdata;
    wire                   seq_ram_ready;

    // Phase G5: net_type dispatch. RUN_NETWORK pulses spi_engine's
    // single `run_start` output; route it to whichever engine
    // net_type selects (the two are mutually exclusive by
    // construction -- spi_engine only accepts a new RUN_NETWORK
    // while !busy_all, so at most one of layer_sequencer/graph_engine
    // is ever mid-run).
    localparam NET_TYPE_GRAPH = 8'h02;

    wire seq_run_start   = (net_type == NET_TYPE_GRAPH) ? 1'b0 : run_start;
    wire graph_run_start = (net_type == NET_TYPE_GRAPH) ? run_start : 1'b0;

    layer_sequencer #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .N_WIDTH(N_NEURONS),
        .N_LAYERS(N_LAYERS)
    ) u_layer_sequencer (
        .clk(clk), .rst(rst),

        .run_start(seq_run_start), .run_num_layers(run_num_layers),
        .seq_busy(seq_busy), .seq_done(seq_done),

        .x_base(x_base), .table_base(table_base),
        .buf_a_base(buf_a_base), .buf_b_base(buf_b_base),

        .nm_x_base(seq_nm_x_base), .nm_w_base(seq_nm_w_base),
        .nm_bias_addr(seq_nm_bias_addr), .nm_activation(seq_nm_activation),
        .nm_n_inputs(seq_nm_n_inputs), .nm_n_neurons(seq_nm_n_neurons),
        .nm_start(seq_nm_start),

        .nm_busy(nm_busy), .nm_done(nm_done),
        .y_bus(y_bus),

        .ram_req(seq_ram_req), .ram_wr(seq_ram_wr),
        .ram_addr(seq_ram_addr), .ram_wdata(seq_ram_wdata),
        .ram_rdata(seq_ram_rdata), .ram_ready(seq_ram_ready)
    );

    // ============================================================
    // GRAPH ENGINE (Phase G5: RUN_NETWORK, net_type == graph)
    //
    // Owns its own private act_buffer and neuron_parallel instance
    // (see rtl/graph_engine.v); shares layer_sequencer's arbiter
    // port C below since the two never run concurrently. Register
    // reuse (x_base/table_base/buf_a_base-as-out_base/n_inputs_real-
    // as-N_in) documented in graph_engine.v's own header.
    // ============================================================

    wire                   graph_ram_req;
    wire                   graph_ram_wr;
    wire [ADDR_WIDTH-1:0]  graph_ram_addr;
    wire signed [7:0]      graph_ram_wdata;
    wire signed [7:0]      graph_ram_rdata;
    wire                   graph_ram_ready;

    // rst is the global reset OR'd with the SPI RESET opcode pulse,
    // same convention as neuron_memory's nm_rst -- a host can clear
    // a stuck `err` without a physical reset.
    wire graph_rst = rst | nm_soft_rst;

    graph_engine #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .ACC_WIDTH(ACC_WIDTH),
        .PARALLEL(PARALLEL),
        .MAX_CONN(GRAPH_MAX_CONN),
        .N_TOTAL(GRAPH_N_TOTAL)
    ) u_graph_engine (
        .clk(clk), .rst(graph_rst),

        .run_start(graph_run_start), .busy(graph_busy), .done(graph_done), .err(graph_err),

        .x_base(x_base), .table_base(table_base), .out_base(buf_a_base),
        .n_inputs_graph(n_inputs_real),
        .num_neurons_graph(num_neurons_graph), .n_out(n_out),

        .ram_req(graph_ram_req), .ram_wr(graph_ram_wr),
        .ram_addr(graph_ram_addr), .ram_wdata(graph_ram_wdata),
        .ram_rdata(graph_ram_rdata), .ram_ready(graph_ram_ready)
    );

    // Arbiter port C mux: static on net_type (not on busy) -- the two
    // engines are mutually exclusive by construction (see above), so
    // whichever one net_type currently selects is the only one ever
    // driving a real request through this port.
    wire                   portc_req   = (net_type == NET_TYPE_GRAPH) ? graph_ram_req   : seq_ram_req;
    wire                   portc_wr    = (net_type == NET_TYPE_GRAPH) ? graph_ram_wr    : seq_ram_wr;
    wire [ADDR_WIDTH-1:0]  portc_addr  = (net_type == NET_TYPE_GRAPH) ? graph_ram_addr  : seq_ram_addr;
    wire signed [7:0]      portc_wdata = (net_type == NET_TYPE_GRAPH) ? graph_ram_wdata : seq_ram_wdata;
    wire signed [7:0]      portc_rdata_bus;
    wire                   portc_ready_bus;

    assign seq_ram_rdata   = portc_rdata_bus;
    assign seq_ram_ready   = portc_ready_bus;
    assign graph_ram_rdata = portc_rdata_bus;
    assign graph_ram_ready = portc_ready_bus;

    // neuron_memory master mux: the sequencer owns it for the whole
    // duration of a RUN_NETWORK job (seq_busy), otherwise spi_engine
    // drives it directly (legacy single-layer SET_BASE/START path).
    wire [ADDR_WIDTH-1:0] mux_nm_x_base    = seq_busy ? seq_nm_x_base    : x_base;
    wire [ADDR_WIDTH-1:0] mux_nm_w_base    = seq_busy ? seq_nm_w_base    : w_base;
    wire [ADDR_WIDTH-1:0] mux_nm_bias_addr = seq_busy ? seq_nm_bias_addr : bias_addr;
    wire [1:0]            mux_nm_activation = seq_busy ? seq_nm_activation : activation;
    wire [15:0]           mux_nm_n_inputs   = seq_busy ? seq_nm_n_inputs   : n_inputs_real;
    wire [15:0]           mux_nm_n_neurons  = seq_busy ? seq_nm_n_neurons  : n_neurons_real;
    wire                  mux_nm_start     = seq_busy ? seq_nm_start    : nm_start;

    // ============================================================
    // NEURON MEMORY
    //
    // rst is the global reset OR'd with the SPI RESET opcode pulse.
    // ============================================================

    wire nm_rst = rst | nm_soft_rst;

    wire                   nm_ram_req;
    wire                   nm_ram_wr;
    wire [ADDR_WIDTH-1:0]  nm_ram_addr;
    wire signed [7:0]      nm_ram_wdata;
    wire signed [7:0]      nm_ram_rdata;
    wire                   nm_ram_ready;

    neuron_memory #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .N_INPUTS(N_INPUTS),
        .N_NEURONS(N_NEURONS),
        .PARALLEL(PARALLEL),
        .ACC_WIDTH(ACC_WIDTH)
    ) u_neuron_memory (
        .clk(clk), .rst(nm_rst),
        .start(mux_nm_start),

        .mem_req(nm_ram_req), .mem_wr(nm_ram_wr),
        .mem_addr(nm_ram_addr), .mem_wdata(nm_ram_wdata),
        .mem_rdata(nm_ram_rdata), .mem_ready(nm_ram_ready),

        .x_base(mux_nm_x_base), .w_base(mux_nm_w_base), .bias_addr(mux_nm_bias_addr),
        .activation(mux_nm_activation),
        .n_inputs_real(mux_nm_n_inputs), .n_neurons_real(mux_nm_n_neurons),

        .y_bus(y_bus), .busy(nm_busy), .done(nm_done)
    );

    // ============================================================
    // SHARED MEMORY ARBITER
    // ============================================================

    wire                   arb_req;
    wire                   arb_wr;
    wire [ADDR_WIDTH-1:0]  arb_addr;
    wire signed [7:0]      arb_wdata;
    wire signed [7:0]      arb_rdata;
    wire                   arb_ready;

    mem_arbiter #(
        .ADDR_WIDTH(ADDR_WIDTH)
    ) u_arbiter (
        .clk(clk), .rst(rst),

        .a_req(spi_ram_req), .a_wr(spi_ram_wr),
        .a_addr(spi_ram_addr), .a_wdata(spi_ram_wdata),
        .a_rdata(spi_ram_rdata), .a_ready(spi_ram_ready),

        .b_req(nm_ram_req), .b_wr(nm_ram_wr),
        .b_addr(nm_ram_addr), .b_wdata(nm_ram_wdata),
        .b_rdata(nm_ram_rdata), .b_ready(nm_ram_ready),

        .c_req(portc_req), .c_wr(portc_wr),
        .c_addr(portc_addr), .c_wdata(portc_wdata),
        .c_rdata(portc_rdata_bus), .c_ready(portc_ready_bus),

        // Port D: flash_slot_manager (Phase F5), lowest priority --
        // see mem_arbiter.v's own header for the full rationale.
        .d_req(flash_d_req), .d_wr(flash_d_wr),
        .d_addr(flash_d_addr), .d_wdata(flash_d_wdata),
        .d_rdata(flash_d_rdata), .d_ready(flash_d_ready),

        .m_req(arb_req), .m_wr(arb_wr),
        .m_addr(arb_addr), .m_wdata(arb_wdata),
        .m_rdata(arb_rdata), .m_ready(arb_ready)
    );

    // ============================================================
    // BYTE <-> WORD BRIDGE (shared, single instance)
    // ============================================================

    wire                    i8_mem_req;
    wire                    i8_mem_wr;
    wire [ADDR_WIDTH-1:0]   i8_mem_addr;
    wire [MEM_DATA_WIDTH-1:0] i8_mem_wdata;
    wire                    i8_mem_lb_n;
    wire                    i8_mem_ub_n;

    wire [MEM_DATA_WIDTH-1:0] i8_mem_rdata;
    wire                       i8_mem_ready;

    int8_memory_access #(
        .ADDR_WIDTH(ADDR_WIDTH)
    ) u_int8_access (
        .clk(clk), .rst(rst),

        .req(arb_req), .wr(arb_wr), .addr(arb_addr), .wdata(arb_wdata),
        .rdata(arb_rdata), .ready(arb_ready),

        .mem_req(i8_mem_req), .mem_wr(i8_mem_wr),
        .mem_addr(i8_mem_addr), .mem_wdata(i8_mem_wdata),
        .mem_lb_n(i8_mem_lb_n), .mem_ub_n(i8_mem_ub_n),

        .mem_rdata(i8_mem_rdata), .mem_ready(i8_mem_ready)
    );

    // ============================================================
    // MEMORY INTERFACE / PSRAM CONTROLLER
    // ============================================================

    wire [MEM_DATA_WIDTH-1:0] psram_mem_rdata;
    wire                      psram_mem_ready;

    wire                       psram_mem_req;
    wire                       psram_mem_wr;
    wire [ADDR_WIDTH-1:0]      psram_mem_addr;
    wire [MEM_DATA_WIDTH-1:0]  psram_mem_wdata;
    wire                       psram_mem_lb_n;
    wire                       psram_mem_ub_n;

    memory_interface #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(MEM_DATA_WIDTH)
    ) u_memory_if (
        .clk(clk), .rst(rst),

        .req(i8_mem_req), .wr(i8_mem_wr), .addr(i8_mem_addr), .wdata(i8_mem_wdata),
        .lb_n(i8_mem_lb_n), .ub_n(i8_mem_ub_n),

        .rdata(i8_mem_rdata), .ready(i8_mem_ready),

        .mem_req(psram_mem_req), .mem_wr(psram_mem_wr),
        .mem_addr(psram_mem_addr), .mem_wdata(psram_mem_wdata),
        .mem_lb_n(psram_mem_lb_n), .mem_ub_n(psram_mem_ub_n),

        .mem_rdata(psram_mem_rdata), .mem_ready(psram_mem_ready)
    );

    psram_controller #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(MEM_DATA_WIDTH),
        .CLK_FREQ_MHZ(CLK_FREQ_MHZ)
    ) u_psram_ctrl (
        .clk(clk), .rst(rst),

        .mem_req(psram_mem_req), .mem_wr(psram_mem_wr),
        .mem_addr(psram_mem_addr), .mem_wdata(psram_mem_wdata),
        .mem_lb_n(psram_mem_lb_n), .mem_ub_n(psram_mem_ub_n),

        .mem_rdata(psram_mem_rdata), .mem_ready(psram_mem_ready),

        .psram_a(psram_a), .psram_dq(psram_dq),
        .psram_ce_n(psram_ce_n), .psram_oe_n(psram_oe_n), .psram_we_n(psram_we_n),
        .psram_lb_n(psram_lb_n), .psram_ub_n(psram_ub_n), .psram_zz_n(psram_zz_n)
    );

endmodule
