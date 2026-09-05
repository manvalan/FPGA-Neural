`timescale 1ns/1ps

// ================================================================
// FPGA-Neural V2 -- Prefetch Engine (M4, docs/v2-description.md §13)
//
// Fetches ONE tile (P_IN activation bytes + P_IN weight bytes) from
// the byte-level Memory Backend Interface into a pair of output
// registers, sequentially (2*P_IN single-byte transactions -- the
// same byte-at-a-time convention hardware/v1/rtl/neuron_memory.v
// already uses against the same backend, reused unmodified here).
//
// This module fetches exactly one tile per fetch_start pulse; the
// double-buffering strategy itself (§13: compute tile N while
// prefetching tile N+1, swap, repeat) is memory_manager.v's
// responsibility -- it retargets this single engine at whichever
// bank currently needs refilling, so no internal arbitration between
// multiple fetch engines sharing the backend port is ever needed.
//
// The backend port (mem_req/mem_wr/mem_addr/mem_wdata/mem_rdata/
// mem_ready) matches hardware/v1/rtl/int8_memory_access.v's contract
// exactly -- this engine can sit directly on top of that unmodified
// V1 module (which itself sits on memory_interface.v ->
// psram_controller.v, also unmodified, per §15).
// ================================================================

module prefetch_engine #(
    parameter DATA_WIDTH = 8,
    parameter P_IN       = 8,
    parameter ADDR_WIDTH = 23
)(
    input  wire clk,
    input  wire rst,

    input  wire                              fetch_start,
    input  wire [ADDR_WIDTH-1:0]              x_addr, // base addr of this tile's P_IN X bytes
    input  wire [ADDR_WIDTH-1:0]              w_addr, // base addr of this tile's P_IN W bytes
    output reg                                fetch_busy,
    output reg                                fetch_done, // one-cycle pulse
    output reg  signed [DATA_WIDTH*P_IN-1:0]  tile_x,
    output reg  signed [DATA_WIDTH*P_IN-1:0]  tile_w,

    output reg                     mem_req,
    output reg                     mem_wr,
    output reg  [ADDR_WIDTH-1:0]   mem_addr,
    output reg  signed [7:0]       mem_wdata,
    input  wire signed [7:0]       mem_rdata,
    input  wire                    mem_ready
);

    localparam ST_IDLE     = 2'd0;
    localparam ST_READ_X   = 2'd1;
    localparam ST_READ_W   = 2'd2;
    localparam ST_DONE     = 2'd3;

    reg [1:0] state;
    reg [$clog2(P_IN+1)-1:0] byte_idx;

    always @(posedge clk) begin
        if (rst) begin
            state      <= ST_IDLE;
            byte_idx   <= 0;
            fetch_busy <= 1'b0;
            fetch_done <= 1'b0;
            mem_req    <= 1'b0;
            mem_wr     <= 1'b0;
            mem_addr   <= {ADDR_WIDTH{1'b0}};
            mem_wdata  <= 8'sd0;
        end else begin
            mem_req    <= 1'b0;
            fetch_done <= 1'b0;

            case (state)

                ST_IDLE: begin
                    if (fetch_start) begin
                        fetch_busy <= 1'b1;
                        byte_idx   <= 0;
                        mem_req    <= 1'b1;
                        mem_wr     <= 1'b0;
                        mem_addr   <= x_addr;
                        state      <= ST_READ_X;
                    end
                end

                ST_READ_X: begin
                    if (mem_ready) begin
                        tile_x[byte_idx*DATA_WIDTH +: DATA_WIDTH] <= mem_rdata;
                        if (byte_idx == P_IN[$clog2(P_IN+1)-1:0] - 1'b1) begin
                            byte_idx <= 0;
                            mem_req  <= 1'b1;
                            mem_wr   <= 1'b0;
                            mem_addr <= w_addr;
                            state    <= ST_READ_W;
                        end else begin
                            byte_idx <= byte_idx + 1'b1;
                            mem_req  <= 1'b1;
                            mem_wr   <= 1'b0;
                            mem_addr <= x_addr + byte_idx + 1'b1;
                        end
                    end
                end

                ST_READ_W: begin
                    if (mem_ready) begin
                        tile_w[byte_idx*DATA_WIDTH +: DATA_WIDTH] <= mem_rdata;
                        if (byte_idx == P_IN[$clog2(P_IN+1)-1:0] - 1'b1) begin
                            state <= ST_DONE;
                        end else begin
                            byte_idx <= byte_idx + 1'b1;
                            mem_req  <= 1'b1;
                            mem_wr   <= 1'b0;
                            mem_addr <= w_addr + byte_idx + 1'b1;
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
