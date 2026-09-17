`timescale 1ns/1ps

// ============================================================
// V3 -- host raw-memory-access bridge: the missing piece flagged
// re-auditing spi_host_bridge.v against V3's real architecture.
// spi_host_bridge.v's WRITE_MEM/READ_MEM opcodes drive a single-
// 16-bit-WORD req/wr/addr/wdata/lb_n/ub_n -> rdata/ready port (the
// SAME shape as V2's real psram_controller.v / sdram_unified_
// backend.v AR port), but V3's shared memory path (sdram_arbiter_n.v
// -> mig_native_adapter.v) only understands BURST_LEN=8 (128-bit)
// chunks. This module is the translator, matching sdram_unified_
// backend.v's own AR-port technique exactly (not reinvented): a
// write masks out every word in the burst except the target one
// (DQM-style byte masking, already how this project's whole memory
// stack works); a read fetches the whole burst and extracts the
// target word combinationally.
//
// Sits as one requester on sdram_arbiter_n.v (alongside N packed_
// slot.v instances) -- `active` is asserted for the WHOLE single-word
// transaction (word-granularity, no multi-burst sequencing needed),
// so mem_grant only needs to be observed once before the one-shot
// ctrl_req fires, same discipline as packed_slot.v's own S_MEMWAIT
// (EXP-0066's real, hard-won lesson).
// ============================================================
module host_mem_bridge #(
    parameter BURST_LEN  = 8,
    parameter ADDR_WIDTH = 25   // word address, matches sdram_arbiter_n.v's own convention
)(
    input  wire clk,
    input  wire rst,

    // ---- host-facing port (matches spi_host_bridge.v's own
    // mem_req/mem_wr/mem_addr/mem_wdata/mem_lb_n/mem_ub_n ->
    // mem_rdata/mem_ready convention exactly) ----
    input  wire                  mem_req,
    input  wire                  mem_wr,
    input  wire [ADDR_WIDTH-1:0] mem_addr,     // WORD address (not burst-aligned)
    input  wire [15:0]           mem_wdata,
    input  wire                  mem_lb_n,
    input  wire                  mem_ub_n,
    output reg  [15:0]           mem_rdata,
    output reg                   mem_ready,

    // ---- arbiter-facing requester port (matches sdram_arbiter_n.v's
    // own per-slot req_active/req_grant/req_req/req_wr/req_addr/
    // req_wdata/req_wmask -> req_rdata/req_ready/req_busy naming) ----
    output wire                     req_active,
    input  wire                     req_grant,
    output reg                      req_req,
    output reg                      req_wr,
    output reg  [ADDR_WIDTH-1:0]    req_addr,
    output reg  [16*BURST_LEN-1:0]  req_wdata,
    output reg  [2*BURST_LEN-1:0]   req_wmask,
    input  wire [16*BURST_LEN-1:0]  req_rdata,
    input  wire                     req_ready,
    input  wire                     req_busy
);
    localparam ALIGN_BITS = $clog2(BURST_LEN);

    localparam S_IDLE     = 2'd0,
               S_MEMWAIT  = 2'd1,
               S_XFER     = 2'd2,
               S_DONE     = 2'd3;

    reg [1:0] state;
    reg [ALIGN_BITS-1:0] word_in_block;

    assign req_active = (state == S_MEMWAIT) || (state == S_XFER);

    always @(posedge clk) begin
        if (rst) begin
            state     <= S_IDLE;
            req_req   <= 1'b0;
            mem_ready <= 1'b0;
        end else begin
            req_req   <= 1'b0;
            mem_ready <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (mem_req) begin
                        req_addr      <= {mem_addr[ADDR_WIDTH-1:ALIGN_BITS], {ALIGN_BITS{1'b0}}};
                        word_in_block <= mem_addr[ALIGN_BITS-1:0];
                        req_wr        <= mem_wr;
                        if (mem_wr) begin
                            // replicate the target word across the whole
                            // burst; only its own mask bits matter (see
                            // header -- same DQM-style technique as
                            // sdram_unified_backend.v's own AR port).
                            req_wdata <= {BURST_LEN{mem_wdata}};
                            req_wmask <= {(2*BURST_LEN){1'b1}} &
                                          ~(({{(2*BURST_LEN-2){1'b0}}, 2'b11}) << (mem_addr[ALIGN_BITS-1:0]*2)) |
                                          (({{(2*BURST_LEN-2){1'b0}}, mem_ub_n, mem_lb_n}) << (mem_addr[ALIGN_BITS-1:0]*2));
                        end
                        state <= S_MEMWAIT;
                    end
                end

                S_MEMWAIT: begin
                    if (req_grant) begin
                        req_req <= 1'b1;
                        state   <= S_XFER;
                    end
                end

                S_XFER: begin
                    if (req_ready) begin
                        if (!req_wr)
                            mem_rdata <= req_rdata[word_in_block*16 +: 16];
                        state <= S_DONE;
                    end
                end

                S_DONE: begin
                    mem_ready <= 1'b1;
                    state     <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
