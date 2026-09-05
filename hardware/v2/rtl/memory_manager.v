`timescale 1ns/1ps

// ================================================================
// FPGA-Neural V2 -- Memory Manager (M4, docs/v2-description.md §12/§15)
//
// Sits between a single Neural Processor (M1) and the byte-level
// Memory Backend Interface (hardware/v1/rtl/int8_memory_access.v,
// reused UNMODIFIED, per §15 -- "NON iniziare modificando il
// controller PSRAM. Mantenere inizialmente il backend esistente").
// The processor sees only "data available" (operand_valid/ready,
// tile_last) -- never PSRAM request/wait cycles directly (§12).
//
// Double-buffered prefetch (§13): while the processor consumes tile
// N from bank "current", this module retargets the single
// prefetch_engine instance (M4) at bank "next" to fetch tile N+1
// concurrently. On tile handoff, banks swap; if a bank isn't ready in
// time (prefetch slower than compute for this run), operand_valid
// simply stays low until it is -- a real stall, not hidden, so its
// frequency is genuinely measurable (§22, deferred to M9). NOTE
// (measured characteristic, not yet optimized -- see
// hardware/v2/logs/decisions.log DEC-0006): the bank-swap-and-check
// control path itself costs a minimum 1 idle cycle per tile handoff
// even when the next bank was already prefetched in time, unlike
// neural_processor.v's own zero-gap tile acceptance -- a real,
// deliberately-not-hidden overhead of this first Memory Manager
// implementation, left for M10 (Optimization) to revisit with real
// stall-percentage data (§22) rather than optimized blindly now.
//
// One job = one neuron's worth of tiles (n_tiles), read from x_base/
// w_base (PSRAM byte addresses), followed by writing the single
// INT8 result back to result_addr. The result write only happens
// after the last tile has been handed off and prefetch_engine is
// idle (temporally disjoint from prefetching by construction), so no
// separate backend arbiter is needed at this milestone -- see
// decisions.log DEC-0006 for why, and what changes once multiple
// concurrent jobs/processors need to share one backend port
// (deferred, not yet needed).
// ================================================================

module memory_manager #(
    parameter DATA_WIDTH = 8,
    parameter P_IN       = 8,
    parameter ADDR_WIDTH = 23
)(
    input  wire clk,
    input  wire rst,

    // ---- job control (from a future Neural Director, M5; driven
    //      directly by a testbench at M4) ----
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

    // ---- Memory Backend Interface (matches int8_memory_access.v) ----
    output wire                    mem_req,
    output wire                    mem_wr,
    output wire [ADDR_WIDTH-1:0]   mem_addr,
    output wire signed [7:0]       mem_wdata,
    input  wire signed [7:0]       mem_rdata,
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

    reg [1:0] bank_ready; // bank_ready[b] = bank b holds valid, unconsumed prefetched data

    // ---- double-buffer storage (owned here, filled by prefetch_engine) ----
    reg signed [DATA_WIDTH*P_IN-1:0] bank_x [0:1];
    reg signed [DATA_WIDTH*P_IN-1:0] bank_w [0:1];

    // ---- single prefetch_engine instance, retargeted per bank ----
    reg                          pf_start;
    reg  [ADDR_WIDTH-1:0]        pf_x_addr, pf_w_addr;
    wire                         pf_busy, pf_done;
    wire signed [DATA_WIDTH*P_IN-1:0] pf_tile_x, pf_tile_w;

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
    reg [ADDR_WIDTH-1:0]  pf_pending_x, pf_pending_w;
    reg                   pf_pending_bank;

    // prefetch_engine drives its OWN internal backend wires; the
    // result-write FSM below drives its own. A combinational mux
    // (never both at once, by construction -- see file header)
    // selects which one actually reaches the real output port,
    // avoiding a two-driver conflict on mem_req/mem_wr/mem_addr/
    // mem_wdata.
    wire                   pf_mem_req, pf_mem_wr;
    wire [ADDR_WIDTH-1:0]  pf_mem_addr;
    wire signed [7:0]      pf_mem_wdata;

    prefetch_engine #(
        .DATA_WIDTH(DATA_WIDTH), .P_IN(P_IN), .ADDR_WIDTH(ADDR_WIDTH)
    ) u_prefetch (
        .clk(clk), .rst(rst),
        .fetch_start(pf_start), .x_addr(pf_x_addr), .w_addr(pf_w_addr),
        .fetch_busy(pf_busy), .fetch_done(pf_done),
        .tile_x(pf_tile_x), .tile_w(pf_tile_w),
        .mem_req(pf_mem_req), .mem_wr(pf_mem_wr), .mem_addr(pf_mem_addr), .mem_wdata(pf_mem_wdata),
        .mem_rdata(mem_rdata), .mem_ready(mem_ready)
    );

    reg                   wr_mem_req;
    reg  [ADDR_WIDTH-1:0] wr_mem_addr;
    reg  signed [7:0]     wr_mem_wdata;

    // wr_mem_req is SET while state==MM_WRITE_RESULT but only becomes
    // valid (via NBA) the FOLLOWING cycle, i.e. while state==MM_DONE --
    // the mux must select the write-back source across BOTH states,
    // not just the one that issues it (an off-by-one here silently
    // dropped the write request entirely -- found and fixed here, see
    // hardware/v2/logs/errors.log ERR-0006).
    wire wr_active = (state == MM_WRITE_RESULT) || (state == MM_DONE);
    assign mem_req   = wr_active ? wr_mem_req   : pf_mem_req;
    assign mem_wr    = wr_active ? 1'b1         : pf_mem_wr;
    assign mem_addr  = wr_active ? wr_mem_addr  : pf_mem_addr;
    assign mem_wdata = wr_active ? wr_mem_wdata : pf_mem_wdata;

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
            bank_ready      <= 2'b00;
            tile_idx        <= 16'h0;
            wr_mem_req      <= 1'b0;
            wr_mem_addr     <= {ADDR_WIDTH{1'b0}};
            wr_mem_wdata    <= 8'sd0;
            pf_pending      <= 1'b0;
        end else begin
            job_done     <= 1'b0;
            pf_start     <= 1'b0;
            result_ready <= 1'b0;

            // Latch a completed prefetch into its target bank.
            if (pf_done) begin
                bank_x[pf_target_bank]    <= pf_tile_x;
                bank_w[pf_target_bank]    <= pf_tile_w;
                bank_ready[pf_target_bank] <= 1'b1;
            end

            // Issue a pending fetch request as soon as the (single)
            // prefetch engine is genuinely free. The `!pf_start` guard
            // is required, not cosmetic: pf_busy does not read 1 until
            // the cycle AFTER pf_start was first observed (prefetch_
            // engine's own fetch_busy<=1 is one clock behind its own
            // fetch_start sampling), so checking !pf_busy alone leaves
            // a genuine one-cycle window where a second pending
            // request would fire on top of the one just launched,
            // silently corrupting pf_target_bank for the fetch already
            // in flight (found and fixed here -- see
            // hardware/v2/logs/errors.log ERR-0006).
            if (pf_pending && !pf_busy && !pf_start) begin
                pf_start       <= 1'b1;
                pf_x_addr      <= pf_pending_x;
                pf_w_addr      <= pf_pending_w;
                pf_target_bank <= pf_pending_bank;
                pf_pending     <= 1'b0;
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
                        bank_ready      <= 2'b00;
                        operand_valid   <= 1'b0;
                        // kick off the very first fetch (tile 0 into bank 0)
                        pf_pending      <= 1'b1;
                        pf_pending_x    <= x_base;
                        pf_pending_w    <= w_base;
                        pf_pending_bank <= 1'b0;
                        state           <= MM_PREFETCH_FIRST;
                    end
                end

                MM_PREFETCH_FIRST: begin
                    if (bank_ready[0] || (pf_done && pf_target_bank == 1'b0)) begin
                        // Present tile 0; concurrently start prefetching
                        // tile 1 into bank 1, if there is one.
                        operand_valid <= 1'b1;
                        input_data    <= pf_done ? pf_tile_x : bank_x[0];
                        weight_data   <= pf_done ? pf_tile_w : bank_w[0];
                        tile_last     <= (n_tiles_reg == 16'h1);
                        if (n_tiles_reg > 16'h1) begin
                            pf_pending      <= 1'b1;
                            pf_pending_x    <= x_base_reg + P_IN[ADDR_WIDTH-1:0];
                            pf_pending_w    <= w_base_reg + P_IN[ADDR_WIDTH-1:0];
                            pf_pending_bank <= 1'b1;
                        end
                        state <= MM_STREAM;
                    end
                end

                MM_STREAM: begin
                    if (operand_valid && operand_ready) begin
                        // This tile consumed; free its bank, swap.
                        bank_ready[current_bank] <= 1'b0;
                        current_bank <= ~current_bank;
                        tile_idx     <= tile_idx + 16'h1;
                        operand_valid <= 1'b0; // re-asserted below once the new bank is ready

                        if (tile_idx + 16'h1 == n_tiles_reg) begin
                            // That was the last tile -- nothing more to present.
                            state <= MM_WAIT_RESULT;
                        end else if (tile_idx + 16'h2 < n_tiles_reg) begin
                            // Queue a prefetch for the tile AFTER next into
                            // the bank we just freed (current_bank, pre-swap)
                            // -- it will actually launch once the (single)
                            // prefetch engine is free (see the pf_pending
                            // issue rule above); it is very likely still
                            // busy with the tile-N+1 fetch kicked off on the
                            // PREVIOUS handoff, so this almost always queues
                            // rather than launching immediately.
                            pf_pending      <= 1'b1;
                            pf_pending_x    <= x_base_reg + (tile_idx + 16'h2) * P_IN[ADDR_WIDTH-1:0];
                            pf_pending_w    <= w_base_reg + (tile_idx + 16'h2) * P_IN[ADDR_WIDTH-1:0];
                            pf_pending_bank <= current_bank; // the one just freed
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
                        wr_mem_wdata <= result_data;
                        state        <= MM_WRITE_RESULT;
                    end
                end

                MM_WRITE_RESULT: begin
                    // prefetch_engine is guaranteed idle here (no more
                    // tiles to fetch for this job), so driving the shared
                    // backend port directly is safe -- see file header.
                    wr_mem_req  <= 1'b1;
                    wr_mem_addr <= result_addr_reg;
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
