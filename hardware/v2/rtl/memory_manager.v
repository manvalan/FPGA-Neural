`timescale 1ns/1ps

// ================================================================
// FPGA-Neural V2 -- Memory Manager (M4, docs/v2-description.md §12/§15)
//
// Sits between a single Neural Processor (M1) and the WORD-level
// Memory Backend Interface (hardware/v1/rtl/memory_interface.v,
// reused UNMODIFIED, per §15 -- "NON iniziare modificando il
// controller PSRAM. Mantenere inizialmente il backend esistente").
// The processor sees only "data available" (operand_valid/ready,
// tile_last) -- never PSRAM request/wait cycles directly (§12).
//
// Post-M10 (decisions.log DEC-0015): the WEIGHT backend port talks
// directly to memory_interface.v's own 16-bit word interface instead
// of routing through int8_memory_access.v's byte-splitting layer --
// every real transaction now moves a full PSRAM word (2 bytes)
// instead of discarding half of one. int8_memory_access.v itself is
// untouched (still frozen V1); V2 simply no longer instantiates it in
// this datapath, reusing the lower (word-level) layer directly
// instead, the same "reuse what fits" precedent slot_mem_arbiter.v
// already set for hardware/v1/rtl/mem_arbiter.v.
//
// Post-M10 (decisions.log DEC-0016): the ACTIVATION (X) side is no
// longer fetched from PSRAM by this module's own prefetch_engine at
// all -- it is requested from a shared activation_cache.v instance
// (one per dataflow_core, not one per slot), which fetches a given
// X vector from PSRAM once and serves every memory_manager sharing
// that same x_base directly on-chip. Each bank therefore becomes
// ready only once BOTH its activation half (cache ack) AND its
// weight half (prefetch_engine's own pf_done, now W-only) have
// arrived -- bank_ready[b] = bank_x_ready[b] && bank_w_ready[b].
//
// Double-buffered prefetch (§13): while the processor consumes tile
// N from bank "current", this module retargets its single
// prefetch_engine instance (M4, W-only) and issues a fresh
// activation_cache request at bank "next" to fetch tile N+1
// concurrently. On tile handoff, banks swap; if a bank isn't ready in
// time, operand_valid simply stays low until it is -- a real stall,
// not hidden (§22). NOTE (measured characteristic, not yet optimized
// -- see decisions.log DEC-0006): the bank-swap-and-check control path
// itself costs a minimum 1 idle cycle per tile handoff even when the
// next bank was already prefetched in time, unlike neural_processor.v's
// own zero-gap tile acceptance.
//
// One job = one neuron's worth of tiles (n_tiles), read from x_base/
// w_base (PSRAM byte addresses), followed by writing the single INT8
// result back to result_addr.
// ================================================================

module memory_manager #(
    parameter DATA_WIDTH = 8,
    parameter P_IN       = 8,
    parameter ADDR_WIDTH = 23
)(
    input  wire clk,
    input  wire rst,

    // ---- job control (from Neural Director, M5) ----
    input  wire                      job_start,
    input  wire [ADDR_WIDTH-1:0]     x_base,
    input  wire [ADDR_WIDTH-1:0]     w_base,
    input  wire [15:0]               n_tiles,
    input  wire [ADDR_WIDTH-1:0]     result_addr,
    output reg                       job_done, // one-cycle pulse

    // ---- Neural Processor-facing operand stream (mirrors
    //      neural_processor.v's own operand port exactly) ----
    output reg                                operand_valid,
    input  wire                               operand_ready,
    output reg  signed [DATA_WIDTH*P_IN-1:0]  input_data,
    output reg  signed [DATA_WIDTH*P_IN-1:0]  weight_data,
    output reg                                tile_last,

    // ---- Neural Processor-facing result consumption ----
    input  wire                       result_valid,
    output reg                        result_ready,
    input  wire signed [DATA_WIDTH-1:0] result_data,

    // ---- shared activation_cache.v request port (post-M10 DEC-0016
    // -- one per memory_manager instance, cache is shared/instantiated
    // once per dataflow_core) ----
    output reg                     xc_req,    // one-cycle pulse
    output reg  [ADDR_WIDTH-1:0]   xc_x_base,
    output reg  [15:0]             xc_tile_idx,
    input  wire                    xc_ack,    // one-cycle pulse
    input  wire signed [DATA_WIDTH*P_IN-1:0] xc_tile_x,

    // ---- WEIGHT Memory Backend Interface (word-level, matches
    // hardware/v1/rtl/memory_interface.v's contract exactly -- see
    // prefetch_engine.v's own header and decisions.log DEC-0015/
    // DEC-0016 for why this is word-level and weight-only) ----
    output wire                    mem_req,
    output wire                    mem_wr,
    output wire [ADDR_WIDTH-1:0]   mem_addr,   // WORD address
    output wire [15:0]             mem_wdata,
    output wire                    mem_lb_n,
    output wire                    mem_ub_n,
    input  wire [15:0]             mem_rdata,
    input  wire                    mem_ready
);

    localparam MM_IDLE            = 3'd0;
    localparam MM_PREFETCH_FIRST  = 3'd1;
    localparam MM_STREAM          = 3'd2;
    localparam MM_WAIT_RESULT     = 3'd3;
    localparam MM_WRITE_RESULT    = 3'd4;
    localparam MM_DONE            = 3'd5;

    reg [2:0] state;

    reg [ADDR_WIDTH-1:0] x_base_reg, w_base_reg, result_addr_reg;
    reg [15:0]           n_tiles_reg;
    reg [15:0]           tile_idx;      // tile currently presented (bank `current`)
    reg                  current_bank;  // 0 or 1

    // ---- double-buffer storage: X half filled by the shared cache,
    // W half filled by this module's own prefetch_engine -- a bank is
    // usable once BOTH halves have arrived. ----
    reg [1:0] bank_x_ready, bank_w_ready;
    wire [1:0] bank_ready = bank_x_ready & bank_w_ready;

    reg signed [DATA_WIDTH*P_IN-1:0] bank_x [0:1];
    reg signed [DATA_WIDTH*P_IN-1:0] bank_w [0:1];

    // ---- activation_cache request bookkeeping: single-entry pending
    // (same idiom as pf_pending below -- only one outstanding cache
    // request at a time, one instance to serve, one bank as its target). ----
    reg                   xc_pending;
    reg [ADDR_WIDTH-1:0]  xc_pending_x_base;
    reg [15:0]            xc_pending_tile_idx;
    reg                   xc_pending_bank;
    // xc_target_bank is the bank the CURRENTLY-outstanding (already
    // issued) cache request will fill -- set ONLY by the issue rule
    // below, from xc_pending_bank, at the exact moment xc_req fires.
    // Queueing logic (MM_IDLE/MM_PREFETCH_FIRST/MM_STREAM) writes
    // xc_pending_bank, NEVER xc_target_bank directly -- writing
    // xc_target_bank directly from queueing was a real bug (found via
    // simulation): a later handoff can queue a NEW request (targeting
    // a DIFFERENT bank) in the same cycle an EARLIER request is being
    // issued, and program-order NBA "last write wins" would silently
    // overwrite which bank the EARLIER (already in-flight) request's
    // eventual ack gets applied to -- the exact same class of bug
    // ERR-0006 already found and fixed once for pf_target_bank/
    // pf_pending_bank (which already used this two-register pattern
    // correctly; this module's activation-cache side did not, until
    // now).
    reg                   xc_target_bank;
    // Tracks whether THIS instance's own cache request is still
    // awaiting its ack (real PSRAM miss latency can easily exceed one
    // neural_processor tile's own compute time, so a later handoff's
    // "queue the next request" can genuinely race an earlier request
    // still in flight -- the same class of race ERR-0006 already found
    // and fixed once for pf_pending/pf_busy; fixed here the same way,
    // with an explicit outstanding flag this module controls directly
    // rather than inferring busy-ness from a signal with its own
    // latency quirk).
    reg                   xc_outstanding;

    // ---- single prefetch_engine instance (WEIGHT-only post-DEC-0016),
    // retargeted per bank ----
    reg                          pf_start;
    reg  [ADDR_WIDTH-1:0]        pf_w_addr;
    wire                         pf_busy, pf_done;
    wire signed [DATA_WIDTH*P_IN-1:0] pf_tile_w;

    reg pf_target_bank; // which bank the CURRENTLY-running (or just-launched) prefetch fills

    // Single-entry pending-request register: prefetch_engine is one
    // instance, so a NEW fetch can only be launched once it has
    // genuinely returned to idle (pf_busy low) -- issuing pf_start
    // while it is still mid-fetch would silently corrupt
    // pf_target_bank for the fetch ALREADY in flight (a real bug
    // found and fixed here -- see hardware/v2/logs/errors.log
    // ERR-0006). Every "kick a prefetch" site below sets this
    // descriptor instead of touching pf_start directly; a single
    // always-active rule issues pf_start once the engine is free.
    reg                   pf_pending;
    reg [ADDR_WIDTH-1:0]  pf_pending_w;
    reg                   pf_pending_bank;

    // prefetch_engine drives its OWN internal weight-backend wires;
    // the result-write FSM below drives its own. A combinational mux
    // (never both at once, by construction -- MM_WRITE_RESULT/MM_DONE
    // only run after every tile for this job has already been fetched,
    // so prefetch_engine is guaranteed idle) selects which one actually
    // reaches the real output port, same pattern as the pre-DEC-0015
    // design, just weight-only now (the activation side moved to the
    // shared activation_cache.v, DEC-0016).
    wire                   pf_mem_req, pf_mem_wr;
    wire [ADDR_WIDTH-1:0]  pf_mem_addr;
    wire [15:0]            pf_mem_wdata;
    wire                   pf_mem_lb_n, pf_mem_ub_n;

    prefetch_engine #(
        .DATA_WIDTH(DATA_WIDTH), .P_IN(P_IN), .ADDR_WIDTH(ADDR_WIDTH)
    ) u_prefetch (
        .clk(clk), .rst(rst),
        .fetch_start(pf_start), .w_addr(pf_w_addr),
        .fetch_busy(pf_busy), .fetch_done(pf_done),
        .tile_w(pf_tile_w),
        .mem_req(pf_mem_req), .mem_wr(pf_mem_wr), .mem_addr(pf_mem_addr), .mem_wdata(pf_mem_wdata),
        .mem_lb_n(pf_mem_lb_n), .mem_ub_n(pf_mem_ub_n),
        .mem_rdata(mem_rdata), .mem_ready(mem_ready)
    );

    reg                   wr_mem_req;
    reg  [ADDR_WIDTH-1:0] wr_mem_addr;   // WORD address
    reg  [15:0]           wr_mem_wdata;
    reg                   wr_mem_lb_n, wr_mem_ub_n;

    wire wr_active = (state == MM_WRITE_RESULT) || (state == MM_DONE);
    assign mem_req   = wr_active ? wr_mem_req   : pf_mem_req;
    assign mem_wr    = wr_active ? 1'b1         : pf_mem_wr;
    assign mem_addr  = wr_active ? wr_mem_addr  : pf_mem_addr;
    assign mem_wdata = wr_active ? wr_mem_wdata : pf_mem_wdata;
    assign mem_lb_n  = wr_active ? wr_mem_lb_n  : pf_mem_lb_n;
    assign mem_ub_n  = wr_active ? wr_mem_ub_n  : pf_mem_ub_n;

    always @(posedge clk) begin
        if (rst) begin
            state           <= MM_IDLE;
            job_done        <= 1'b0;
            operand_valid   <= 1'b0;
            tile_last       <= 1'b0;
            input_data      <= {DATA_WIDTH*P_IN{1'b0}};
            weight_data     <= {DATA_WIDTH*P_IN{1'b0}};
            result_ready    <= 1'b0;
            pf_start        <= 1'b0;
            current_bank    <= 1'b0;
            bank_x_ready    <= 2'b00;
            bank_w_ready    <= 2'b00;
            tile_idx        <= 16'h0;
            pf_pending      <= 1'b0;
            xc_req          <= 1'b0;
            xc_pending      <= 1'b0;
            xc_outstanding  <= 1'b0;
            wr_mem_req      <= 1'b0;
            wr_mem_addr     <= {ADDR_WIDTH{1'b0}};
            wr_mem_wdata    <= 16'h0000;
            wr_mem_lb_n     <= 1'b1;
            wr_mem_ub_n     <= 1'b1;
        end else begin
            job_done     <= 1'b0;
            pf_start     <= 1'b0;
            xc_req       <= 1'b0;
            result_ready <= 1'b0;

            // Latch a completed weight prefetch into its target bank.
            if (pf_done) begin
                bank_w[pf_target_bank]    <= pf_tile_w;
                bank_w_ready[pf_target_bank] <= 1'b1;
            end

            // Latch a completed activation-cache fetch into its target
            // bank and clear the outstanding flag (see its own
            // declaration comment above).
            if (xc_ack) begin
                bank_x[xc_target_bank]    <= xc_tile_x;
                bank_x_ready[xc_target_bank] <= 1'b1;
                xc_outstanding <= 1'b0;
            end

            // Issue a pending weight fetch as soon as the (single)
            // prefetch engine is genuinely free. The `!pf_start` guard
            // is required, not cosmetic -- see hardware/v2/logs/
            // errors.log ERR-0006.
            if (pf_pending && !pf_busy && !pf_start) begin
                pf_start       <= 1'b1;
                pf_w_addr      <= pf_pending_w;
                pf_target_bank <= pf_pending_bank;
                pf_pending     <= 1'b0;
            end

            // Issue a pending activation-cache request only once this
            // instance's own PREVIOUS request has been genuinely acked
            // (xc_outstanding low) -- see that flag's own declaration
            // comment for why checking xc_req alone is not enough.
            if (xc_pending && !xc_outstanding) begin
                xc_req         <= 1'b1;
                xc_outstanding <= 1'b1;
                xc_x_base      <= xc_pending_x_base;
                xc_tile_idx    <= xc_pending_tile_idx;
                xc_target_bank <= xc_pending_bank;
                xc_pending     <= 1'b0;
            end

            case (state)

                MM_IDLE: begin
                    if (job_start) begin
                        x_base_reg      <= x_base;
                        w_base_reg      <= w_base;
                        n_tiles_reg     <= n_tiles;
                        result_addr_reg <= result_addr;
                        tile_idx        <= 16'h0;
                        current_bank    <= 1'b0;
                        bank_x_ready    <= 2'b00;
                        bank_w_ready    <= 2'b00;
                        operand_valid   <= 1'b0;
                        // kick off the very first fetch (tile 0 into bank 0)
                        pf_pending      <= 1'b1;
                        pf_pending_w    <= w_base;
                        pf_pending_bank <= 1'b0;
                        xc_pending          <= 1'b1;
                        xc_pending_x_base   <= x_base;
                        xc_pending_tile_idx <= 16'h0;
                        xc_pending_bank      <= 1'b0;
                        state           <= MM_PREFETCH_FIRST;
                    end
                end

                MM_PREFETCH_FIRST: begin
                    if (bank_ready[0]) begin
                        // Present tile 0; concurrently start prefetching
                        // tile 1 into bank 1, if there is one.
                        operand_valid <= 1'b1;
                        input_data    <= bank_x[0];
                        weight_data   <= bank_w[0];
                        tile_last     <= (n_tiles_reg == 16'h1);
                        if (n_tiles_reg > 16'h1) begin
                            pf_pending      <= 1'b1;
                            pf_pending_w    <= w_base_reg + P_IN[ADDR_WIDTH-1:0];
                            pf_pending_bank <= 1'b1;
                            xc_pending          <= 1'b1;
                            xc_pending_x_base   <= x_base_reg;
                            xc_pending_tile_idx <= 16'h1;
                            xc_pending_bank      <= 1'b1;
                        end
                        state <= MM_STREAM;
                    end
                end

                MM_STREAM: begin
                    if (operand_valid && operand_ready) begin
                        // This tile consumed; free its bank, swap.
                        bank_x_ready[current_bank] <= 1'b0;
                        bank_w_ready[current_bank] <= 1'b0;
                        current_bank <= ~current_bank;
                        tile_idx     <= tile_idx + 16'h1;
                        operand_valid <= 1'b0; // re-asserted below once the new bank is ready

                        if (tile_idx + 16'h1 == n_tiles_reg) begin
                            // That was the last tile -- nothing more to present.
                            state <= MM_WAIT_RESULT;
                        end else if (tile_idx + 16'h2 < n_tiles_reg) begin
                            // Queue a prefetch for the tile AFTER next into
                            // the bank we just freed (current_bank, pre-swap).
                            pf_pending      <= 1'b1;
                            pf_pending_w    <= w_base_reg + (tile_idx + 16'h2) * P_IN[ADDR_WIDTH-1:0];
                            pf_pending_bank <= current_bank; // the one just freed
                            xc_pending          <= 1'b1;
                            xc_pending_x_base   <= x_base_reg;
                            xc_pending_tile_idx <= tile_idx + 16'h2;
                            xc_pending_bank      <= current_bank;
                        end
                    end else if (!operand_valid) begin
                        // Waiting for the new current bank to become ready
                        // (either just swapped, or a stall still in
                        // progress).
                        if (bank_ready[current_bank] && tile_idx < n_tiles_reg) begin
                            operand_valid <= 1'b1;
                            input_data    <= bank_x[current_bank];
                            weight_data   <= bank_w[current_bank];
                            tile_last     <= (tile_idx == n_tiles_reg - 16'h1);
                        end
                    end
                end

                MM_WAIT_RESULT: begin
                    result_ready <= 1'b1;
                    if (result_valid && result_ready) begin
                        // Replicate int8_memory_access.v's own byte-
                        // select convention exactly (addr[0]==0 -> low
                        // byte, addr[0]==1 -> high byte) since that
                        // module is no longer in the datapath -- see
                        // prefetch_engine.v's header/decisions.log
                        // DEC-0015.
                        wr_mem_wdata <= result_addr_reg[0] ? {result_data, 8'h00} : {8'h00, result_data};
                        wr_mem_lb_n  <= result_addr_reg[0] ? 1'b1 : 1'b0;
                        wr_mem_ub_n  <= result_addr_reg[0] ? 1'b0 : 1'b1;
                        state        <= MM_WRITE_RESULT;
                    end
                end

                MM_WRITE_RESULT: begin
                    // prefetch_engine is guaranteed idle here (no more
                    // tiles to fetch for this job), so driving the
                    // shared weight backend port directly is safe --
                    // see file header/wr_active above.
                    wr_mem_req  <= 1'b1;
                    wr_mem_addr <= result_addr_reg[ADDR_WIDTH-1:1]; // byte -> word
                    state       <= MM_DONE;
                end

                MM_DONE: begin
                    wr_mem_req <= 1'b0;
                    if (mem_ready) begin
                        job_done <= 1'b1;
                        state    <= MM_IDLE;
                    end
                end

                default: state <= MM_IDLE;

            endcase
        end
    end

endmodule
