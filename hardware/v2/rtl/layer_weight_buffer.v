`timescale 1ns/1ps

// ============================================================
// EXP-0057 -- double-buffered, per-layer resident weight scratchpad.
//
// One layer's worth of weights (up to LAYER_DEPTH entries of
// DATA_WIDTH bits, real BRAM-style array, same coding idiom as
// nms_weight_packed.v's own per-slot memories) stays resident and is
// read MANY times (once per output position that reuses it -- e.g.
// every spatial position a convolutional filter slides across),
// while the NEXT layer's weights are being fetched into the OTHER
// buffer in the background. Buffers swap only when BOTH conditions
// hold: the compute side has finished consuming the active buffer
// (consume_done) AND the fill side has finished loading the other one
// (fill_done) -- matches this project's own established discipline
// (never swap/overwrite data still in use, same spirit as
// sdram_unified_backend.v's own req_pending latch correctness fixes).
//
// This is deliberately NOT the same thing as the existing per-slot
// nms_weight_packed.v buffer: that one holds MAX_TILES tiles for ONE
// job with no reuse across neurons (D-Stress's own zero-reuse case).
// This module exists for the OPPOSITE traffic pattern -- one weight
// block read many times before being replaced -- which is what a
// convolutional filter (or any weight-stationary dataflow) needs.
// ============================================================
module layer_weight_buffer #(
    parameter DATA_WIDTH  = 8,
    parameter LAYER_DEPTH = 128,
    parameter ADDRW       = (LAYER_DEPTH <= 1) ? 1 : $clog2(LAYER_DEPTH)
)(
    input  wire clk,
    input  wire rst,

    // ---- fill side: writes into the INACTIVE buffer ----
    input  wire                  fill_we,
    input  wire [ADDRW-1:0]      fill_addr,
    input  wire [DATA_WIDTH-1:0] fill_data,
    input  wire                  fill_done,   // pulse: inactive buffer fully loaded

    // ---- compute side: reads from the ACTIVE buffer, any number of
    // times, any order (real conv access pattern is not necessarily
    // sequential -- e.g. im2col-style window reuse) ----
    input  wire [ADDRW-1:0]      rd_addr,
    output wire [DATA_WIDTH-1:0] rd_data,
    input  wire                  consume_done, // pulse: compute side is done with the active buffer

    // ---- swap: happens the cycle AFTER both fill_done and
    // consume_done have been seen since the last swap -- order-
    // independent (a pulse arriving before the other is latched, not
    // dropped), matching this project's own req_pending latch idiom ----
    output reg                   active_sel,   // which physical buffer (0/1) is active for reads
    output reg                   swapped       // pulses the cycle a swap occurs
);
    reg [DATA_WIDTH-1:0] mem0 [0:LAYER_DEPTH-1];
    reg [DATA_WIDTH-1:0] mem1 [0:LAYER_DEPTH-1];

    reg fill_done_latched, consume_done_latched;

    wire do_swap = fill_done_latched && consume_done_latched;

    always @(posedge clk) begin
        if (fill_we) begin
            if (active_sel == 1'b0) mem1[fill_addr] <= fill_data; // fill the INACTIVE one
            else                    mem0[fill_addr] <= fill_data;
        end
    end

    // read from the ACTIVE buffer, combinational (matches
    // nms_weight_packed.v's own same-cycle-bypass-free combinational
    // read convention for a single-port style array read)
    assign rd_data = active_sel ? mem1[rd_addr] : mem0[rd_addr];

    always @(posedge clk) begin
        if (rst) begin
            active_sel           <= 1'b0;
            swapped               <= 1'b0;
            fill_done_latched     <= 1'b0;
            consume_done_latched  <= 1'b0;
        end else begin
            swapped <= 1'b0;

            if (fill_done)    fill_done_latched    <= 1'b1;
            if (consume_done) consume_done_latched <= 1'b1;

            if (do_swap) begin
                active_sel            <= ~active_sel;
                swapped               <= 1'b1;
                fill_done_latched     <= 1'b0;
                consume_done_latched  <= 1'b0;
            end
        end
    end
endmodule
