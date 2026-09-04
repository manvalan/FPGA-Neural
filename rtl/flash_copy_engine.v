`timescale 1ns/1ps

// ================================================================
// FLASH_COPY_ENGINE
//
// DMA-style block-streaming engine between the boot/persistence
// flash (via rtl/spi_flash_master.v, which it owns internally) and
// the shared PSRAM (via a new low-priority Port D on
// rtl/mem_arbiter.v -- see that file's updated header). This is the
// module the flash-subsystem phase-plan's §3 describes: the host
// issues a high-level command and walks away; there is no
// byte-at-a-time host involvement, only the FPGA streaming at
// whatever rate the flash/PSRAM actually allow.
//
// F2 SCOPE: LOAD direction, flash -> PSRAM. `op_start` with
// `op_dir = DIR_LOAD` copies `len` bytes from `flash_addr` to
// `psram_addr`. The Read Data (03h) instruction has no page-boundary
// restriction (unlike Page Program, §8 intro p.24: only
// WRITE/PROGRAM/ERASE instructions must land on a byte/page boundary
// or get ignored -- READ just streams and auto-increments, wrapping
// at the top of the array), so a LOAD needs no internal
// erase/program looping.
//
// F3 SCOPE: SAVE direction, PSRAM -> flash. `op_start` with
// `op_dir = DIR_SAVE` copies `len` bytes from `psram_addr` to
// `flash_addr`, doing erase-before-write internally:
//
//   - Design decision (phase-plan §2.1 explicitly asks for one,
//     with a stated reason): `flash_addr` MUST be 4KB-sector-aligned
//     (low 12 bits zero) -- rejected as a bounds/alignment error
//     otherwise (§A.3 "blocco non allineato al settore"), rather
//     than silently doing a read-modify-erase-write of a partial
//     sector. Reason: this project has NO scratch buffer large
//     enough to hold a whole 4KB sector's unrelated surrounding data
//     while erasing/reprogramming it, and the flash-subsystem's own
//     design (fixed-size catalog slots, §4 of the phase-plan) means
//     every real SAVE_SLOT call (F5) already writes whole,
//     sector-aligned slots -- so alignment is not a real-world
//     restriction here, only a rejected pathological case.
//   - Erase phase: every 4KB sector overlapping [flash_addr,
//     flash_addr+len) is erased (WREN + SE + poll RDSR-1 bit0/WIP
//     until clear) before any programming starts. A `len` that
//     isn't itself a sector multiple still erases the WHOLE last
//     (partial) sector -- erase has no finer granularity (Table 1
//     p.26) -- leaving the unwritten tail of that sector at 0xFF
//     (erased state), which is correct/expected, not a bug: the
//     catalog's own valid_flag+CRC (F4) is what marks the meaningful
//     length of a slot, not "everything in the sector is meaningful".
// F5 SCOPE: DIR_ERASE, a standalone sector erase (the phase-plan's
// §5 FLASH_ERASE opcode, exposed once F5 wires this engine to
// spi_engine). `op_start` with `op_dir = DIR_ERASE` erases exactly
// the one 4KB sector at `flash_addr` (which must be sector-aligned,
// same check/reason as DIR_SAVE) -- `psram_addr` and `len` are
// ignored. Reuses DIR_SAVE's own erase-phase states verbatim (WREN +
// SE + poll RDSR-1/WIP), just stopping after that one sector instead
// of falling through to the program phase -- see `erase_only` below.
//
//   - Program phase: looped Page Program (02h) calls of up to 256B
//     each (never crossing a page boundary -- guaranteed by
//     `flash_addr` being sector-, hence page-, aligned, and by
//     capping every chunk at 256B), each individually WREN'd and
//     RDSR-polled to completion before the next, exactly as the
//     phase-plan's §2.2 requires ("Il loop lo fa la FPGA"). Each
//     page's bytes are sourced live from PSRAM one at a time via
//     Port D reads, driven by spi_flash_master's own `wdata_req`
//     handshake (F1) -- no local buffer needed, matching this
//     engine's LOAD-side "stream through" style.
//
// spi_flash_master's `n_data` is 16 bits (max 65535 bytes per SPI
// transaction); this engine's own `len` is 24 bits (matching the
// flash-subsystem opcode draft's 3-byte length field, §5 of the
// phase-plan), so a LOAD larger than 65535 bytes is split into
// multiple back-to-back spi_flash_master READ transactions
// (CHUNK_MAX bytes each) rather than assumed to fit in one -- closes
// a latent bug rather than leaving an untested edge case.
//
// Bounds checking (§A.3 "len fuori range" negative case, enforced
// here rather than deferred entirely to the F5 opcode layer, in
// case a future caller other than spi_engine ever drives this
// module directly): a request whose flash_addr+len would exceed the
// modeled 16MB (2^24) flash address space, or whose psram_addr+len
// would exceed the 8MB (2^23, ADDR_WIDTH) PSRAM address space,
// completes immediately with `err` asserted and does not touch the
// flash or PSRAM at all.
// ================================================================

module flash_copy_engine #(
    parameter PSRAM_ADDR_WIDTH = 23,
    parameter CLK_FREQ_MHZ     = 80,
    parameter SCLK_DIV         = 2
)(
    input  wire clk,
    input  wire rst,

    // ------------------------------------------------------------
    // Physical flash pins (this module owns spi_flash_master)
    // ------------------------------------------------------------
    output wire mosi,
    input  wire miso,
    output wire cs_n,
`ifdef SIMULATION
    output wire sclk_sim,
`endif

    // ------------------------------------------------------------
    // Command interface
    // ------------------------------------------------------------
    input  wire        op_start,
    input  wire [1:0]  op_dir,           // DIR_LOAD (F2, flash->PSRAM) or DIR_SAVE (F3, PSRAM->flash)
    input  wire [23:0] flash_addr,
    input  wire [PSRAM_ADDR_WIDTH-1:0] psram_addr,
    input  wire [23:0] len,

    output wire         busy,
    output reg           done, // one-cycle pulse
    output reg           err,  // held until next op_start; see bounds check above

    // ------------------------------------------------------------
    // PSRAM arbiter master port (mem_arbiter.v Port D)
    //
    // d_req is a LEVEL signal (held for the whole ST_PSRAM_WAIT
    // state, see below), not a one-cycle pulse like the other
    // ports' requesters (spi_engine.v etc.) use. Found necessary
    // during F2 bring-up (see WORKLOG.md): mem_arbiter.v only
    // samples a requester's `req` while `owner==SEL_NONE`, so a
    // ONE-CYCLE pulse that happens to land on the exact same cycle
    // a higher-priority port (A/B/C) also requests is granted to
    // that other port and simply never retried -- Port D is lowest
    // priority by design (see mem_arbiter.v's header), so under any
    // real, sustained contention from Port A a one-shot pulse would
    // eventually get "unlucky" and hang this engine forever waiting
    // for a d_ready that will never come. Holding d_req at the
    // arbiter continuously (not just once) makes the wait exactly
    // what the design intends -- "gets stretched out", never lost --
    // without needing to change mem_arbiter.v itself (which serves
    // the three already-validated masters too).
    // ------------------------------------------------------------
    output wire                          d_req,
    output reg                           d_wr,
    output reg  [PSRAM_ADDR_WIDTH-1:0]   d_addr,
    output reg  signed [7:0]             d_wdata,
    input  wire signed [7:0]             d_rdata,
    input  wire                          d_ready
);

    localparam DIR_LOAD  = 2'd0;
    localparam DIR_SAVE  = 2'd1;
    localparam DIR_ERASE = 2'd2;

    // FLASH_SPACE_BYTES = 16MB = 2^24 does NOT fit in 24 bits (24 bits
    // only reaches 2^24-1) -- needs 25. Caught by iverilog's own
    // "numeric constant truncated" warning on the first compile
    // attempt (it silently became 0, which would have broken every
    // bounds check below into "always in range"); widened here.
    localparam [24:0] FLASH_SPACE_BYTES = 25'h100_0000; // 16MB, 2^24
    localparam [23:0] CHUNK_MAX         = 24'h00_FFFF;  // spi_flash_master's n_data is 16b
    localparam [23:0] SECTOR_BYTES      = 24'd4096;     // Sector Erase (4KB), Table 1 p.26 "20h"
    localparam [23:0] PAGE_BYTES        = 24'd256;      // Page Program max, Table 1 p.26/note 3 p.29

    // ============================================================
    // spi_flash_master instance (F1 primitive)
    // ============================================================

    reg         fm_start;
    reg  [7:0]  fm_opcode;
    reg          fm_has_addr;
    reg  [23:0]  fm_addr;
    reg  [1:0]   fm_dir;
    reg  [15:0]  fm_n_data;

    wire         fm_wdata_req;
    reg  [7:0]   fm_wdata;      // F3: driven from a live PSRAM read during Page Program
    reg           fm_wdata_valid;

    wire         fm_rdata_valid;
    wire [7:0]   fm_rdata;
    reg           fm_rdata_ack;

    wire fm_busy;
    wire fm_done;

    localparam [1:0] FM_DIR_NONE  = 2'd0;
    localparam [1:0] FM_DIR_WRITE = 2'd1;
    localparam [1:0] FM_DIR_READ  = 2'd2;

    spi_flash_master #(
        .CLK_FREQ_MHZ(CLK_FREQ_MHZ),
        .SCLK_DIV(SCLK_DIV)
    ) u_spi_flash_master (
        .clk(clk), .rst(rst),

        .mosi(mosi), .miso(miso), .cs_n(cs_n),
`ifdef SIMULATION
        .sclk_sim(sclk_sim),
`endif

        .start(fm_start), .opcode(fm_opcode), .has_addr(fm_has_addr),
        .addr(fm_addr), .dir(fm_dir), .n_data(fm_n_data),

        .wdata_req(fm_wdata_req), .wdata(fm_wdata), .wdata_valid(fm_wdata_valid),

        .rdata_valid(fm_rdata_valid), .rdata(fm_rdata), .rdata_ack(fm_rdata_ack),

        .busy(fm_busy), .done(fm_done)
    );

    localparam [7:0] OP_READ  = 8'h03;
    localparam [7:0] OP_WREN  = 8'h06;
    localparam [7:0] OP_PP    = 8'h02;
    localparam [7:0] OP_SE    = 8'h20;
    localparam [7:0] OP_RDSR1 = 8'h05;

    // ============================================================
    // Main FSM
    // ============================================================

    localparam ST_IDLE        = 5'd0;
    localparam ST_CHUNK_ISSUE = 5'd1;  // LOAD: starts one spi_flash_master READ for up to CHUNK_MAX bytes
    localparam ST_CHUNK_WAIT  = 5'd2;  // LOAD: services rdata_valid -> PSRAM write, one byte at a time
    localparam ST_PSRAM_WAIT  = 5'd3;  // LOAD: waiting for d_ready after issuing a PSRAM write
    localparam ST_DONE        = 5'd4;

    // F3 (SAVE) states
    localparam ST_SAVE_ERASE_WREN  = 5'd5;  // WREN before this sector's erase
    localparam ST_SAVE_ERASE_WWAIT = 5'd6;  // wait for WREN's own fm_done
    localparam ST_SAVE_ERASE_ISSUE = 5'd7;  // issue SE for the current sector
    localparam ST_SAVE_ERASE_EWAIT = 5'd8;  // wait for SE's own fm_done (command accepted, not WIP clear)
    localparam ST_SAVE_PROG_WREN   = 5'd9;  // WREN before this page's Page Program
    localparam ST_SAVE_PROG_WWAIT  = 5'd10; // wait for WREN's own fm_done
    localparam ST_SAVE_PROG_ISSUE  = 5'd11; // issue PP header for the current page
    localparam ST_SAVE_PROG_BYTE   = 5'd12; // waiting for fm_wdata_req or fm_done (page byte loop)
    localparam ST_SAVE_PROG_PWAIT  = 5'd13; // waiting for d_ready on the PSRAM source read (presents wdata_valid the same cycle d_ready arrives)

    // Shared RDSR (WIP) poll, used after both SE and PP -- which one
    // is in progress, and what to do once WIP clears, is tracked by
    // `save_phase` (below) rather than duplicated poll logic.
    localparam ST_RDSR_ISSUE    = 5'd15;
    localparam ST_RDSR_BYTE     = 5'd16; // waiting for the single response byte
    localparam ST_RDSR_DWAIT    = 5'd17; // wait for RDSR's own fm_done

    reg [4:0] state;
    reg [23:0] remaining;
    reg [23:0] cur_flash_addr;
    reg [PSRAM_ADDR_WIDTH-1:0] cur_psram_addr;

    // F3 (SAVE) bookkeeping
    localparam SAVE_PHASE_ERASE = 1'b0;
    localparam SAVE_PHASE_PROG  = 1'b1;
    reg        save_phase;
    reg [24:0] save_end;        // flash_addr + len, one extra bit of headroom
    reg [23:0] erase_addr;      // current sector cursor during the erase phase
    reg [23:0] prog_addr;       // current flash address cursor during the program phase
    reg [PSRAM_ADDR_WIDTH-1:0] prog_psram_addr; // current PSRAM source cursor
    reg [23:0] prog_remaining;  // bytes left to program overall
    reg        wip_busy;        // RDSR-1 bit0, captured by the poll
    reg        erase_only;      // F5 (DIR_ERASE): stop after the erase phase, no program phase

    assign busy  = (state != ST_IDLE);

    // d_req must drop the SAME cycle d_ready is observed, not wait
    // for the state transition out of ST_PSRAM_WAIT (which only
    // takes effect the following cycle): mem_arbiter's grant of Port
    // D also completes (owner -> SEL_NONE) that same cycle, and its
    // SEL_NONE case is combinational logic re-evaluated that very
    // cycle -- if d_req were still 1 (as it would be with a plain
    // `state == ST_PSRAM_WAIT` here, since `state` itself hasn't
    // updated yet), the arbiter would immediately re-grant Port D a
    // SECOND time using stale d_addr/d_wdata, which this engine is
    // no longer driving meaningfully. Found during F2 bring-up (see
    // WORKLOG.md) as a hang after the last byte of a LOAD. Same
    // reasoning applies to F3's SAVE-side PSRAM source reads
    // (ST_SAVE_PROG_PWAIT) -- same Port D, same arbiter, same race.
    assign d_req = ((state == ST_PSRAM_WAIT) || (state == ST_SAVE_PROG_PWAIT)) && !d_ready;

    always @(posedge clk) begin

        if (rst) begin

            state          <= ST_IDLE;
            done           <= 1'b0;
            err            <= 1'b0;
            fm_start       <= 1'b0;
            fm_opcode      <= 8'h00;
            fm_has_addr    <= 1'b0;
            fm_addr        <= 24'h0;
            fm_dir         <= 2'd0;
            fm_n_data      <= 16'h0;
            fm_rdata_ack   <= 1'b0;
            d_wr           <= 1'b0;
            d_addr         <= {PSRAM_ADDR_WIDTH{1'b0}};
            d_wdata        <= 8'sd0;
            remaining      <= 24'h0;
            cur_flash_addr <= 24'h0;
            cur_psram_addr <= {PSRAM_ADDR_WIDTH{1'b0}};

            fm_wdata       <= 8'h00;
            fm_wdata_valid <= 1'b0;

            save_phase      <= SAVE_PHASE_ERASE;
            save_end        <= 25'h0;
            erase_addr      <= 24'h0;
            prog_addr       <= 24'h0;
            prog_psram_addr <= {PSRAM_ADDR_WIDTH{1'b0}};
            prog_remaining  <= 24'h0;
            wip_busy        <= 1'b0;
            erase_only      <= 1'b0;

        end else begin

            fm_start       <= 1'b0;
            fm_rdata_ack   <= 1'b0;
            fm_wdata_valid <= 1'b0;
            done           <= 1'b0;

            case (state)

                // --------------------------------------------
                ST_IDLE: begin

                    if (op_start) begin

                        if (op_dir == DIR_ERASE) begin

                            // F5: standalone sector erase. `len` and
                            // `psram_addr` are not meaningful here
                            // (ignored) -- only flash_addr's own
                            // sector-alignment and range matter.
                            if ( ({8'h0, flash_addr} + {8'h0, SECTOR_BYTES}) > {7'h0, FLASH_SPACE_BYTES} ||
                                 flash_addr[11:0] != 12'h000
                               ) begin
                                err  <= 1'b1;
                                done <= 1'b1;
                            end else begin
                                err        <= 1'b0;
                                save_phase <= SAVE_PHASE_ERASE;
                                erase_addr <= flash_addr;
                                save_end   <= {1'b0, flash_addr} + {1'b0, SECTOR_BYTES}; // exactly one sector
                                erase_only <= 1'b1;
                                state      <= ST_SAVE_ERASE_WREN;
                            end

                        // §A.3 negative cases (LOAD/SAVE): length
                        // pushes either address space past its own
                        // size (compared in generously-wide 32b
                        // temporaries so no same-width overflow can
                        // hide the very condition being checked
                        // for); an unknown direction; and, for SAVE
                        // only, a non-sector-aligned flash_addr (the
                        // design decision documented in the module
                        // header).
                        end else if ( ({8'h0, flash_addr} + {8'h0, len}) > {7'h0, FLASH_SPACE_BYTES} ||
                             ({{(32-PSRAM_ADDR_WIDTH){1'b0}}, psram_addr} + {8'h0, len})
                               > (32'h1 << PSRAM_ADDR_WIDTH) ||
                             len == 24'h0 ||
                             (op_dir != DIR_LOAD && op_dir != DIR_SAVE) ||
                             (op_dir == DIR_SAVE && flash_addr[11:0] != 12'h000)
                           ) begin
                            err  <= 1'b1;
                            done <= 1'b1;
                        end else if (op_dir == DIR_LOAD) begin
                            err            <= 1'b0;
                            remaining      <= len;
                            cur_flash_addr <= flash_addr;
                            cur_psram_addr <= psram_addr;
                            state          <= ST_CHUNK_ISSUE;
                        end else begin // DIR_SAVE
                            err             <= 1'b0;
                            erase_only      <= 1'b0;
                            save_phase      <= SAVE_PHASE_ERASE;
                            save_end        <= {1'b0, flash_addr} + {1'b0, len};
                            erase_addr      <= flash_addr;
                            prog_addr       <= flash_addr;
                            prog_psram_addr <= psram_addr;
                            prog_remaining  <= len;
                            state           <= ST_SAVE_ERASE_WREN;
                        end

                    end

                end

                // --------------------------------------------
                ST_CHUNK_ISSUE: begin

                    fm_start    <= 1'b1;
                    fm_opcode   <= OP_READ;
                    fm_has_addr <= 1'b1;
                    fm_addr     <= cur_flash_addr;
                    fm_dir      <= FM_DIR_READ;
                    fm_n_data   <= (remaining > {8'h0, CHUNK_MAX}) ? CHUNK_MAX[15:0] : remaining[15:0];

                    state <= ST_CHUNK_WAIT;

                end

                // --------------------------------------------
                // Services one byte at a time: spi_flash_master
                // pauses (holds CS low, sclk idle) with rdata_valid
                // asserted until fm_rdata_ack; meanwhile this state
                // issues the matching PSRAM write and waits for
                // d_ready before acking, giving natural backpressure
                // -- the flash is never read faster than PSRAM can
                // absorb.
                // --------------------------------------------
                ST_CHUNK_WAIT: begin

                    if (fm_rdata_valid) begin
                        d_wr    <= 1'b1;
                        d_addr  <= cur_psram_addr;
                        d_wdata <= $signed(fm_rdata);
                        state   <= ST_PSRAM_WAIT; // d_req becomes 1 combinationally, see assign above
                    end else if (fm_done) begin
                        // Chunk's spi_flash_master transaction fully
                        // complete (`remaining` already decremented,
                        // one per byte, in ST_PSRAM_WAIT below --
                        // for each byte of THIS chunk). Zero means
                        // the whole request is done; nonzero means
                        // another chunk is still needed.
                        if (remaining == 24'h0) begin
                            state <= ST_DONE;
                        end else begin
                            state <= ST_CHUNK_ISSUE;
                        end
                    end

                end

                // --------------------------------------------
                ST_PSRAM_WAIT: begin

                    if (d_ready) begin
                        fm_rdata_ack   <= 1'b1;
                        cur_flash_addr <= cur_flash_addr + 24'd1;
                        cur_psram_addr <= cur_psram_addr + 1'b1;
                        remaining      <= remaining - 24'd1;
                        state          <= ST_CHUNK_WAIT;
                    end

                end

                // --------------------------------------------
                ST_DONE: begin
                    done  <= 1'b1;
                    state <= ST_IDLE;
                end

                // ============================================
                // F3 (SAVE): erase phase
                // ============================================

                ST_SAVE_ERASE_WREN: begin
                    fm_start    <= 1'b1;
                    fm_opcode   <= OP_WREN;
                    fm_has_addr <= 1'b0;
                    fm_dir      <= FM_DIR_NONE;
                    fm_n_data   <= 16'd0;
                    state       <= ST_SAVE_ERASE_WWAIT;
                end

                ST_SAVE_ERASE_WWAIT: begin
                    if (fm_done)
                        state <= ST_SAVE_ERASE_ISSUE;
                end

                ST_SAVE_ERASE_ISSUE: begin
                    fm_start    <= 1'b1;
                    fm_opcode   <= OP_SE;
                    fm_has_addr <= 1'b1;
                    fm_addr     <= erase_addr;
                    fm_dir      <= FM_DIR_NONE;
                    fm_n_data   <= 16'd0;
                    state       <= ST_SAVE_ERASE_EWAIT;
                end

                ST_SAVE_ERASE_EWAIT: begin
                    // SE's own fm_done only means the command was
                    // clocked in, NOT that the erase has physically
                    // completed -- §2.1/§2.4 of the phase-plan: must
                    // poll RDSR-1's WIP bit next.
                    if (fm_done) begin
                        save_phase <= SAVE_PHASE_ERASE;
                        state      <= ST_RDSR_ISSUE;
                    end
                end

                // ============================================
                // F3 (SAVE): program phase, one page (<=256B) at a
                // time, each individually WREN'd and WIP-polled.
                // ============================================

                ST_SAVE_PROG_WREN: begin
                    fm_start    <= 1'b1;
                    fm_opcode   <= OP_WREN;
                    fm_has_addr <= 1'b0;
                    fm_dir      <= FM_DIR_NONE;
                    fm_n_data   <= 16'd0;
                    state       <= ST_SAVE_PROG_WWAIT;
                end

                ST_SAVE_PROG_WWAIT: begin
                    if (fm_done)
                        state <= ST_SAVE_PROG_ISSUE;
                end

                ST_SAVE_PROG_ISSUE: begin
                    fm_start    <= 1'b1;
                    fm_opcode   <= OP_PP;
                    fm_has_addr <= 1'b1;
                    fm_addr     <= prog_addr;
                    fm_dir      <= FM_DIR_WRITE;
                    // Never crosses a 256B page boundary: prog_addr
                    // is always page-aligned when a page starts
                    // (flash_addr was required sector-, hence page-,
                    // aligned at DIR_SAVE dispatch, and every page
                    // before this one consumed exactly PAGE_BYTES
                    // bytes -- only the LAST page of the whole
                    // request can be shorter).
                    fm_n_data   <= (prog_remaining > PAGE_BYTES) ? PAGE_BYTES[15:0] : prog_remaining[15:0];
                    state       <= ST_SAVE_PROG_BYTE;
                end

                // Services spi_flash_master's wdata_req one byte at
                // a time by reading the next PSRAM source byte
                // (Port D) and handing it straight through -- no
                // local page buffer, same "stream through" style as
                // the LOAD path. prog_addr/prog_psram_addr/
                // prog_remaining are advanced per-byte in
                // ST_SAVE_PROG_PWAIT below, so by the time fm_done
                // fires here they already reflect the post-page
                // state (mirrors ST_PSRAM_WAIT's own bookkeeping on
                // the LOAD side).
                ST_SAVE_PROG_BYTE: begin
                    if (fm_wdata_req) begin
                        d_wr   <= 1'b0;
                        d_addr <= prog_psram_addr;
                        state  <= ST_SAVE_PROG_PWAIT;
                    end else if (fm_done) begin
                        save_phase <= SAVE_PHASE_PROG;
                        state      <= ST_RDSR_ISSUE;
                    end
                end

                ST_SAVE_PROG_PWAIT: begin
                    if (d_ready) begin
                        fm_wdata        <= d_rdata;
                        fm_wdata_valid  <= 1'b1;
                        prog_psram_addr <= prog_psram_addr + 1'b1;
                        prog_addr       <= prog_addr + 24'd1;
                        prog_remaining  <= prog_remaining - 24'd1;
                        state           <= ST_SAVE_PROG_BYTE;
                    end
                end

                // ============================================
                // Shared RDSR-1 (WIP) poll, used after both SE and
                // PP. `save_phase` (latched by the caller just
                // before entering here) decides what "WIP cleared"
                // means next: advance to the next sector / finish
                // the erase phase, or advance to the next page /
                // finish the whole SAVE.
                // ============================================

                ST_RDSR_ISSUE: begin
                    fm_start    <= 1'b1;
                    fm_opcode   <= OP_RDSR1;
                    fm_has_addr <= 1'b0;
                    fm_dir      <= FM_DIR_READ;
                    fm_n_data   <= 16'd1;
                    state       <= ST_RDSR_BYTE;
                end

                ST_RDSR_BYTE: begin
                    if (fm_rdata_valid) begin
                        wip_busy     <= fm_rdata[0]; // RDSR-1 bit0 = BUSY/WIP, sim/flash_model.v header
                        fm_rdata_ack <= 1'b1;
                        state        <= ST_RDSR_DWAIT;
                    end
                end

                ST_RDSR_DWAIT: begin
                    if (fm_done) begin
                        if (wip_busy) begin
                            state <= ST_RDSR_ISSUE; // still busy: poll again
                        end else if (save_phase == SAVE_PHASE_ERASE) begin
                            erase_addr <= erase_addr + SECTOR_BYTES;
                            if (({1'b0, erase_addr} + {1'b0, SECTOR_BYTES}) >= save_end) begin
                                // Erase phase covers the whole requested
                                // range: F5's standalone DIR_ERASE stops
                                // here (erase_only); DIR_SAVE falls
                                // through to programming.
                                state <= erase_only ? ST_DONE : ST_SAVE_PROG_WREN;
                            end else begin
                                state <= ST_SAVE_ERASE_WREN; // next sector
                            end
                        end else begin // SAVE_PHASE_PROG
                            if (prog_remaining == 24'h0) begin
                                state <= ST_DONE;
                            end else begin
                                state <= ST_SAVE_PROG_WREN; // next page
                            end
                        end
                    end
                end

                default: state <= ST_IDLE;

            endcase

        end

    end

endmodule
