`timescale 1ns/1ps

// ============================================================
// V3 -- synthesis top for the EXP-0062 verified weight-reuse memory
// path + packed compute core, flat structural wiring (real modules,
// real internal connections), for a real P&R resource/timing check.
//
// Control ports (pf_start/tile_req/operand_valid/...) are exposed
// directly at the top level rather than internally sequenced -- the
// closed-loop sequencing logic (what EXP-0062's testbench did
// procedurally) is the still-not-built neural_director.v integration,
// deliberately out of scope here. This module exists ONLY to let
// Vivado see the REAL combined logic (SDRAM controller + prefetch +
// weight buffer + tile gather + packed compute core) together for
// utilization/timing purposes, matching EXP-0059's own single-core
// out-of-context methodology.
// ============================================================
module np_packed_weight_reuse_top #(
    parameter DATA_WIDTH  = 8,
    parameter P_IN        = 8,
    parameter ACC_WIDTH   = 32,
    parameter BURST_LEN   = 8,
    parameter ROW_BITS    = 13,
    parameter COL_BITS    = 10,
    parameter BANK_BITS   = 2,
    parameter ADDR_WIDTH  = BANK_BITS + ROW_BITS + COL_BITS,
    parameter LAYER_BYTES = 128,
    parameter BUFADDRW    = $clog2(LAYER_BYTES)
)(
    input  wire clk,
    input  wire rst,

    // ---- layer_prefetch_ctrl.v control ----
    input  wire                   pf_start,
    input  wire [ADDR_WIDTH-1:0]  pf_layer_base,
    output wire                   pf_busy,
    output wire                   pf_done,

    // ---- layer_weight_buffer.v control ----
    input  wire                   consume_done,

    // ---- weight_tile_gather.v control ----
    input  wire                    tile_req,
    input  wire [BUFADDRW-1:0]     tile_base,
    output wire                    tile_valid,

    // ---- neural_processor_packed.v job/operand control ----
    input  wire                                job_valid,
    output wire                                job_ready,
    input  wire [15:0]                         job_node_id_a,
    input  wire [15:0]                         job_node_id_b,
    input  wire signed [DATA_WIDTH-1:0]        job_bias,
    input  wire [1:0]                          job_activation,
    input  wire                                operand_valid,
    output wire                                operand_ready,
    input  wire signed [DATA_WIDTH*P_IN-1:0]   input_data_a,
    input  wire signed [DATA_WIDTH*P_IN-1:0]   input_data_b,
    input  wire                                tile_last,
    output wire                                result_valid,
    input  wire                                result_ready,
    output wire signed [DATA_WIDTH-1:0]        result_data_a,
    output wire signed [DATA_WIDTH-1:0]        result_data_b,
    output wire [15:0]                         result_node_id_a,
    output wire [15:0]                         result_node_id_b,

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
    wire                     ctrl_req, ctrl_wr, ctrl_ready, ctrl_busy;
    wire [ADDR_WIDTH-1:0]    ctrl_addr;
    wire [16*BURST_LEN-1:0]  ctrl_wdata, ctrl_rdata;
    wire [2*BURST_LEN-1:0]   ctrl_wmask;

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

    wire                  pf_fill_we;
    wire [BUFADDRW-1:0]   pf_fill_addr;
    wire [DATA_WIDTH-1:0] pf_fill_data;

    layer_prefetch_ctrl #(
        .DATA_WIDTH(DATA_WIDTH), .LAYER_BYTES(LAYER_BYTES), .BURST_LEN(BURST_LEN), .ADDR_WIDTH(ADDR_WIDTH)
    ) u_pf (
        .clk(clk), .rst(rst),
        .start(pf_start), .layer_base(pf_layer_base), .busy(pf_busy), .done(pf_done),
        .fill_we(pf_fill_we), .fill_addr(pf_fill_addr), .fill_data(pf_fill_data),
        .ctrl_req(ctrl_req), .ctrl_wr(ctrl_wr), .ctrl_addr(ctrl_addr),
        .ctrl_wdata(ctrl_wdata), .ctrl_wmask(ctrl_wmask),
        .ctrl_rdata(ctrl_rdata), .ctrl_ready(ctrl_ready), .ctrl_busy(ctrl_busy)
    );

    wire [BUFADDRW-1:0]   lwb_rd_addr;
    wire [DATA_WIDTH-1:0] lwb_rd_data;

    layer_weight_buffer #(.DATA_WIDTH(DATA_WIDTH), .LAYER_DEPTH(LAYER_BYTES)) u_lwb (
        .clk(clk), .rst(rst),
        .fill_we(pf_fill_we), .fill_addr(pf_fill_addr), .fill_data(pf_fill_data), .fill_done(pf_done),
        .rd_addr(lwb_rd_addr), .rd_data(lwb_rd_data), .consume_done(consume_done),
        .active_sel(), .swapped()
    );

    wire [DATA_WIDTH*P_IN-1:0] tile_data;

    weight_tile_gather #(
        .DATA_WIDTH(DATA_WIDTH), .P_IN(P_IN), .BUFADDRW(BUFADDRW)
    ) u_gather (
        .clk(clk), .rst(rst),
        .tile_req(tile_req), .tile_base(tile_base),
        .tile_valid(tile_valid), .tile_data(tile_data),
        .rd_addr(lwb_rd_addr), .rd_data(lwb_rd_data)
    );

    wire [3:0] np_state;
    wire       np_error;

    neural_processor_packed #(
        .DATA_WIDTH(DATA_WIDTH), .P_IN(P_IN), .ACC_WIDTH(ACC_WIDTH)
    ) u_np (
        .clk(clk), .rst(rst),
        .job_valid(job_valid), .job_ready(job_ready),
        .job_node_id_a(job_node_id_a), .job_node_id_b(job_node_id_b),
        .job_bias(job_bias), .job_activation(job_activation),
        .operand_valid(operand_valid), .operand_ready(operand_ready),
        .input_data_a(input_data_a), .input_data_b(input_data_b),
        .weight_data(tile_data), .tile_last(tile_last),
        .result_valid(result_valid), .result_ready(result_ready),
        .result_data_a(result_data_a), .result_data_b(result_data_b),
        .result_node_id_a(result_node_id_a), .result_node_id_b(result_node_id_b),
        .np_state(np_state), .np_error(np_error)
    );
endmodule
