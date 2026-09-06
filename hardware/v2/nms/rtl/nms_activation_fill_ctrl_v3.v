// ============================================================
// Neural Memory System (NMS) -- shared Activation fill controller.
//
// One instance per neural_memory_system (shared across all N_SLOTS),
// backing nms_activation_replicated.v's single broadcast-write fill
// port. Owns ONE prefetch_engine.v instance (real word-level PSRAM
// fetch, DEC-0015 convention, reused verbatim -- it is generic
// P_IN-byte-tile fetch logic, not weight-specific despite its name).
//
// Single-tag design (same honest limitation as the superseded
// hardware/v2/rtl/activation_cache.v, DEC-0016): tracks ONE resident
// x_base at a time. Refills (resident_count resets to 0, restarts
// fetching from tile 0) whenever the lowest-indexed currently-active
// slot's own x_base differs from what is resident -- correct always,
// but can thrash under interleaved, genuinely-different-x_base
// concurrent traffic; not exercised by this project's own realistic
// dense-layer workloads (shared-producer dispatch, many slots given
// the SAME x_base together).
//
// resident_count extends to the MAX n_tiles needed by any currently
// active slot that shares resident_tag (not just the reference slot
// that triggered the refill), so a later-joining slot with a deeper
// need is served without a second refill.
// ============================================================
module nms_activation_fill_ctrl_v3 #(
    parameter DATA_WIDTH = 8,
    parameter P_IN       = 8,
    parameter N_SLOTS    = 4,
    parameter ADDR_WIDTH = 23,
    parameter MAX_TILES  = 16,
    // TIW indexes the SRAM fill address (0..MAX_TILES-1); CNTW is for
    // resident_count, which must represent the VALUE MAX_TILES itself
    // (e.g. a fully-resident 16-tile vector with MAX_TILES=16) -- one
    // bit wider than TIW, same distinction/bug as
    // nms_memory_manager.v's own tile_idx/wgt_fetched (see that file's
    // header for the real deadlock this caused before the fix).
    parameter TIW        = (MAX_TILES <= 1) ? 1 : $clog2(MAX_TILES),
    parameter CNTW        = $clog2(MAX_TILES+1)
)(
    input  wire clk,
    input  wire rst,

    // ---- per-slot job status (levels, held while that slot's job is active) ----
    input  wire [N_SLOTS-1:0]              job_active,
    input  wire [N_SLOTS*ADDR_WIDTH-1:0]   x_base_flat,
    input  wire [N_SLOTS*16-1:0]           n_tiles_flat,

    // ---- broadcast status (every slot compares this against its own x_base) ----
    output reg  [ADDR_WIDTH-1:0] resident_tag,
    output reg  [CNTW-1:0]       resident_count,

    // ---- fill port into nms_activation_replicated.v ----
    output wire                     fill_we,
    output wire [TIW-1:0]           fill_addr,
    output wire [DATA_WIDTH*P_IN-1:0] fill_data,

    // ---- real word-level PSRAM backend (arbitrated externally) ----
    output wire                    mem_req,
    output wire                    mem_wr,
    output wire [ADDR_WIDTH-1:0]   mem_addr,
    output wire [15:0]             mem_wdata,
    output wire                    mem_lb_n,
    output wire                    mem_ub_n,
    input  wire [15:0]             mem_rdata,
    input  wire                    mem_ready
);

    integer i;

    // ---- desired x_base: lowest-indexed currently-active slot (fixed
    // priority -- simple, not fairness-critical here since this only
    // decides which TAG to chase, not who gets bandwidth) ----
    reg                   desired_valid;
    reg [ADDR_WIDTH-1:0]  desired_x_base;

    always @* begin
        desired_valid  = 1'b0;
        desired_x_base = {ADDR_WIDTH{1'b0}};
        for (i = N_SLOTS-1; i >= 0; i = i - 1) begin
            if (job_active[i]) begin
                desired_valid  = 1'b1;
                desired_x_base = x_base_flat[i*ADDR_WIDTH +: ADDR_WIDTH];
            end
        end
    end

    // ---- STEP14/EXP-0029->EXP-0030: max_n_tiles computation split
    // into TWO pipeline stages, since registering ONLY its final use
    // (v2, DEC-0026) left the computation ITSELF as the new critical
    // path (EXP-0030, N=4 Fmax=72.78MHz, still FAIL@80MHz): the
    // original single-cycle logic mixed, PER SLOT, a 23-bit tag
    // equality check (x_base_flat[i]==resident_tag) together with an
    // N_SLOTS-wide SEQUENTIALLY-CHAINED 16-bit running-max fold (each
    // iteration's update depends on the previous one) -- both
    // combinational, both in the same cycle as the register that
    // captures the result.
    //
    // Stage 1 (independent per-slot work, no chain dependency between
    // slots): register a per-slot "counts toward this refill" mask
    // (job_active[i] && tag-match) and, gated by that mask, each
    // slot's own n_tiles value (0 if it doesn't count) -- N_SLOTS
    // independent 23-bit equality checks, no data dependency between
    // slots, so their combined depth does not grow with N_SLOTS the
    // way a sequential fold does.
    // Stage 2 (the actual reduction): fold the REGISTERED, already-
    // masked per-slot values into max_n_tiles_reg -- still an
    // N_SLOTS-wide sequential chain (same fold as before), but now
    // operating alone, without the equality check sharing the same
    // cycle.
    reg [15:0] n_tiles_masked [0:N_SLOTS-1];
    genvar gsi;
    generate
        for (gsi = 0; gsi < N_SLOTS; gsi = gsi + 1) begin : GEN_MASK
            wire slot_counts = job_active[gsi] &&
                (x_base_flat[gsi*ADDR_WIDTH +: ADDR_WIDTH] == resident_tag);
            always @(posedge clk) begin
                if (rst) n_tiles_masked[gsi] <= 16'h0;
                else     n_tiles_masked[gsi] <= slot_counts ? n_tiles_flat[gsi*16 +: 16] : 16'h0;
            end
        end
    endgenerate

    reg [15:0] max_n_tiles_reg;
    integer j;
    reg [15:0] max_n_tiles_comb;
    always @* begin
        max_n_tiles_comb = 16'h0;
        for (j = 0; j < N_SLOTS; j = j + 1)
            if (n_tiles_masked[j] > max_n_tiles_comb)
                max_n_tiles_comb = n_tiles_masked[j];
    end
    always @(posedge clk) begin
        if (rst) max_n_tiles_reg <= 16'h0;
        else     max_n_tiles_reg <= max_n_tiles_comb;
    end

    localparam ST_IDLE  = 1'd0;
    localparam ST_FETCH = 1'd1;
    reg state;

    reg               pf_start;
    reg [ADDR_WIDTH-1:0] pf_addr;
    wire              pf_busy, pf_done;
    wire signed [DATA_WIDTH*P_IN-1:0] pf_tile;

    prefetch_engine #(
        .DATA_WIDTH(DATA_WIDTH), .P_IN(P_IN), .ADDR_WIDTH(ADDR_WIDTH)
    ) u_pf (
        .clk(clk), .rst(rst),
        .fetch_start(pf_start), .w_addr(pf_addr),
        .fetch_busy(pf_busy), .fetch_done(pf_done), .tile_w(pf_tile),
        .mem_req(mem_req), .mem_wr(mem_wr), .mem_addr(mem_addr), .mem_wdata(mem_wdata),
        .mem_lb_n(mem_lb_n), .mem_ub_n(mem_ub_n),
        .mem_rdata(mem_rdata), .mem_ready(mem_ready)
    );

    reg              fill_we_reg;
    reg [TIW-1:0]    fill_addr_reg;
    reg [DATA_WIDTH*P_IN-1:0] fill_data_reg;
    assign fill_we   = fill_we_reg;
    assign fill_addr = fill_addr_reg;
    assign fill_data = fill_data_reg;

    always @(posedge clk) begin
        if (rst) begin
            resident_tag   <= {ADDR_WIDTH{1'b1}}; // sentinel: matches no real x_base at reset
            resident_count <= {CNTW{1'b0}};
            state          <= ST_IDLE;
            pf_start       <= 1'b0;
            fill_we_reg    <= 1'b0;
        end else begin
            pf_start    <= 1'b0;
            fill_we_reg <= 1'b0;

            // latch a completed fetch into the replicated activation
            // memory's broadcast fill port
            if (pf_done) begin
                fill_we_reg   <= 1'b1;
                fill_addr_reg <= resident_count[TIW-1:0]; // valid: gated < max_n_tiles <= MAX_TILES
                fill_data_reg <= pf_tile;
                resident_count <= resident_count + 1'b1;
            end

            // refill trigger: the reference slot wants a DIFFERENT tag,
            // and the fetch engine is genuinely idle (never interrupt an
            // in-flight fetch -- same discipline as memory_manager.v's
            // own pf_pending guard, ERR-0006). Stays in ST_IDLE (not
            // ST_FETCH): only updates resident_tag/resident_count here;
            // the ST_IDLE case below is what actually issues pf_start,
            // reading the NEW resident_tag starting next cycle -- this
            // path must NOT itself jump to ST_FETCH without a matching
            // pf_start, or the engine would sit in ST_FETCH forever
            // waiting for a pf_done that was never triggered.
            if (desired_valid && (desired_x_base != resident_tag) && !pf_busy && (state == ST_IDLE)) begin
                resident_tag   <= desired_x_base;
                resident_count <= {CNTW{1'b0}};
            end

            case (state)
                ST_IDLE: begin
                    // stay idle: fetching further tiles for the CURRENT
                    // tag (if any active slot still needs more) is
                    // handled below, symmetric to the refill case.
                    if (!pf_busy && !pf_start && (resident_count < max_n_tiles_reg) &&
                        desired_valid && (desired_x_base == resident_tag)) begin
                        pf_start <= 1'b1;
                        pf_addr  <= resident_tag + (resident_count * P_IN[ADDR_WIDTH-1:0]);
                        state    <= ST_FETCH;
                    end
                end
                ST_FETCH: begin
                    if (pf_done) begin
                        // resident_count already bumped above this cycle;
                        // decide whether more remain once back in IDLE.
                        state <= ST_IDLE;
                    end
                end
                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
