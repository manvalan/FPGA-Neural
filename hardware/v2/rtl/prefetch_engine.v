`timescale 1ns/1ps

// ================================================================
// FPGA-Neural V2 -- Prefetch Engine (M4, docs/v2-description.md §13;
// word-level burst rewrite post-M10 -- see hardware/v2/logs/
// decisions.log DEC-0015)
//
// Fetches ONE tile (P_IN activation bytes + P_IN weight bytes) from
// the WORD-level Memory Backend Interface, P_IN/2 sixteen-bit
// transactions per array instead of P_IN single-byte ones.
//
// WHY: hardware/v1/rtl/int8_memory_access.v (the byte-level backend
// this engine originally sat on) converts every 8-bit logical request
// into a FULL 16-bit PSRAM word access internally (mem_addr <= addr
// >> 1, one byte lane selected via lb_n/ub_n) -- so a byte-at-a-time
// fetch was ALREADY paying for two bytes of real PSRAM bandwidth per
// transaction while only using one. This engine now talks directly to
// hardware/v1/rtl/memory_interface.v's own 16-bit word interface
// (skipping int8_memory_access.v entirely -- both are frozen V1 files,
// unmodified either way, §1/§34; V2 is simply choosing to reuse the
// lower layer instead of the byte-splitting one on top of it, the
// same "reuse what fits" precedent already set by slot_mem_arbiter.v
// not reusing hardware/v1/rtl/mem_arbiter.v verbatim). psram_controller.v's
// own real page-mode support (already implemented, unmodified) then
// serves consecutive same-page word reads faster than a cold access --
// this engine's job is simply to stop discarding half of every word it
// already paid for, and to halve the number of real backend
// round-trips needed per tile.
//
// CONSTRAINT: P_IN must be even, and x_addr/w_addr must be word-
// aligned (even BYTE addresses) -- each 16-bit transaction covers
// BYTE addresses {addr, addr+1} as {low byte, high byte} (matches
// int8_memory_access.v's own addr[0] convention exactly, replicated
// here since that module is no longer in the datapath). A host/loader
// placing X/W tile arrays at even byte offsets (already true of every
// address used in this project's own testbenches) satisfies this
// with no special handling.
//
// The double-buffering strategy itself (§13) remains memory_manager.v's
// responsibility -- unchanged by this rewrite.
// ================================================================

module prefetch_engine #(
    parameter DATA_WIDTH = 8,
    parameter P_IN       = 8,
    parameter ADDR_WIDTH = 23
)(
    input  wire clk,
    input  wire rst,

    input  wire                              fetch_start,
    input  wire [ADDR_WIDTH-1:0]              x_addr, // BYTE address, word-aligned
    input  wire [ADDR_WIDTH-1:0]              w_addr, // BYTE address, word-aligned
    output reg                                fetch_busy,
    output reg                                fetch_done, // one-cycle pulse
    output reg  signed [DATA_WIDTH*P_IN-1:0]  tile_x,
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
    localparam ST_READ_X   = 2'd1;
    localparam ST_READ_W   = 2'd2;
    localparam ST_DONE     = 2'd3;

    localparam WORDS_PER_TILE = P_IN/2;
    localparam WIW = $clog2(WORDS_PER_TILE+1);

    reg [1:0] state;
    reg [WIW-1:0] word_idx;

    wire [ADDR_WIDTH-1:0] x_word_base = x_addr[ADDR_WIDTH-1:1];
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
                        mem_addr   <= x_word_base;
                        mem_lb_n   <= 1'b0; // both byte lanes -- fetch the whole word
                        mem_ub_n   <= 1'b0;
                        state      <= ST_READ_X;
                    end
                end

                ST_READ_X: begin
                    if (mem_ready) begin
                        tile_x[word_idx*16 +: 16] <= mem_rdata;
                        if (word_idx == WORDS_PER_TILE[WIW-1:0] - 1'b1) begin
                            word_idx <= 0;
                            mem_req  <= 1'b1;
                            mem_wr   <= 1'b0;
                            mem_addr <= w_word_base;
                            mem_lb_n <= 1'b0;
                            mem_ub_n <= 1'b0;
                            state    <= ST_READ_W;
                        end else begin
                            word_idx <= word_idx + 1'b1;
                            mem_req  <= 1'b1;
                            mem_wr   <= 1'b0;
                            mem_addr <= x_word_base + word_idx + 1'b1;
                            mem_lb_n <= 1'b0;
                            mem_ub_n <= 1'b0;
                        end
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
