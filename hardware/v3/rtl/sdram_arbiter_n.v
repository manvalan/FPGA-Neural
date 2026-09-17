`timescale 1ns/1ps

// ============================================================
// V3 -- generalized N-way arbiter for a shared memory controller
// port (SDRAM placeholder today, DDR3/mig_native_adapter.v tomorrow
// -- this arbiter sits on the req/wr/addr/wdata/wmask->rdata/ready/
// busy side, identical on either backend).
//
// Generalizes sdram_slot_arbiter2.v (EXP-0066) to NUM_REQ requesters
// instead of a hardcoded 2, for (a) scaling the compute system past
// N=2 packed slots, and (b) adding a HOST raw-memory-access requester
// (the still-missing SPI WRITE_MEM/READ_MEM equivalent for V3,
// flagged when re-auditing spi_host_bridge.v's own opcode set against
// this project's actual V3 architecture).
//
// Preserves EXACTLY the combinational-first-grant mechanism EXP-0066
// found necessary the hard way: layer_prefetch_ctrl.v (and any other
// requester built the same way, e.g. a future host-access engine)
// issues its own ctrl_req as a genuine ONE-SHOT pulse with no retry,
// so a requester must see ITS OWN grant asserted the SAME cycle its
// own `active` first goes high, or that first request is silently
// lost forever (a real, previously-hit bug, not a hypothetical one --
// see EXP-0066's own writeup). `locked`/`grant_reg` below only LATCH
// a decision already available combinationally, purely to keep it
// sticky once made (no mid-fetch grant switching), never to delay
// the first grant.
//
// Priority: lowest-indexed active requester wins on first grant (same
// policy as sdram_slot_arbiter2.v -- a documented, simple, first-
// come-by-index scheme, not fairness-optimized; matches this
// project's own "correctness first" precedent of choosing the
// simplest policy that is provably correct before optimizing).
// ============================================================
module sdram_arbiter_n #(
    parameter NUM_REQ    = 3,
    parameter ADDR_WIDTH = 25,
    parameter BURST_LEN  = 8
)(
    input  wire clk,
    input  wire rst,

    input  wire [NUM_REQ-1:0]                    req_active,
    output wire [NUM_REQ-1:0]                    req_grant,
    input  wire [NUM_REQ-1:0]                    req_req,
    input  wire [NUM_REQ-1:0]                    req_wr,
    input  wire [NUM_REQ*ADDR_WIDTH-1:0]         req_addr,
    input  wire [NUM_REQ*16*BURST_LEN-1:0]       req_wdata,
    input  wire [NUM_REQ*2*BURST_LEN-1:0]        req_wmask,
    output wire [NUM_REQ*16*BURST_LEN-1:0]       req_rdata,
    output wire [NUM_REQ-1:0]                    req_ready,
    output wire [NUM_REQ-1:0]                    req_busy,

    output wire                    ctrl_req,
    output wire                    ctrl_wr,
    output wire [ADDR_WIDTH-1:0]   ctrl_addr,
    output wire [16*BURST_LEN-1:0] ctrl_wdata,
    output wire [2*BURST_LEN-1:0]  ctrl_wmask,
    input  wire [16*BURST_LEN-1:0] ctrl_rdata,
    input  wire                    ctrl_ready,
    input  wire                    ctrl_busy
);
    localparam SELW = (NUM_REQ <= 1) ? 1 : $clog2(NUM_REQ);

    wire any_active = |req_active;

    // combinational lowest-index-active picker -- available with zero
    // cycle latency relative to req_active first asserting (see header).
    reg [SELW-1:0] pick_idx;
    integer pi;
    always @(*) begin
        pick_idx = {SELW{1'b0}};
        for (pi = NUM_REQ-1; pi >= 0; pi = pi - 1)
            if (req_active[pi]) pick_idx = pi[SELW-1:0];
    end

    reg              locked;
    reg [SELW-1:0]   grant_idx_r;

    wire [SELW-1:0] grant_idx_now = locked ? grant_idx_r : pick_idx;

    always @(posedge clk) begin
        if (rst) begin
            locked      <= 1'b0;
            grant_idx_r <= {SELW{1'b0}};
        end else begin
            if (!locked) begin
                if (any_active) begin
                    locked      <= 1'b1;
                    grant_idx_r <= grant_idx_now;
                end
            end else begin
                if (!req_active[grant_idx_r]) locked <= 1'b0;
            end
        end
    end

    wire [NUM_REQ-1:0] sel;
    genvar gs;
    generate
        for (gs = 0; gs < NUM_REQ; gs = gs + 1) begin : GEN_SEL
            assign sel[gs] = any_active && (grant_idx_now == gs[SELW-1:0]);
        end
    endgenerate

    assign req_grant = sel;

    // mux request-side signals from the granted requester -> shared ctrl
    reg                    m_req, m_wr;
    reg [ADDR_WIDTH-1:0]   m_addr;
    reg [16*BURST_LEN-1:0] m_wdata;
    reg [2*BURST_LEN-1:0]  m_wmask;
    integer mi;
    always @(*) begin
        m_req   = 1'b0;
        m_wr    = 1'b0;
        m_addr  = {ADDR_WIDTH{1'b0}};
        m_wdata = {(16*BURST_LEN){1'b0}};
        m_wmask = {(2*BURST_LEN){1'b0}};
        for (mi = 0; mi < NUM_REQ; mi = mi + 1) begin
            if (sel[mi]) begin
                m_req   = req_req[mi];
                m_wr    = req_wr[mi];
                m_addr  = req_addr[mi*ADDR_WIDTH +: ADDR_WIDTH];
                m_wdata = req_wdata[mi*16*BURST_LEN +: 16*BURST_LEN];
                m_wmask = req_wmask[mi*2*BURST_LEN +: 2*BURST_LEN];
            end
        end
    end

    assign ctrl_req   = m_req;
    assign ctrl_wr    = m_wr;
    assign ctrl_addr  = m_addr;
    assign ctrl_wdata = m_wdata;
    assign ctrl_wmask = m_wmask;

    // demux response back to whichever requester is currently granted
    genvar gd;
    generate
        for (gd = 0; gd < NUM_REQ; gd = gd + 1) begin : GEN_DEMUX
            assign req_rdata[gd*16*BURST_LEN +: 16*BURST_LEN] = ctrl_rdata;
            assign req_ready[gd] = sel[gd] ? ctrl_ready : 1'b0;
            assign req_busy[gd]  = sel[gd] ? ctrl_busy  : 1'b1;
        end
    endgenerate
endmodule
