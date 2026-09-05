`timescale 1ns/1ps

// ================================================================
// FPGA-Neural V2 -- Activation Buffer (M3, docs/v2-description.md §14)
//
// Holds the "Input Buffer" of the §12 data-plane diagram: one INT8
// activation slot per signal id, read by the Neural Processor Array
// (via the Memory Manager, M4) and written by producers (external
// input load, or a Neural Processor's own result forwarded here for
// a downstream consumer).
//
// Same proven BRAM-inference idiom as hardware/v1/rtl/act_buffer.v
// (frozen, unmodified reference): dual-port, byte-addressed, Port A
// synchronous write, Port B synchronous REGISTERED read (1-cycle
// latency, no `rst` on the read register -- a synchronous reset on an
// indexed array forces Yosys onto LUT-RAM instead of a Lattice
// DP16KD block RAM). DEPTH is fully parametric (§14: "la profondita'
// deve essere parametrica").
// ================================================================

module activation_buffer #(
    parameter DEPTH       = 4096,
    parameter DATA_WIDTH  = 8,
    localparam ADDR_WIDTH = $clog2(DEPTH)
)(
    input wire clk,

    input wire                          wr_en,
    input wire [ADDR_WIDTH-1:0]         wr_addr,
    input wire signed [DATA_WIDTH-1:0]  wr_data,

    input  wire [ADDR_WIDTH-1:0]        rd_addr,
    output reg  signed [DATA_WIDTH-1:0] rd_data
);

    reg signed [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    always @(posedge clk) begin
        if (wr_en)
            mem[wr_addr] <= wr_data;
    end

    always @(posedge clk) begin
        rd_data <= mem[rd_addr];
    end

endmodule
