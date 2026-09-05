`timescale 1ns/1ps

// ================================================================
// FPGA-Neural V2 -- Neural Director (M5, docs/v2-description.md §9)
//
// Dispatches job descriptors, arriving via a simple valid/ready
// producer interface, to whichever of N_SLOTS (memory_manager, M4)
// instances is currently free -- first-free scheduling (§9's initial
// policy; round-robin/least-loaded/etc are explicitly deferred to a
// later, experimentally-driven milestone, not this one).
//
// Each "slot" is one memory_manager's own job_start/x_base/w_base/
// n_tiles/result_addr/job_done interface (M4) -- the Director does
// not touch a Neural Processor directly, matching §34's division of
// labor ("Il Director gestisce WHAT deve essere eseguito... Il
// Memory Manager gestisce COME rendere disponibili i dati").
//
// Scope of THIS milestone (see hardware/v2/logs/decisions.log
// DEC-0007 for the full rationale): jobs are assumed already READY
// (no unresolved dependencies) -- dependency tracking, the waiting
// queue, and wake-up are explicitly the Dependency Manager's job
// (§10, M6, not yet built). §9's baseline FSM states
// DIR_WAIT_DEPENDENCY/DIR_COMPLETE/DIR_WAKEUP are therefore not
// separate states here; DIR_MONITOR's job (detecting a slot's
// completion) is handled by an always-active per-slot busy tracker,
// not a state the main allocate/scan loop must visit -- the same
// "don't gate concurrent per-unit progress behind a single shared
// FSM state" principle already applied to the Neural Processor's own
// FSM (DEC-0002).
// ================================================================

module neural_director #(
    parameter ADDR_WIDTH  = 23,
    parameter N_SLOTS     = 4,
    parameter QUEUE_DEPTH = 8
)(
    input  wire clk,
    input  wire rst,

    // ---- job submission (producer interface, e.g. a host or a
    //      future Dependency Manager, M6) ----
    input  wire                     job_in_valid,
    output wire                     job_in_ready,
    input  wire [ADDR_WIDTH-1:0]    job_in_x_base,
    input  wire [ADDR_WIDTH-1:0]    job_in_w_base,
    input  wire [15:0]              job_in_n_tiles,
    input  wire [ADDR_WIDTH-1:0]    job_in_result_addr,
    input  wire [15:0]              job_in_node_id,

    // ---- per-slot memory_manager job control (arrayed, §9) ----
    output reg  [N_SLOTS-1:0]              slot_job_start,
    output reg  [ADDR_WIDTH*N_SLOTS-1:0]   slot_x_base,
    output reg  [ADDR_WIDTH*N_SLOTS-1:0]   slot_w_base,
    output reg  [16*N_SLOTS-1:0]           slot_n_tiles,
    output reg  [ADDR_WIDTH*N_SLOTS-1:0]   slot_result_addr,
    // slot_node_id: which node_id is currently occupying each slot --
    // not needed by memory_manager itself (it has no notion of node
    // ids), but needed by a caller (dataflow_core.v, M7) that must
    // map a slot's job_done back to the node_id that just completed,
    // to notify the Dependency Manager (M6). Purely additive: existing
    // callers (hardware/v2/sim/tb_neural_director.v, M5) that don't
    // connect it are unaffected.
    output reg  [16*N_SLOTS-1:0]           slot_node_id,
    input  wire [N_SLOTS-1:0]              slot_job_done,

    // ---- completion notification (§9 "rilevamento dei completamenti") ----
    output reg                       job_out_done,  // one-cycle pulse
    output reg  [$clog2(N_SLOTS)-1:0] job_out_slot,

    output reg [3:0] dir_state,
    output reg       dir_error
);

    localparam DIR_IDLE       = 4'd0;
    localparam DIR_SCAN_READY = 4'd1;
    localparam DIR_ALLOCATE   = 4'd2;
    localparam DIR_ERROR      = 4'd3;

    // ---- ready queue: a plain circular FIFO of job descriptors.
    // Depth is parametric (§9 implies no fixed size); pushing and
    // popping are independent of the allocate FSM below so a new job
    // can be accepted the same cycle an old one is dispatched. ----
    localparam Q_ADDR_WIDTH = $clog2(QUEUE_DEPTH);

    reg [ADDR_WIDTH-1:0] q_x_base    [0:QUEUE_DEPTH-1];
    reg [ADDR_WIDTH-1:0] q_w_base    [0:QUEUE_DEPTH-1];
    reg [15:0]           q_n_tiles   [0:QUEUE_DEPTH-1];
    reg [ADDR_WIDTH-1:0] q_result_addr [0:QUEUE_DEPTH-1];
    reg [15:0]           q_node_id   [0:QUEUE_DEPTH-1];

    reg [Q_ADDR_WIDTH-1:0] q_head, q_tail;
    reg [Q_ADDR_WIDTH:0]   q_count; // one extra bit: 0..QUEUE_DEPTH inclusive

    wire q_empty = (q_count == 0);
    wire q_full  = (q_count == QUEUE_DEPTH[Q_ADDR_WIDTH:0]);

    assign job_in_ready = !q_full;

    // ---- per-slot busy tracking: always-active, independent of the
    // main allocate/scan FSM state (see file header). ----
    reg [N_SLOTS-1:0] slot_busy;

    wire [N_SLOTS-1:0] slot_free = ~slot_busy;
    wire                any_slot_free = |slot_free;

    // first-free slot index (priority encoder, lowest index wins --
    // "first-free", per §9's initial policy, not load-balanced).
    // Reset/default values below use '0 rather than
    // {$clog2(N_SLOTS){1'b0}} -- at N_SLOTS=1, $clog2(1)=0 makes that
    // replication a ZERO-width replication, illegal outside a
    // concatenation (IEEE 1800 11.4.12.1); found when this module was
    // first synthesized/simulated at N_SLOTS=1 by the post-M10
    // benchmark campaign (never exercised at N_SLOTS=1 through M5-M9).
    // '0 self-sizes correctly for any width, including 0.
    reg [$clog2(N_SLOTS)-1:0] free_slot_idx;
    integer fi;
    always @(*) begin
        free_slot_idx = '0;
        for (fi = N_SLOTS-1; fi >= 0; fi = fi - 1) begin
            if (slot_free[fi]) free_slot_idx = fi[$clog2(N_SLOTS)-1:0];
        end
    end

    // Priority-encoded lowest-indexed slot reporting job_done this
    // cycle (combinational, so it reflects THIS cycle's slot_job_done
    // bus directly -- a register-based "already reported one" flag
    // would read its own pre-edge value and not actually suppress a
    // second same-cycle match, see file header/DEC-0007).
    reg [$clog2(N_SLOTS)-1:0] done_slot_idx;
    integer di;
    always @(*) begin
        done_slot_idx = '0;
        for (di = N_SLOTS-1; di >= 0; di = di - 1) begin
            if (slot_job_done[di]) done_slot_idx = di[$clog2(N_SLOTS)-1:0];
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            dir_state        <= DIR_IDLE;
            dir_error        <= 1'b0;
            q_head           <= {Q_ADDR_WIDTH{1'b0}};
            q_tail           <= {Q_ADDR_WIDTH{1'b0}};
            q_count          <= {(Q_ADDR_WIDTH+1){1'b0}};
            slot_busy        <= {N_SLOTS{1'b0}};
            slot_job_start   <= {N_SLOTS{1'b0}};
            slot_x_base      <= {(ADDR_WIDTH*N_SLOTS){1'b0}};
            slot_w_base      <= {(ADDR_WIDTH*N_SLOTS){1'b0}};
            slot_n_tiles     <= {(16*N_SLOTS){1'b0}};
            slot_result_addr <= {(ADDR_WIDTH*N_SLOTS){1'b0}};
            slot_node_id     <= {(16*N_SLOTS){1'b0}};
            job_out_done     <= 1'b0;
            job_out_slot     <= '0;
        end else begin
            slot_job_start <= {N_SLOTS{1'b0}};
            job_out_done   <= 1'b0;

            // ---- Accept a new job into the ready queue (independent
            // of the allocate FSM's own state -- a producer must
            // never be blocked just because the FSM is mid-allocate
            // this cycle). ----
            if (job_in_valid && job_in_ready) begin
                q_x_base[q_tail]      <= job_in_x_base;
                q_w_base[q_tail]      <= job_in_w_base;
                q_n_tiles[q_tail]     <= job_in_n_tiles;
                q_result_addr[q_tail] <= job_in_result_addr;
                q_node_id[q_tail]     <= job_in_node_id;
                q_tail  <= (q_tail == QUEUE_DEPTH[Q_ADDR_WIDTH-1:0]-1'b1) ? {Q_ADDR_WIDTH{1'b0}} : q_tail + 1'b1;
            end

            // ---- Free a slot the instant its job_done pulses,
            // regardless of the allocate FSM's own state (DIR_MONITOR
            // absorbed here -- see file header). Cleared with a single
            // vectorized AND-NOT of the whole slot_job_done bus (not a
            // per-bit for-loop of individual NBA writes) so that TWO
            // slots completing on the SAME cycle both get freed --a
            // per-bit loop would have each iteration's non-blocking
            // write use the same pre-edge slot_busy, so only the LAST
            // matching bit would actually clear ("last write wins").
            // job_out_done/job_out_slot still report at most one
            // (the lowest-indexed) simultaneous completion per cycle
            // -- a documented simplification (decisions.log DEC-0007),
            // not a correctness issue for slot freeing itself. ----
            slot_busy <= slot_busy & ~slot_job_done;
            if (|slot_job_done) begin
                job_out_done <= 1'b1;
                job_out_slot <= done_slot_idx;
            end

            // ---- Main allocate/scan loop ----
            case (dir_state)

                DIR_IDLE: begin
                    dir_state <= DIR_SCAN_READY;
                end

                DIR_SCAN_READY: begin
                    if (!q_empty && any_slot_free) begin
                        dir_state <= DIR_ALLOCATE;
                    end
                end

                DIR_ALLOCATE: begin
                    // Dispatch the head of the queue to the first
                    // free slot found this cycle.
                    slot_job_start[free_slot_idx]                                <= 1'b1;
                    slot_x_base[free_slot_idx*ADDR_WIDTH +: ADDR_WIDTH]          <= q_x_base[q_head];
                    slot_w_base[free_slot_idx*ADDR_WIDTH +: ADDR_WIDTH]          <= q_w_base[q_head];
                    slot_n_tiles[free_slot_idx*16 +: 16]                        <= q_n_tiles[q_head];
                    slot_result_addr[free_slot_idx*ADDR_WIDTH +: ADDR_WIDTH]    <= q_result_addr[q_head];
                    slot_node_id[free_slot_idx*16 +: 16]                        <= q_node_id[q_head];
                    slot_busy[free_slot_idx] <= 1'b1;
                    q_head  <= (q_head == QUEUE_DEPTH[Q_ADDR_WIDTH-1:0]-1'b1) ? {Q_ADDR_WIDTH{1'b0}} : q_head + 1'b1;
                    dir_state <= DIR_SCAN_READY;
                end

                DIR_ERROR: begin
                    // Recoverable only via rst (§34: an error must not
                    // block the rest of the system).
                end

                default: dir_state <= DIR_ERROR;

            endcase

            // q_count tracks push/pop independently of which branch
            // above fired, so it stays correct even when a push and a
            // pop happen the same cycle.
            case ({job_in_valid && job_in_ready, (dir_state == DIR_SCAN_READY) && !q_empty && any_slot_free})
                2'b10: q_count <= q_count + 1'b1;
                2'b01: q_count <= q_count - 1'b1;
                default: q_count <= q_count; // 00: no change, 11: push+pop cancel out
            endcase
        end
    end

endmodule
