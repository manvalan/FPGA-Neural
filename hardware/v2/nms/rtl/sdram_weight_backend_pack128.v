`timescale 1ns/1ps

// ============================================================
// NMS STEP18 Part C/D/F -- SDRAM weight-fetch backend, PACKED variant.
//
// Same external contract as sdram_weight_backend.v (STEP16): byte
// address in, 64-bit mem_rdata out, mem_req/mem_wr/mem_ready --
// weight_prefetch_engine_wide.v (MEM_DATA_WIDTH=64) plugs in UNCHANGED,
// and neural_processor.v is never touched. ONLY the physical transfer
// underneath changes: BURST_LEN=8 (128 bits/16 bytes per real SDRAM
// transaction, 2 P8 tiles' worth) instead of STEP16's BURST_LEN=4 (64
// bits/8 bytes, 1 tile).
//
// Design: an N_ENTRIES-deep, fully-associative "other half" cache
// holds the not-yet-requested half of each real 128-bit fetch still
// issued, tagged by its own byte address. On mem_req(addr):
//   - cache HIT (some entry's addr matches): serve instantly, no new
//     SDRAM transaction, invalidate that entry.
//   - cache MISS: issue a real BURST_LEN=8 fetch at the 16-byte-
//     aligned base covering addr, serve the HALF the caller actually
//     asked for, and cache the OTHER half (round-robin-allocated
//     entry) for a possible future hit.
//
// WHY N_ENTRIES>1 IS REQUIRED (found the hard way, EXP-0046): a first
// draft used a single-entry cache, correct in isolation (see
// tb_sdram_weight_backend_pack128.v, 20/20 PASS for one requester) but
// a REAL regression in the full N=4 system (74004 cycles vs the
// STEP16 baseline's 49430 -- WORSE, not better). Root cause: the real
// system's N_SLOTS independent memory managers all share ONE physical
// backend through slot_mem_arbiter_wide.v, which interleaves their
// requests round-robin. A single cache entry gets overwritten by
// ANOTHER slot's own "other half" before the ORIGINAL slot's own next
// (paired) request ever arrives, so nearly every access became a real
// 16-cycle miss instead of the intended ~50% instant-hit rate --
// WORSE than the STEP16 baseline's 10-cycle BURST_LEN=4 transactions.
// Fix: size the cache to N_ENTRIES (>= N_SLOTS, the real worst-case
// number of simultaneously-pending "other halves" -- each slot has at
// most ONE outstanding request at a time, by the existing memory
// manager's own design, so N_SLOTS entries can never be exceeded in
// real traffic). Round-robin eviction (not LRU) is used for
// simplicity; it is SAFE regardless of sizing accuracy, since an
// evicted-too-early entry only costs an extra real fetch (a
// performance effect), never incorrect data (a cache MISS always
// falls back to a real, address-exact fetch).
// ============================================================
module sdram_weight_backend_pack128 #(
    parameter ADDR_WIDTH   = 23,  // byte address width (project convention)
    parameter CLK_FREQ_MHZ = 80,
    parameter N_ENTRIES    = 4    // >= real N_SLOTS in the system using this backend
)(
    input  wire clk,
    input  wire rst,

    input  wire                   mem_req,
    input  wire                   mem_wr,
    input  wire [ADDR_WIDTH-1:0]  mem_addr,
    input  wire [63:0]            mem_wdata,
    output reg  [63:0]            mem_rdata,
    output reg                    mem_ready,

    output wire        sdram_cke,
    output wire        sdram_cs_n,
    output wire        sdram_ras_n,
    output wire        sdram_cas_n,
    output wire        sdram_we_n,
    output wire [1:0]  sdram_ba,
    output wire [11:0] sdram_a,
    inout  wire [15:0] sdram_dq,
    output wire [1:0]  sdram_dqm
);

    localparam EIDXW = (N_ENTRIES <= 1) ? 1 : $clog2(N_ENTRIES);

    reg                  cache_valid [0:N_ENTRIES-1];
    reg [ADDR_WIDTH-1:0] cache_addr  [0:N_ENTRIES-1];
    reg [63:0]           cache_data  [0:N_ENTRIES-1];
    reg [EIDXW-1:0]      alloc_ptr;

    reg                  hit_found_c;
    reg [EIDXW-1:0]      hit_idx_c;
    integer ei;
    always @(*) begin
        hit_found_c = 1'b0;
        hit_idx_c   = {EIDXW{1'b0}};
        for (ei = 0; ei < N_ENTRIES; ei = ei + 1) begin
            if (cache_valid[ei] && cache_addr[ei] == mem_addr) begin
                hit_found_c = 1'b1;
                hit_idx_c   = ei[EIDXW-1:0];
            end
        end
    end
    wire cache_hit = hit_found_c && mem_req && !mem_wr;

    // ---- real SDRAM controller, BURST_LEN=8 (128-bit/16-byte txns) ----
    reg         ctrl_req;
    reg         ctrl_wr;
    reg  [21:0] ctrl_addr;         // 22-bit word address (16-bit words)
    wire [127:0] ctrl_rdata;
    wire        ctrl_ready;
    wire        ctrl_busy;

    wire [21:0] aligned_word_addr = {mem_addr[ADDR_WIDTH-1:4], 3'b000}; // 16-byte-aligned word address
    wire        addr_is_upper_half = mem_addr[3]; // 1 = caller wants bytes [aligned+8 .. aligned+15]

    sdram_controller #(
        .CLK_FREQ_MHZ(CLK_FREQ_MHZ), .BURST_LEN(8), .ADDR_WIDTH(22)
    ) u_sdram_ctrl (
        .clk(clk), .rst(rst),
        .req(ctrl_req), .wr(ctrl_wr), .addr(ctrl_addr),
        .wdata(64'h0), .wmask(16'h0000), .rdata(ctrl_rdata), .ready(ctrl_ready), .busy(ctrl_busy),
        .sdram_cke(sdram_cke), .sdram_cs_n(sdram_cs_n), .sdram_ras_n(sdram_ras_n),
        .sdram_cas_n(sdram_cas_n), .sdram_we_n(sdram_we_n),
        .sdram_ba(sdram_ba), .sdram_a(sdram_a), .sdram_dq(sdram_dq), .sdram_dqm(sdram_dqm)
    );

    localparam S_IDLE = 2'd0, S_WAIT = 2'd1;
    reg [1:0] state;
    reg       pending_upper_half;
    reg [ADDR_WIDTH-1:0] pending_addr;

    integer ri;
    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            for (ri = 0; ri < N_ENTRIES; ri = ri + 1) cache_valid[ri] <= 1'b0;
            alloc_ptr <= {EIDXW{1'b0}};
            ctrl_req <= 1'b0; ctrl_wr <= 1'b0; ctrl_addr <= 22'h0;
            mem_ready <= 1'b0; mem_rdata <= 64'h0;
            pending_upper_half <= 1'b0; pending_addr <= {ADDR_WIDTH{1'b0}};
        end else begin
            ctrl_req  <= 1'b0;
            mem_ready <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (cache_hit) begin
                        mem_rdata            <= cache_data[hit_idx_c];
                        mem_ready             <= 1'b1;
                        cache_valid[hit_idx_c] <= 1'b0;
                    end else if (mem_req && !mem_wr) begin
                        ctrl_req  <= 1'b1;
                        ctrl_wr   <= 1'b0;
                        ctrl_addr <= aligned_word_addr;
                        pending_upper_half <= addr_is_upper_half;
                        pending_addr       <= mem_addr;
                        state <= S_WAIT;
                    end
                end
                S_WAIT: begin
                    if (ctrl_ready) begin
                        if (pending_upper_half) begin
                            mem_rdata <= ctrl_rdata[127:64];
                            cache_data[alloc_ptr] <= ctrl_rdata[63:0];
                            cache_addr[alloc_ptr] <= pending_addr - {{(ADDR_WIDTH-4){1'b0}}, 4'd8};
                        end else begin
                            mem_rdata <= ctrl_rdata[63:0];
                            cache_data[alloc_ptr] <= ctrl_rdata[127:64];
                            cache_addr[alloc_ptr] <= pending_addr + {{(ADDR_WIDTH-4){1'b0}}, 4'd8};
                        end
                        cache_valid[alloc_ptr] <= 1'b1;
                        alloc_ptr <= (alloc_ptr == N_ENTRIES[EIDXW-1:0]-1'b1) ? {EIDXW{1'b0}} : alloc_ptr + 1'b1;
                        mem_ready <= 1'b1;
                        state     <= S_IDLE;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
