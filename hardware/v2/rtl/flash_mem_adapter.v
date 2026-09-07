`timescale 1ns/1ps

// ================================================================
// FLASH_MEM_ADAPTER -- bridges flash_slot_manager.v's real, unmodified
// V1 "Port D" (PSRAM-style byte interface: d_req/d_wr/d_addr/d_wdata/
// d_rdata/d_ready, byte-addressed, 8-bit signed data) to V2's real AR-
// port convention (word address, 16-bit data, lb_n/ub_n byte lane
// masking) used by slot_mem_arbiter.v's clients.
//
// Byte<->word convention matches nms_memory_manager_stream_wide.v's
// own real, already-verified result-writeback logic EXACTLY (not
// invented): word_addr = byte_addr[ADDR_WIDTH-1:1], byte_addr[0]==0
// selects the LOWER lane (lb_n=0,ub_n=1), byte_addr[0]==1 selects the
// UPPER lane (lb_n=1,ub_n=0); write data is replicated to both halves
// of the 16-bit word, the mask picks which half the SDRAM controller
// actually writes.
//
// Simple valid/ready passthrough: request held (s_req) from issue
// until the arbiter/backend returns s_ready, matching the same
// "hold, don't pulse" idiom already used throughout this project
// (nms_memory_manager_stream_wide.v, spi_host_bridge.v's own mem_req).
// ================================================================
module flash_mem_adapter #(
    parameter ADDR_WIDTH      = 26,  // AR-side word-address bus width
    parameter BYTE_ADDR_WIDTH = 26   // flash_slot_manager's own PSRAM_ADDR_WIDTH
)(
    input  wire clk,
    input  wire rst,

    // ---- flash_slot_manager's own real "Port D" ----
    input  wire                        d_req,
    input  wire                        d_wr,
    input  wire [BYTE_ADDR_WIDTH-1:0]  d_addr,
    input  wire signed [7:0]           d_wdata,
    output reg  signed [7:0]           d_rdata,
    output reg                         d_ready,

    // ---- AR-port-style client, into slot_mem_arbiter.v ----
    output reg                       s_req,
    output reg                       s_wr,
    output reg  [ADDR_WIDTH-1:0]     s_addr,
    output reg  [15:0]               s_wdata,
    output reg                       s_lb_n,
    output reg                       s_ub_n,
    input  wire [15:0]               s_rdata,
    input  wire                      s_ready
);

    reg pending;
    reg lane;

    always @(posedge clk) begin
        if (rst) begin
            s_req   <= 1'b0;
            s_wr    <= 1'b0;
            s_addr  <= {ADDR_WIDTH{1'b0}};
            s_wdata <= 16'h0;
            s_lb_n  <= 1'b1;
            s_ub_n  <= 1'b1;
            d_ready <= 1'b0;
            d_rdata <= 8'sd0;
            pending <= 1'b0;
            lane    <= 1'b0;
        end else begin
            d_ready <= 1'b0;
            if (!pending && d_req) begin
                s_req   <= 1'b1;
                s_wr    <= d_wr;
                s_addr  <= d_addr[BYTE_ADDR_WIDTH-1:1];
                lane    <= d_addr[0];
                s_wdata <= d_addr[0] ? {d_wdata, 8'h00} : {8'h00, d_wdata};
                s_lb_n  <= d_addr[0] ? 1'b1 : 1'b0;
                s_ub_n  <= d_addr[0] ? 1'b0 : 1'b1;
                pending <= 1'b1;
            end else if (pending && s_ready) begin
                s_req   <= 1'b0;
                d_rdata <= lane ? s_rdata[15:8] : s_rdata[7:0];
                d_ready <= 1'b1;
                pending <= 1'b0;
            end
        end
    end

endmodule
