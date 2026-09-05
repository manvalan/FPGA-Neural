`timescale 1ns/1ps

// ================================================================
// ACT_BUFFER (Phase G1 -- Graph engine, Type #2 network)
//
// Global activation buffer for the sparse-graph datapath: one INT8
// slot per signal id, id 0..N_in-1 are the network's external
// inputs, every other id is the output of exactly one neuron (its
// out_id). graph_engine's gather stage reads this buffer by src_id;
// each neuron's result is written back here at its own out_id.
//
// Dual-port, byte-addressed:
//   Port A - synchronous write (neuron output / input copy-in).
//   Port B - synchronous READ, REGISTERED: rd_data reflects rd_addr
//            from the PREVIOUS clock edge, not the current one (one
//            cycle of latency). Callers must account for this --
//            see graph_engine.v's gather stage.
//
// This is the plain always-block-per-port inference idiom Yosys'
// ECP5 memory_bram pass maps onto a Lattice DP16KD block RAM (single
// clock, independent read/write address, synchronous read with no
// output reset): no `rst` port is provided on purpose, matching what
// a real DP16KD offers and keeping this off the LUT-RAM path that a
// register-array-with-reset idiom would force it down.
//
// N_TOTAL is the V1 ceiling on distinct signal ids (§2 of the spec:
// 4096, 16-bit id space would allow up to 65536 without a format
// change). ADDR_WIDTH is derived, not passed in, so every caller
// stays consistent with N_TOTAL automatically.
// ================================================================

module act_buffer #(
    parameter N_TOTAL    = 4096,
    parameter DATA_WIDTH = 8,
    localparam ADDR_WIDTH = $clog2(N_TOTAL)
)(
    input wire clk,

    // ------------------------------------------------------------
    // Port A: write
    // ------------------------------------------------------------
    input wire                          wr_en,
    input wire [ADDR_WIDTH-1:0]         wr_addr,
    input wire signed [DATA_WIDTH-1:0]  wr_data,

    // ------------------------------------------------------------
    // Port B: read (registered, 1-cycle latency)
    // ------------------------------------------------------------
    input  wire [ADDR_WIDTH-1:0]        rd_addr,
    output reg  signed [DATA_WIDTH-1:0] rd_data
);

    reg signed [DATA_WIDTH-1:0] mem [0:N_TOTAL-1];

    always @(posedge clk) begin
        if (wr_en)
            mem[wr_addr] <= wr_data;
    end

    always @(posedge clk) begin
        rd_data <= mem[rd_addr];
    end

endmodule
