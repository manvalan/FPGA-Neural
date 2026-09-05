`timescale 1ns/1ps

// ================================================================
// FPGA-Neural V2 -- Weight Buffer (M3, docs/v2-description.md §14)
//
// Holds the "Weight Buffer" of the §12 data-plane diagram. Unlike
// activation_buffer (one INT8 per signal id), each address here holds
// one WHOLE TILE of P_IN weights -- exactly the width a Neural
// Processor (M1) consumes per cycle on its weight_data port, so the
// Memory Manager (M4) can feed a processor one tile/cycle without any
// additional muxing/serialization at this buffer's boundary (§7:
// avoid big dynamic muxes).
//
// Same BRAM-inference idiom as activation_buffer.v /
// hardware/v1/rtl/act_buffer.v (dual-port, Port A sync write, Port B
// sync REGISTERED read, no reset on the read register). DEPTH (in
// TILES, not individual weights) is fully parametric.
// ================================================================

module weight_buffer #(
    parameter DEPTH       = 512,  // depth in TILES (each DEPTH*P_IN*DATA_WIDTH/8 bytes)
    parameter DATA_WIDTH  = 8,
    parameter P_IN        = 8,
    localparam ADDR_WIDTH = $clog2(DEPTH),
    localparam TILE_WIDTH = DATA_WIDTH * P_IN
)(
    input wire clk,

    input wire                                 wr_en,
    input wire [ADDR_WIDTH-1:0]                wr_addr,
    input wire signed [TILE_WIDTH-1:0]         wr_data,

    input  wire [ADDR_WIDTH-1:0]               rd_addr,
    output reg  signed [TILE_WIDTH-1:0]        rd_data
);

    reg signed [TILE_WIDTH-1:0] mem [0:DEPTH-1];

    always @(posedge clk) begin
        if (wr_en)
            mem[wr_addr] <= wr_data;
    end

    always @(posedge clk) begin
        rd_data <= mem[rd_addr];
    end

endmodule
