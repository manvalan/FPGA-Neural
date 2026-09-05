`timescale 1ns/1ps

// ================================================================
// FPGA-Neural V2 -- Dependency Manager (M6, docs/v2-description.md §10)
//
// Holds a small table of N_NODES job descriptors, each tracking:
//   node_id, state (EMPTY/WAITING/READY/DISPATCHED),
//   required_dependencies, resolved_dependencies, producer_ids[MAX_DEPS]
// (§10's exact field list), plus the job descriptor fields
// (x_base/w_base/n_tiles/result_addr) needed to hand the node off to
// the Neural Director (M5) once it becomes READY.
//
// A node with required_dependencies==0 is immediately READY on
// registration (no producers to wait for -- a graph's own input
// nodes, or a fully-independent job). When a PRODUCER completes
// (producer_done_valid/producer_done_node_id, tagged by whichever
// node just finished -- fed from the Director's own job_out_done/
// job_out_slot, resolved back to a node_id by the caller), every
// OTHER node that lists that producer among its own producer_ids
// gets its resolved_dependencies incremented -- a single producer
// can satisfy MULTIPLE waiting consumers this way (§10 "risultati
// condivisi... più consumer"), and a node depending on several
// producers accumulates resolved_dependencies across separate
// producer-done events ("dipendenze multiple").
//
// Ready nodes are handed to the Director one at a time via a
// valid/ready producer interface (ready_valid/ready_ready), backpressure-
// safe (§10 "backpressure"): a node stays READY, occupying its table
// slot, until the consumer (Director) actually accepts it.
//
// Scope note (see hardware/v2/logs/decisions.log DEC-0008): §11's
// direct producer-to-consumer VALUE forwarding (bypassing the Result
// Buffer / external memory round-trip) is NOT implemented here --
// this module tracks dependency COUNTS/readiness only ("has this
// node's data become available", not the data itself), which is what
// actually gates scheduling; the job descriptor's result_addr already
// points at wherever the Memory Manager (M4) wrote the producer's
// result, which is how a ready consumer finds its inputs today. Real
// zero-copy forwarding is a possible future optimization (§11 itself:
// "quando possibile"), deferred until measured to matter (§22).
// ================================================================

module dependency_manager #(
    parameter N_NODES    = 16,
    parameter MAX_DEPS   = 4,
    parameter ADDR_WIDTH = 23
)(
    input  wire clk,
    input  wire rst,

    // ---- node registration (host / graph loader) ----
    input  wire                                   reg_valid,
    output wire                                    reg_ready,
    input  wire [$clog2(N_NODES)-1:0]             reg_node_id,
    input  wire [$clog2(MAX_DEPS+1)-1:0]          reg_required,
    input  wire [MAX_DEPS*$clog2(N_NODES)-1:0]    reg_producer_ids,
    input  wire [ADDR_WIDTH-1:0]                   reg_x_base,
    input  wire [ADDR_WIDTH-1:0]                   reg_w_base,
    input  wire [15:0]                             reg_n_tiles,
    input  wire [ADDR_WIDTH-1:0]                   reg_result_addr,

    // ---- producer completion notification ----
    input  wire                          producer_done_valid,
    input  wire [$clog2(N_NODES)-1:0]    producer_done_node_id,

    // ---- ready job output (to neural_director.v's job_in_* port) ----
    output reg                       ready_valid,
    input  wire                      ready_ready,
    output reg  [$clog2(N_NODES)-1:0] ready_node_id,
    output reg  [ADDR_WIDTH-1:0]      ready_x_base,
    output reg  [ADDR_WIDTH-1:0]      ready_w_base,
    output reg  [15:0]                ready_n_tiles,
    output reg  [ADDR_WIDTH-1:0]      ready_result_addr
);

    localparam ST_EMPTY      = 2'd0;
    localparam ST_WAITING    = 2'd1;
    localparam ST_READY      = 2'd2;
    localparam ST_DISPATCHED = 2'd3;

    localparam NODE_IDW = $clog2(N_NODES);
    localparam REQW      = $clog2(MAX_DEPS+1);

    reg [1:0]              node_state         [0:N_NODES-1];
    reg [REQW-1:0]          node_required       [0:N_NODES-1];
    reg [REQW-1:0]          node_resolved       [0:N_NODES-1];
    reg [NODE_IDW-1:0]      node_producer_ids  [0:N_NODES-1][0:MAX_DEPS-1];
    reg [ADDR_WIDTH-1:0]    node_x_base        [0:N_NODES-1];
    reg [ADDR_WIDTH-1:0]    node_w_base        [0:N_NODES-1];
    reg [15:0]              node_n_tiles       [0:N_NODES-1];
    reg [ADDR_WIDTH-1:0]    node_result_addr   [0:N_NODES-1];

    // A node id doubles as its own table slot index (§10's example
    // literally addresses nodes by id: "node 37") -- N_NODES must
    // therefore cover the full id range a caller intends to use.
    assign reg_ready = (node_state[reg_node_id] == ST_EMPTY);

    // ---- priority-encoded first READY node (first-found scan, same
    // idiom as neural_director's own free-slot scan) ----
    reg [NODE_IDW-1:0] first_ready_idx;
    reg                any_ready;
    integer ri;
    always @(*) begin
        first_ready_idx = {NODE_IDW{1'b0}};
        any_ready       = 1'b0;
        for (ri = N_NODES-1; ri >= 0; ri = ri - 1) begin
            if (node_state[ri] == ST_READY) begin
                first_ready_idx = ri[NODE_IDW-1:0];
                any_ready       = 1'b1;
            end
        end
    end

    integer ni, di;

    always @(posedge clk) begin
        if (rst) begin
            for (ni = 0; ni < N_NODES; ni = ni + 1) begin
                node_state[ni]    <= ST_EMPTY;
                node_required[ni] <= {REQW{1'b0}};
                node_resolved[ni] <= {REQW{1'b0}};
            end
            ready_valid <= 1'b0;
        end else begin

            // ---- registration: create a new WAITING (or immediately
            // READY, if required==0) node entry. ----
            if (reg_valid && reg_ready) begin
                node_required[reg_node_id]     <= reg_required;
                node_resolved[reg_node_id]     <= {REQW{1'b0}};
                node_x_base[reg_node_id]       <= reg_x_base;
                node_w_base[reg_node_id]       <= reg_w_base;
                node_n_tiles[reg_node_id]      <= reg_n_tiles;
                node_result_addr[reg_node_id]  <= reg_result_addr;
                for (di = 0; di < MAX_DEPS; di = di + 1)
                    node_producer_ids[reg_node_id][di] <= reg_producer_ids[di*NODE_IDW +: NODE_IDW];
                node_state[reg_node_id] <= (reg_required == {REQW{1'b0}}) ? ST_READY : ST_WAITING;
            end

            // ---- wake-up: a completed producer increments
            // resolved_dependencies for EVERY WAITING node that lists
            // it, independent of the registration above (a node can
            // be registered and immediately woken by an in-flight
            // producer-done event the same cycle, since both read the
            // PRE-edge node_state/node_producer_ids consistently). ----
            if (producer_done_valid) begin
                for (ni = 0; ni < N_NODES; ni = ni + 1) begin
                    if (node_state[ni] == ST_WAITING) begin
                        for (di = 0; di < MAX_DEPS; di = di + 1) begin
                            if (di < node_required[ni] &&
                                node_producer_ids[ni][di] == producer_done_node_id) begin
                                if (node_resolved[ni] + 1'b1 >= node_required[ni])
                                    node_state[ni] <= ST_READY;
                                node_resolved[ni] <= node_resolved[ni] + 1'b1;
                            end
                        end
                    end
                end
            end

            // ---- dispatch: hand the first READY node to the
            // Director, one at a time, backpressure-safe. ----
            if (ready_valid && ready_ready) begin
                node_state[ready_node_id] <= ST_DISPATCHED;
                // ST_DISPATCHED is terminal here (M6 does not yet
                // reclaim slots for re-use -- see decisions.log
                // DEC-0008): a full graph run allocates N_NODES once.
                ready_valid <= 1'b0;
            end else if (!ready_valid && any_ready) begin
                // Deliberately NOT combined with the dispatch branch
                // above into "!ready_valid || (ready_valid&&ready_ready)"
                // -- the scan for first_ready_idx is combinational
                // over node_state's PRE-edge value, which still shows
                // the about-to-be-dispatched node as READY this same
                // edge; reloading in the same cycle as a dispatch
                // could re-present the SAME node that is simultaneously
                // transitioning to DISPATCHED. Reloading strictly the
                // cycle AFTER (once ready_valid has genuinely gone
                // low and node_state has committed) costs one extra
                // idle cycle between consecutive dispatches but is
                // unambiguously correct.
                ready_valid       <= 1'b1;
                ready_node_id     <= first_ready_idx;
                ready_x_base      <= node_x_base[first_ready_idx];
                ready_w_base      <= node_w_base[first_ready_idx];
                ready_n_tiles     <= node_n_tiles[first_ready_idx];
                ready_result_addr <= node_result_addr[first_ready_idx];
            end
        end
    end

endmodule
