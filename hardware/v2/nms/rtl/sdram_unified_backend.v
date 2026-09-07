`timescale 1ns/1ps

// ============================================================
// NMS STEP19 -- UNIFIED single-SDRAM memory backend.
//
// Replaces BOTH physical memory paths that existed through STEP18
// (sdram_weight_backend_pack128.v for weights, and hardware/v1/rtl/
// memory_interface.v + psram_controller.v for activation-fill/result-
// writeback) with ONE physical AS4C4M16SA-6TIN SDRAM chip, ONE
// sdram_controller.v instance (BURST_LEN=8), serving THREE logical
// traffic classes through TWO external ports that exactly match what
// the existing, UNCHANGED consumers already drive:
//
//   W  port (64-bit): weight_prefetch_engine_wide.v's own real
//      traffic, via slot_mem_arbiter_wide.v -- IDENTICAL external
//      contract to STEP18's sdram_weight_backend_pack128.v (byte
//      address in, 64-bit mem_rdata out), and internally reuses that
//      module's own validated N_ENTRIES=4 "other half" cache
//      unchanged (EXP-0046/ERR-0022's own fix, not re-derived here).
//
//   AR port (16-bit, byte-maskable): nms_activation_fill_ctrl_v3.v's
//      own activation reads AND every per-slot nms_memory_manager_
//      stream_wide.v's own result writes, via slot_mem_arbiter.v --
//      IDENTICAL external contract to the real V1 psram_controller.v
//      port it replaces (word address in, 16-bit mem_wdata/mem_rdata,
//      mem_lb_n/mem_ub_n byte-lane write masking). Neither
//      nms_activation_fill_ctrl_v3.v nor nms_memory_manager_stream_
//      wide.v needed ANY change -- they already produce a WORD
//      address and already drive lb_n/ub_n exactly as the real V1
//      PSRAM controller expected.
//
// Neither weight_prefetch_engine_wide.v, nms_activation_fill_ctrl_v3.
// v, nms_memory_manager_stream_wide.v, nor neural_processor.v changed
// AT ALL for this step -- this is a pure memory-side substitution,
// per the governing spec's own explicit instruction.
//
// KEY ENABLING FACT: real SDR SDRAM's own DQM pins are a per-BYTE
// write mask (STEP19's own real, tested extension to sdram_
// controller.v's `wmask` port) -- this lets a single-BYTE result
// write happen INSIDE a shared BURST_LEN=8 (128-bit) transaction by
// masking out every byte except the one/two the caller actually wants
// written, with NO read-modify-write needed at all (the real SDRAM
// chip itself leaves masked bytes untouched, by JEDEC definition).
// Activation reads need no such trick -- a full 128-bit block is
// fetched and the caller's own requested 16-bit word is extracted
// combinationally from it.
//
// Arbitration: simple, correctness-first 2-way priority (weight
// traffic strongly dominates real measured traffic -- STEP17 showed
// the activation/result path at <=7.2% of all external-memory
// activity -- so W is granted priority when both are pending, AR is
// never starved since W's own real traffic pattern always eventually
// idles between tiles/jobs). Exactly one physical SDRAM transaction
// in flight at a time (matches sdram_controller.v's own inherent
// single-transaction design, STEP18 Part E's own documented, accepted
// scope boundary -- not revisited here).
// ============================================================
module sdram_unified_backend #(
    parameter ADDR_WIDTH   = 26,  // byte address width (W port convention)
    parameter CLK_FREQ_MHZ = 64,
    parameter W_ENTRIES    = 4,   // weight-cache depth, >= real N_SLOTS
    // physical SDRAM geometry, forwarded directly to sdram_controller.v
    // (AS4C32M16SA defaults: 13 row bits/A0-A12, 10 col bits/A0-A9,
    // 2 bank bits/BA0-BA1) -- must satisfy ADDR_WIDTH-1 ==
    // BANK_BITS+ROW_BITS+COL_BITS (byte address = word address + 1 bit),
    // asserted at elaboration below.
    parameter ROW_BITS     = 13,
    parameter COL_BITS     = 10,
    parameter BANK_BITS    = 2
)(
    input  wire clk,
    input  wire rst,

    // ---- W: weight fetch (64-bit, byte address, read-only) ----
    input  wire                   w_req,
    input  wire [ADDR_WIDTH-1:0]  w_addr,
    output reg  [63:0]            w_rdata,
    output reg                    w_ready,

    // ---- AR: activation-fill (read) + result-writeback (write),
    // 16-bit, WORD address (matches the real V1 psram_controller.v
    // convention this port replaces exactly) ----
    input  wire                   ar_req,
    input  wire                   ar_wr,
    input  wire [ADDR_WIDTH-1:0]  ar_addr,   // word address, low 22 bits meaningful
                                              // (matches slot_mem_arbiter.v's own
                                              // m_addr width convention exactly --
                                              // that arbiter's real callers only ever
                                              // drive a 22-bit-significant word
                                              // address into an ADDR_WIDTH-wide bus)
    input  wire [15:0]            ar_wdata,
    input  wire                   ar_lb_n,
    input  wire                   ar_ub_n,
    output reg  [15:0]            ar_rdata,
    output reg                    ar_ready,

    output wire        sdram_cke,
    output wire        sdram_cs_n,
    output wire        sdram_ras_n,
    output wire        sdram_cas_n,
    output wire        sdram_we_n,
    output wire [BANK_BITS-1:0] sdram_ba,
    output wire [ROW_BITS-1:0]  sdram_a,
    inout  wire [15:0] sdram_dq,
    output wire [1:0]  sdram_dqm
);

    initial if (ADDR_WIDTH != BANK_BITS + ROW_BITS + COL_BITS + 1) begin
        $display("FATAL sdram_unified_backend: ADDR_WIDTH(%0d) != BANK_BITS(%0d)+ROW_BITS(%0d)+COL_BITS(%0d)+1",
            ADDR_WIDTH, BANK_BITS, ROW_BITS, COL_BITS);
        $finish;
    end

    // ============================================================
    // W-port cache (identical logic to sdram_weight_backend_pack128.v
    // -- an N_ENTRIES-deep, fully-associative "other half" cache,
    // round-robin allocated; safe under any sizing, see that module's
    // own header/ERR-0022 for the full rationale, not repeated here)
    // ============================================================
    localparam WEIDXW = (W_ENTRIES <= 1) ? 1 : $clog2(W_ENTRIES);
    reg                  w_cache_valid [0:W_ENTRIES-1];
    reg [ADDR_WIDTH-1:0] w_cache_addr  [0:W_ENTRIES-1];
    reg [63:0]           w_cache_data  [0:W_ENTRIES-1];
    reg [WEIDXW-1:0]     w_alloc_ptr;

    // ERR-0029 fix (N=8 @64MHz critical-path, measured via real P&R:
    // worst seed1 total delay 17.909ns, 84% routing, dominant hop
    // 2.5-2.8ns): the original RTL used a sequential for-loop that
    // overwrites w_hit_idx_c on every match ("last valid+matching entry
    // wins"), which Yosys/nextpnr synthesized as a serially-dependent
    // cascade of PFUMX/OFX fast-mux primitives -- each entry's result
    // depends on the previous one, forcing nextpnr to place the whole
    // chain along one physical path with no freedom to shorten it. This
    // is the same architectural fix class as ERR-0028 (activation_fill_
    // ctrl's max-tree): replace the serial dependency chain with a flat
    // one-hot compare (fully parallel, W_ENTRIES=4 comparators, no
    // inter-entry dependency) followed by a single-level priority-encode
    // casez, preserving the EXACT original "highest index wins" semantics
    // bit-for-bit (verified: original loop always ends on the highest ei
    // that matched, since ei counts up without break).
    wire [W_ENTRIES-1:0] w_match_oh;
    genvar wgi;
    generate
        for (wgi = 0; wgi < W_ENTRIES; wgi = wgi + 1) begin : GEN_WMATCH
            assign w_match_oh[wgi] = w_cache_valid[wgi] && (w_cache_addr[wgi] == w_addr);
        end
    endgenerate

    reg               w_hit_found_c;
    reg [WEIDXW-1:0]  w_hit_idx_c;
    integer ei;
    generate
        if (W_ENTRIES == 4) begin : GEN_WHIT_FLAT
            // real, measured configuration (see ERR-0029) -- flat,
            // single-level priority encode over the parallel one-hot
            // compare above, no serial inter-entry dependency.
            always @(*) begin
                w_hit_found_c = |w_match_oh;
                casez (w_match_oh)
                    4'b1???: w_hit_idx_c = 2'd3;
                    4'b01??: w_hit_idx_c = 2'd2;
                    4'b001?: w_hit_idx_c = 2'd1;
                    4'b0001: w_hit_idx_c = 2'd0;
                    default: w_hit_idx_c = {WEIDXW{1'b0}};
                endcase
            end
        end else begin : GEN_WHIT_FALLBACK
            // any other W_ENTRIES value: fall back to the original,
            // functionally-equivalent (but serially-dependent) scan --
            // not the measured/optimized configuration this project
            // actually builds, kept only for parametric safety.
            always @(*) begin
                w_hit_found_c = 1'b0;
                w_hit_idx_c   = {WEIDXW{1'b0}};
                for (ei = 0; ei < W_ENTRIES; ei = ei + 1) begin
                    if (w_cache_valid[ei] && w_cache_addr[ei] == w_addr) begin
                        w_hit_found_c = 1'b1;
                        w_hit_idx_c   = ei[WEIDXW-1:0];
                    end
                end
            end
        end
    endgenerate
    wire w_cache_hit = w_hit_found_c && w_req;

    // ============================================================
    // Shared physical controller, BURST_LEN=8 (128-bit/16-byte real
    // SDRAM transactions), reused UNCHANGED from STEP16-18.
    // ============================================================
    reg          ctrl_req;
    reg          ctrl_wr;
    reg  [ADDR_WIDTH-2:0]  ctrl_addr;
    reg  [127:0] ctrl_wdata;
    reg  [15:0]  ctrl_wmask;
    wire [127:0] ctrl_rdata;
    wire         ctrl_ready;
    wire         ctrl_busy;

    sdram_controller #(
        .CLK_FREQ_MHZ(CLK_FREQ_MHZ), .BURST_LEN(8),
        .ROW_BITS(ROW_BITS), .COL_BITS(COL_BITS), .BANK_BITS(BANK_BITS)
    ) u_sdram_ctrl (
        .clk(clk), .rst(rst),
        .req(ctrl_req), .wr(ctrl_wr), .addr(ctrl_addr),
        .wdata(ctrl_wdata), .wmask(ctrl_wmask),
        .rdata(ctrl_rdata), .ready(ctrl_ready), .busy(ctrl_busy),
        .sdram_cke(sdram_cke), .sdram_cs_n(sdram_cs_n), .sdram_ras_n(sdram_ras_n),
        .sdram_cas_n(sdram_cas_n), .sdram_we_n(sdram_we_n),
        .sdram_ba(sdram_ba), .sdram_a(sdram_a), .sdram_dq(sdram_dq), .sdram_dqm(sdram_dqm)
    );

    localparam S_IDLE      = 3'd0,
               S_W_WAIT     = 3'd1,
               S_AR_RD_WAIT = 3'd2,
               S_AR_WR_WAIT = 3'd3;
    reg [2:0] state;
    reg       w_pending_upper_half;
    reg [ADDR_WIDTH-1:0] w_pending_addr;
    reg [2:0] ar_pending_word;

    // ---- req_pending latches (same fix class as sdram_controller.v's
    // own ERR-0019/ERR-0020): this backend's own top-level S_IDLE
    // arbitration can only START a new transaction when it is
    // genuinely idle. A single-cycle w_req/ar_req pulse (this
    // project's own established mem_req convention) arriving on a
    // cycle this backend happens to be busy servicing the OTHER port
    // would otherwise be silently dropped -- the caller has no idea,
    // waits forever for a `ready` that never comes. Found the hard way
    // (STEP19, EXP-0048): the first real N=4 D-Stress run deadlocked
    // at 0/256 neurons, jobs_allocated stuck at 12, because the very
    // first activation-fill read raced against weight-prefetch traffic
    // and was lost exactly this way. Fix: latch EVERY req's own fields
    // unconditionally, every cycle, regardless of current state (not
    // just from S_IDLE), mirroring sdram_controller.v's own corrected
    // fix exactly (ERR-0020: the FIRST attempt only latched from
    // S_IDLE, which was still not enough -- latch unconditionally).
    reg                   w_req_pending;
    reg [ADDR_WIDTH-1:0]  w_req_addr_lat;
    reg                   ar_req_pending;
    reg                   ar_req_wr_lat;
    reg [ADDR_WIDTH-1:0]  ar_req_addr_lat;
    reg [15:0]            ar_req_wdata_lat;
    reg                   ar_req_lbn_lat, ar_req_ubn_lat;

    wire                  w_eff_req  = w_req || w_req_pending;
    wire [ADDR_WIDTH-1:0] w_eff_addr = w_req ? w_addr : w_req_addr_lat;
    wire                  ar_eff_req  = ar_req || ar_req_pending;
    wire                  ar_eff_wr   = ar_req ? ar_wr    : ar_req_wr_lat;
    wire [ADDR_WIDTH-1:0] ar_eff_addr = ar_req ? ar_addr  : ar_req_addr_lat;
    wire [15:0]           ar_eff_wdata= ar_req ? ar_wdata : ar_req_wdata_lat;
    wire                  ar_eff_lbn  = ar_req ? ar_lb_n  : ar_req_lbn_lat;
    wire                  ar_eff_ubn  = ar_req ? ar_ub_n  : ar_req_ubn_lat;

    wire [ADDR_WIDTH-2:0] w_eff_aligned_word_addr  = {w_eff_addr[ADDR_WIDTH-1:4], 3'b000};
    wire        w_eff_addr_is_upper_half = w_eff_addr[3];
    wire [ADDR_WIDTH-2:0] ar_eff_block_base   = {ar_eff_addr[ADDR_WIDTH-2:3], 3'b000};
    wire [2:0]  ar_eff_word_in_blk  = ar_eff_addr[2:0];

    integer ri;
    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            for (ri = 0; ri < W_ENTRIES; ri = ri + 1) w_cache_valid[ri] <= 1'b0;
            w_alloc_ptr <= {WEIDXW{1'b0}};
            ctrl_req <= 1'b0; ctrl_wr <= 1'b0; ctrl_addr <= {(ADDR_WIDTH-1){1'b0}};
            ctrl_wdata <= 128'h0; ctrl_wmask <= 16'hFFFF;
            w_ready <= 1'b0; w_rdata <= 64'h0;
            ar_ready <= 1'b0; ar_rdata <= 16'h0;
            w_pending_upper_half <= 1'b0; w_pending_addr <= {ADDR_WIDTH{1'b0}};
            ar_pending_word <= 3'h0;
            w_req_pending <= 1'b0; w_req_addr_lat <= {ADDR_WIDTH{1'b0}};
            ar_req_pending <= 1'b0; ar_req_wr_lat <= 1'b0;
            ar_req_addr_lat <= {ADDR_WIDTH{1'b0}}; ar_req_wdata_lat <= 16'h0;
            ar_req_lbn_lat <= 1'b1; ar_req_ubn_lat <= 1'b1;
        end else begin
            ctrl_req  <= 1'b0;
            w_ready   <= 1'b0;
            ar_ready  <= 1'b0;

            // latch fresh requests unconditionally, every cycle,
            // regardless of state (see req_pending's own comment above)
            if (w_req) begin
                w_req_addr_lat <= w_addr;
                w_req_pending  <= 1'b1;
            end
            if (ar_req) begin
                ar_req_wr_lat    <= ar_wr;
                ar_req_addr_lat  <= ar_addr;
                ar_req_wdata_lat <= ar_wdata;
                ar_req_lbn_lat   <= ar_lb_n;
                ar_req_ubn_lat   <= ar_ub_n;
                ar_req_pending   <= 1'b1;
            end

            case (state)
                S_IDLE: begin
                    // W has priority when both are pending (real
                    // measured traffic: weight >>> activation+result,
                    // STEP17 EXP-0045 -- AR is never starved since W's
                    // own real access pattern idles between tiles).
                    if (w_cache_hit) begin
                        // fully serviced THIS cycle -- must also cancel
                        // the unconditional latch above, which just set
                        // w_req_pending<=1 for this SAME w_req pulse
                        // (real bug found via full regression, EXP-0048
                        // /ERR-0023: without this the latch survives
                        // uncontested, and next cycle w_eff_req reads
                        // true from STALE w_req_pending/w_req_addr_lat,
                        // issuing a bogus extra fetch that shifts every
                        // subsequent response by one).
                        w_rdata              <= w_cache_data[w_hit_idx_c];
                        w_ready               <= 1'b1;
                        w_cache_valid[w_hit_idx_c] <= 1'b0;
                        w_req_pending         <= 1'b0;
                    end else if (w_eff_req) begin
                        ctrl_req  <= 1'b1;
                        ctrl_wr   <= 1'b0;
                        ctrl_addr <= w_eff_aligned_word_addr;
                        ctrl_wmask <= 16'h0000;
                        w_pending_upper_half <= w_eff_addr_is_upper_half;
                        w_pending_addr       <= w_eff_addr;
                        w_req_pending        <= 1'b0;
                        state <= S_W_WAIT;
                    end else if (ar_eff_req && !ar_eff_wr) begin
                        ctrl_req  <= 1'b1;
                        ctrl_wr   <= 1'b0;
                        ctrl_addr <= ar_eff_block_base;
                        ctrl_wmask <= 16'h0000;
                        ar_pending_word <= ar_eff_word_in_blk;
                        ar_req_pending  <= 1'b0;
                        state <= S_AR_RD_WAIT;
                    end else if (ar_eff_req && ar_eff_wr) begin
                        // mask every word except the target one; within
                        // the target word, pass ar_lb_n/ar_ub_n through
                        // directly (same active-low "write this byte"
                        // polarity as real SDRAM DQM: lb_n=0 -> DQM=0
                        // -> byte written; lb_n=1 -> DQM=1 -> masked).
                        ctrl_req  <= 1'b1;
                        ctrl_wr   <= 1'b1;
                        ctrl_addr <= ar_eff_block_base;
                        ctrl_wdata <= {8{ar_eff_wdata}}; // replicate; only the target word's mask bits matter
                        ctrl_wmask <= {16{1'b1}} & ~(16'h0003 << (ar_eff_word_in_blk*2)) | ({14'b0, ar_eff_ubn, ar_eff_lbn} << (ar_eff_word_in_blk*2));
                        ar_req_pending <= 1'b0;
                        state <= S_AR_WR_WAIT;
                    end
                end
                S_W_WAIT: begin
                    if (ctrl_ready) begin
                        if (w_pending_upper_half) begin
                            w_rdata <= ctrl_rdata[127:64];
                            w_cache_data[w_alloc_ptr] <= ctrl_rdata[63:0];
                            w_cache_addr[w_alloc_ptr] <= w_pending_addr - {{(ADDR_WIDTH-4){1'b0}}, 4'd8};
                        end else begin
                            w_rdata <= ctrl_rdata[63:0];
                            w_cache_data[w_alloc_ptr] <= ctrl_rdata[127:64];
                            w_cache_addr[w_alloc_ptr] <= w_pending_addr + {{(ADDR_WIDTH-4){1'b0}}, 4'd8};
                        end
                        w_cache_valid[w_alloc_ptr] <= 1'b1;
                        w_alloc_ptr <= (w_alloc_ptr == W_ENTRIES[WEIDXW-1:0]-1'b1) ? {WEIDXW{1'b0}} : w_alloc_ptr + 1'b1;
                        w_ready <= 1'b1;
                        state   <= S_IDLE;
                    end
                end
                S_AR_RD_WAIT: begin
                    if (ctrl_ready) begin
                        ar_rdata <= ctrl_rdata[ar_pending_word*16 +: 16];
                        ar_ready <= 1'b1;
                        state    <= S_IDLE;
                    end
                end
                S_AR_WR_WAIT: begin
                    if (ctrl_ready) begin
                        ar_ready <= 1'b1;
                        state    <= S_IDLE;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
