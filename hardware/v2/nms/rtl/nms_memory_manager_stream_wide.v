// ============================================================
// Neural Memory System (NMS) -- STEP13: per-slot memory manager,
// PIPELINED CONTINUOUS TILE STREAM variant ("_stream").
//
// Identical external interface to nms_memory_manager_pf.v (drop-in,
// same Director/Dependency-Manager side, same Neural-Processor-facing
// operand/result streams, same weight_prefetch_engine.v instance) --
// the ONLY change is INSIDE ST_RUN: the operand-delivery pipeline that
// feeds neural_processor.v.
//
// EXP-0025 traced nms_memory_manager_pf.v's own ST_RUN state with a
// zero-real-memory-latency configuration and found it costs EXACTLY 4
// cycles/tile in steady state (read_issued -> read_ready -> present
// -> consumed, a strictly sequential if/else-if chain with ZERO
// overlap between consecutive tiles), even though neither side of the
// interface requires it: the local activation/weight SRAMs
// (nms_activation_replicated.v / nms_weight_packed.v) have only a
// 1-cycle rd_en-to-data latency, and neural_processor.v's own
// operand_ready is held continuously high through the whole
// NP_WAIT_OPERANDS phase (its datapath is explicitly designed to
// accept a new tile every cycle). That 4-cycles/tile serialization
// was found to account for 93.4% of EXP-0024's real, measured
// "non-memory" cycle floor (DEC-0024) -- the dominant real bottleneck,
// NOT per-job dispatch overhead.
//
// This variant replaces ST_RUN's 4-state chain with a pipelined
// read-ahead design:
//   - `rd_ptr` (CNTW bits): the tile index whose SRAM read has been
//     (or is about to be) ISSUED -- independent of, and normally one
//     tile AHEAD of, `tile_idx` (the CONSUMPTION pointer, i.e. how
//     many tiles neural_processor.v has actually accepted).
//   - a 1-deep skid buffer (`buf_valid`/`buf_input`/`buf_weight`/
//     `buf_last`) holds one tile's fully-read SRAM data, presented to
//     NP as `operand_valid`/`input_data`/`weight_data`/`tile_last`.
//   - every cycle: if a read was issued last cycle (`rd_pending`), its
//     data is now valid (1-cycle SRAM latency) and is captured into
//     the skid buffer; independently, a NEW read is issued for
//     `rd_ptr` whenever it is legal to do so (in bounds, weight+
//     activation ready) AND the skid buffer will not overflow (it is
//     empty, or being drained -- consumed -- this very same cycle).
// Since NP's own operand_ready is continuously high through the tile-
// loading phase, the skid buffer is drained every cycle it is full,
// so a new read can be issued every cycle too: sustained ~1 cycle/
// tile, down from 4 -- a real ~4x reduction in the dominant component
// of EXP-0024's measured floor.
//
// `tile_idx` (the CONSUMPTION pointer) is still what is fed to
// weight_prefetch_engine.v's own `consumed_count` port -- its
// external contract (bound the lookahead window against how far the
// CONSUMER has progressed) is unchanged; only the local SRAM
// read-issue pointer (`rd_ptr`) is new, and it can run up to ONE tile
// ahead of `tile_idx` (the skid buffer's own depth), same as before
// conceptually (read_issued/read_ready already implied a similar
// small lookahead, just serialized rather than pipelined).
//
// nms_memory_manager_pf.v itself is UNTOUCHED -- this file exists
// alongside it (and alongside the original nms_memory_manager.v) so
// all three ("Current NMS", "NMS + weight prefetch",
// "NMS + weight prefetch + continuous tile stream") remain
// independently reproducible for A/B/C comparison.
// ============================================================
module nms_memory_manager_stream_wide #(
    parameter MEM_DATA_WIDTH = 64,
    parameter DATA_WIDTH = 8,
    parameter P_IN       = 8,
    parameter ADDR_WIDTH = 23,
    parameter MAX_TILES  = 16,
    parameter PREFETCH_DISTANCE = 8,
    parameter TIW        = (MAX_TILES <= 1) ? 1 : $clog2(MAX_TILES),
    parameter CNTW        = $clog2(MAX_TILES+1)
)(
    input  wire clk,
    input  wire rst,

    input  wire                      job_start,
    input  wire [ADDR_WIDTH-1:0]     x_base,
    input  wire [ADDR_WIDTH-1:0]     w_base,
    input  wire [15:0]               n_tiles,
    input  wire [ADDR_WIDTH-1:0]     result_addr,
    output reg                       job_done,

    output wire                                operand_valid,
    input  wire                               operand_ready,
    output wire signed [DATA_WIDTH*P_IN-1:0]  input_data,
    output wire signed [DATA_WIDTH*P_IN-1:0]  weight_data,
    output wire                                tile_last,

    input  wire                       result_valid,
    output reg                        result_ready,
    input  wire signed [DATA_WIDTH-1:0] result_data,

    output wire            job_active,
    output wire [ADDR_WIDTH-1:0] job_x_base,
    output wire [15:0]     job_n_tiles,

    input  wire [ADDR_WIDTH-1:0] act_resident_tag,
    input  wire [CNTW-1:0]       act_resident_count,

    output reg              act_rd_en,
    output reg  [TIW-1:0]   act_rd_addr,
    input  wire signed [DATA_WIDTH*P_IN-1:0] act_rd_data,

    // ---- weight SRAM fill port driven by weight_prefetch_engine
    // (below), NOT by this FSM directly -- read port unchanged ----
    output wire              wgt_fill_we,
    output wire [TIW-1:0]    wgt_fill_addr,
    output wire [DATA_WIDTH*P_IN-1:0] wgt_fill_data,
    output reg              wgt_rd_en,
    output reg  [TIW-1:0]   wgt_rd_addr,
    input  wire signed [DATA_WIDTH*P_IN-1:0] wgt_rd_data,

    // ---- result write-back only in this experimental variant (real
    // 16-bit-word protocol, matches memory_interface.v exactly) --
    // weight fetch uses the separate wide logical port below instead
    // of sharing this one, since this variant exists purely to
    // explore logical weight-path width in isolation (STEP14 Part A).
    output wire                    mem_req,
    output wire                    mem_wr,
    output wire [ADDR_WIDTH-1:0]   mem_addr,
    output wire [15:0]             mem_wdata,
    output wire                    mem_lb_n,
    output wire                    mem_ub_n,
    input  wire [15:0]             mem_rdata,
    input  wire                    mem_ready,

    // ---- separate wide logical weight-fetch port (ideal_memory_
    // model_wide.v or a real packing adapter, STEP14 Part A/A5) ----
    output wire                        wide_mem_req,
    output wire [ADDR_WIDTH-1:0]       wide_mem_addr,
    input  wire [MEM_DATA_WIDTH-1:0]   wide_mem_rdata,
    input  wire                        wide_mem_ready
);

    localparam ST_IDLE        = 3'd0;
    localparam ST_RUN         = 3'd1;
    localparam ST_WAIT_RESULT = 3'd2;
    localparam ST_WRITE_RES   = 3'd3;
    localparam ST_DONE        = 3'd4;

    reg [2:0] state;
    reg job_active_reg;
    reg [ADDR_WIDTH-1:0] x_base_reg, w_base_reg, result_addr_reg;
    reg [15:0]           n_tiles_reg;
    reg [CNTW-1:0]       tile_idx;   // CONSUMPTION pointer (tiles handed to NP so far)
    reg [CNTW-1:0]       rd_ptr;     // READ-ISSUE pointer (tiles whose SRAM read has been issued)

    assign job_active  = job_active_reg;
    assign job_x_base  = x_base_reg;
    assign job_n_tiles = n_tiles_reg;

    // Result write-back port regs (moved up from their original,
    // later position in this file -- STEP20 tooling-compatibility
    // fix, zero behavior change: module-scope reg declarations are
    // not order-dependent in real Verilog semantics, but a icarus
    // Verilog 13.0 elaborates `always` blocks in file order and
    // requires a reg's declaration to textually precede its first
    // use inside one; this file predates that stricter check).
    reg                   wr_mem_req;
    reg  [ADDR_WIDTH-1:0] wr_mem_addr;
    reg  [15:0]           wr_mem_wdata;
    reg                   wr_mem_lb_n, wr_mem_ub_n;

    wire [CNTW-1:0] wgt_ready_count;

    wire usable_act_count_valid = (act_resident_tag == x_base_reg);
    wire [CNTW-1:0] usable_act = usable_act_count_valid ? act_resident_count : {CNTW{1'b0}};

    // Gating for the READ-ISSUE pointer (rd_ptr), same semantics as
    // the old can_present but evaluated against rd_ptr instead of
    // tile_idx, since reads may now run ahead of consumption.
    wire can_issue_rd = ({{(16-CNTW){1'b0}}, rd_ptr} < n_tiles_reg) &&
                        (rd_ptr < wgt_ready_count) &&
                        (rd_ptr < usable_act);

    // ---- pipelined read-ahead + 1-deep skid buffer ----
    reg                          rd_pending;   // a read issued last cycle; its data is valid THIS cycle
    reg  [CNTW-1:0]              rd_pending_tile;
    reg                          rd_pending_last;
    reg                          buf_valid;
    reg  signed [DATA_WIDTH*P_IN-1:0] buf_input, buf_weight;
    reg                          buf_last;

    assign operand_valid = buf_valid;
    assign input_data    = buf_input;
    assign weight_data   = buf_weight;
    assign tile_last     = buf_last;

    // May issue a new read this cycle iff the skid buffer will not
    // overflow: it's currently empty, or it is being drained
    // (consumed) THIS cycle.
    wire buf_will_be_free = !buf_valid || (operand_valid && operand_ready);
    wire issue_rd_now     = (state == ST_RUN) && can_issue_rd && buf_will_be_free;

    always @(posedge clk) begin
        if (rst) begin
            state          <= ST_IDLE;
            job_active_reg <= 1'b0;
            job_done       <= 1'b0;
            result_ready   <= 1'b0;
            tile_idx       <= {CNTW{1'b0}};
            rd_ptr         <= {CNTW{1'b0}};
            rd_pending     <= 1'b0;
            buf_valid      <= 1'b0;
            act_rd_en      <= 1'b0;
            wgt_rd_en      <= 1'b0;
            wr_mem_req     <= 1'b0;
            wr_mem_lb_n    <= 1'b1;
            wr_mem_ub_n    <= 1'b1;
        end else begin
            job_done     <= 1'b0;
            act_rd_en    <= 1'b0;
            wgt_rd_en    <= 1'b0;
            result_ready <= 1'b0;

            case (state)
                ST_IDLE: begin
                    if (job_start) begin
                        x_base_reg      <= x_base;
                        w_base_reg      <= w_base;
                        n_tiles_reg     <= n_tiles;
                        result_addr_reg <= result_addr;
                        tile_idx        <= {CNTW{1'b0}};
                        rd_ptr          <= {CNTW{1'b0}};
                        rd_pending      <= 1'b0;
                        buf_valid       <= 1'b0;
                        job_active_reg  <= 1'b1;
                        state           <= ST_RUN;
                    end
                end

                ST_RUN: begin
                    // ---- Step 1: a read issued LAST cycle lands now ----
                    if (rd_pending) begin
                        buf_valid  <= 1'b1;
                        buf_input  <= act_rd_data;
                        buf_weight <= wgt_rd_data;
                        buf_last   <= rd_pending_last;
                    end else if (operand_valid && operand_ready) begin
                        // no new data arriving this cycle -- if the
                        // buffer is being drained and nothing refills
                        // it, it goes empty.
                        buf_valid <= 1'b0;
                    end

                    // ---- Step 2: consumption bookkeeping ----
                    if (operand_valid && operand_ready) begin
                        if ({{(16-CNTW){1'b0}}, tile_idx} + 16'd1 == n_tiles_reg) begin
                            job_active_reg <= 1'b0;
                            state          <= ST_WAIT_RESULT;
                        end else begin
                            tile_idx <= tile_idx + 1'b1;
                        end
                    end

                    // ---- Step 3: issue the NEXT read, if legal ----
                    if (issue_rd_now) begin
                        act_rd_en       <= 1'b1;
                        act_rd_addr     <= rd_ptr[TIW-1:0];
                        wgt_rd_en       <= 1'b1;
                        wgt_rd_addr     <= rd_ptr[TIW-1:0];
                        rd_pending      <= 1'b1;
                        rd_pending_tile <= rd_ptr;
                        rd_pending_last <= ({{(16-CNTW){1'b0}}, rd_ptr} == n_tiles_reg - 16'd1);
                        rd_ptr          <= rd_ptr + 1'b1;
                    end else begin
                        rd_pending <= 1'b0;
                    end
                end

                ST_WAIT_RESULT: begin
                    result_ready <= 1'b1;
                    if (result_valid && result_ready) begin
                        wr_mem_wdata <= result_addr_reg[0] ? {result_data, 8'h00} : {8'h00, result_data};
                        wr_mem_lb_n  <= result_addr_reg[0] ? 1'b1 : 1'b0;
                        wr_mem_ub_n  <= result_addr_reg[0] ? 1'b0 : 1'b1;
                        state        <= ST_WRITE_RES;
                    end
                end

                ST_WRITE_RES: begin
                    wr_mem_req  <= 1'b1;
                    wr_mem_addr <= result_addr_reg[ADDR_WIDTH-1:1];
                    state       <= ST_DONE;
                end

                ST_DONE: begin
                    wr_mem_req <= 1'b0;
                    if (mem_ready) begin
                        job_done <= 1'b1;
                        state    <= ST_IDLE;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

    // ---- REAL weight prefetch engine (STEP11): unchanged from
    // nms_memory_manager_pf.v -- consumed_count is still the
    // CONSUMPTION pointer (tile_idx), not the read-issue pointer
    // (rd_ptr): the engine's own lookahead window is bounded by how
    // far the CONSUMER has progressed, exactly as before. ----
    weight_prefetch_engine_wide #(
        .DATA_WIDTH(DATA_WIDTH), .P_IN(P_IN), .ADDR_WIDTH(ADDR_WIDTH),
        .MAX_TILES(MAX_TILES), .PREFETCH_DISTANCE(PREFETCH_DISTANCE),
        .MEM_DATA_WIDTH(MEM_DATA_WIDTH)
    ) u_wpf (
        .clk(clk), .rst(rst),
        .job_active(job_active_reg), .w_base(w_base_reg), .n_tiles(n_tiles_reg),
        .consumed_count(tile_idx),
        .wgt_fill_we(wgt_fill_we), .wgt_fill_addr(wgt_fill_addr), .wgt_fill_data(wgt_fill_data),
        .ready_count(wgt_ready_count),
        .mem_req(wide_mem_req), .mem_addr(wide_mem_addr),
        .mem_rdata(wide_mem_rdata), .mem_ready(wide_mem_ready)
    );

    // Result write-back has the real 16-bit port entirely to itself
    // in this variant (no mux needed -- weight fetch lives on the
    // separate wide port above). Declarations moved up (see above).

    assign mem_req   = wr_mem_req;
    assign mem_wr    = 1'b1;
    assign mem_addr  = wr_mem_addr;
    assign mem_wdata = wr_mem_wdata;
    assign mem_lb_n  = wr_mem_lb_n;
    assign mem_ub_n  = wr_mem_ub_n;

endmodule
