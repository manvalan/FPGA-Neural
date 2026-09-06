`timescale 1ns/1ps

// ============================================================
// NMS STEP16 Phase 5 -- SDRAM weight-fetch backend. Wraps the real,
// isolated-and-validated sdram_controller.v (Phase 1-4, EXP-0040/0041,
// ERR-0016..0019) with BURST_LEN=4 (P_IN*DATA_WIDTH/16 = 4 words/tile,
// the exact natural match identified in Phase 1) and presents the
// same mem_req/mem_wr/mem_addr/mem_wdata/mem_rdata/mem_ready
// convention as psram_controller_dual32.v, so it drops into
// nms_neural_multiprocessor_sdram.v's wide weight-fetch port exactly
// where psram_controller_dual32.v sits in the dual32 baseline --
// same external contract, different physical memory underneath, for
// a direct, apples-to-apples STEP16 comparison.
//
// Address conversion: `mem_addr` is a BYTE address (this project's
// own established convention, matching weight_prefetch_engine_wide.v
// and psram_controller_dual32.v's own external contract). The real
// AS4C4M16SA-6TIN is x16 (2 bytes/word), so the SDRAM controller's
// own word address is `mem_addr >> 1` -- exactly analogous to
// STEP15's own real ">>2" byte-to-32-bit-word fix (EXP-0037 bug #1),
// here ">>1" for a 16-bit-word device.
//
// Weight fetch never writes (same convention as psram_controller_
// dual32.v's own top-level instantiation, which ties mem_wr=0):
// `mem_wr` is exposed here for interface symmetry but the underlying
// sdram_controller is only ever driven with wr=0 by this wrapper's
// own real usage in nms_neural_multiprocessor_sdram.v.
// ============================================================
module sdram_weight_backend #(
    parameter ADDR_WIDTH   = 23,  // byte address width (project convention)
    parameter CLK_FREQ_MHZ = 80
)(
    input  wire clk,
    input  wire rst,

    input  wire                   mem_req,
    input  wire                   mem_wr,
    input  wire [ADDR_WIDTH-1:0]  mem_addr,
    input  wire [63:0]            mem_wdata,
    output wire [63:0]            mem_rdata,
    output wire                   mem_ready,

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

    wire busy;
    wire [21:0] sdram_word_addr = mem_addr[ADDR_WIDTH-1:1]; // byte -> 16-bit-word address

    sdram_controller #(
        .CLK_FREQ_MHZ(CLK_FREQ_MHZ), .BURST_LEN(4), .ADDR_WIDTH(22)
    ) u_sdram_ctrl (
        .clk(clk), .rst(rst),
        .req(mem_req), .wr(mem_wr), .addr(sdram_word_addr),
        .wdata(mem_wdata), .wmask(8'h00), .rdata(mem_rdata), .ready(mem_ready), .busy(busy),
        .sdram_cke(sdram_cke), .sdram_cs_n(sdram_cs_n), .sdram_ras_n(sdram_ras_n),
        .sdram_cas_n(sdram_cas_n), .sdram_we_n(sdram_we_n),
        .sdram_ba(sdram_ba), .sdram_a(sdram_a), .sdram_dq(sdram_dq), .sdram_dqm(sdram_dqm)
    );

endmodule
