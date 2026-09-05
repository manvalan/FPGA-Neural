`timescale 1ns/1ps

// ================================================================
// FPGA-Neural V2 -- Result Buffer (M3, docs/v2-description.md §14)
//
// Holds the "Result Buffer" of the §12 data-plane diagram: one INT8
// slot per node id, written by a Neural Processor's result_data (at
// its result_node_id address) once its job's tile_last has drained
// through the pipeline (M1), and read by whichever consumer needs it
// next -- a downstream layer's Weight/Activation Buffer producer, the
// Dependency Manager (M6, dependency resolution), or the host
// (READ_RAM-equivalent path, M4/M8).
//
// Same BRAM-inference idiom as activation_buffer.v (dual-port, Port A
// sync write, Port B sync REGISTERED read, no reset on the read
// register). DEPTH is fully parametric. Deliberately NOT tracking
// "has this id been written yet" here -- that bookkeeping belongs to
// the Dependency Manager (M6), not this buffer.
// ================================================================

module result_buffer #(
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
