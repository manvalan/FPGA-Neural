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
    parameter N_LAYERS       = 4    // Phase 5: RUN_NETWORK, requires N_INPUTS==N_NEURONS
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

    spi_engine #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .N_INPUTS(N_INPUTS),
        .N_NEURONS(N_NEURONS),
        .PARALLEL(PARALLEL)
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
        .seq_busy(seq_busy), .seq_done(seq_done)
    );

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

    layer_sequencer #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .N_WIDTH(N_NEURONS),
        .N_LAYERS(N_LAYERS)
    ) u_layer_sequencer (
        .clk(clk), .rst(rst),

        .run_start(run_start), .run_num_layers(run_num_layers),
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

        .c_req(seq_ram_req), .c_wr(seq_ram_wr),
        .c_addr(seq_ram_addr), .c_wdata(seq_ram_wdata),
        .c_rdata(seq_ram_rdata), .c_ready(seq_ram_ready),

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
