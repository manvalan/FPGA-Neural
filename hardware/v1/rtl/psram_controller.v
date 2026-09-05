module psram_controller #(
    parameter ADDR_WIDTH   = 23,
    parameter DATA_WIDTH   = 16,
    parameter CLK_FREQ_MHZ = 80
)(
    input  wire                   clk,
    input  wire                   rst,

    // ============================================================
    // Memory Interface side
    // ============================================================

    input  wire                   mem_req,
    input  wire                   mem_wr,
    input  wire [ADDR_WIDTH-1:0]  mem_addr,
    input  wire [DATA_WIDTH-1:0]  mem_wdata,
    input  wire                   mem_lb_n,
    input  wire                   mem_ub_n,

    output reg  [DATA_WIDTH-1:0]  mem_rdata,
    output reg                    mem_ready,

    // ============================================================
    // PSRAM physical interface
    // ============================================================

    output reg  [ADDR_WIDTH-1:0]  psram_a,

    inout  wire [DATA_WIDTH-1:0]  psram_dq,

    output reg                    psram_ce_n,
    output reg                    psram_oe_n,
    output reg                    psram_we_n,
    output reg                    psram_lb_n,
    output reg                    psram_ub_n,
    output reg                    psram_zz_n
);

    // ============================================================
    // Timing
    // ============================================================
    //
    // ISSI IS66WVE4M16EBLL-70BLI (-70 speed grade): async random
    // access is 70ns (tAA/tRC). The chip also supports PAGE MODE
    // reads: once an initial tAA access has been done, further
    // reads to the same 16-word page (address bits above A[3])
    // only need to wait tAPA/tPC = 20ns before the next word is
    // valid, because CE#/OE# stay asserted and only the low
    // address bits change (datasheet Fig. 4). Page mode only
    // applies to reads; writes always pay the full random-access
    // time.
    //
    // Page mode read access is DISABLED at power-up (CR[7] = 0)
    // and must be turned on with a configuration-register write
    // before it can be relied on -- see STATE_CR_INIT below.
    // ============================================================

    localparam integer ACCESS_CYCLES =
        ((70 * CLK_FREQ_MHZ) + 999) / 1000;

    localparam integer PAGE_CYCLES =
        ((20 * CLK_FREQ_MHZ) + 999) / 1000;

    localparam integer INIT_CYCLES =
        150 * CLK_FREQ_MHZ;

    localparam integer COUNTER_WIDTH =
        (INIT_CYCLES <= 1) ? 1 : $clog2(INIT_CYCLES + 1);

    // A page is kept open (CE#/OE# held low between transactions)
    // only up to a safety margin under tCEM (8us max CE# low
    // pulse, refresh-related). 6us leaves comfortable headroom.

    localparam integer PAGE_HOLD_NS = 6000;

    localparam integer PAGE_TIMEOUT_CYCLES =
        ((PAGE_HOLD_NS * CLK_FREQ_MHZ) + 999) / 1000;

    localparam integer HOLD_WIDTH =
        (PAGE_TIMEOUT_CYCLES <= 1) ? 1 : $clog2(PAGE_TIMEOUT_CYCLES + 1);

    // ============================================================
    // Configuration register value
    //
    // Loaded once at power-up via the software-access sequence
    // (datasheet Fig. 6/7 -- 2 dummy reads + 2 writes at the
    // highest chip address; the first write is a required 0x0000
    // "unlock", the second carries the real value). Bit layout is
    // the standard ISSI CellularRAM CR (verified against the
    // sibling IS66WVE1M16BLL datasheet -- same CR layout is used
    // across the whole BLL family; re-check against the exact
    // -EBLL datasheet at hardware bring-up):
    //
    //   bit 7   Page      1 = page-mode reads enabled
    //   bits6:5 TCR       11 = +85C refresh (matches power-on default)
    //   bit 4   Sleep     1  = PAR on ZZ# (matches power-on default)
    //   bits2:0 PAR       000 = full-array refresh (default)
    //
    // i.e. power-on default (0x0070) with only the Page bit set.
    // ============================================================

    localparam [DATA_WIDTH-1:0] CR_VALUE = 16'h00F0;

    // ============================================================
    // State machine
    // ============================================================

    localparam [3:0]
        STATE_INIT        = 4'd0,
        STATE_IDLE        = 4'd1,
        STATE_READ        = 4'd2,
        STATE_WRITE       = 4'd3,
        STATE_WRITE_WAIT  = 4'd4,
        STATE_CR_INIT     = 4'd5,
        STATE_PAGE_OPEN   = 4'd6,
        STATE_PAGE_CLOSE  = 4'd7,
        STATE_PAGE_REOPEN = 4'd8;

    reg [3:0] state;
    reg [COUNTER_WIDTH-1:0] counter;

    // ============================================================
    // Latched transaction
    // ============================================================

    reg [ADDR_WIDTH-1:0] address_reg;
    reg [DATA_WIDTH-1:0] wdata_reg;
    reg                   wr_reg;

    // ============================================================
    // Latched byte enables
    //
    // Active LOW:
    //   0 = byte enabled
    //   1 = byte disabled
    // ============================================================

    reg lb_reg;
    reg ub_reg;

    // ============================================================
    // Page-mode bookkeeping
    // ============================================================

    reg                   page_hit_reg;  // current READ: fast (page) vs slow (tAA)
    reg [HOLD_WIDTH-1:0]  hold_cycles;   // cycles CE# has been held low this session

    // ============================================================
    // Configuration-register load sequence
    // ============================================================

    reg       cr_init_active;
    reg [2:0] cr_step;

    // ============================================================
    // Early-request latch (bug found + fixed 2026-09-04, see
    // WORKLOG.md flash-subsystem F2 entry for the full writeup)
    //
    // STATE_INIT (150us power-up wait) and STATE_CR_INIT (the 4-step
    // software-access sequence) do not check `mem_req` at all -- an
    // external request arriving during that window was previously
    // silently LOST (mem_req is a one-cycle pulse from
    // int8_memory_access.v with no retry), while the caller sat in
    // its own WAIT state watching for `mem_ready`. Meanwhile
    // STATE_READ/STATE_WRITE_WAIT's completion unconditionally
    // pulsed the SAME external `mem_ready` for CR_INIT's own 4
    // internal dummy-read/write steps too -- so the waiting caller
    // would see one of THOSE stray pulses, believe its own (never
    // actually issued) request had completed, and move on with
    // garbage/no data. Two independent effects of the same root
    // cause (CR_INIT reusing the external-facing datapath for
    // internal housekeeping): fixed together below (this latch) and
    // at both `mem_ready <= 1'b1` sites (guarded on `!cr_init_active`).
    // ============================================================

    reg                   req_pending;
    reg [ADDR_WIDTH-1:0]  pending_addr;
    reg [DATA_WIDTH-1:0]  pending_wdata;
    reg                   pending_wr;
    reg                   pending_lb_n;
    reg                   pending_ub_n;

    // ============================================================
    // PSRAM data bus control
    // ============================================================

    reg [DATA_WIDTH-1:0] dq_out;
    reg                   dq_oe;

    assign psram_dq =
        dq_oe ? dq_out : {DATA_WIDTH{1'bz}};

    // ============================================================
    // Main state machine
    // ============================================================

    always @(posedge clk) begin

        if (rst) begin

            // ----------------------------------------------------
            // State
            // ----------------------------------------------------

            state   <= STATE_INIT;
            counter <= 0;

            // ----------------------------------------------------
            // Transaction registers
            // ----------------------------------------------------

            address_reg <= {ADDR_WIDTH{1'b0}};
            wdata_reg   <= {DATA_WIDTH{1'b0}};
            wr_reg      <= 1'b0;

            // Byte enables disabled during reset
            lb_reg <= 1'b1;
            ub_reg <= 1'b1;

            // ----------------------------------------------------
            // Page-mode bookkeeping
            // ----------------------------------------------------

            page_hit_reg <= 1'b0;
            hold_cycles  <= 0;

            cr_init_active <= 1'b0;
            cr_step         <= 0;

            req_pending   <= 1'b0;
            pending_addr  <= {ADDR_WIDTH{1'b0}};
            pending_wdata <= {DATA_WIDTH{1'b0}};
            pending_wr    <= 1'b0;
            pending_lb_n  <= 1'b1;
            pending_ub_n  <= 1'b1;

            // ----------------------------------------------------
            // Memory interface
            // ----------------------------------------------------

            mem_rdata <= {DATA_WIDTH{1'b0}};
            mem_ready <= 1'b0;

            // ----------------------------------------------------
            // PSRAM address
            // ----------------------------------------------------

            psram_a <= {ADDR_WIDTH{1'b0}};

            // ----------------------------------------------------
            // PSRAM control
            // ----------------------------------------------------

            psram_ce_n <= 1'b1;
            psram_oe_n <= 1'b1;
            psram_we_n <= 1'b1;

            psram_lb_n <= 1'b1;
            psram_ub_n <= 1'b1;

            psram_zz_n <= 1'b1;

            // ----------------------------------------------------
            // Data bus
            // ----------------------------------------------------

            dq_out <= {DATA_WIDTH{1'b0}};
            dq_oe  <= 1'b0;

        end else begin

            // mem_ready is a one-cycle pulse
            mem_ready <= 1'b0;

            // Latch (don't drop) a request that arrives while the
            // controller is still busy with its own power-up/CR-init
            // sequence -- see the req_pending declaration above for
            // why this is needed. Only ever latches ONE request (the
            // arbiter + int8_memory_access contract guarantees no
            // caller issues a second req before its first is
            // acknowledged, so this window can only ever have at
            // most one outstanding request to remember).
            if ((state == STATE_INIT || state == STATE_CR_INIT) &&
                mem_req && !req_pending) begin
                req_pending   <= 1'b1;
                pending_addr  <= mem_addr;
                pending_wdata <= mem_wdata;
                pending_wr    <= mem_wr;
                pending_lb_n  <= mem_lb_n;
                pending_ub_n  <= mem_ub_n;
            end

            case (state)

                // =================================================
                // PSRAM power-up initialization
                // =================================================

                STATE_INIT: begin

                    psram_ce_n <= 1'b1;
                    psram_oe_n <= 1'b1;
                    psram_we_n <= 1'b1;

                    psram_lb_n <= 1'b1;
                    psram_ub_n <= 1'b1;

                    psram_zz_n <= 1'b1;

                    dq_oe <= 1'b0;

                    if (counter == INIT_CYCLES - 1) begin

                        counter  <= 0;
                        cr_step  <= 0;
                        state    <= STATE_CR_INIT;

                    end else begin

                        counter <= counter + 1'b1;

                    end
                end

                // =================================================
                // Configuration-register load
                //
                // Software-access sequence (datasheet Fig. 6):
                // 2 dummy reads + 2 writes at the highest chip
                // address, each a fully separate CE# pulse. The
                // first write clocks in 0x0000 (unlock), the
                // second clocks in the real CR value. Reuses the
                // ordinary STATE_READ/STATE_WRITE datapath so it
                // is checked by the exact same timing as every
                // other transaction.
                // =================================================

                STATE_CR_INIT: begin

                    if (cr_step == 3'd4) begin

                        cr_init_active <= 1'b0;
                        state          <= STATE_IDLE;

                    end else begin

                        cr_init_active <= 1'b1;

                        address_reg <= {ADDR_WIDTH{1'b1}};
                        lb_reg      <= 1'b0;
                        ub_reg      <= 1'b0;

                        psram_a    <= {ADDR_WIDTH{1'b1}};
                        psram_lb_n <= 1'b0;
                        psram_ub_n <= 1'b0;
                        psram_ce_n <= 1'b0;
                        psram_zz_n <= 1'b1;

                        counter      <= 0;
                        page_hit_reg <= 1'b0;

                        if (cr_step < 3'd2) begin

                            // Dummy READ steps
                            wr_reg <= 1'b0;
                            dq_oe  <= 1'b0;

                            psram_we_n <= 1'b1;
                            psram_oe_n <= 1'b0;

                            state <= STATE_READ;

                        end else begin

                            // WRITE steps: 0x0000 unlock, then real CR value
                            wr_reg    <= 1'b1;
                            wdata_reg <= (cr_step == 3'd2) ?
                                         {DATA_WIDTH{1'b0}} : CR_VALUE;
                            dq_out    <= (cr_step == 3'd2) ?
                                         {DATA_WIDTH{1'b0}} : CR_VALUE;
                            dq_oe     <= 1'b1;

                            psram_we_n <= 1'b0;
                            psram_oe_n <= 1'b1;

                            state <= STATE_WRITE;

                        end

                        cr_step <= cr_step + 1'b1;

                    end
                end

                // =================================================
                // Idle
                // =================================================

                STATE_IDLE: begin

                    psram_ce_n <= 1'b1;
                    psram_oe_n <= 1'b1;
                    psram_we_n <= 1'b1;

                    psram_lb_n <= 1'b1;
                    psram_ub_n <= 1'b1;

                    psram_zz_n <= 1'b1;

                    dq_oe <= 1'b0;

                    if (mem_req || req_pending) begin

                        // ------------------------------------------------
                        // Latch transaction -- from the live port if a
                        // fresh request arrived this cycle, otherwise
                        // from the early-request latch (see above)
                        // captured while STATE_INIT/STATE_CR_INIT was
                        // still running. `mem_req` takes priority
                        // (cannot both be true from a real caller given
                        // the one-outstanding-request contract, but if
                        // they ever were, the live request is the more
                        // recent one).
                        // ------------------------------------------------

                        address_reg <= mem_req ? mem_addr   : pending_addr;
                        wdata_reg   <= mem_req ? mem_wdata  : pending_wdata;
                        wr_reg      <= mem_req ? mem_wr     : pending_wr;

                        // ------------------------------------------------
                        // Latch byte enables
                        // ------------------------------------------------

                        lb_reg <= mem_req ? mem_lb_n : pending_lb_n;
                        ub_reg <= mem_req ? mem_ub_n : pending_ub_n;

                        req_pending <= 1'b0;

                        // ------------------------------------------------
                        // Address
                        // ------------------------------------------------

                        psram_a <= mem_addr;

                        // ------------------------------------------------
                        // Apply byte enables immediately
                        // ------------------------------------------------

                        psram_lb_n <= mem_lb_n;
                        psram_ub_n <= mem_ub_n;

                        psram_ce_n <= 1'b0;

                        counter <= 0;

                        // =================================================
                        // WRITE
                        // =================================================

                        if (mem_wr) begin

                            dq_out <= mem_wdata;
                            dq_oe  <= 1'b1;

                            psram_we_n <= 1'b0;
                            psram_oe_n <= 1'b1;

                            state <= STATE_WRITE;

                        end

                        // =================================================
                        // READ (fresh session -- always full tAA)
                        // =================================================

                        else begin

                            dq_oe <= 1'b0;

                            psram_we_n <= 1'b1;
                            psram_oe_n <= 1'b0;

                            page_hit_reg <= 1'b0;
                            hold_cycles  <= 0;

                            state <= STATE_READ;

                        end
                    end
                end

                // =================================================
                // READ
                //
                // Wait ACCESS_CYCLES (tAA, fresh/random access) or
                // PAGE_CYCLES (tAPA, same-page continuation) as
                // selected by page_hit_reg.
                // =================================================

                STATE_READ: begin

                    psram_ce_n <= 1'b0;
                    psram_oe_n <= 1'b0;
                    psram_we_n <= 1'b1;

                    psram_lb_n <= lb_reg;
                    psram_ub_n <= ub_reg;

                    psram_zz_n <= 1'b1;

                    dq_oe <= 1'b0;

                    hold_cycles <= hold_cycles + 1'b1;

                    if (counter ==
                        (page_hit_reg ? PAGE_CYCLES : ACCESS_CYCLES) - 1) begin

                        // ------------------------------------------------
                        // Capture PSRAM data
                        // ------------------------------------------------

                        mem_rdata <= psram_dq;

                        // Only a REAL external transaction's
                        // completion may pulse the external
                        // mem_ready -- CR_INIT's own 2 dummy-read
                        // steps reuse this same state but must never
                        // be visible to whatever caller happens to
                        // be waiting (see req_pending's declaration
                        // above for the full incident writeup).
                        if (!cr_init_active)
                            mem_ready <= 1'b1;

                        counter <= 0;

                        if (cr_init_active) begin

                            // Close between CR software-access-sequence
                            // steps (datasheet Fig. 6 -- 4 separate CE#
                            // pulses).

                            psram_ce_n <= 1'b1;
                            psram_oe_n <= 1'b1;
                            psram_lb_n <= 1'b1;
                            psram_ub_n <= 1'b1;

                            state <= STATE_CR_INIT;

                        end else begin

                            // Keep the page open: CE#/OE# stay
                            // asserted so a following same-page read
                            // can skip straight to a fast PAGE_CYCLES
                            // access instead of a full tAA.

                            state <= STATE_PAGE_OPEN;

                        end

                    end else begin

                        counter <= counter + 1'b1;

                    end
                end

                // =================================================
                // PAGE OPEN
                //
                // A read just completed and CE#/OE# were left
                // asserted. From here:
                //   - a same-page READ continues immediately with
                //     only the address/byte-enable lines changing
                //     (fast PAGE_CYCLES access) -- byte enables are
                //     free to change here too, since
                //     int8_memory_access.v alternates LB#/UB# on
                //     nearly every byte-granular access and the
                //     datasheet's page timing (Fig. 4) is defined
                //     purely on the address bus and CE#/OE#;
                //   - a different-page READ can also continue
                //     without a CE# toggle, but pays the full
                //     ACCESS_CYCLES for that one word (real chip
                //     behaviour: any change at A[4] or above needs
                //     a fresh tAA);
                //   - a WRITE, or exceeding the tCEM safety margin,
                //     closes the page first.
                // =================================================

                STATE_PAGE_OPEN: begin

                    psram_ce_n <= 1'b0;
                    psram_oe_n <= 1'b0;
                    psram_we_n <= 1'b1;

                    psram_lb_n <= lb_reg;
                    psram_ub_n <= ub_reg;

                    psram_zz_n <= 1'b1;

                    dq_oe <= 1'b0;

                    if (mem_req) begin

                        if (mem_wr ||
                            (hold_cycles >= PAGE_TIMEOUT_CYCLES)) begin

                            // Latch the new transaction, then close
                            // the page before servicing it.

                            address_reg <= mem_addr;
                            wdata_reg   <= mem_wdata;
                            wr_reg      <= mem_wr;
                            lb_reg      <= mem_lb_n;
                            ub_reg      <= mem_ub_n;

                            psram_ce_n <= 1'b1;
                            psram_oe_n <= 1'b1;
                            psram_lb_n <= 1'b1;
                            psram_ub_n <= 1'b1;

                            state <= STATE_PAGE_CLOSE;

                        end else begin

                            // READ continuation: address and byte
                            // enables change freely, CE#/OE# stay
                            // low. int8_memory_access.v alternates
                            // LB#/UB# on essentially every access
                            // (byte-granular reads over the 16-bit
                            // bus) so byte-enable changes are the
                            // common case, not an exception -- the
                            // datasheet's page-mode timing (Fig. 4)
                            // is defined purely on the address bus
                            // and CE#/OE#, and says nothing that
                            // requires LB#/UB# to stay fixed.

                            page_hit_reg <=
                                (mem_addr[ADDR_WIDTH-1:4] ==
                                 address_reg[ADDR_WIDTH-1:4]);

                            address_reg <= mem_addr;
                            psram_a     <= mem_addr;

                            lb_reg     <= mem_lb_n;
                            ub_reg     <= mem_ub_n;
                            psram_lb_n <= mem_lb_n;
                            psram_ub_n <= mem_ub_n;

                            counter <= 0;

                            state <= STATE_READ;

                        end

                    end else begin

                        // Idle inside an open page -- respect tCEM.

                        if (hold_cycles >= PAGE_TIMEOUT_CYCLES) begin

                            psram_ce_n <= 1'b1;
                            psram_oe_n <= 1'b1;
                            psram_lb_n <= 1'b1;
                            psram_ub_n <= 1'b1;

                            state <= STATE_IDLE;

                        end else begin

                            hold_cycles <= hold_cycles + 1'b1;

                        end
                    end
                end

                // =================================================
                // PAGE CLOSE
                //
                // One fully-deasserted cycle before reopening for a
                // WRITE (or a timed-out page): guarantees OE# has
                // been high for a full cycle (>= tHZ) before the
                // controller starts driving DQ, avoiding bus
                // contention with the PSRAM's own output buffer.
                // =================================================

                STATE_PAGE_CLOSE: begin

                    psram_ce_n <= 1'b1;
                    psram_oe_n <= 1'b1;
                    psram_we_n <= 1'b1;

                    psram_lb_n <= 1'b1;
                    psram_ub_n <= 1'b1;

                    psram_zz_n <= 1'b1;

                    dq_oe <= 1'b0;

                    state <= STATE_PAGE_REOPEN;

                end

                // =================================================
                // PAGE REOPEN
                //
                // Dispatches the transaction latched just before
                // STATE_PAGE_CLOSE, exactly like STATE_IDLE would.
                // =================================================

                STATE_PAGE_REOPEN: begin

                    psram_a <= address_reg;

                    psram_lb_n <= lb_reg;
                    psram_ub_n <= ub_reg;

                    psram_zz_n <= 1'b1;

                    counter <= 0;

                    if (wr_reg) begin

                        dq_out <= wdata_reg;
                        dq_oe  <= 1'b1;

                        psram_ce_n <= 1'b0;
                        psram_we_n <= 1'b0;
                        psram_oe_n <= 1'b1;

                        state <= STATE_WRITE;

                    end else begin

                        dq_oe <= 1'b0;

                        psram_ce_n <= 1'b0;
                        psram_we_n <= 1'b1;
                        psram_oe_n <= 1'b0;

                        page_hit_reg <= 1'b0;
                        hold_cycles  <= 0;

                        state <= STATE_READ;

                    end
                end

                // =================================================
                // WRITE
                // =================================================

                STATE_WRITE: begin

                    psram_ce_n <= 1'b0;
                    psram_oe_n <= 1'b1;
                    psram_we_n <= 1'b0;

                    psram_lb_n <= lb_reg;
                    psram_ub_n <= ub_reg;

                    psram_zz_n <= 1'b1;

                    dq_oe <= 1'b1;

                    if (counter == ACCESS_CYCLES - 1) begin

                        // ------------------------------------------------
                        // End WE# pulse
                        // ------------------------------------------------

                        psram_we_n <= 1'b1;

                        counter <= 0;
                        state   <= STATE_WRITE_WAIT;

                    end else begin

                        counter <= counter + 1'b1;

                    end
                end

                // =================================================
                // WRITE WAIT
                //
                // Keep CE#/LB#/UB# active for the final write hold
                // interval before releasing the transaction.
                // =================================================

                STATE_WRITE_WAIT: begin

                    psram_ce_n <= 1'b0;
                    psram_oe_n <= 1'b1;
                    psram_we_n <= 1'b1;

                    psram_lb_n <= lb_reg;
                    psram_ub_n <= ub_reg;

                    psram_zz_n <= 1'b1;

                    dq_oe <= 1'b0;

                    // ------------------------------------------------
                    // Release PSRAM
                    // ------------------------------------------------

                    psram_ce_n <= 1'b1;
                    psram_lb_n <= 1'b1;
                    psram_ub_n <= 1'b1;

                    // ------------------------------------------------
                    // Transaction complete -- same cr_init_active
                    // guard as the STATE_READ completion above (this
                    // is CR_INIT's own 2 write steps reusing this
                    // state too).
                    // ------------------------------------------------

                    if (!cr_init_active)
                        mem_ready <= 1'b1;

                    state <= cr_init_active ? STATE_CR_INIT : STATE_IDLE;
                end

                // =================================================
                // Default recovery
                // =================================================

                default: begin

                    state   <= STATE_INIT;
                    counter <= 0;

                    psram_ce_n <= 1'b1;
                    psram_oe_n <= 1'b1;
                    psram_we_n <= 1'b1;

                    psram_lb_n <= 1'b1;
                    psram_ub_n <= 1'b1;

                    psram_zz_n <= 1'b1;

                    dq_oe <= 1'b0;

                    lb_reg <= 1'b1;
                    ub_reg <= 1'b1;

                    page_hit_reg   <= 1'b0;
                    hold_cycles    <= 0;
                    cr_init_active <= 1'b0;
                    cr_step        <= 0;

                end

            endcase
        end
    end

endmodule
