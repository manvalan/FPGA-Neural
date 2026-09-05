`timescale 1ns/1ps

// ================================================================
// FPGA-Neural V2 -- Slot Memory Arbiter (M8, docs/v2-description.md §15)
//
// Generic N_PORTS-way arbiter for dataflow_core.v's per-slot Memory
// Backend Interface ports (docs/v2-description.md §15's "Memory
// Manager -> Memory Backend Interface -> PSRAM Controller" layering),
// funneling N_SLOTS independent memory_manager backend ports down to
// the ONE physical PSRAM port a real chip actually has.
//
// Inspired by (NOT copied from -- see hardware/v2/logs/decisions.log
// DEC-0006's own note) hardware/v1/rtl/mem_arbiter.v: same
// single-owner-until-ready-pulse discipline (a port, once granted,
// holds the shared master port until ITS OWN transaction's m_ready
// pulse, then releases -- no queuing/pipelining needed, since every
// requester already issues a clean one-cycle req pulse matching
// int8_memory_access's own contract). Generalized from V1's fixed
// 4 named ports (A/B/C/D) to a parametric N_PORTS array, since
// dataflow_core.v's N_SLOTS is itself a parameter.
//
// Priority: fixed, lowest port index wins on a cycle where more than
// one port requests simultaneously while the arbiter is idle -- same
// "first-found, lowest index" convention already used by
// neural_director's free-slot scan and dependency_manager's
// first-ready scan (not fairness-balanced; see decisions.log DEC-0010
// for why that is an acceptable starting point, same rationale as
// neural_director's own "first-free, not load-balanced" choice).
//
// IMPORTANT (found via real concurrent-slot simulation, see
// hardware/v2/logs/errors.log ERR-0008): each port's own s_req is a
// FIRE-AND-FORGET single-cycle pulse (prefetch_engine.v/
// memory_manager.v's own byte-level backend protocol -- M4 verified
// it only against a DIRECT 1:1 connection to int8_memory_access,
// which is always free to accept it since there is exactly one
// requester). A naive "grant only while req is live" arbiter silently
// DROPS a pulse that arrives while the shared bus is owned by another
// port, hanging that slot's prefetch/writeback forever. Every
// incoming s_req is therefore LATCHED into a per-port `pending`
// register (capturing wr/addr/wdata the same cycle) regardless of
// arbiter state -- the same single-entry "queue, don't drop the
// request" idiom already used by memory_manager's own pf_pending
// register (ERR-0006 fix #1). Grants are drawn from `pending`, never
// from a live s_req directly, which adds a uniform minimum 1-cycle
// latency to every byte transaction (a real, measured cost of sharing
// one PSRAM port -- see timing.log/benchmark.log EXP-0009) but never
// drops a request.
// ================================================================

module slot_mem_arbiter #(
    parameter ADDR_WIDTH = 23,
    parameter N_PORTS    = 4
)(
    input  wire clk,
    input  wire rst,

    // ---- N_PORTS requester side (one per dataflow_core slot) ----
    input  wire [N_PORTS-1:0]            s_req,
    input  wire [N_PORTS-1:0]            s_wr,
    input  wire [ADDR_WIDTH*N_PORTS-1:0] s_addr,
    input  wire signed [8*N_PORTS-1:0]   s_wdata,
    output reg  signed [8*N_PORTS-1:0]   s_rdata,
    output reg  [N_PORTS-1:0]            s_ready,

    // ---- single shared master port (-> int8_memory_access) ----
    output reg                    m_req,
    output reg                    m_wr,
    output reg  [ADDR_WIDTH-1:0]  m_addr,
    output reg  signed [7:0]      m_wdata,
    input  wire signed [7:0]      m_rdata,
    input  wire                   m_ready
);

    localparam PIDXW = $clog2(N_PORTS+1);
    localparam OWNER_NONE = {PIDXW{1'b0}}; // 0 = no owner; port i owned = i+1

    reg [PIDXW-1:0] owner;

    // Per-port pending-request latch (see file header/ERR-0008): every
    // s_req pulse is captured here, regardless of arbiter state, so it
    // is never silently dropped while the bus is owned by another port.
    reg [N_PORTS-1:0]            pending;
    reg [ADDR_WIDTH*N_PORTS-1:0] pending_addr;
    reg signed [8*N_PORTS-1:0]   pending_wdata;
    reg [N_PORTS-1:0]            pending_wr;

    // Fixed lowest-index-wins priority scan over PENDING requests (not
    // raw s_req -- see file header).
    reg [PIDXW-1:0] grant_idx;
    reg             any_pending;
    integer ri;
    always @(*) begin
        grant_idx   = {PIDXW{1'b0}};
        any_pending = 1'b0;
        for (ri = N_PORTS-1; ri >= 0; ri = ri - 1) begin
            if (pending[ri]) begin
                grant_idx   = ri[PIDXW-1:0];
                any_pending = 1'b1;
            end
        end
    end

    integer pi;

    always @(posedge clk) begin
        if (rst) begin
            owner         <= OWNER_NONE;
            pending       <= {N_PORTS{1'b0}};
            pending_addr  <= {(ADDR_WIDTH*N_PORTS){1'b0}};
            pending_wdata <= {(8*N_PORTS){1'b0}};
            pending_wr    <= {N_PORTS{1'b0}};
            m_req   <= 1'b0;
            m_wr    <= 1'b0;
            m_addr  <= {ADDR_WIDTH{1'b0}};
            m_wdata <= 8'sd0;
            s_rdata <= {(8*N_PORTS){1'b0}};
            s_ready <= {N_PORTS{1'b0}};
        end else begin
            m_req   <= 1'b0;
            s_ready <= {N_PORTS{1'b0}};

            // Latch every incoming request pulse. Safe against a
            // same-cycle collision with the grant-clear write below:
            // a port only ever becomes grant_idx while its OWN pending
            // bit is already 1 (latched on an earlier cycle), and its
            // requester (memory_manager/prefetch_engine) never issues
            // a NEW s_req for that port until THIS transaction's
            // s_ready arrives -- so s_req[grant_idx] is guaranteed low
            // the cycle it is granted.
            for (pi = 0; pi < N_PORTS; pi = pi + 1) begin
                if (s_req[pi]) begin
                    pending[pi]                          <= 1'b1;
                    pending_wr[pi]                        <= s_wr[pi];
                    pending_addr[pi*ADDR_WIDTH +: ADDR_WIDTH] <= s_addr[pi*ADDR_WIDTH +: ADDR_WIDTH];
                    pending_wdata[pi*8 +: 8]              <= s_wdata[pi*8 +: 8];
                end
            end

            if (owner == OWNER_NONE) begin
                if (any_pending) begin
                    owner   <= grant_idx + 1'b1;
                    m_req   <= 1'b1;
                    m_wr    <= pending_wr[grant_idx];
                    m_addr  <= pending_addr[grant_idx*ADDR_WIDTH +: ADDR_WIDTH];
                    m_wdata <= pending_wdata[grant_idx*8 +: 8];
                    pending[grant_idx] <= 1'b0;
                end
            end else begin
                if (m_ready) begin
                    // owner is (port_index+1); vectorized single-write
                    // so exactly one s_rdata/s_ready lane updates (no
                    // per-bit loop last-write-wins hazard -- same class
                    // of bug already hit/fixed at ERR-0006/M2/M6).
                    for (pi = 0; pi < N_PORTS; pi = pi + 1) begin
                        if (owner == pi[PIDXW-1:0] + 1'b1) begin
                            s_rdata[pi*8 +: 8] <= m_rdata;
                            s_ready[pi]        <= 1'b1;
                        end
                    end
                    owner <= OWNER_NONE;
                end
            end
        end
    end

endmodule
