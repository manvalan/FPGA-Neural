`timescale 1ns/1ps

// ================================================================
// SPI_FLASH_MASTER
//
// SPI MASTER toward the boot/persistence NOR flash (Winbond
// W25Q128JV, confirmed part per docs/FPGA-Neural-Hardware-Design.md
// §6/§7 -- see sim/flash_model.v's header for the JEDEC-ID variant
// caveat). This is the FPGA's *only* path to that flash: the host
// never touches these pins directly (see the phase-plan's §0
// constraint) -- it issues opcodes through spi_engine, which this
// module (and, in later phases, the copy engine built on top of it)
// serves.
//
// Everything the existing design talks to (rtl/spi_slave.v) is an
// SPI SLAVE toward the host. This module is the mirror image: an
// SPI MASTER toward the flash, mode 0 (CPOL=0, CPHA=0), MSB-first,
// matching every timing diagram in the W25Q128JV datasheet (Fig.
// 7/28/30/43a): MOSI driven on the falling edge of SCLK (one edge
// ahead of the flash's own rising-edge sample), MISO sampled on the
// rising edge (the flash drove it on the previous falling edge).
//
// ----------------------------------------------------------------
// ECP5 CCLK GOTCHA (USRMCLK) -- §1 of the phase-plan prompt
// ----------------------------------------------------------------
// After bitstream configuration, the ECP5's dedicated CCLK pad is
// NOT an ordinary user I/O and cannot be driven by fabric logic
// through a normal top-level port:
//
//   - Lattice FPGA-DS-02012-3.4 "ECP5 and ECP5-5G Family Data
//     Sheet", §2.18 "Device Configuration" (p.48): "There are 11
//     dedicated pins for TAP and sysConfig support (TDI, TDO, TCK,
//     TMS, CFG[2:0], PROGRAMN, DONE, INITN, and CCLK). The
//     remaining sysCONFIG pins are used as dual function pins."
//     -- CCLK is explicitly in the DEDICATED list, not the
//     dual-function list that "can be released" as user I/O
//     (§2.14.1, p.42, re: Bank 8 dual-function pins in general).
//     This is why MOSI/MISO/CS_N (bank 8 dual-function pins) CAN be
//     ordinary top-level ports here, but SCLK cannot.
//   - The mechanism to drive it anyway is the `USRMCLK` primitive.
//     Its port list (USRMCLKI, USRMCLKTS) is confirmed directly
//     from the open-source toolchain's own cell library --
//     /opt/homebrew/Cellar/yosys/*/share/yosys/ecp5/cells_bb.v,
//     `module USRMCLK(USRMCLKI, USRMCLKTS)` -- the same blackbox
//     yosys/nextpnr-ecp5 use to place it at the dedicated MCLK
//     site; not a guessed API.
//   - Full behavioral details of USRMCLK (e.g. the exact polarity
//     of USRMCLKTS, pad enable timing) live in Lattice's "ECP5 and
//     ECP5-5G sysCONFIG Usage Guide" (FPGA-TN-02039), referenced
//     repeatedly by the family datasheet (p.42/48/49) but NOT
//     present in this project's local document set -- flagged as a
//     limitation (§A.6): USRMCLKTS is tied low here (driver
//     enabled, matching the common open-source-toolchain usage
//     pattern for this primitive), unverified against the primary
//     Lattice TN. Real hardware bring-up must confirm this pin
//     actually toggles CCLK as expected -- simulation cannot: see
//     below.
//   - USRMCLK is a synthesis blackbox with NO Icarus simulation
//     model. Simulating this module therefore needs an escape hatch
//     for the physical clock pin: under `SIMULATION`, `sclk_sim` is
//     exposed as an ordinary output port (driving sim/flash_model.v
//     directly); under real synthesis, no such port exists at all
//     -- the module instantiates USRMCLK internally instead, and
//     nextpnr-ecp5 places it at the dedicated MCLK site with no LPF
//     entry needed (it is not a regular constrainable I/O pin).
// ----------------------------------------------------------------
//
// Command interface (byte-oriented, req/valid handshakes matching
// this codebase's existing conventions -- see rtl/spi_slave.v's
// rx_valid/tx_byte_req and rtl/mem_arbiter.v's req/ready):
//
//   start        -- one-cycle pulse, transaction accepted iff !busy
//   opcode[7:0]  -- flash instruction byte (RDID/READ/WREN/PP/SE/RDSR1)
//   has_addr     -- 1: send 3 address bytes (A23-A0) after opcode
//   addr[23:0]   -- address, sent MSB-first (matches every W25Q128JV
//                   instruction diagram: A23-A16, A15-A8, A7-A0)
//   dir[1:0]     -- DIR_NONE (opcode/addr only, e.g. WREN/SE),
//                   DIR_WRITE (stream n_data bytes TO the flash,
//                   e.g. PP), DIR_READ (stream n_data bytes FROM
//                   the flash, e.g. READ/RDID/RDSR1)
//   n_data[15:0] -- byte count for the data phase (0 for DIR_NONE)
//
//   wdata_req    -- one-cycle pulse: master needs the next write
//                   byte now; caller responds (same cycle or later,
//                   this module simply waits, sclk idles low with
//                   CS still held low -- a legal SPI technique, no
//                   deselect-time constraint applies mid-transaction)
//                   with wdata_valid+wdata.
//   wdata_valid  -- one-cycle pulse, wdata is valid this cycle
//   wdata[7:0]
//
//   rdata_valid  -- one-cycle pulse: rdata holds a freshly-received
//                   byte; master pauses (sclk idle, CS still low)
//                   until the caller acks.
//   rdata[7:0]
//   rdata_ack    -- one-cycle pulse from caller: byte consumed,
//                   resume shifting.
//
//   busy, done (one-cycle pulse on transaction completion)
//
// SCLK RATE -- §1 of the phase-plan prompt requires citing timing:
// the W25Q128JV(-DTR) datasheet's §9.6 AC Electrical Characteristics
// (p.90) caps the Read Data (03h) instruction specifically at
// fR=50MHz (all OTHER standard-SPI instructions allow up to
// 104-133MHz depending on VCC). Since this master uses one fixed
// divider for every instruction, it must honor the TIGHTEST of
// those limits. Default SCLK_DIV=2 at CLK_FREQ_MHZ=80 gives
// sclk = 80/(2*2) = 20MHz, comfortably under the 50MHz Read Data cap
// with margin for the rise/fall-time and setup/hold non-idealities
// this digital model does not represent (§A.6) -- correctness over
// speed, per the phase-plan's own §A.6/§8 guidance (this is an
// init/persistence path, not the inference hot path).
// ================================================================

module spi_flash_master #(
    parameter CLK_FREQ_MHZ = 80,
    parameter SCLK_DIV     = 2   // sclk = CLK_FREQ_MHZ / (2*SCLK_DIV) MHz
)(
    input  wire clk,
    input  wire rst,

    // ------------------------------------------------------------
    // Physical pins toward the flash
    // ------------------------------------------------------------
    output reg  mosi,
    input  wire miso,
    output reg  cs_n,
`ifdef SIMULATION
    output wire sclk_sim,   // simulation-only escape hatch, see header
`endif

    // ------------------------------------------------------------
    // Command interface
    // ------------------------------------------------------------
    input  wire        start,
    input  wire [7:0]  opcode,
    input  wire         has_addr,
    input  wire [23:0]  addr,
    input  wire [1:0]   dir,
    input  wire [15:0]  n_data,

    output reg          wdata_req,
    input  wire [7:0]   wdata,
    input  wire          wdata_valid,

    output reg          rdata_valid,
    output reg  [7:0]   rdata,
    input  wire          rdata_ack,

    output wire          busy,
    output reg           done
);

    localparam DIR_NONE  = 2'd0;
    localparam DIR_WRITE = 2'd1;
    localparam DIR_READ  = 2'd2;

    // ============================================================
    // SCLK generator: free-running divider, gated by `shifting`
    // (asserted only while actively clocking a bit; held with sclk
    // low and CS still low during the WAIT_W/EMIT_R handshake
    // pauses between data bytes).
    // ============================================================

    reg [15:0] div_cnt;
    reg        sclk_reg;
    reg        shifting;

    wire sclk_half_reached = (div_cnt == SCLK_DIV - 1);

    always @(posedge clk) begin
        if (rst || !shifting) begin
            div_cnt  <= 16'd0;
            sclk_reg <= 1'b0;
        end else if (sclk_half_reached) begin
            div_cnt  <= 16'd0;
            sclk_reg <= ~sclk_reg;
        end else begin
            div_cnt <= div_cnt + 16'd1;
        end
    end

    wire sclk_will_rise  = shifting & sclk_half_reached & ~sclk_reg; // about to go 0->1
    wire sclk_will_fall  = shifting & sclk_half_reached &  sclk_reg; // about to go 1->0

`ifdef SIMULATION
    assign sclk_sim = sclk_reg;
`else
    // USRMCLKTS tied low (driver enabled) -- see header for the
    // documented-but-unverified-against-the-primary-TN caveat.
    USRMCLK u_usrmclk (
        .USRMCLKI(sclk_reg),
        .USRMCLKTS(1'b0)
    );
`endif

    // ============================================================
    // Main FSM
    // ============================================================

    localparam ST_IDLE       = 4'd0;
    localparam ST_CS_SETTLE  = 4'd1; // one clk cycle: CS asserted, sclk still idle (setup margin)
    localparam ST_HDR        = 4'd2; // shifting opcode (+ addr) out
    localparam ST_DATA_WAIT_W = 4'd3; // paused: need next write byte from caller
    localparam ST_DATA_SHIFT = 4'd4; // shifting one data byte (either direction)
    localparam ST_DATA_EMIT_R = 4'd5; // paused: present a received byte, wait ack
    localparam ST_CS_RELEASE = 4'd6; // one clk cycle: CS deasserted, settle
    localparam ST_DONE       = 4'd7;

    reg [3:0]  state;
    reg [31:0] hdr_shift;   // up to 32 bits: 8 opcode + 24 addr
    reg [5:0]  hdr_len;     // total header bits for this transaction
    reg [5:0]  bit_idx;     // bit position within the current chunk (header or one data byte)
    reg [7:0]  byte_shift;  // current data byte, shifting
    reg [15:0] data_idx;    // completed data bytes so far
    reg [15:0] data_total;
    reg [1:0]  cur_dir;

    assign busy = (state != ST_IDLE);

    always @(posedge clk) begin

        if (rst) begin

            state       <= ST_IDLE;
            cs_n        <= 1'b1;
            mosi        <= 1'b0;
            shifting    <= 1'b0;
            wdata_req   <= 1'b0;
            rdata_valid <= 1'b0;
            rdata       <= 8'h00;
            done        <= 1'b0;
            hdr_shift   <= 32'h0;
            hdr_len     <= 6'd0;
            bit_idx     <= 6'd0;
            byte_shift  <= 8'h00;
            data_idx    <= 16'd0;
            data_total  <= 16'd0;
            cur_dir     <= DIR_NONE;

        end else begin

            wdata_req   <= 1'b0;
            rdata_valid <= 1'b0;
            done        <= 1'b0;

            case (state)

                // --------------------------------------------
                ST_IDLE: begin
                    shifting <= 1'b0;
                    if (start) begin
                        cs_n       <= 1'b0;
                        hdr_shift  <= has_addr ? {opcode, addr} : {opcode, 24'h0};
                        hdr_len    <= has_addr ? 6'd32 : 6'd8;
                        bit_idx    <= 6'd0;
                        data_idx   <= 16'd0;
                        data_total <= n_data;
                        cur_dir    <= dir;
                        mosi       <= opcode[7]; // bit index 0, preloaded ahead of the first rising edge
                        state      <= ST_CS_SETTLE;
                    end
                end

                // --------------------------------------------
                ST_CS_SETTLE: begin
                    shifting <= 1'b1;
                    state    <= ST_HDR;
                end

                // --------------------------------------------
                // Generic bit shifter for the header (opcode+addr).
                // MOSI updated on the falling edge (one edge ahead
                // of the flash's rising-edge sample); bit_idx
                // advances on the rising edge (the edge on which
                // the flash actually captures the bit we set up on
                // the PRECEDING falling edge).
                // --------------------------------------------
                ST_HDR: begin
                    if (sclk_will_fall) begin
                        // At this point bit_idx already equals the
                        // number of bits sampled so far (updated by
                        // the preceding rising edge, below), which
                        // is exactly the index of the NEXT bit to
                        // put on MOSI ahead of its own rising-edge
                        // sample -- e.g. after the 1st rising edge
                        // samples bit 0, bit_idx==1 and this falling
                        // edge must prepare bit 1 = hdr_shift[31-1].
                        if (bit_idx < hdr_len)
                            mosi <= hdr_shift[31 - bit_idx];
                    end
                    if (sclk_will_rise) begin
                        if (bit_idx == hdr_len - 1) begin
                            // Header done. Move to data phase or
                            // straight to CS release (DIR_NONE).
                            bit_idx <= 6'd0;
                            if (cur_dir == DIR_NONE || data_total == 16'd0) begin
                                shifting <= 1'b0;
                                state    <= ST_CS_RELEASE;
                            end else if (cur_dir == DIR_WRITE) begin
                                shifting  <= 1'b0;
                                wdata_req <= 1'b1;
                                state     <= ST_DATA_WAIT_W;
                            end else begin // DIR_READ
                                state <= ST_DATA_SHIFT;
                            end
                        end else begin
                            bit_idx <= bit_idx + 6'd1;
                        end
                    end
                end

                // --------------------------------------------
                ST_DATA_WAIT_W: begin
                    if (wdata_valid) begin
                        byte_shift <= wdata;
                        mosi       <= wdata[7];
                        bit_idx    <= 6'd0;
                        shifting   <= 1'b1;
                        state      <= ST_DATA_SHIFT;
                    end
                end

                // --------------------------------------------
                // One data byte, either direction.
                // --------------------------------------------
                ST_DATA_SHIFT: begin

                    if (sclk_will_rise) begin
                        if (cur_dir == DIR_READ)
                            byte_shift <= {byte_shift[6:0], miso};

                        if (bit_idx == 6'd7) begin

                            data_idx <= data_idx + 16'd1;

                            if (cur_dir == DIR_READ) begin
                                shifting    <= 1'b0;
                                rdata       <= {byte_shift[6:0], miso};
                                rdata_valid <= 1'b1;
                                state       <= ST_DATA_EMIT_R;
                            end else begin
                                if (data_idx + 16'd1 == data_total) begin
                                    shifting <= 1'b0;
                                    state    <= ST_CS_RELEASE;
                                end else begin
                                    shifting  <= 1'b0;
                                    wdata_req <= 1'b1;
                                    state     <= ST_DATA_WAIT_W;
                                end
                            end

                        end else begin
                            bit_idx <= bit_idx + 6'd1;
                        end
                    end

                    if (sclk_will_fall && cur_dir == DIR_WRITE) begin
                        // Same indexing rationale as ST_HDR above.
                        if (bit_idx < 6'd8)
                            mosi <= byte_shift[7 - bit_idx];
                    end

                end

                // --------------------------------------------
                ST_DATA_EMIT_R: begin
                    if (rdata_ack) begin
                        if (data_idx == data_total) begin
                            state <= ST_CS_RELEASE;
                        end else begin
                            bit_idx  <= 6'd0;
                            shifting <= 1'b1;
                            state    <= ST_DATA_SHIFT;
                        end
                    end
                end

                // --------------------------------------------
                ST_CS_RELEASE: begin
                    cs_n  <= 1'b1;
                    state <= ST_DONE;
                end

                // --------------------------------------------
                ST_DONE: begin
                    done  <= 1'b1;
                    state <= ST_IDLE;
                end

                default: state <= ST_IDLE;

            endcase

        end

    end

endmodule
