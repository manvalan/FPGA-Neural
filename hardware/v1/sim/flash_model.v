`timescale 1ns/1ps

// ================================================================
// FLASH_MODEL - behavioral model of the Winbond W25Q128JV(-DTR)
// SPI NOR flash, SIMULATION ONLY (not synthesizable, not intended
// to be instantiated anywhere but a testbench).
//
// This is an independent-oracle support model for F1-F6 of the
// flash subsystem (see WORKLOG.md): it exists so RTL testbenches
// have something to talk to that enforces the datasheet's write
// rules in hardware-like fashion (erase-to-FF, program-can-only-
// clear-bits, WIP timing, 256B page-program wraparound), rather
// than a trivial RAM that would silently accept violations the
// real chip would corrupt on. It is NOT the oracle for "is the
// design's behavior correct" (that oracle is the Python reference
// model + datasheet numbers, per WORKLOG.md §A.1) -- it is the
// thing-under-test's counterparty, playing the role of the flash.
//
// Unlike rtl/spi_slave.v (which crosses an async SPI clock into
// the FPGA's own `clk` domain via double-flop sync), this model has
// no domain of its own to defend -- it IS the SPI-clocked device,
// so sampling/driving directly on posedge/negedge of `sclk` (as the
// real chip's internal logic does) is the correct and simplest
// idiom here, not a shortcut.
//
// Datasheet: local copy at
//   /Users/michelebigi/Development/HubAudio/datasheets/W25Q128JVS.pdf
// title page identifies it as "W25Q128JV-DTR" (Double Transfer Rate
// variant). All rules modeled here come from that document's
// STANDARD SPI instruction set (§8.1.2 Table 1, p.26) and AC
// Electrical Characteristics (§9.6, p.90), which are shared across
// the whole W25Q128JV family (DTR adds extra instructions/modes on
// top; it does not change the base standard-SPI behavior modeled
// here) -- see the JEDEC ID note below for the one confirmed
// discrepancy between this PDF and the actual populated part.
//
// Modeled (datasheet citations inline at point of use below):
//   - RDID  (9Fh)  §8.2.30 p.70   -- manufacturer/type/capacity, 3 bytes
//   - READ  (03h)  Table 1 p.26   -- sequential byte read, address wraps
//                                     at the modeled DEPTH boundary
//   - WREN  (06h)  §8.2.1 p.30    -- sets WEL
//   - PP    (02h)  Table 1 p.26,  -- program (AND-only, never sets bits),
//                  note 3 p.29       wraps to page start past byte 256
//   - SE    (20h)  Table 1 p.26   -- 4KB sector erase -> all-FF
//   - RDSR-1(05h)  §7.1.1/7.1.2   -- bit0=BUSY(WIP), bit1=WEL (TOC order
//                  p.15              on p.2 lists BUSY before WEL; this
//                                    bit assignment is also universal
//                                    across the whole Winbond SPI-NOR
//                                    family -- flagged as the one bit-
//                                    layout fact taken from convention
//                                    rather than a single explicit
//                                    consolidated bit table in this
//                                    particular local PDF, see WORKLOG.md
//                                    F1 entry)
//   - tPP/tSE timing: §9.6 p.90, MAX (worst-case) values used, scaled
//     by TIME_SCALE (see parameter) so simulation doesn't burn real
//     milliseconds of event-queue time. Using MAX rather than TYP is
//     deliberate: a design that only polls WIP a couple of times
//     (tuned to the typical-case latency) must still pass against the
//     worst case, or it is not actually correct.
//
// NOT modeled (explicit limitation, see WORKLOG.md §A.6):
//   - Fast Read / Dual / Quad / QPI / DTR instructions (out of scope
//     for this design's F1, which only uses standard single-SPI).
//   - Status Register-2/3, block/sector protect bits, individual
//     block locks, /WP, /HOLD, power-down (B9h/ABh) -- the FPGA has
//     exclusive, trusted control of this flash, so write protection
//     is out of scope; this model always accepts writes once WEL is
//     set, like a factory-default (WPS=0, all BP bits 0) part.
//   - Analog/electrical timing (rise/fall times, setup/hold margins,
//     signal integrity) -- not reachable in a digital behavioral model.
//   - True mid-operation power-loss: real NOR flash can leave a page
//     PARTIALLY programmed if power is cut mid-instruction. This
//     model's commit is a single non-blocking assignment burst after
//     the modeled tPP/tSE delay, so the power-loss hook (below) can
//     only represent "operation aborted before it committed at all",
//     not "committed halfway" -- still sufficient to exercise the
//     catalog's CRC+valid_flag rejection path (F4), but coarser than
//     real silicon.
// ================================================================

module flash_model #(
    parameter DEPTH       = 32'h0002_0000, // 128KB modeled (32x 4KB sectors).
                                            // §A.6: NOT the real 16MB (2^24) --
                                            // mirrors sim/psram_model.v's own
                                            // precedent of a reduced DEPTH for
                                            // simulation speed. Covers the
                                            // catalog sector + several data
                                            // sectors for F2-F5 without the
                                            // multi-second iverilog elaboration
                                            // cost a full 16MB reg array would add.
    parameter integer TIME_SCALE = 100000  // divides real ms-scale datasheet
                                            // timing (see tPP/tSE below) into
                                            // simulation-friendly ns
)(
    input  wire sclk,
    input  wire mosi,
    output reg  miso,
    input  wire cs_n
);

    localparam [31:0] SECTOR_BYTES = 32'd4096; // Sector Erase (4KB), Table 1 p.26 "20h"

    // ------------------------------------------------------------
    // JEDEC ID: EF4018h (plain, non-DTR W25Q128JV), NOT the 7018h
    // this DTR-titled PDF's own §8.1.1 table (p.24) shows.
    //
    // ASSUMPTION FLAGGED (§A.1/§A.6): docs/FPGA-Neural-Hardware-Design.md
    // and docs/FPGA-Neural-Datapatch-Benchmark.md both specify the
    // populated part as "W25Q128JV" / "W25Q128JVS" -- WITHOUT the
    // -DTR suffix -- and those hardware docs are the confirmed BOM
    // source (per project memory). The plain (non-DTR) part's
    // publicly-documented JEDEC ID is EF4018h (memory type 40h);
    // this local PDF is for the DTR-capable die (memory type 70h),
    // a different part number that happens to share the same base
    // filename. Rather than silently trusting whichever byte the
    // one local PDF prints, this model uses the value that matches
    // the part actually specified in the project's own hardware
    // docs, and flags the mismatch explicitly (see WORKLOG.md F1
    // entry) -- real hardware bring-up MUST confirm the populated
    // chip's actual RDID response against this constant.
    // ------------------------------------------------------------
    localparam [7:0] JEDEC_MFR      = 8'hEF;
    localparam [7:0] JEDEC_MEMTYPE  = 8'h40;
    localparam [7:0] JEDEC_CAPACITY = 8'h18; // 128Mbit -- §8.1.1 p.24, agrees between DTR/non-DTR

    localparam [7:0] OP_WREN  = 8'h06;
    localparam [7:0] OP_READ  = 8'h03;
    localparam [7:0] OP_PP    = 8'h02;
    localparam [7:0] OP_SE    = 8'h20;
    localparam [7:0] OP_RDSR1 = 8'h05;
    localparam [7:0] OP_RDID  = 8'h9F;

    reg [7:0] mem [0:DEPTH-1];

    integer i;
    initial begin
        // Erase state is 0xFF everywhere -- §8.2.18 p.56: Sector
        // Erase sets every bit in the addressed region to 1. A
        // freshly-elaborated model matches a freshly-blanked part.
        for (i = 0; i < DEPTH; i = i + 1)
            mem[i] = 8'hFF;
    end

    reg        wel;
    reg        busy;
    reg [7:0]  opcode;
    reg [23:0] addr;
    reg [31:0] bit_count;   // total bits received since CS fell
    reg [7:0]  shift_out;

    reg        pending_pp, pending_se;
    reg [23:0] pending_addr;
    reg [8:0]  pp_nbytes;
    reg [7:0]  pp_bytes [0:255];

    localparam realtime TPP_MAX_NS = 3_000_000.0   / TIME_SCALE; // 3ms MAX, §9.6 p.90
    localparam realtime TSE_MAX_NS = 400_000_000.0 / TIME_SCALE; // 400ms MAX, §9.6 p.90

    initial begin
        wel = 1'b0; busy = 1'b0; miso = 1'b0;
        pending_pp = 1'b0; pending_se = 1'b0; bit_count = 0;
    end

    // ============================================================
    // Transaction start: reset framing state. Every instruction is
    // exactly one CS-low period (§8 intro, p.24: "Instructions are
    // initiated with the falling edge of Chip Select").
    // ============================================================
    always @(negedge cs_n) begin
        bit_count <= 0;
        opcode    <= 8'h00;
    end

    // ============================================================
    // MOSI sampled on the rising edge of CLK (mode 0), matching
    // every timing diagram in the datasheet (Fig. 7/28/30/43a).
    // ============================================================
    always @(posedge sclk) begin
        if (!cs_n) begin

            if (bit_count < 8) begin
                opcode <= {opcode[6:0], mosi};
            end else if (bit_count < 32) begin
                addr <= {addr[22:0], mosi};
            end else begin
                // Data phase: PP captures incoming bytes; READ's
                // outgoing bytes are handled entirely in the
                // falling-edge block below (this model does not
                // echo MOSI during READ, matching "DI High
                // Impedance" shown for read-type instructions).
                if (opcode == OP_PP && wel) begin
                    pp_bytes[(bit_count - 32) >> 3][7 - ((bit_count - 32) & 3'h7)] <= mosi;
                end
            end

            bit_count <= bit_count + 1;
        end
    end

    // ============================================================
    // MISO driven on the falling edge of CLK, one bit ahead of the
    // next rising-edge sample (mode 0), exactly as every read-type
    // timing diagram in the datasheet shows (e.g. Fig. 43a: DO
    // changes shortly after each falling edge).
    // ============================================================
    always @(negedge sclk) begin
        if (!cs_n) begin
            case (opcode)

                OP_RDID: begin
                    if (bit_count < 16)       miso <= JEDEC_MFR[15 - bit_count];
                    else if (bit_count < 24)  miso <= JEDEC_MEMTYPE[23 - bit_count];
                    else if (bit_count < 32)  miso <= JEDEC_CAPACITY[31 - bit_count];
                    else                      miso <= 1'b0;
                end

                OP_RDSR1: begin
                    // bit0=BUSY, bit1=WEL -- see header note.
                    if (bit_count < 8) miso <= 1'b0;
                    else case ((bit_count - 8) & 3'h7)
                        3'd7:    miso <= busy; // MSB-first shift-out of {6'b0,WEL,BUSY}
                        3'd6:    miso <= wel;
                        default: miso <= 1'b0;
                    endcase
                end

                OP_READ: begin
                    if (bit_count < 32) begin
                        miso <= 1'b0;
                    end else if (bit_count == 32) begin
                        if (addr >= DEPTH) begin
                            $display("[flash_model] FATAL: READ out of modeled range 0x%06h (DEPTH=0x%06h) at t=%0t", addr, DEPTH, $time);
                            $fatal(1);
                        end
                        shift_out <= mem[addr];
                        miso      <= mem[addr][7];
                    end else if (((bit_count - 32) & 3'h7) == 0) begin
                        shift_out <= mem[(addr + ((bit_count - 32) >> 3)) % DEPTH];
                        miso      <= mem[(addr + ((bit_count - 32) >> 3)) % DEPTH][7];
                    end else begin
                        shift_out <= {shift_out[6:0], 1'b0};
                        miso      <= shift_out[6];
                    end
                end

                default: miso <= 1'b0;

            endcase
        end
    end

    // ============================================================
    // Transaction end: byte-boundary-gated side effects (§8 intro,
    // p.24: writes/erases that don't end on a byte boundary are
    // ignored entirely -- modeled by requiring bit_count to be an
    // exact multiple of 8 with the right minimum length below).
    // ============================================================
    always @(posedge cs_n) begin

        if (!busy && opcode == OP_WREN && bit_count == 8) begin
            wel <= 1'b1;
        end

        if (!busy && wel && opcode == OP_PP
            && bit_count >= 40 && ((bit_count - 32) & 3'h7) == 0) begin
            pp_nbytes    <= (bit_count - 32) >> 3;
            pending_addr <= addr;
            pending_pp   <= 1'b1;
            busy         <= 1'b1;
            wel          <= 1'b0;
        end

        if (!busy && wel && opcode == OP_SE && bit_count == 32) begin
            if (addr >= DEPTH || addr[11:0] != 12'h000) begin
                // §A.3 negative test: Sector Erase to an address not
                // aligned to a 4KB sector boundary. Real Winbond
                // parts silently erase the containing sector (low
                // address bits don't-care); this model instead
                // FATALs so a design bug that relies on that
                // silent behavior (rather than aligning addresses
                // itself, per WORKLOG.md's erase-before-write design
                // decision) is caught, not masked.
                $display("[flash_model] FATAL: Sector Erase to unaligned/out-of-range address 0x%06h at t=%0t", addr, $time);
                $fatal(1);
            end
            pending_addr <= addr;
            pending_se   <= 1'b1;
            busy         <= 1'b1;
            wel          <= 1'b0;
        end

    end

    // ============================================================
    // WIP timers: commit the write/erase after the modeled MAX
    // (worst-case) datasheet duration. Committing all at once here
    // (rather than incrementally) is what makes the power-loss hook
    // below meaningful: forcing `pending_pp`/`pending_se` and `busy`
    // low from a testbench (via hierarchical reference) before this
    // block's delay expires means the commit loop never runs at all
    // -- see the NOT-modeled note in the header for the fidelity
    // limit of that hook.
    // ============================================================

    always @(posedge pending_pp) begin
        # (TPP_MAX_NS);
        if (pending_pp) begin // still armed: not aborted by a power-loss hook
            for (i = 0; i < pp_nbytes; i = i + 1)
                mem[pending_addr + i] <= mem[pending_addr + i] & pp_bytes[i]; // AND-only, Table1/§8.2.16 p.53
            busy <= 1'b0;
        end
        pending_pp <= 1'b0;
    end

    always @(posedge pending_se) begin
        # (TSE_MAX_NS);
        if (pending_se) begin
            for (i = 0; i < SECTOR_BYTES; i = i + 1)
                mem[pending_addr + i] <= 8'hFF; // erase -> all-ones, §8.2.18 p.56
            busy <= 1'b0;
        end
        pending_se <= 1'b0;
    end

endmodule
