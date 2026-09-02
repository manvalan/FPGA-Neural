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
//
// Fixed priority B > C > A when more than one requests on the same
// idle cycle (an in-progress inference is treated as more
// time-critical than the sequencer's own bookkeeping, which in turn
// is treated as more time-critical than a newly-arriving manual SPI
// RAM access). In normal operation B and C are temporally disjoint
// anyway -- neuron_memory only requests while running, and
// layer_sequencer only requests in the gaps between layers -- so
// this priority mostly matters for the edge case of a manual
// WRITE_RAM/READ_RAM arriving while a Phase 5 run is in progress.
// Once a port is granted, the arbiter holds ownership until that
// single transaction's m_ready pulse, then releases -- all three
// masters already issue `req` as a clean one-cycle pulse (matching
// int8_memory_access's own contract), so a simple grant-and-forward
// design is sufficient; no request queuing/pipelining is needed.
// ================================================================

module mem_arbiter #(
    parameter ADDR_WIDTH = 22
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
    // Shared master port
    // ------------------------------------------------------------

    output reg                   m_req,
    output reg                   m_wr,
    output reg [ADDR_WIDTH-1:0]  m_addr,
    output reg signed [7:0]      m_wdata,

    input wire signed [7:0]      m_rdata,
    input wire                   m_ready
);

    localparam SEL_NONE = 2'd0;
    localparam SEL_A    = 2'd1;
    localparam SEL_B    = 2'd2;
    localparam SEL_C    = 2'd3;

    reg [1:0] owner;

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

        end else begin

            m_req   <= 1'b0;
            a_ready <= 1'b0;
            b_ready <= 1'b0;
            c_ready <= 1'b0;

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

                default: begin
                    owner <= SEL_NONE;
                end

            endcase

        end

    end

endmodule
