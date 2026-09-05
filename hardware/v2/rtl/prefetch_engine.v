`timescale 1ns/1ps

// ================================================================
// FPGA-Neural V2 -- Weight Prefetch Engine (M4, docs/v2-description.md
// §13; word-level burst rewrite post-M10 DEC-0015; X-fetch moved out
// to a shared activation_cache.v post-M10 DEC-0016)
//
// Fetches ONE tile's P_IN WEIGHT bytes from the WORD-level Memory
// Backend Interface, P_IN/2 sixteen-bit transactions instead of P_IN
// single-byte ones (DEC-0015 -- see this rationale in full below).
//
// Historical note: this module used to ALSO fetch the P_IN
// ACTIVATION (X) bytes for the same tile. DEC-0016 moved that
// responsibility to a new shared activation_cache.v instead: in the
// realistic dense-layer workloads this project actually benchmarks
// (hardware/v2/docs/benchmarks/final-benchmark.md), many neurons
// share the exact same X vector, and each of memory_manager.v's own
// N_SLOTS instances re-fetching that identical vector from PSRAM
// independently was real, measured, redundant traffic on the one
// shared PSRAM port -- exactly the kind of real recommendation the
// benchmark campaign was built to surface. Weights (W) are NOT shared
// across neurons (each neuron has its own trained weight vector), so
// there is no equivalent caching opportunity on the W side -- this
// engine keeps fetching W directly from PSRAM, unchanged in spirit
// from DEC-0015, just no longer also fetching X.
//
// WHY word-level (DEC-0015, unchanged rationale): int8_memory_access.v
// (the byte-level backend this engine originally sat on) converts
// every 8-bit logical request into a FULL 16-bit PSRAM word access
// internally (mem_addr <= addr >> 1, one byte lane selected via
// lb_n/ub_n) -- so a byte-at-a-time fetch was ALREADY paying for two
// bytes of real PSRAM bandwidth per transaction while only using one.
// This engine talks directly to hardware/v1/rtl/memory_interface.v's
// own 16-bit word interface (skipping int8_memory_access.v entirely --
// both are frozen V1 files, unmodified either way, §1/§34).
//
// CONSTRAINT: P_IN must be even, and w_addr must be word-aligned (even
// BYTE address) -- each 16-bit transaction covers BYTE addresses
// {addr, addr+1} as {low byte, high byte} (matches int8_memory_access.v's
// own addr[0] convention exactly, replicated here since that module is
// no longer in the datapath).
// ================================================================

module prefetch_engine #(
    parameter DATA_WIDTH = 8,
    parameter P_IN       = 8,
    parameter ADDR_WIDTH = 23
)(
    input  wire clk,
    input  wire rst,

    input  wire                              fetch_start,
    input  wire [ADDR_WIDTH-1:0]              w_addr, // BYTE address, word-aligned
    output reg                                fetch_busy,
    output reg                                fetch_done, // one-cycle pulse
    output reg  signed [DATA_WIDTH*P_IN-1:0]  tile_w,

    // ---- word-level Memory Backend Interface (matches
    // hardware/v1/rtl/memory_interface.v's contract exactly) ----
    output reg                     mem_req,
    output reg                     mem_wr,
    output reg  [ADDR_WIDTH-1:0]   mem_addr,   // WORD address
    output reg  [15:0]             mem_wdata,
    output reg                     mem_lb_n,
    output reg                     mem_ub_n,
    input  wire [15:0]             mem_rdata,
    input  wire                    mem_ready
);

    localparam ST_IDLE     = 2'd0;
    localparam ST_READ_W   = 2'd2;
    localparam ST_DONE     = 2'd3;

    localparam WORDS_PER_TILE = P_IN/2;
    localparam WIW = $clog2(WORDS_PER_TILE+1);

    reg [1:0] state;
    reg [WIW-1:0] word_idx;

    wire [ADDR_WIDTH-1:0] w_word_base = w_addr[ADDR_WIDTH-1:1];

    always @(posedge clk) begin
        if (rst) begin
            state      <= ST_IDLE;
            word_idx   <= 0;
            fetch_busy <= 1'b0;
            fetch_done <= 1'b0;
            mem_req    <= 1'b0;
            mem_wr     <= 1'b0;
            mem_addr   <= {ADDR_WIDTH{1'b0}};
            mem_wdata  <= 16'h0000;
            mem_lb_n   <= 1'b1;
            mem_ub_n   <= 1'b1;
        end else begin
            mem_req    <= 1'b0;
            fetch_done <= 1'b0;

            case (state)

                ST_IDLE: begin
                    if (fetch_start) begin
                        fetch_busy <= 1'b1;
                        word_idx   <= 0;
                        mem_req    <= 1'b1;
                        mem_wr     <= 1'b0;
                        mem_addr   <= w_word_base;
                        mem_lb_n   <= 1'b0; // both byte lanes -- fetch the whole word
                        mem_ub_n   <= 1'b0;
                        state      <= ST_READ_W;
                    end
                end

                ST_READ_W: begin
                    if (mem_ready) begin
                        tile_w[word_idx*16 +: 16] <= mem_rdata;
                        if (word_idx == WORDS_PER_TILE[WIW-1:0] - 1'b1) begin
                            state <= ST_DONE;
                        end else begin
                            word_idx <= word_idx + 1'b1;
                            mem_req  <= 1'b1;
                            mem_wr   <= 1'b0;
                            mem_addr <= w_word_base + word_idx + 1'b1;
                            mem_lb_n <= 1'b0;
                            mem_ub_n <= 1'b0;
                        end
                    end
                end

                ST_DONE: begin
                    fetch_busy <= 1'b0;
                    fetch_done <= 1'b1;
                    state      <= ST_IDLE;
                end

                default: state <= ST_IDLE;

            endcase
        end
    end

endmodule
