// ============================================================
// Neural Memory System (NMS) -- STEP 1 bandwidth requirement study.
//
// SIMULATION-ONLY, NEVER SYNTHESIZED, NOT A REAL MEMORY.
//
// Idealized single-port backing-store model: a shared pipe with two
// independently configurable, RUNTIME (not just compile-time)
// parameters:
//   cfg_latency  -- fixed cycles from "bytes fully transferred" to
//                   "response visible to the requester" (DRAM-style
//                   round-trip latency, independent of throughput).
//   cfg_bw_bytes -- aggregate bytes/cycle the shared pipe can drain,
//                   shared across however many TILE_BYTES-sized
//                   transfers are queued (sustained bandwidth).
//
// Admission is effectively unconstrained (a deep FIFO, req_ready
// combinationally follows req_valid) -- the real, modeled constraint
// is entirely in the DRAIN stage: each cycle a shared byte budget of
// cfg_bw_bytes is applied against the head of the queue, completing
// as many whole TILE_BYTES-sized transfers as the budget allows
// (zero, one, or several in the same cycle when cfg_bw_bytes is a
// multiple of TILE_BYTES) before carrying any leftover partial
// progress to the next cycle. This correctly separates BANDWIDTH
// (how many bytes/cycle the shared pipe drains, aggregate across all
// outstanding requests) from LATENCY (a fixed per-transfer delay
// applied after draining, via a FIFO of pending completions -- see
// hardware/v2/nms/logs, DEC for the first (broken) revision of this
// module: EXP-0017 attempt 1 modeled only ONE transfer in service at
// a time regardless of cfg_bw_bytes, which silently capped aggregate
// system throughput at 1 transfer/cycle and made utilization collapse
// to 1/N_SLOTS at every N_SLOTS>1 config -- a modeling bug, not a real
// architectural finding; caught by the finding being suspiciously
// exact (1/8, 1/4, 1/2 ...) instead of a physically-motivated curve).
//
// Requester ordering when several assert req_valid the same cycle is
// a fixed, low-index-first tie-break -- not fairness-relevant here
// since every requester in this study is symmetric.
// ============================================================
module ideal_memory_model #(
    parameter NREQ        = 4,
    parameter TILE_BYTES  = 16,
    parameter QDEPTH      = 256,   // max total outstanding across all requesters
    parameter MAX_ITERS   = 16,    // max queue pops/pushes processed in one cycle
    parameter TAGW        = (NREQ <= 1) ? 1 : $clog2(NREQ)
)(
    input                     clk,
    input                     rst,

    input      [15:0]         cfg_latency,     // cycles, runtime-configurable
    input      [15:0]         cfg_bw_bytes,    // bytes/cycle, runtime-configurable, min 1

    input      [NREQ-1:0]     req_valid,
    output wire [NREQ-1:0]    req_ready,       // combinational, essentially unconstrained
    output reg [NREQ-1:0]     resp_valid       // one-cycle completion pulse per requester
);

    // ---- global free-running cycle counter (absolute time base) ----
    reg [63:0] cycle_count;
    always @(posedge clk) begin
        if (rst) cycle_count <= 64'd0;
        else     cycle_count <= cycle_count + 64'd1;
    end

    wire [15:0] bw_eff = (cfg_bw_bytes == 16'd0) ? 16'd1 : cfg_bw_bytes;

    // Admission is unconstrained (QDEPTH sized generously vs. the real
    // max outstanding this study ever drives: N_SLOTS*PREFETCH_DEPTH <= 64).
    assign req_ready = req_valid;

    // ---- queue of admitted-but-not-yet-drained tags ----
    reg [TAGW-1:0] inq_tag [0:QDEPTH-1];
    reg [$clog2(QDEPTH+1)-1:0] inq_head, inq_count;

    // ---- currently-draining head item (persists partial progress across cycles) ----
    reg            head_active;
    reg [TAGW-1:0] head_tag;
    reg [31:0]     head_remain;

    // ---- latency tail FIFO (uniform latency -> strict FIFO completion order) ----
    reg [TAGW-1:0] lat_tag   [0:QDEPTH-1];
    reg [63:0]     lat_finish[0:QDEPTH-1];
    reg [$clog2(QDEPTH+1)-1:0] lat_head, lat_tail, lat_count;

    integer i, k;

    // ---- scratch (blocking-updated shadow state, committed via NBA at the end) ----
    reg [$clog2(QDEPTH+1)-1:0] s_inq_head, s_inq_count, s_lat_tail, s_lat_count;
    reg s_head_active;
    reg [TAGW-1:0] s_head_tag;
    reg [31:0] s_head_remain;
    integer s_budget;
    reg [TAGW-1:0] complete_tag [0:MAX_ITERS-1];
    integer n_complete;
    reg [$clog2(QDEPTH+1)-1:0] s_lat_head;
    integer n_popped;
    reg [TAGW-1:0] pop_tag [0:MAX_ITERS-1];

    always @(posedge clk) begin
        if (rst) begin
            inq_head <= 0; inq_count <= 0;
            head_active <= 1'b0; head_tag <= {TAGW{1'b0}}; head_remain <= 32'd0;
            lat_head <= 0; lat_tail <= 0; lat_count <= 0;
            resp_valid <= {NREQ{1'b0}};
        end else begin
            // ================= 1. admission: append every asserted
            // requester this cycle to the queue tail, low-index-first =====
            s_inq_head  = inq_head;
            s_inq_count = inq_count;
            // tail position for admission = (inq_head + inq_count) mod QDEPTH,
            // computed fresh per pushed item below.
            for (i = 0; i < NREQ; i = i + 1) begin
                if (req_valid[i]) begin
                    inq_tag[(s_inq_head + s_inq_count) % QDEPTH] <= i[TAGW-1:0];
                    s_inq_count = s_inq_count + 1;
                end
            end

            // ================= 2. drain: shared byte budget consumes the
            // queue head (and the persisted in-progress head item), possibly
            // completing several TILE_BYTES-sized transfers in one cycle ====
            s_head_active = head_active;
            s_head_tag    = head_tag;
            s_head_remain = head_remain;
            s_budget      = bw_eff;
            n_complete    = 0;

            for (k = 0; k < MAX_ITERS; k = k + 1) begin
                if (!s_head_active && s_inq_count > 0) begin
                    s_head_active = 1'b1;
                    s_head_tag    = inq_tag[s_inq_head];
                    s_head_remain = TILE_BYTES;
                    s_inq_head    = (s_inq_head + 1) % QDEPTH;
                    s_inq_count   = s_inq_count - 1;
                end
                if (s_head_active && s_budget > 0) begin
                    if (s_head_remain <= s_budget) begin
                        s_budget = s_budget - s_head_remain;
                        complete_tag[n_complete] = s_head_tag;
                        n_complete = n_complete + 1;
                        s_head_active = 1'b0;
                        s_head_remain = 32'd0;
                    end else begin
                        s_head_remain = s_head_remain - s_budget;
                        s_budget = 0;
                    end
                end
            end

            inq_head    <= s_inq_head;
            inq_count   <= s_inq_count;
            head_active <= s_head_active;
            head_tag    <= s_head_tag;
            head_remain <= s_head_remain;

            // push every completion from this cycle into the latency tail
            s_lat_tail  = lat_tail;
            s_lat_count = lat_count;
            for (i = 0; i < MAX_ITERS; i = i + 1) begin
                if (i < n_complete) begin
                    lat_tag[(s_lat_tail) % QDEPTH]    <= complete_tag[i];
                    lat_finish[(s_lat_tail) % QDEPTH] <= cycle_count + {48'd0, cfg_latency};
                    s_lat_tail = s_lat_tail + 1;
                end
            end

            // ================= 3. latency tail: pop every entry whose time
            // has come (uniform latency -> all due entries are contiguous
            // at the head, so a bounded scan suffices) =====================
            s_lat_head = lat_head;
            n_popped   = 0;
            for (k = 0; k < MAX_ITERS; k = k + 1) begin
                if ((s_lat_count > 0) && (cycle_count >= lat_finish[s_lat_head])) begin
                    pop_tag[n_popped] = lat_tag[s_lat_head];
                    n_popped   = n_popped + 1;
                    s_lat_head = (s_lat_head + 1) % QDEPTH;
                    s_lat_count = s_lat_count - 1;
                end
            end
            lat_head  <= s_lat_head;
            lat_tail  <= s_lat_tail % QDEPTH;
            // final count = old registered count + this cycle's new
            // completions (not yet poppable -- they only become visible
            // via lat_tag/lat_finish starting NEXT cycle, since those
            // array writes above are non-blocking) - this cycle's pops
            // (n_popped, drawn only from previously-registered entries).
            lat_count <= lat_count + n_complete - n_popped;

            resp_valid <= {NREQ{1'b0}};
            for (i = 0; i < MAX_ITERS; i = i + 1) begin
                if (i < n_popped) resp_valid[pop_tag[i]] <= 1'b1;
            end
        end
    end

endmodule
