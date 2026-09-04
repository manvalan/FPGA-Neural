`timescale 1ns/1ps

// ================================================================
// MEM_ARBITER
//
// Arbitrates a single shared byte-level memory master port (feeding
// a shared int8_memory_access -> memory_interface -> psram_controller
// chain) between three byte-level requesters:
//
//   Port A: spi_engine.v       (WRITE_RAM / READ_RAM opcodes)
//   Port B: neuron_memory.v    (its own X/W/bias reads during a run)
//   Port C: layer_sequencer.v  (Phase 5: descriptor reads + output
//                                buffer writes between layers)
//   Port D: flash_copy_engine.v (flash-subsystem F2: flash<->PSRAM
//                                block DMA, LOWEST priority -- see
//                                below)
//
// Fixed priority B > C > A > D when more than one requests on the
// same idle cycle (an in-progress inference is treated as more
// time-critical than the sequencer's own bookkeeping, which in turn
// is treated as more time-critical than a newly-arriving manual SPI
// RAM access, which in turn is treated as more time-critical than
// the flash copy engine -- flash operations are ms-scale and never
// meant to compete with inference for memory bandwidth, per the
// flash-subsystem phase-plan's explicit "priorita bassa" requirement:
// a flash load/save simply waits its turn, one byte-transaction at a
// time, behind anything else that wants the shared PSRAM port).
// In normal operation B and C are temporally disjoint anyway --
// neuron_memory only requests while running, and layer_sequencer
// only requests in the gaps between layers -- so priority among
// A/B/C mostly matters for the edge case of a manual
// WRITE_RAM/READ_RAM arriving while a Phase 5 run is in progress.
// Port D is expected to be active only during flash load/save,
// which this design assumes does not overlap real-time inference
// (the same "not the hot path" assumption the flash phase-plan
// states explicitly) -- if it ever did overlap, its lowest-priority
// placement here means it simply gets stretched out, never starves
// or corrupts A/B/C.
// Once a port is granted, the arbiter holds ownership until that
// single transaction's m_ready pulse, then releases -- all four
// masters already issue `req` as a clean one-cycle pulse (matching
// int8_memory_access's own contract), so a simple grant-and-forward
// design is sufficient; no request queuing/pipelining is needed.
// ================================================================

module mem_arbiter #(
    parameter ADDR_WIDTH = 23
)(
    input wire clk,
    input wire rst,

    // ------------------------------------------------------------
    // Port A - spi_engine
    // ------------------------------------------------------------

    input  wire                   a_req,
    input  wire                   a_wr,
    input  wire [ADDR_WIDTH-1:0]  a_addr,
    input  wire signed [7:0]      a_wdata,
    output reg  signed [7:0]      a_rdata,
    output reg                    a_ready,

    // ------------------------------------------------------------
    // Port B - neuron_memory
    // ------------------------------------------------------------

    input  wire                   b_req,
    input  wire                   b_wr,
    input  wire [ADDR_WIDTH-1:0]  b_addr,
    input  wire signed [7:0]      b_wdata,
    output reg  signed [7:0]      b_rdata,
    output reg                    b_ready,

    // ------------------------------------------------------------
    // Port C - layer_sequencer
    // ------------------------------------------------------------

    input  wire                   c_req,
    input  wire                   c_wr,
    input  wire [ADDR_WIDTH-1:0]  c_addr,
    input  wire signed [7:0]      c_wdata,
    output reg  signed [7:0]      c_rdata,
    output reg                    c_ready,

    // ------------------------------------------------------------
    // Port D - flash_copy_engine (F2, lowest priority)
    // ------------------------------------------------------------

    input  wire                   d_req,
    input  wire                   d_wr,
    input  wire [ADDR_WIDTH-1:0]  d_addr,
    input  wire signed [7:0]      d_wdata,
    output reg  signed [7:0]      d_rdata,
    output reg                    d_ready,

    // ------------------------------------------------------------
    // Shared master port
    // ------------------------------------------------------------

    output reg                   m_req,
    output reg                   m_wr,
    output reg [ADDR_WIDTH-1:0]  m_addr,
    output reg signed [7:0]      m_wdata,

    input wire signed [7:0]      m_rdata,
    input wire                   m_ready
);

    localparam SEL_NONE = 3'd0;
    localparam SEL_A    = 3'd1;
    localparam SEL_B    = 3'd2;
    localparam SEL_C    = 3'd3;
    localparam SEL_D    = 3'd4;

    reg [2:0] owner;

    always @(posedge clk) begin

        if (rst) begin

            owner   <= SEL_NONE;

            m_req   <= 1'b0;
            m_wr    <= 1'b0;
            m_addr  <= {ADDR_WIDTH{1'b0}};
            m_wdata <= 8'sd0;

            a_rdata <= 8'sd0;
            a_ready <= 1'b0;

            b_rdata <= 8'sd0;
            b_ready <= 1'b0;

            c_rdata <= 8'sd0;
            c_ready <= 1'b0;

            d_rdata <= 8'sd0;
            d_ready <= 1'b0;

        end else begin

            m_req   <= 1'b0;
            a_ready <= 1'b0;
            b_ready <= 1'b0;
            c_ready <= 1'b0;
            d_ready <= 1'b0;

            case (owner)

                SEL_NONE: begin

                    if (b_req) begin

                        owner   <= SEL_B;
                        m_req   <= 1'b1;
                        m_wr    <= b_wr;
                        m_addr  <= b_addr;
                        m_wdata <= b_wdata;

                    end else if (c_req) begin

                        owner   <= SEL_C;
                        m_req   <= 1'b1;
                        m_wr    <= c_wr;
                        m_addr  <= c_addr;
                        m_wdata <= c_wdata;

                    end else if (a_req) begin

                        owner   <= SEL_A;
                        m_req   <= 1'b1;
                        m_wr    <= a_wr;
                        m_addr  <= a_addr;
                        m_wdata <= a_wdata;

                    end else if (d_req) begin

                        owner   <= SEL_D;
                        m_req   <= 1'b1;
                        m_wr    <= d_wr;
                        m_addr  <= d_addr;
                        m_wdata <= d_wdata;

                    end

                end

                SEL_A: begin

                    if (m_ready) begin
                        a_rdata <= m_rdata;
                        a_ready <= 1'b1;
                        owner   <= SEL_NONE;
                    end

                end

                SEL_B: begin

                    if (m_ready) begin
                        b_rdata <= m_rdata;
                        b_ready <= 1'b1;
                        owner   <= SEL_NONE;
                    end

                end

                SEL_C: begin

                    if (m_ready) begin
                        c_rdata <= m_rdata;
                        c_ready <= 1'b1;
                        owner   <= SEL_NONE;
                    end

                end

                SEL_D: begin

                    if (m_ready) begin
                        d_rdata <= m_rdata;
                        d_ready <= 1'b1;
                        owner   <= SEL_NONE;
                    end

                end

                default: begin
                    owner <= SEL_NONE;
                end

            endcase

        end

    end

endmodule
