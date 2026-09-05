`timescale 1ns/1ps

// ================================================================
// FLASH_SLOT_MANAGER
//
// Fixed-slot catalog layer on top of rtl/flash_copy_engine.v (F2/F3,
// reused UNCHANGED -- zero modifications, zero regression risk to
// its already-verified LOAD/SAVE paths). This is the module the
// flash-subsystem phase-plan's §4 describes: NOT a filesystem --
// a small fixed-size table mapping slot_id -> (offset, length,
// type, valid, CRC), read at boot and resolved before every
// LOAD_SLOT/SAVE_SLOT, no dynamic allocation, no GC.
//
// ----------------------------------------------------------------
// Catalog layout (matches tools/flash_catalog/oracle.py exactly --
// that script is the independent §A.1 oracle for both the byte
// layout and the CRC32 value; kept in sync by hand, cross-checked
// by the testbenches comparing actual bytes, not by either side
// trusting the other's prose)
// ----------------------------------------------------------------
//   - N_SLOTS = 16 entries x ENTRY_BYTES = 16 bytes = 256 bytes
//     total, comfortably inside one 4KB sector (CATALOG_SECTOR_ADDR,
//     flash sector 0 -- RESERVED, never used for slot data).
//   - Per-entry layout, MSB-first: offset[24b] | length[24b] |
//     type[8b] | valid[8b] (0x01=valid, else invalid) | crc32[32b]
//     | reserved[32b, always 0].
//   - A freshly-erased catalog sector is all-0xFF, so every
//     unwritten slot decodes as valid=0xFF != 0x01 => invalid,
//     without needing any format/init step -- matches flash_model.v
//     and the real Winbond erase behavior (§8.2.18 p.56).
//
// ----------------------------------------------------------------
// How the catalog gets to/from flash without touching PSRAM as user
// data (design decision, documented per the phase-plan's own
// "traccia ogni scelta" requirement):
// ----------------------------------------------------------------
//   flash_copy_engine already knows how to move bytes flash<->PSRAM
//   (F2/F3). Rather than teach it a THIRD destination (on-chip
//   registers), this module stages the 256-byte catalog through a
//   small reserved PSRAM region (CATALOG_PSRAM_ADDR) using
//   flash_copy_engine's EXISTING, unmodified DIR_LOAD/DIR_SAVE, then
//   itself reads/writes that staging region byte-by-byte via the
//   SAME Port D connection flash_copy_engine uses -- safe because
//   the two uses are TEMPORALLY DISJOINT by construction (this
//   module's own sequential FSM never drives Port D itself while an
//   internal flash_copy_engine operation is in flight, and vice
//   versa): a static mux on `fce_busy` selects the owner, no new
//   arbiter port needed.
//   ASSUMPTION flagged (§A.5): CATALOG_PSRAM_ADDR is a convention,
//   not enforced anywhere else -- nothing else in this design may
//   use that PSRAM range while a catalog operation is in flight.
//
// ----------------------------------------------------------------
// CRC32 (rtl/crc32.v, IEEE 802.3/zlib -- verified independently
// against tools/flash_catalog/oracle.py + a textbook check-value,
// see sim/crc32_tb.v / WORKLOG.md's F4 entry) is computed by TAPPING
// flash_copy_engine's own Port D traffic while it is the active
// owner during a LOAD_SLOT or SAVE_SLOT (fce_d_wdata for a LOAD's
// PSRAM writes, fce_d_rdata for a SAVE's PSRAM reads) -- again zero
// modification to flash_copy_engine.v itself.
// ----------------------------------------------------------------
//
// Command interface:
//   op_start, op_code (OP_CAT_READ / OP_CAT_WRITE_SLOT /
//   OP_LOAD_SLOT / OP_SAVE_SLOT), slot_id, and per-opcode fields
//   below. busy/done/err mirror flash_copy_engine's own convention.
//
//   OP_CAT_READ: reloads the on-chip catalog register file from the
//     flash catalog sector (e.g. at boot, or to force a refresh).
//   OP_CAT_WRITE_SLOT: registers/updates slot_id's (offset, length,
//     type) in the on-chip table, marks it INVALID (no verified
//     data behind it yet -- SAVE_SLOT is what marks it valid), and
//     persists the WHOLE catalog table to flash.
//   OP_LOAD_SLOT(slot_id, psram_addr): resolves slot_id's offset+
//     length from the on-chip catalog; if invalid, `err`+`done`
//     immediately, no flash/PSRAM touched. Otherwise streams the
//     slot's data flash->PSRAM (reusing flash_copy_engine's DIR_LOAD
//     verbatim) while recomputing the CRC32 live; if it does not
//     match the catalog's stored CRC, `err` is asserted (the data
//     still lands in PSRAM -- the host is being told "unreliable",
//     not given a transactional rollback, matching this project's
//     existing STATUS-flag error convention rather than introducing
//     a new one).
//   OP_SAVE_SLOT(slot_id, psram_addr, length): resolves slot_id's
//     already-registered offset (from a prior CAT_WRITE_SLOT);
//     streams `length` bytes PSRAM->flash at that offset (reusing
//     flash_copy_engine's DIR_SAVE verbatim) while computing the
//     CRC32 live; on completion updates the on-chip entry (length,
//     crc, valid=1) and persists the whole catalog to flash.
// ================================================================

module flash_slot_manager #(
    parameter PSRAM_ADDR_WIDTH   = 23,
    parameter CLK_FREQ_MHZ       = 80,
    parameter SCLK_DIV           = 2,
    parameter [PSRAM_ADDR_WIDTH-1:0] CATALOG_PSRAM_ADDR = {PSRAM_ADDR_WIDTH{1'b0}}
)(
    input  wire clk,
    input  wire rst,

    // ------------------------------------------------------------
    // Physical flash pins (owns flash_copy_engine, which owns
    // spi_flash_master -- same ownership chain as F2/F3)
    // ------------------------------------------------------------
    output wire mosi,
    input  wire miso,
    output wire cs_n,
    output wire sclk,   // ordinary GPIO, real in both sim and synthesis

    // ------------------------------------------------------------
    // Command interface. op_code 0-3 are the F4 catalog/slot ops;
    // 4-6 (added in F5) are raw, non-slot, non-CRC block ops that
    // just forward straight to the internal flash_copy_engine --
    // the phase-plan's §5 FLASH_READ_BLOCK/FLASH_WRITE_BLOCK/
    // FLASH_ERASE, which take an explicit flash address rather than
    // resolving one from the catalog.
    // ------------------------------------------------------------
    input  wire        op_start,
    input  wire [2:0]  op_code,
    input  wire [3:0]  slot_id,

    input  wire [23:0] new_offset,   // CAT_WRITE_SLOT
    input  wire [23:0] new_length,   // CAT_WRITE_SLOT
    input  wire [7:0]  new_type,     // CAT_WRITE_SLOT

    input  wire [PSRAM_ADDR_WIDTH-1:0] ext_psram_addr, // LOAD_SLOT / SAVE_SLOT / raw ops
    input  wire [23:0] ext_length,   // SAVE_SLOT / raw block ops
    input  wire [23:0] raw_flash_addr, // FLASH_READ_BLOCK / FLASH_WRITE_BLOCK / FLASH_ERASE

    output wire         busy,
    output reg           done, // one-cycle pulse
    output reg           err,  // held until next op_start

    // ------------------------------------------------------------
    // Catalog inspection (combinational read port, e.g. for a
    // future CAT_READ SPI response -- F5 -- or this module's own
    // testbench)
    // ------------------------------------------------------------
    input  wire [3:0]  cat_read_sel,
    output wire [23:0] cat_out_offset,
    output wire [23:0] cat_out_length,
    output wire [7:0]  cat_out_type,
    output wire         cat_out_valid,
    output wire [31:0] cat_out_crc,

    // ------------------------------------------------------------
    // PSRAM arbiter master port (mem_arbiter.v Port D) -- muxed
    // between the internal flash_copy_engine's own use and this
    // module's own catalog-staging-buffer access, see header.
    // ------------------------------------------------------------
    output wire                          d_req,
    output wire                          d_wr,
    output wire [PSRAM_ADDR_WIDTH-1:0]   d_addr,
    output wire signed [7:0]             d_wdata,
    input  wire signed [7:0]             d_rdata,
    input  wire                          d_ready
);

    localparam OP_CAT_READ         = 3'd0;
    localparam OP_CAT_WRITE_SLOT   = 3'd1;
    localparam OP_LOAD_SLOT        = 3'd2;
    localparam OP_SAVE_SLOT        = 3'd3;
    localparam OP_FLASH_READ_BLOCK  = 3'd4; // F5, raw: flash -> PSRAM, explicit flash_addr
    localparam OP_FLASH_WRITE_BLOCK = 3'd5; // F5, raw: PSRAM -> flash, explicit flash_addr
    localparam OP_FLASH_ERASE       = 3'd6; // F5, raw: standalone sector erase

    localparam N_SLOTS      = 16;
    localparam ENTRY_BYTES  = 16;
    localparam CATALOG_BYTES = N_SLOTS * ENTRY_BYTES; // 256
    localparam [23:0] CATALOG_SECTOR_ADDR = 24'h000000; // reserved, see header

    localparam [7:0] VALID_MARK = 8'h01;

    // ============================================================
    // On-chip catalog register file
    // ============================================================

    reg [23:0] cat_offset [0:N_SLOTS-1];
    reg [23:0] cat_length [0:N_SLOTS-1];
    reg [7:0]  cat_type   [0:N_SLOTS-1];
    reg        cat_valid  [0:N_SLOTS-1];
    reg [31:0] cat_crc    [0:N_SLOTS-1];

    assign cat_out_offset = cat_offset[cat_read_sel];
    assign cat_out_length = cat_length[cat_read_sel];
    assign cat_out_type   = cat_type[cat_read_sel];
    assign cat_out_valid  = cat_valid[cat_read_sel];
    assign cat_out_crc    = cat_crc[cat_read_sel];

    // ============================================================
    // flash_copy_engine instance (F2/F3 primitive, unmodified)
    // ============================================================

    reg          fce_start;
    reg  [1:0]   fce_dir;
    reg  [23:0]  fce_flash_addr;
    reg  [PSRAM_ADDR_WIDTH-1:0] fce_psram_addr;
    reg  [23:0]  fce_len;

    wire fce_busy, fce_done, fce_err;

    wire                          fce_d_req, fce_d_wr;
    wire [PSRAM_ADDR_WIDTH-1:0]   fce_d_addr;
    wire signed [7:0]             fce_d_wdata;

    localparam FCE_DIR_LOAD  = 2'd0;
    localparam FCE_DIR_SAVE  = 2'd1;
    localparam FCE_DIR_ERASE = 2'd2;

    flash_copy_engine #(
        .PSRAM_ADDR_WIDTH(PSRAM_ADDR_WIDTH),
        .CLK_FREQ_MHZ(CLK_FREQ_MHZ),
        .SCLK_DIV(SCLK_DIV)
    ) u_fce (
        .clk(clk), .rst(rst),

        .mosi(mosi), .miso(miso), .cs_n(cs_n), .sclk(sclk),

        .op_start(fce_start), .op_dir(fce_dir),
        .flash_addr(fce_flash_addr), .psram_addr(fce_psram_addr), .len(fce_len),
        .busy(fce_busy), .done(fce_done), .err(fce_err),

        .d_req(fce_d_req), .d_wr(fce_d_wr), .d_addr(fce_d_addr), .d_wdata(fce_d_wdata),
        .d_rdata(d_rdata), .d_ready(d_ready)
    );

    // ============================================================
    // Port D mux: fce owns it whenever busy; otherwise this module
    // drives it directly for catalog-staging-buffer access. See
    // header for why this is safe without a new arbiter port.
    // ============================================================

    reg                          fsm_d_req;
    reg                          fsm_d_wr;
    reg  [PSRAM_ADDR_WIDTH-1:0]  fsm_d_addr;
    reg  signed [7:0]            fsm_d_wdata;

    assign d_req   = fce_busy ? fce_d_req   : fsm_d_req;
    assign d_wr    = fce_busy ? fce_d_wr    : fsm_d_wr;
    assign d_addr  = fce_busy ? fce_d_addr  : fsm_d_addr;
    assign d_wdata = fce_busy ? fce_d_wdata : fsm_d_wdata;

    // ============================================================
    // CRC32 accumulator, tapped from fce's own Port D traffic while
    // it is the active owner (see header). Active only during
    // LOAD_SLOT/SAVE_SLOT's data-transfer phase (`crc_active`).
    // ============================================================

    reg         crc_active;
    reg  [31:0] crc_acc;
    wire [31:0] crc_next;
    wire [7:0]  crc_tap_byte = fce_d_wr ? fce_d_wdata : d_rdata; // LOAD writes vs SAVE reads

    crc32_byte u_crc32 (
        .crc_in(crc_acc),
        .data(crc_tap_byte),
        .crc_out(crc_next)
    );

    // NOTE: fce's own `d_req` is combinationally defined (in
    // flash_copy_engine.v) as `(waiting_state) && !d_ready` -- so
    // `fce_d_req && d_ready` is a contradiction, always false, and
    // would never fire. The correct "a byte transfer through fce
    // just completed" condition is simply `fce_busy && d_ready`: at
    // that exact cycle fce's own state hasn't advanced out of its
    // waiting state yet (same one-cycle-late FSM update reasoning
    // documented in flash_copy_engine.v), so fce_busy is still 1,
    // and this is the only reason d_ready would be high while fce
    // owns Port D (see the mux above).
    always @(posedge clk) begin
        if (rst) begin
            crc_acc <= 32'hFFFFFFFF;
        end else if (crc_active && fce_busy && d_ready) begin
            crc_acc <= crc_next;
        end else if (!crc_active) begin
            crc_acc <= 32'hFFFFFFFF; // re-armed for the next operation
        end
    end

    // ============================================================
    // Main FSM
    // ============================================================

    localparam ST_IDLE           = 4'd0;

    localparam ST_CATRD_FCE_GO   = 4'd1;
    localparam ST_CATRD_FCE_WAIT = 4'd2;
    localparam ST_CATRD_RD_ISSUE = 4'd3;
    localparam ST_CATRD_RD_WAIT  = 4'd4;

    localparam ST_CATWR_SER_ISSUE = 4'd5;
    localparam ST_CATWR_SER_WAIT  = 4'd6;
    localparam ST_CATWR_FCE_GO    = 4'd7;
    localparam ST_CATWR_FCE_WAIT  = 4'd8;

    localparam ST_SLOT_FCE_GO    = 4'd9;
    localparam ST_SLOT_FCE_WAIT  = 4'd10;
    localparam ST_SLOT_CATWR_KICK = 4'd11; // SAVE_SLOT only: fall into the CAT_WRITE_SLOT persist sequence

    localparam ST_DONE = 4'd15;

    reg [3:0] state;
    reg [8:0] byte_idx;          // 0..255, position within the 256B catalog
    reg [3:0] cur_slot;          // slot_id of the entry currently being (de)serialized
    reg [127:0] entry_shift;     // 16-byte (de)serialization shift register, see header

    reg [2:0] active_op;
    reg [3:0] active_slot;

    integer rst_i;

    assign busy = (state != ST_IDLE);

    always @(posedge clk) begin

        if (rst) begin

            state      <= ST_IDLE;
            done       <= 1'b0;
            err        <= 1'b0;
            fce_start  <= 1'b0;
            fce_dir    <= 2'd0;
            fce_flash_addr <= 24'h0;
            fce_psram_addr <= {PSRAM_ADDR_WIDTH{1'b0}};
            fce_len    <= 24'h0;
            fsm_d_req  <= 1'b0;
            fsm_d_wr   <= 1'b0;
            fsm_d_addr <= {PSRAM_ADDR_WIDTH{1'b0}};
            fsm_d_wdata <= 8'sd0;
            crc_active <= 1'b0;
            byte_idx   <= 9'h0;
            cur_slot   <= 4'h0;
            entry_shift <= 128'h0;
            active_op  <= 2'd0;
            active_slot <= 4'h0;

            for (rst_i = 0; rst_i < N_SLOTS; rst_i = rst_i + 1) begin
                cat_offset[rst_i] <= 24'h0;
                cat_length[rst_i] <= 24'h0;
                cat_type[rst_i]   <= 8'h0;
                cat_valid[rst_i]  <= 1'b0;
                cat_crc[rst_i]    <= 32'h0;
            end

        end else begin

            fce_start  <= 1'b0;
            fsm_d_req  <= 1'b0;
            done       <= 1'b0;

            case (state)

                // ========================================
                ST_IDLE: begin

                    if (op_start) begin
                        active_op   <= op_code;
                        active_slot <= slot_id;

                        case (op_code)

                            OP_CAT_READ: begin
                                err            <= 1'b0;
                                fce_start      <= 1'b1;
                                fce_dir        <= FCE_DIR_LOAD;
                                fce_flash_addr <= CATALOG_SECTOR_ADDR;
                                fce_psram_addr <= CATALOG_PSRAM_ADDR;
                                fce_len        <= CATALOG_BYTES[23:0];
                                state          <= ST_CATRD_FCE_WAIT;
                            end

                            OP_CAT_WRITE_SLOT: begin
                                err <= 1'b0;
                                cat_offset[slot_id] <= new_offset;
                                cat_length[slot_id] <= new_length;
                                cat_type[slot_id]   <= new_type;
                                cat_valid[slot_id]  <= 1'b0; // no verified data yet, see header
                                cat_crc[slot_id]    <= 32'h0;
                                byte_idx  <= 9'h0;
                                cur_slot  <= 4'h0;
                                state     <= ST_CATWR_SER_ISSUE;
                            end

                            OP_LOAD_SLOT: begin
                                if (!cat_valid[slot_id]) begin
                                    err  <= 1'b1;
                                    done <= 1'b1;
                                end else begin
                                    err            <= 1'b0;
                                    crc_active     <= 1'b1;
                                    fce_start      <= 1'b1;
                                    fce_dir        <= FCE_DIR_LOAD;
                                    fce_flash_addr <= cat_offset[slot_id];
                                    fce_psram_addr <= ext_psram_addr;
                                    fce_len        <= cat_length[slot_id];
                                    state          <= ST_SLOT_FCE_WAIT;
                                end
                            end

                            OP_SAVE_SLOT: begin
                                err            <= 1'b0;
                                crc_active     <= 1'b1;
                                fce_start      <= 1'b1;
                                fce_dir        <= FCE_DIR_SAVE;
                                fce_flash_addr <= cat_offset[slot_id]; // registered by a prior CAT_WRITE_SLOT
                                fce_psram_addr <= ext_psram_addr;
                                fce_len        <= ext_length;
                                state          <= ST_SLOT_FCE_WAIT;
                            end

                            // F5: raw block ops, no catalog/CRC
                            // involvement at all -- straight pass-
                            // through to flash_copy_engine with an
                            // explicit flash address from the host.
                            OP_FLASH_READ_BLOCK: begin
                                err            <= 1'b0;
                                fce_start      <= 1'b1;
                                fce_dir        <= FCE_DIR_LOAD;
                                fce_flash_addr <= raw_flash_addr;
                                fce_psram_addr <= ext_psram_addr;
                                fce_len        <= ext_length;
                                state          <= ST_SLOT_FCE_WAIT;
                            end

                            OP_FLASH_WRITE_BLOCK: begin
                                err            <= 1'b0;
                                fce_start      <= 1'b1;
                                fce_dir        <= FCE_DIR_SAVE;
                                fce_flash_addr <= raw_flash_addr;
                                fce_psram_addr <= ext_psram_addr;
                                fce_len        <= ext_length;
                                state          <= ST_SLOT_FCE_WAIT;
                            end

                            OP_FLASH_ERASE: begin
                                err            <= 1'b0;
                                fce_start      <= 1'b1;
                                fce_dir        <= FCE_DIR_ERASE;
                                fce_flash_addr <= raw_flash_addr;
                                state          <= ST_SLOT_FCE_WAIT;
                            end

                            default: begin
                                err  <= 1'b1;
                                done <= 1'b1;
                            end

                        endcase
                    end

                end

                // ========================================
                // CAT_READ: load the catalog sector into the
                // PSRAM staging buffer (fce, unmodified), then
                // parse it 16 bytes (one entry) at a time.
                // ========================================

                ST_CATRD_FCE_WAIT: begin
                    if (fce_done) begin
                        byte_idx <= 9'h0;
                        state    <= ST_CATRD_RD_ISSUE;
                    end
                end

                ST_CATRD_RD_ISSUE: begin
                    fsm_d_req  <= 1'b1;
                    fsm_d_wr   <= 1'b0;
                    fsm_d_addr <= CATALOG_PSRAM_ADDR + byte_idx;
                    state      <= ST_CATRD_RD_WAIT;
                end

                ST_CATRD_RD_WAIT: begin
                    if (d_ready) begin

                        if (byte_idx[3:0] == 4'hF) begin
                            // 16th byte of this entry (bytes 12-15
                            // are reserved/ignored, so `d_rdata`
                            // itself -- this 16th byte -- never
                            // actually feeds any decoded field, only
                            // the PRE-update `entry_shift`, which at
                            // this point holds bytes 0-14 from the
                            // 15 shifts so far: entry_shift[119:112]
                            // = byte0 ... entry_shift[7:0] = byte14.
                            // See the module header for the full
                            // derivation.
                            cat_offset[byte_idx[8:4]] <= entry_shift[119:96]; // bytes 0-2
                            cat_length[byte_idx[8:4]] <= entry_shift[95:72];  // bytes 3-5
                            cat_type[byte_idx[8:4]]   <= entry_shift[71:64]; // byte 6
                            cat_valid[byte_idx[8:4]]  <= (entry_shift[63:56] == VALID_MARK); // byte 7
                            cat_crc[byte_idx[8:4]]    <= entry_shift[55:24]; // bytes 8-11
                        end

                        entry_shift <= {entry_shift[119:0], d_rdata};

                        if (byte_idx == 9'd255) begin
                            state <= ST_DONE;
                        end else begin
                            byte_idx <= byte_idx + 9'd1;
                            state    <= ST_CATRD_RD_ISSUE;
                        end
                    end
                end

                // ========================================
                // CAT_WRITE_SLOT: serialize all N_SLOTS entries
                // (from the just-updated on-chip table) into the
                // PSRAM staging buffer, then persist via fce's
                // unmodified DIR_SAVE (erase + page-program loop
                // + WIP poll, all F3).
                // ========================================

                ST_CATWR_SER_ISSUE: begin
                    fsm_d_req   <= 1'b1;
                    fsm_d_wr    <= 1'b1;
                    fsm_d_addr  <= CATALOG_PSRAM_ADDR + byte_idx;
                    // Byte to send: byte_idx[3:0] selects which of the
                    // 16 bytes of cur_slot's entry, MSB-first, same
                    // layout as the CAT_READ decode.
                    case (byte_idx[3:0])
                        4'h0: fsm_d_wdata <= cat_offset[cur_slot][23:16];
                        4'h1: fsm_d_wdata <= cat_offset[cur_slot][15:8];
                        4'h2: fsm_d_wdata <= cat_offset[cur_slot][7:0];
                        4'h3: fsm_d_wdata <= cat_length[cur_slot][23:16];
                        4'h4: fsm_d_wdata <= cat_length[cur_slot][15:8];
                        4'h5: fsm_d_wdata <= cat_length[cur_slot][7:0];
                        4'h6: fsm_d_wdata <= cat_type[cur_slot];
                        4'h7: fsm_d_wdata <= cat_valid[cur_slot] ? VALID_MARK : 8'h00;
                        4'h8: fsm_d_wdata <= cat_crc[cur_slot][31:24];
                        4'h9: fsm_d_wdata <= cat_crc[cur_slot][23:16];
                        4'hA: fsm_d_wdata <= cat_crc[cur_slot][15:8];
                        4'hB: fsm_d_wdata <= cat_crc[cur_slot][7:0];
                        default: fsm_d_wdata <= 8'h00; // reserved, bytes C-F
                    endcase
                    state <= ST_CATWR_SER_WAIT;
                end

                ST_CATWR_SER_WAIT: begin
                    if (d_ready) begin
                        if (byte_idx == 9'd255) begin
                            fce_start      <= 1'b1;
                            fce_dir        <= FCE_DIR_SAVE;
                            fce_flash_addr <= CATALOG_SECTOR_ADDR;
                            fce_psram_addr <= CATALOG_PSRAM_ADDR;
                            fce_len        <= CATALOG_BYTES[23:0];
                            state          <= ST_CATWR_FCE_WAIT;
                        end else begin
                            byte_idx <= byte_idx + 9'd1;
                            cur_slot <= (byte_idx[3:0] == 4'hF) ? (byte_idx[8:4] + 4'd1) : byte_idx[8:4];
                            state    <= ST_CATWR_SER_ISSUE;
                        end
                    end
                end

                ST_CATWR_FCE_WAIT: begin
                    // Reached either directly from a CAT_WRITE_SLOT
                    // op, or via ST_SLOT_CATWR_KICK after a
                    // SAVE_SLOT's own data transfer already updated
                    // the catalog entry -- either way, this state is
                    // just "persist the catalog sector, then done".
                    if (fce_done)
                        state <= ST_DONE;
                end

                // ========================================
                // LOAD_SLOT / SAVE_SLOT: run fce's existing
                // DIR_LOAD/DIR_SAVE verbatim, CRC accumulated via
                // the tap above.
                // ========================================

                ST_SLOT_FCE_WAIT: begin
                    if (fce_done) begin
                        crc_active <= 1'b0;

                        case (active_op)

                            OP_LOAD_SLOT: begin
                                // fce_err here would mean the
                                // catalog's own (offset,length) is
                                // somehow out of range -- shouldn't
                                // happen for a slot that passed the
                                // CAT_WRITE_SLOT/SAVE_SLOT bounds
                                // checks, but checked anyway rather
                                // than assumed.
                                if (fce_err || ((crc_acc ^ 32'hFFFFFFFF) != cat_crc[active_slot]))
                                    err <= 1'b1;
                                state <= ST_DONE;
                            end

                            OP_SAVE_SLOT: begin
                                // BUG FIXED HERE (found during F5
                                // integration review, before ever
                                // running the F5 testbench): this
                                // branch previously updated+persisted
                                // the catalog as "valid" unconditionally
                                // on fce_done, without checking
                                // fce_err first -- a SAVE_SLOT whose
                                // underlying flash_copy_engine call
                                // itself failed (e.g. an out-of-range
                                // length) would still have been
                                // marked valid in the catalog. Now
                                // skips the catalog update entirely
                                // on a failed transfer.
                                if (fce_err) begin
                                    err   <= 1'b1;
                                    state <= ST_DONE;
                                end else begin
                                    cat_length[active_slot] <= fce_len;
                                    cat_crc[active_slot]    <= crc_acc ^ 32'hFFFFFFFF;
                                    cat_valid[active_slot]  <= 1'b1;
                                    byte_idx <= 9'h0;
                                    cur_slot <= 4'h0;
                                    state    <= ST_SLOT_CATWR_KICK;
                                end
                            end

                            default: begin
                                // F5 raw block ops (FLASH_READ_BLOCK/
                                // FLASH_WRITE_BLOCK/FLASH_ERASE): no
                                // catalog/CRC involvement, just
                                // forward fce's own error status.
                                err   <= fce_err;
                                state <= ST_DONE;
                            end

                        endcase
                    end
                end

                // One-cycle bridge: the cat_* writes above need a
                // cycle to land before ST_CATWR_SER_ISSUE reads them
                // back out for serialization.
                ST_SLOT_CATWR_KICK: begin
                    state <= ST_CATWR_SER_ISSUE;
                end

                // ========================================
                ST_DONE: begin
                    done  <= 1'b1;
                    state <= ST_IDLE;
                end

                default: state <= ST_IDLE;

            endcase

        end

    end

endmodule
