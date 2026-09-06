`timescale 1ns/1ps

// ============================================================
// Neural Memory System (NMS) -- STEP11: real weight prefetch engine.
//
// Replaces prefetch_engine.v's per-tile single-shot usage inside
// nms_memory_manager.v with a CONTINUOUS, multi-tile fetch stream.
//
// Real analysis (see docs/architecture/nms_weight_prefetch.md and
// hardware/v2/logs/development.log): the real backend
// (hardware/v1/rtl/memory_interface.v -> psram_controller.v) is a
// fire-and-forget, ONE-transaction-in-flight-at-a-time protocol (a
// single mem_req pulse, wait for mem_ready, that IS the transaction --
// no wire-level pipelining is physically possible against this real
// backend, matching the real PSRAM's own single physical port). So
// "multiple outstanding requests" cannot mean multiple simultaneous
// WORD transactions -- it means eliminating the CONTROL-PLANE
// overhead the old design paid at every tile boundary (prefetch_engine
// return-to-IDLE, fetch_done pulse, nms_memory_manager's own
// !pf_done-gated restart, ERR-0013) and letting the fetch stream run
// CONTINUOUSLY across tile boundaries, queueing up to
// PREFETCH_DISTANCE tiles' worth of lookahead ahead of consumption
// instead of restarting control state once per tile.
//
// Tiles are always fetched in strict sequential order (0..n_tiles-1,
// never reordered, never re-fetched) -- so no per-tile state array is
// needed; two monotonic counters (fetch progress, consumption
// progress) fully describe the system, exactly like the superseded
// design, but the FETCH counter now advances continuously instead of
// stalling at each tile boundary.
// ============================================================
module weight_prefetch_engine #(
    parameter DATA_WIDTH  = 8,
    parameter P_IN        = 8,
    parameter ADDR_WIDTH  = 23,
    parameter MAX_TILES   = 16,
    parameter PREFETCH_DISTANCE = 8,
    parameter TIW   = (MAX_TILES <= 1) ? 1 : $clog2(MAX_TILES),
    parameter CNTW  = $clog2(MAX_TILES+1),
    parameter WORDS_PER_TILE = P_IN/2,
    parameter WIW   = $clog2(WORDS_PER_TILE+1)
)(
    input  wire clk,
    input  wire rst,

    // ---- job control (level-held while a job is running; the
    // consumer -- nms_memory_manager.v -- resets its OWN tile_idx to 0
    // on job_start, this engine mirrors that via job_active falling/
    // rising) ----
    input  wire                  job_active,
    input  wire [ADDR_WIDTH-1:0] w_base,      // byte address, word-aligned
    input  wire [15:0]           n_tiles,
    input  wire [CNTW-1:0]       consumed_count, // consumer's own tile_idx, bounds lookahead

    // ---- fill port into nms_weight_packed.v (this slot's own private lane) ----
    output reg                    wgt_fill_we,
    output reg  [TIW-1:0]         wgt_fill_addr,
    output reg  [DATA_WIDTH*P_IN-1:0] wgt_fill_data,

    // ---- status to consumer: tiles 0..ready_count-1 are fully resident ----
    output reg  [CNTW-1:0]        ready_count,

    // ---- real word-level PSRAM backend (matches
    // hardware/v1/rtl/memory_interface.v's contract exactly, same as
    // prefetch_engine.v's own real, proven usage) ----
    output reg                    mem_req,
    output wire                   mem_wr,
    output reg  [ADDR_WIDTH-1:0]  mem_addr,
    output wire [15:0]            mem_wdata,
    output wire                   mem_lb_n,
    output wire                   mem_ub_n,
    input  wire [15:0]            mem_rdata,
    input  wire                   mem_ready
);

    assign mem_wr    = 1'b0;
    assign mem_wdata = 16'h0000;
    assign mem_lb_n  = 1'b0; // fetch the whole word, both byte lanes
    assign mem_ub_n  = 1'b0;

    // fetch_tile/fetch_word: the NEXT word to be requested (or, while
    // req_outstanding, the word CURRENTLY in flight).
    reg [CNTW-1:0] fetch_tile;
    reg [WIW-1:0]  fetch_word;
    reg            req_outstanding;
    reg [DATA_WIDTH*P_IN-1:0] tile_buf;

    wire [ADDR_WIDTH-1:0] w_word_base = w_base[ADDR_WIDTH-1:1];

    // Don't fetch past n_tiles, and don't get more than
    // PREFETCH_DISTANCE tiles ahead of the consumer's own progress --
    // the real, configurable lookahead window (STEP11's own
    // requirement). consumed_count is the consumer's tile_idx
    // (registered, one cycle old at most -- fine, this only bounds a
    // SOFT bandwidth-shaping window, not a correctness-critical value:
    // over-fetching by one extra tile due to a one-cycle-stale compare
    // is harmless, the SRAM has room for the whole vector regardless).
    //
    // window_limit/the comparison below are computed in a FIXED 32-bit
    // width, wide enough to hold PREFETCH_DISTANCE undamaged for any
    // realistic parameter value -- an earlier version truncated
    // PREFETCH_DISTANCE down to CNTW bits before adding it
    // (PREFETCH_DISTANCE[CNTW-1:0]), which silently wrapped PFD=32 to 0
    // at MAX_TILES=16 (CNTW=5 bits), making window_limit==consumed_count
    // and more_to_fetch permanently false -- a full, real deadlock (see
    // errors.log ERR-0015, same TIW/CNTW-truncation bug class as
    // ERR-0014, this time on the newly-introduced PREFETCH_DISTANCE
    // parameter itself rather than a tile counter).
    wire [31:0] window_limit = {{(32-CNTW){1'b0}}, consumed_count} + PREFETCH_DISTANCE;
    wire more_to_fetch = job_active &&
                         ({{(16-CNTW){1'b0}}, fetch_tile} < n_tiles) &&
                         ({{(32-CNTW){1'b0}}, fetch_tile} < window_limit);

    always @(posedge clk) begin
        if (rst) begin
            fetch_tile      <= {CNTW{1'b0}};
            fetch_word      <= {WIW{1'b0}};
            ready_count     <= {CNTW{1'b0}};
            req_outstanding <= 1'b0;
            mem_req         <= 1'b0;
            wgt_fill_we     <= 1'b0;
        end else begin
            mem_req     <= 1'b0;
            wgt_fill_we <= 1'b0;

            if (!job_active) begin
                // mirrors the consumer's own job_start reset (nms_
                // memory_manager.v resets its tile_idx the same way)
                fetch_tile      <= {CNTW{1'b0}};
                fetch_word      <= {WIW{1'b0}};
                ready_count     <= {CNTW{1'b0}};
                req_outstanding <= 1'b0;
            end else if (mem_ready && req_outstanding) begin
                // A word just completed. Commit it, THEN -- same
                // cycle, not next -- decide the very next request
                // (same tile's next word, or the following tile's
                // first word): this is what makes the fetch stream
                // genuinely continuous across tile boundaries, not
                // just within one tile the way prefetch_engine.v's own
                // design already was. Computed with blocking-style
                // "next state" locals so both the commit and the next
                // request land in a single, unambiguous set of NBAs.
                req_outstanding <= 1'b0;
                tile_buf[fetch_word*16 +: 16] <= mem_rdata;

                if (fetch_word == WORDS_PER_TILE[WIW-1:0] - 1'b1) begin
                    wgt_fill_we   <= 1'b1;
                    wgt_fill_addr <= fetch_tile[TIW-1:0];
                    wgt_fill_data <= {mem_rdata, tile_buf[DATA_WIDTH*P_IN-17:0]};
                    ready_count   <= ready_count + 1'b1;
                    fetch_tile    <= fetch_tile + 1'b1;
                    fetch_word    <= {WIW{1'b0}};
                    // start the NEXT tile's first word immediately if
                    // the (post-increment) tile is still within bounds
                    if (({{(16-CNTW){1'b0}}, fetch_tile + 1'b1} < n_tiles) &&
                        ({{(32-CNTW){1'b0}}, fetch_tile + 1'b1} < window_limit)) begin
                        mem_req         <= 1'b1;
                        mem_addr        <= w_word_base + (fetch_tile + 1'b1) * WORDS_PER_TILE[CNTW-1:0];
                        req_outstanding <= 1'b1;
                    end
                end else begin
                    fetch_word <= fetch_word + 1'b1;
                    mem_req         <= 1'b1;
                    mem_addr        <= w_word_base + fetch_tile*WORDS_PER_TILE[CNTW-1:0] + {{(ADDR_WIDTH-WIW){1'b0}}, fetch_word} + 1'b1;
                    req_outstanding <= 1'b1;
                end
            end else if (!req_outstanding && more_to_fetch) begin
                // reached only when nothing has ever been requested
                // yet for this job (the very first word) -- every
                // subsequent request is issued from the branch above,
                // in the same cycle its predecessor's mem_ready
                // arrives, with zero gap, including across tile
                // boundaries.
                mem_req         <= 1'b1;
                mem_addr        <= w_word_base + fetch_tile*WORDS_PER_TILE[CNTW-1:0] + {{(ADDR_WIDTH-WIW){1'b0}}, fetch_word};
                req_outstanding <= 1'b1;
            end
        end
    end

endmodule
