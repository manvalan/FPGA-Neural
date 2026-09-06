// ============================================================
// Neural Memory System (NMS) -- per-slot memory manager.
//
// Same EXTERNAL job/operand/result interface as
// hardware/v2/rtl/memory_manager.v (drop-in for the Neural Director/
// Dependency Manager side -- neither needs to change). Internally
// simpler: since the on-chip Activation/Weight SRAMs
// (nms_activation_replicated.v, nms_weight_packed.v) each hold the
// ENTIRE shared/private vector (sized MAX_TILES deep), there is no
// more double-buffering/bank-swap logic at all -- this module just
// tracks a private WEIGHT fetch progress counter (own prefetch_engine
// instance, exactly memory_manager.v's own proven pattern, writing
// into this slot's own private SRAM lane instead of a bank register)
// and reads the shared Activation fill controller's own
// resident_tag/resident_count to know how many tiles of ITS x_base are
// currently usable.
//
// A tile is presentable once tile_idx is below BOTH: this slot's own
// weight-fetch progress, and (resident_tag==x_base_reg) ?
// resident_count : 0. SRAM reads have 1-cycle registered latency
// (matches nms_activation_replicated.v/nms_weight_packed.v exactly).
// ============================================================
module nms_memory_manager #(
    parameter DATA_WIDTH = 8,
    parameter P_IN       = 8,
    parameter ADDR_WIDTH = 23,
    parameter MAX_TILES  = 16,
    // TIW indexes SRAM addresses (0..MAX_TILES-1) -- matches
    // nms_activation_replicated.v/nms_weight_packed.v's own address
    // port width exactly, must stay in sync with them.
    parameter TIW        = (MAX_TILES <= 1) ? 1 : $clog2(MAX_TILES),
    // CNTW is for COUNTERS (tile_idx, wgt_fetched) and the resident-
    // count status they compare against -- these must be able to
    // represent the VALUE MAX_TILES itself (e.g. n_tiles=16 with
    // MAX_TILES=16), one bit wider than an address index needs. Using
    // TIW for these counters was a real bug: a 4-bit wgt_fetched
    // (MAX_TILES=16) can count 0..15 but overflows 15->0 right when it
    // should reach 16, so "wgt_fetched < n_tiles" was NEVER false once
    // truly done -- the weight fetch looped forever, and separately
    // resident_count never advanced past its own analogous ceiling
    // (found via simulation: any n_tiles==MAX_TILES job -- exactly
    // D-Stress's real 16-tile neurons -- hung forever, while every
    // earlier n_tiles<MAX_TILES test in this project passed).
    parameter CNTW        = $clog2(MAX_TILES+1)
)(
    input  wire clk,
    input  wire rst,

    // ---- job control (from Neural Director, unchanged interface) ----
    input  wire                      job_start,
    input  wire [ADDR_WIDTH-1:0]     x_base,
    input  wire [ADDR_WIDTH-1:0]     w_base,
    input  wire [15:0]               n_tiles,
    input  wire [ADDR_WIDTH-1:0]     result_addr,
    output reg                       job_done,

    // ---- Neural Processor-facing operand stream (unchanged) ----
    output reg                                operand_valid,
    input  wire                               operand_ready,
    output reg  signed [DATA_WIDTH*P_IN-1:0]  input_data,
    output reg  signed [DATA_WIDTH*P_IN-1:0]  weight_data,
    output reg                                tile_last,

    // ---- Neural Processor-facing result consumption (unchanged) ----
    input  wire                       result_valid,
    output reg                        result_ready,
    input  wire signed [DATA_WIDTH-1:0] result_data,

    // ---- job status broadcast to the shared activation fill controller ----
    output wire            job_active,
    output wire [ADDR_WIDTH-1:0] job_x_base,
    output wire [15:0]     job_n_tiles,

    // ---- shared activation fill controller status (broadcast, same for every slot) ----
    input  wire [ADDR_WIDTH-1:0] act_resident_tag,
    input  wire [CNTW-1:0]       act_resident_count,

    // ---- this slot's own private lane into nms_activation_replicated.v (READ only -- fill is owned by the shared controller) ----
    output reg              act_rd_en,
    output reg  [TIW-1:0]   act_rd_addr,
    input  wire signed [DATA_WIDTH*P_IN-1:0] act_rd_data,

    // ---- this slot's own private lane into nms_weight_packed.v (fill AND read -- private) ----
    output reg              wgt_fill_we,
    output reg  [TIW-1:0]   wgt_fill_addr,
    output reg  [DATA_WIDTH*P_IN-1:0] wgt_fill_data,
    output reg              wgt_rd_en,
    output reg  [TIW-1:0]   wgt_rd_addr,
    input  wire signed [DATA_WIDTH*P_IN-1:0] wgt_rd_data,

    // ---- real word-level PSRAM backend for THIS slot's own weight
    // fetch + result write-back (arbitrated externally, exactly
    // memory_manager.v's own mem_* port) ----
    output wire                    mem_req,
    output wire                    mem_wr,
    output wire [ADDR_WIDTH-1:0]   mem_addr,
    output wire [15:0]             mem_wdata,
    output wire                    mem_lb_n,
    output wire                    mem_ub_n,
    input  wire [15:0]             mem_rdata,
    input  wire                    mem_ready
);

    localparam ST_IDLE        = 3'd0;
    localparam ST_RUN         = 3'd1;
    localparam ST_WAIT_RESULT = 3'd2;
    localparam ST_WRITE_RES   = 3'd3;
    localparam ST_DONE        = 3'd4;

    reg [2:0] state;
    reg job_active_reg;
    assign job_active  = job_active_reg;
    assign job_x_base  = x_base_reg;
    assign job_n_tiles = n_tiles_reg;

    reg [ADDR_WIDTH-1:0] x_base_reg, w_base_reg, result_addr_reg;
    reg [15:0]           n_tiles_reg;
    reg [CNTW-1:0]       tile_idx;       // consumption pointer (0..MAX_TILES)
    reg [CNTW-1:0]       wgt_fetched;    // this slot's own weight fetch progress (0..MAX_TILES)
    // Two-stage read pipeline, NOT one: both nms_activation_replicated.v
    // and nms_weight_packed.v register rd_en THEN register the memory
    // read off THAT (rd_data_reg <= mem[addr]) -- i.e. asserting rd_en
    // at cycle T makes the SRAM's own always block see it at cycle T+1
    // (scheduling the read for T+2), so rd_data is only valid starting
    // T+2, not T+1. A single "read_issued" flag capturing rd_data one
    // cycle after issuing it (T+1) grabbed the SRAM's PRE-read (stale)
    // output -- found via simulation: node0's own first tile computed
    // 0 instead of 48 (2*3*8) because input_data/weight_data were still
    // read AS ZERO the very cycle operand_valid first asserted (the
    // real act_rd_data/wgt_rd_data were correct by then, but the NBA
    // capture into input_data/weight_data was one cycle too early to
    // use them). Fixed with a genuine 2-stage pipeline: read_issued
    // (SRAM now computing) -> read_ready (SRAM output now valid,
    // capture NOW).
    reg                  read_issued;
    reg                  read_ready;

    wire usable_act_count_valid = (act_resident_tag == x_base_reg);
    wire [CNTW-1:0] usable_act = usable_act_count_valid ? act_resident_count : {CNTW{1'b0}};
    // tile_idx/wgt_fetched/usable_act are CNTW-bit (able to represent
    // the value MAX_TILES itself, not just index it). First term
    // compares against the full 16-bit n_tiles_reg (Verilog zero-
    // extends automatically since CNTW<16 for any real MAX_TILES);
    // the other two compare tile_idx (what's NEEDED now) against
    // wgt_fetched/usable_act (what's actually AVAILABLE) -- NOT
    // against n_tiles_reg, which says nothing about availability. An
    // earlier revision of this fix mistakenly compared wgt_fetched
    // against n_tiles_reg here instead of against tile_idx: once
    // wgt_fetched legitimately reached n_tiles (fetch complete, no
    // more needed), that comparison went permanently false and
    // deadlocked consumption forever even though every tile was
    // genuinely ready -- caught because act_resident_count kept
    // climbing normally while operand_valid never once asserted.
    wire can_present = ({{(16-CNTW){1'b0}}, tile_idx} < n_tiles_reg) &&
                        (tile_idx < wgt_fetched) &&
                        (tile_idx < usable_act);

    // ---- private weight prefetch (own prefetch_engine instance,
    // exactly memory_manager.v's own proven pattern -- fetch AS FAST AS
    // POSSIBLE up to n_tiles, no lookahead throttling needed since the
    // SRAM holds the whole vector, not just 2 double-buffered banks) ----
    reg               pf_start;
    reg [ADDR_WIDTH-1:0] pf_w_addr;
    wire              pf_busy, pf_done;
    wire signed [DATA_WIDTH*P_IN-1:0] pf_tile_w;

    prefetch_engine #(
        .DATA_WIDTH(DATA_WIDTH), .P_IN(P_IN), .ADDR_WIDTH(ADDR_WIDTH)
    ) u_prefetch (
        .clk(clk), .rst(rst),
        .fetch_start(pf_start), .w_addr(pf_w_addr),
        .fetch_busy(pf_busy), .fetch_done(pf_done), .tile_w(pf_tile_w),
        .mem_req(pf_mem_req), .mem_wr(pf_mem_wr), .mem_addr(pf_mem_addr), .mem_wdata(pf_mem_wdata),
        .mem_lb_n(pf_mem_lb_n), .mem_ub_n(pf_mem_ub_n),
        .mem_rdata(mem_rdata), .mem_ready(mem_ready)
    );
    wire pf_mem_req, pf_mem_wr;
    wire [ADDR_WIDTH-1:0] pf_mem_addr;
    wire [15:0] pf_mem_wdata;
    wire pf_mem_lb_n, pf_mem_ub_n;

    reg                   wr_mem_req;
    reg  [ADDR_WIDTH-1:0] wr_mem_addr;
    reg  [15:0]           wr_mem_wdata;
    reg                   wr_mem_lb_n, wr_mem_ub_n;

    wire wr_active = (state == ST_WRITE_RES) || (state == ST_DONE);
    assign mem_req   = wr_active ? wr_mem_req   : pf_mem_req;
    assign mem_wr    = wr_active ? 1'b1         : pf_mem_wr;
    assign mem_addr  = wr_active ? wr_mem_addr  : pf_mem_addr;
    assign mem_wdata = wr_active ? wr_mem_wdata : pf_mem_wdata;
    assign mem_lb_n  = wr_active ? wr_mem_lb_n  : pf_mem_lb_n;
    assign mem_ub_n  = wr_active ? wr_mem_ub_n  : pf_mem_ub_n;

    always @(posedge clk) begin
        if (rst) begin
            state          <= ST_IDLE;
            job_active_reg <= 1'b0;
            job_done       <= 1'b0;
            operand_valid  <= 1'b0;
            tile_last      <= 1'b0;
            result_ready   <= 1'b0;
            tile_idx       <= {CNTW{1'b0}};
            wgt_fetched    <= {CNTW{1'b0}};
            read_issued    <= 1'b0;
            read_ready     <= 1'b0;
            pf_start       <= 1'b0;
            act_rd_en      <= 1'b0;
            wgt_rd_en      <= 1'b0;
            wgt_fill_we    <= 1'b0;
            wr_mem_req     <= 1'b0;
            wr_mem_lb_n    <= 1'b1;
            wr_mem_ub_n    <= 1'b1;
        end else begin
            job_done     <= 1'b0;
            pf_start     <= 1'b0;
            act_rd_en    <= 1'b0;
            wgt_rd_en    <= 1'b0;
            wgt_fill_we  <= 1'b0;
            result_ready <= 1'b0;

            // latch a completed private weight fetch into this slot's
            // own SRAM lane
            if (pf_done) begin
                wgt_fill_we   <= 1'b1;
                wgt_fill_addr <= wgt_fetched[TIW-1:0]; // valid: gated < n_tiles <= MAX_TILES
                wgt_fill_data <= pf_tile_w;
                wgt_fetched   <= wgt_fetched + 1'b1;
            end

            // keep fetching weight tiles as fast as the (single, private)
            // prefetch engine allows, up to n_tiles. The `!pf_done` guard
            // is required, not cosmetic: pf_done and the "wgt_fetched<=
            // wgt_fetched+1" increment above happen the SAME cycle
            // pf_busy also drops back to 0 (prefetch_engine.v's own
            // ST_DONE clears fetch_busy the same cycle it pulses
            // fetch_done) -- without this guard, THIS SAME cycle would
            // read the OLD (pre-increment) wgt_fetched to compute
            // pf_w_addr, re-issuing a fetch for the tile that JUST
            // completed instead of the next one, and that duplicate
            // fetch's own completion would then write into the NEXT
            // tile's SRAM slot using the WRONG (duplicated) source data
            // -- silently corrupting every other tile for any n_tiles>1
            // job (found via simulation once a >1-tile test was run;
            // every n_tiles=1 test in this file's own first pass never
            // exercised this path). Same bug class as ERR-0006's own
            // "don't gate solely on a signal with its own same-cycle
            // side effect" lesson.
            if (job_active_reg && !pf_busy && !pf_start && !pf_done &&
                ({{(16-CNTW){1'b0}}, wgt_fetched} < n_tiles_reg)) begin
                pf_start  <= 1'b1;
                pf_w_addr <= w_base_reg + (wgt_fetched * P_IN[ADDR_WIDTH-1:0]);
            end

            case (state)
                ST_IDLE: begin
                    if (job_start) begin
                        x_base_reg      <= x_base;
                        w_base_reg      <= w_base;
                        n_tiles_reg     <= n_tiles;
                        result_addr_reg <= result_addr;
                        tile_idx        <= {CNTW{1'b0}};
                        wgt_fetched     <= {CNTW{1'b0}};
                        read_issued     <= 1'b0;
                        read_ready      <= 1'b0;
                        operand_valid   <= 1'b0;
                        job_active_reg  <= 1'b1;
                        state           <= ST_RUN;
                    end
                end

                ST_RUN: begin
                    if (!operand_valid && !read_issued && !read_ready && can_present) begin
                        act_rd_en    <= 1'b1;
                        act_rd_addr  <= tile_idx[TIW-1:0]; // valid: gated < n_tiles <= MAX_TILES
                        wgt_rd_en    <= 1'b1;
                        wgt_rd_addr  <= tile_idx[TIW-1:0];
                        read_issued  <= 1'b1;
                    end else if (read_issued) begin
                        // SRAM's own always block has now seen rd_en
                        // (this cycle) and scheduled rd_data_reg<=mem[addr]
                        // for the NEXT cycle -- wait one more cycle before
                        // trusting act_rd_data/wgt_rd_data.
                        read_issued <= 1'b0;
                        read_ready  <= 1'b1;
                    end else if (read_ready) begin
                        operand_valid <= 1'b1;
                        input_data    <= act_rd_data;
                        weight_data   <= wgt_rd_data;
                        tile_last     <= ({{(16-CNTW){1'b0}}, tile_idx} == n_tiles_reg - 16'd1);
                        read_ready    <= 1'b0;
                    end else if (operand_valid && operand_ready) begin
                        operand_valid <= 1'b0;
                        if ({{(16-CNTW){1'b0}}, tile_idx} + 16'd1 == n_tiles_reg) begin
                            job_active_reg <= 1'b0;
                            state <= ST_WAIT_RESULT;
                        end else begin
                            tile_idx <= tile_idx + 1'b1;
                        end
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

endmodule
