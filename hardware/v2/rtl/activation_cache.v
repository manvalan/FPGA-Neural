`timescale 1ns/1ps

// ================================================================
// FPGA-Neural V2 -- Shared Activation Cache (post-M10, docs/v2-
// description.md §14; decisions.log DEC-0016)
//
// User-requested optimization #2, following the final benchmark
// campaign's own recommendation: in the realistic dense-layer
// workloads this project benchmarks (hardware/v2/docs/benchmarks/
// final-benchmark.md), many neurons in the same layer share the
// EXACT SAME activation (X) input vector -- each of dataflow_core's
// N_SLOTS memory_manager instances re-fetching that identical vector
// from PSRAM independently was real, measured, redundant traffic on
// the one shared PSRAM port. This module fetches a given X vector
// from PSRAM ONCE (tile by tile, on first use) and serves every
// subsequent request for the SAME x_base/tile directly from an
// on-chip buffer -- no PSRAM access at all on a hit.
//
// Single-tag design: one active cached x_base at a time, filled
// tile-by-tile up to `filled_up_to` (tiles [0, filled_up_to) are
// valid). A request for a DIFFERENT x_base invalidates the cache and
// restarts filling from tile 0 for the new tag. This is correct
// (never serves stale/wrong data -- a tag switch always resets
// filled_up_to, so a later request against the OLD tag is treated as
// a fresh miss, refetched from scratch) but can THRASH under
// interleaved concurrent requests for genuinely different x_base
// values (falls back to no worse than the pre-cache behavior, never
// incorrect -- see decisions.log DEC-0016 for the full analysis).
// Fine for this project's own realistic workload shape (a "layer" of
// neurons dispatched together, sharing one x_base for the whole
// phase); a multi-way cache would avoid thrashing for interleaved
// multi-layer traffic, deferred until measured to matter.
//
// Request protocol: each of N_SLOTS ports issues a ONE-CYCLE req
// pulse (x_base + tile_idx); the cache LATCHES it into a per-slot
// pending register regardless of hit/miss/fetch-in-progress state --
// the same single-entry "queue, don't drop the request" idiom already
// used by memory_manager's own pf_pending register (ERR-0006) and
// slot_mem_arbiter's own pending latch (ERR-0008) -- so a request
// arriving while the cache is busy filling a miss for another slot is
// never lost. ack pulses exactly once per request, the cycle its
// data becomes available (immediately, if already a hit at latch
// time; after the real PSRAM fetch completes, on a miss). Multiple
// slots pending on tiles that become valid the SAME cycle a fetch
// completes are all acked that same cycle (broadcast hit).
//
// Backend: word-level (16-bit + lb_n/ub_n), same convention as
// prefetch_engine.v post-DEC-0015 -- talks to memory_interface.v's
// own 16-bit word interface via the shared slot_mem_arbiter.v (one
// more arbiter port, dedicated to this cache).
// ================================================================

module activation_cache #(
    parameter DATA_WIDTH = 8,
    parameter P_IN       = 8,
    parameter ADDR_WIDTH = 23,
    parameter N_SLOTS    = 4,
    parameter MAX_TILES  = 16   // max cacheable vector length, in tiles
)(
    input  wire clk,
    input  wire rst,

    // ---- per-slot request port (one per memory_manager) ----
    input  wire [N_SLOTS-1:0]                     req,
    input  wire [ADDR_WIDTH*N_SLOTS-1:0]          req_x_base,
    input  wire [16*N_SLOTS-1:0]                  req_tile_idx,
    output reg  [N_SLOTS-1:0]                     ack,
    output reg  signed [DATA_WIDTH*P_IN*N_SLOTS-1:0] tile_x_out,

    // ---- shared backend port (word-level, -> slot_mem_arbiter.v) ----
    output reg                    mem_req,
    output reg                    mem_wr,
    output reg  [ADDR_WIDTH-1:0]  mem_addr,   // WORD address
    output reg  [15:0]            mem_wdata,  // unused (read-only), tied 0
    output reg                    mem_lb_n,
    output reg                    mem_ub_n,
    input  wire [15:0]            mem_rdata,
    input  wire                   mem_ready
);

    localparam WORDS_PER_TILE = P_IN/2;
    localparam WIW = $clog2(WORDS_PER_TILE+1);
    localparam TIW = $clog2(MAX_TILES+1);

    localparam ST_IDLE  = 1'd0;
    localparam ST_FETCH = 1'd1;

    reg               state;
    reg [ADDR_WIDTH-1:0] tag;
    reg               tag_valid;
    reg [TIW-1:0]     filled_up_to;
    reg signed [DATA_WIDTH*P_IN-1:0] tile_store [0:MAX_TILES-1];

    reg [TIW-1:0]     fetch_tile_idx;
    reg [WIW-1:0]     word_idx;

    // ---- per-slot pending-request latch (see file header) ----
    reg [N_SLOTS-1:0]            pending;
    reg [ADDR_WIDTH*N_SLOTS-1:0] pending_x_base;
    reg [16*N_SLOTS-1:0]         pending_tile_idx;

    integer pi;

    wire [N_SLOTS-1:0] hit;
    wire [N_SLOTS-1:0] miss;
    genvar gi;
    generate
        for (gi = 0; gi < N_SLOTS; gi = gi + 1) begin : GEN_HITCHK
            assign hit[gi]  = pending[gi] && tag_valid &&
                               (pending_x_base[gi*ADDR_WIDTH +: ADDR_WIDTH] == tag) &&
                               (pending_tile_idx[gi*16 +: 16] < {{(16-TIW){1'b0}}, filled_up_to});
            assign miss[gi] = pending[gi] && !hit[gi];
        end
    endgenerate

    // Fixed lowest-index-wins priority scan over MISS requests (same
    // convention as neural_director/dependency_manager/slot_mem_arbiter).
    reg [$clog2(N_SLOTS)-1:0] miss_idx;
    reg                       any_miss;
    integer mi;
    always @(*) begin
        miss_idx = '0; // '0 self-sizes for any width incl. 0 (N_SLOTS=1) -- see errors.log ERR-0009
        any_miss = 1'b0;
        for (mi = N_SLOTS-1; mi >= 0; mi = mi - 1) begin
            if (miss[mi]) begin
                miss_idx = mi[$clog2(N_SLOTS)-1:0];
                any_miss = 1'b1;
            end
        end
    end

    wire [ADDR_WIDTH-1:0] miss_x_base = pending_x_base[miss_idx*ADDR_WIDTH +: ADDR_WIDTH];
    wire                  miss_is_new_tag = !tag_valid || (miss_x_base != tag);
    wire [TIW-1:0]        next_fetch_tile = miss_is_new_tag ? {TIW{1'b0}} : filled_up_to;
    wire [ADDR_WIDTH-1:0] next_word_base  = miss_x_base[ADDR_WIDTH-1:1] +
                                             (next_fetch_tile * WORDS_PER_TILE[TIW-1:0]);

    always @(posedge clk) begin
        if (rst) begin
            state            <= ST_IDLE;
            tag              <= {ADDR_WIDTH{1'b0}};
            tag_valid        <= 1'b0;
            filled_up_to     <= {TIW{1'b0}};
            fetch_tile_idx   <= {TIW{1'b0}};
            word_idx         <= {WIW{1'b0}};
            pending          <= {N_SLOTS{1'b0}};
            pending_x_base   <= {(ADDR_WIDTH*N_SLOTS){1'b0}};
            pending_tile_idx <= {(16*N_SLOTS){1'b0}};
            ack              <= {N_SLOTS{1'b0}};
            tile_x_out       <= {(DATA_WIDTH*P_IN*N_SLOTS){1'b0}};
            mem_req          <= 1'b0;
            mem_wr           <= 1'b0;
            mem_addr         <= {ADDR_WIDTH{1'b0}};
            mem_wdata        <= 16'h0000;
            mem_lb_n         <= 1'b1;
            mem_ub_n         <= 1'b1;
        end else begin
            mem_req <= 1'b0;
            ack     <= {N_SLOTS{1'b0}};

            // Latch every incoming request pulse (never dropped, see
            // file header).
            for (pi = 0; pi < N_SLOTS; pi = pi + 1) begin
                if (req[pi]) begin
                    pending[pi]                                  <= 1'b1;
                    pending_x_base[pi*ADDR_WIDTH +: ADDR_WIDTH]   <= req_x_base[pi*ADDR_WIDTH +: ADDR_WIDTH];
                    pending_tile_idx[pi*16 +: 16]                 <= req_tile_idx[pi*16 +: 16];
                end
            end

            // Serve every currently-pending HIT this same cycle
            // (broadcast -- see file header). Safe against colliding
            // with the latch loop above: a slot only ever hits while
            // its OWN pending bit was already set on an EARLIER cycle
            // (this cycle's freshly-latched requests read `filled_up_to`/
            // `tag` at their OWN NEXT evaluation, not this one).
            for (pi = 0; pi < N_SLOTS; pi = pi + 1) begin
                if (hit[pi]) begin
                    ack[pi]        <= 1'b1;
                    tile_x_out[pi*DATA_WIDTH*P_IN +: DATA_WIDTH*P_IN] <= tile_store[pending_tile_idx[pi*16 +: 16]];
                    pending[pi]    <= 1'b0;
                end
            end

            case (state)
                ST_IDLE: begin
                    if (any_miss) begin
                        tag            <= miss_x_base;
                        tag_valid      <= 1'b1;
                        filled_up_to   <= miss_is_new_tag ? {TIW{1'b0}} : filled_up_to;
                        fetch_tile_idx <= next_fetch_tile;
                        word_idx       <= {WIW{1'b0}};
                        mem_req        <= 1'b1;
                        mem_wr         <= 1'b0;
                        mem_lb_n       <= 1'b0;
                        mem_ub_n       <= 1'b0;
                        mem_addr       <= next_word_base;
                        state          <= ST_FETCH;
                    end
                end

                ST_FETCH: begin
                    if (mem_ready) begin
                        tile_store[fetch_tile_idx][word_idx*16 +: 16] <= mem_rdata;
                        if (word_idx == WORDS_PER_TILE[WIW-1:0] - 1'b1) begin
                            filled_up_to <= fetch_tile_idx + 1'b1;
                            state        <= ST_IDLE;
                        end else begin
                            word_idx <= word_idx + 1'b1;
                            mem_req  <= 1'b1;
                            mem_wr   <= 1'b0;
                            mem_lb_n <= 1'b0;
                            mem_ub_n <= 1'b0;
                            mem_addr <= tag[ADDR_WIDTH-1:1] + fetch_tile_idx*WORDS_PER_TILE[TIW-1:0] + word_idx + 1'b1;
                        end
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
