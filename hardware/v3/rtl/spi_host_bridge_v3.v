`timescale 1ns/1ps

// ================================================================
// FPGA-Neural V3 -- SPI HOST BRIDGE (forked from hardware/v2/rtl/
// spi_host_bridge.v, per this session's own re-audit -- explicitly
// requested: "Ricontrolla anche gli opcode SPI per essere sicuri che
// in questo contesto siano corretti e completi.")
//
// WHY A FORK, NOT A REUSE (the audit's finding): V2's spi_host_
// bridge.v drives reg_valid/reg_node_id/reg_required/reg_producer_ids/
// reg_x_base/reg_w_base/reg_n_tiles/reg_result_addr, matching
// dependency_manager.v's job-registration port. V3's scheduler
// (neural_director_packed.v) has NO dependency manager -- it exposes
// a simpler job_in_valid/ready/x_base/w_base/n_tiles/result_addr/
// node_id port with no required/producer_ids fields at all. Trying to
// reuse V2's bridge unmodified would either silently drop 3 real
// payload fields on the floor or block forever waiting on a reg_ready
// signal that doesn't exist in V3. Per this project's fork-before-
// promote discipline, this is a NEW, independently owned V3 file.
//
// The SPI physical layer (byte shift register, CS framing, CDC
// synchronizers, the MISO falling-edge-lookahead fix) is carried over
// BYTE FOR BYTE from spi_host_bridge.v -- that logic is protocol-
// agnostic and was already hard-won (two real bugs, root-caused via
// full internal signal traces, see that file's own header). Only the
// PROTOCOL FSM (opcode payload shapes and where they're wired) is new.
//
// Also closes the second gap the same audit found: V2's bridge wired
// mem_req/wr/addr/wdata/lb_n/ub_n directly into a WORD-granularity
// host-arb port that existed in V2's memory stack. V3 has no such
// port -- its shared memory path (sdram_arbiter_n.v) only understands
// BURST_LEN=8 chunks. This bridge's mem_* port is therefore wired to
// hardware/v3/rtl/host_mem_bridge.v (EXP-0071, verified standalone),
// which performs that exact word<->burst translation; the mem_* port
// below is UNCHANGED in shape from V2's (still single-16-bit-word
// req/wr/addr/wdata/lb_n/ub_n -> rdata/ready), because host_mem_
// bridge.v's own host-facing port was deliberately built to match it.
//
// ---------------------------------------------------------------
// PROTOCOL (one opcode byte, MSB-first, per CS-low transaction;
// multi-byte fields are MSB-first):
//
//   0x00 NOP           -- 0 payload bytes.
//   0x0F RESET         -- 0 payload bytes. Pulses soft_rst_pulse for
//                         one clk cycle after CS rises.
//   0x10 WRITE_JOB     -- 16 payload bytes, submits one job to
//                         neural_director_packed.v's job_in_* port
//                         (== one job_in_valid/ready handshake):
//                           byte0:1  = node_id[15:0]
//                           byte2:5  = x_base[25:0]      (byte2 msb={6'b0,x_base[25:24]})
//                           byte6:9  = w_base[25:0]
//                           byte10:11= n_tiles[15:0]
//                           byte12:15= result_addr[25:0]
//                         job_in_valid is asserted and HELD until the
//                         cycle job_in_ready also reads 1 (same-cycle
//                         valid&&ready acceptance, matching neural_
//                         director_packed.v's own combinational
//                         job_in_ready contract) -- never a blind pulse.
//
//                         NOTE (the audit's disclosed, deliberate gap):
//                         V2's WRITE_JOB carried required[2:0] and
//                         producer_ids[15:0] for dependency_manager.v.
//                         V3 has no dependency manager yet -- those
//                         fields are DROPPED from this protocol, not
//                         silently ignored. A future dependency-
//                         tracking layer for V3, if built, needs its
//                         own opcode/fields; this one intentionally
//                         does not reserve space for it.
//   0x20 STATUS        -- 0 payload bytes. Returns 1 byte on MISO
//                         (clocked out during payload byte 1):
//                           bit0 = job_busy   (WRITE_JOB waiting on job_in_ready)
//                           bit1 = mem_busy   (WRITE_MEM/READ_MEM waiting on mem_ready)
//                           bit2 = last_job_accepted (sticky, cleared by next WRITE_JOB)
//                           bits[7:3] = 0 (reserved)
//   0x01 WRITE_MEM     -- 4 header bytes + 2*len_words payload bytes:
//                           byte0:3 = addr[24:0]   (WORD address, MIG_
//                                     ADDR_WIDTH convention -- matches
//                                     host_mem_bridge.v/sdram_arbiter_n.v,
//                                     NOT the 26-bit job-base-address
//                                     convention above; byte0 msb=
//                                     {7'b0,addr[24]})
//                           then len_words * 2 bytes of data, MSB-first
//                           per word; each word is written via one
//                           mem_req/mem_ready handshake (lb_n=ub_n=0,
//                           full 16-bit write) before the next word's
//                           bytes are accepted. len_words comes right
//                           after addr, 2 bytes, same as below.
//   0x02 READ_MEM      -- 6 header bytes (4 addr + 2 len_words, same
//                           addr convention as WRITE_MEM), 0 further
//                           MOSI payload; the 2*len_words response
//                           bytes are clocked out on MISO starting at
//                           payload byte 7, MSB-first per word, one
//                           mem_req/mem_ready read per word.
//
//   0x30 REG_WRITE     -- 5 payload bytes: byte0 = reg_addr[7:0],
//                         byte1:4 = value[31:0] MSB-first. Applied the
//                         instant the last data byte lands (no backend
//                         handshake needed, register writes are purely
//                         internal). Writing a read-only or unknown
//                         register address is inert (accepted on the
//                         wire, has no effect) -- same "never wedges
//                         the bus" precedent as an unknown opcode.
//   0x31 REG_READ      -- 1 payload byte (reg_addr[7:0]), then 4
//                         response bytes clocked out on MISO MSB-
//                         first starting at payload byte 2. An unknown
//                         register address reads back 32'hFFFF_FFFF
//                         (deliberately distinct from any real 0
//                         value, so a host can tell "read an unmapped
//                         register" apart from "read a real zero").
//
//   REGISTER MAP (v1, extensible -- add new addresses, never repurpose
//   an existing one, so old host software stays correct against new
//   firmware):
//     0x00 DEVICE_ID   (RO) -- 32'h4E50_5601 ("NPV" + protocol
//                              version 1, ASCII 'N''P''V' + 0x01).
//                              Lets host software confirm it's really
//                              talking to this protocol/version before
//                              trusting anything else.
//     0x01 CONTROL     (RW) -- bit0: write 1 to pulse soft_rst_pulse
//                              for one clk cycle (same physical effect
//                              as the RESET opcode, exposed here too
//                              since a register-based control path is
//                              often more convenient for host software
//                              than a dedicated opcode). Always reads
//                              back 0 (it's a pulse trigger, not a
//                              level). bits[31:1] reserved.
//     0x02 STATUS      (RO) -- bit0: job_busy: bit1: mem_busy;
//                              bit2: last_job_accepted (sticky, same
//                              as the STATUS opcode's own bits);
//                              bit3: init_calib_complete (DDR3 PHY
//                              calibration done, i.e. DRAM traffic is
//                              actually safe to issue); bit4: dir_error
//                              (neural_director_packed.v's own error
//                              latch). bits[31:5] reserved.
//     0x03 N_SLOTS     (RO) -- number of compute slots this build was
//                              synthesized with (the N_SLOTS parameter
//                              below), so host software doesn't need
//                              to hardcode it.
//
// Any opcode byte not listed above is treated as NOP (0 payload,
// MISO drives 0x00) -- matches spi_host_bridge.v's own "unknown
// opcode is inert, never wedges the bus" precedent.
// ================================================================

module spi_host_bridge_v3 #(
    parameter JOB_ADDR_WIDTH = 26,   // matches neural_director_packed.v's ADDR_WIDTH (byte-base convention)
    parameter MEM_ADDR_WIDTH = 25,   // matches host_mem_bridge.v's ADDR_WIDTH (word/burst convention)
    parameter N_SLOTS        = 2     // reported read-only via REG 0x03, purely informational
)(
    input  wire clk,
    input  wire rst,

    // ---- system status, for the REG 0x02 STATUS register ----
    input  wire init_calib_complete,
    input  wire dir_error,

    // ---- physical SPI pins ----
    input  wire sclk,
    input  wire mosi,
    output wire miso,
    input  wire cs_n,

    // ---- job submission (-> neural_director_packed.v job_in_* port) ----
    output reg                        job_in_valid,
    input  wire                       job_in_ready,
    output reg  [JOB_ADDR_WIDTH-1:0]  job_in_x_base,
    output reg  [JOB_ADDR_WIDTH-1:0]  job_in_w_base,
    output reg  [15:0]                job_in_n_tiles,
    output reg  [JOB_ADDR_WIDTH-1:0]  job_in_result_addr,
    output reg  [15:0]                job_in_node_id,

    // ---- host raw DDR3 access (-> host_mem_bridge.v mem_* port) ----
    output reg                       mem_req,
    output reg                       mem_wr,
    output reg  [MEM_ADDR_WIDTH-1:0] mem_addr,
    output reg  [15:0]               mem_wdata,
    output reg                       mem_lb_n,
    output reg                       mem_ub_n,
    input  wire [15:0]               mem_rdata,
    input  wire                      mem_ready,

    output reg  soft_rst_pulse
);

    // ============================================================
    // SPI PHYSICAL LAYER (byte shift register + CS framing + CDC) --
    // carried over unmodified from spi_host_bridge.v (see header).
    // ============================================================

    reg [2:0] sclk_sync, mosi_sync, cs_n_sync;
    always @(posedge clk) begin
        if (rst) begin
            sclk_sync <= 3'b000; mosi_sync <= 3'b000; cs_n_sync <= 3'b111;
        end else begin
            sclk_sync <= {sclk_sync[1:0], sclk};
            mosi_sync <= {mosi_sync[1:0], mosi};
            cs_n_sync <= {cs_n_sync[1:0], cs_n};
        end
    end
    wire sclk_s = sclk_sync[2];
    wire cs_n_s = cs_n_sync[2];
    wire mosi_s = mosi_sync[2];

    reg sclk_prev, cs_n_prev;
    always @(posedge clk) begin
        if (rst) begin sclk_prev <= 1'b0; cs_n_prev <= 1'b1; end
        else     begin sclk_prev <= sclk_s; cs_n_prev <= cs_n_s; end
    end
    wire sclk_rise = sclk_s & ~sclk_prev;
    wire cs_fell    = ~cs_n_s &  cs_n_prev;
    wire cs_rose    =  cs_n_s & ~cs_n_prev;
    wire cs_active  = ~cs_n_s;

    reg [2:0] bit_count;
    reg [7:0] rx_shift;
    reg [7:0] rx_byte;
    reg       rx_valid;

    wire [7:0] tx_byte;
    reg        miso_shift_bit;

    // REAL BUG found and fixed this session (via REG_READ's DEVICE_ID
    // register, whose non-zero LSB exposed it -- prior tests'
    // response values happened to coincidentally mask it, see the
    // note above "mem_rout_pending_ignore" for the full root-cause):
    // this used to be `(cs_active && bit_count==3'd0) ? tx_byte[7] :
    // miso_shift_bit`, a combinational bypass meant to serve the
    // FIRST bit of a fresh byte before any falling edge has prepared
    // miso_shift_bit for it. bit_count==0 is ALSO true for the ENTIRE
    // remainder of the bit period immediately AFTER a byte's LAST bit
    // was sampled (it only advances again at the next byte's own
    // first sampling edge) -- so this bypass showed tx_byte[7] (the
    // wrong bit, and on continuously-clocked multi-byte reads,
    // possibly a byte value that's already stale/wrong too) for the
    // WHOLE tail of every byte-to-byte gap, corrupting exactly the
    // moment a real (non-instant) SPI master samples the last bit.
    // Proven unnecessary for every opcode this module has: a genuine
    // "first bit with zero prior falling edges" only occurs for the
    // opcode byte itself (whose MISO value is always don't-care 0x00
    // anyway) -- every real response byte in this protocol is always
    // preceded by several other bytes in the same CS session, so
    // miso_shift_bit has always already been freshly prepared by the
    // ordinary falling-edge mechanism below by the time it matters.
    assign miso = miso_shift_bit;

    always @(posedge clk) begin
        if (rst) begin
            bit_count <= 3'd0; rx_shift <= 8'h00; rx_byte <= 8'h00; rx_valid <= 1'b0;
            miso_shift_bit <= 1'b0;
        end else begin
            rx_valid <= 1'b0;
            if (cs_fell) begin
                bit_count <= 3'd0;
            end else if (cs_active) begin
                if (sclk_rise) begin
                    rx_shift <= {rx_shift[6:0], mosi_s};
                    if (bit_count == 3'd7) begin
                        bit_count <= 3'd0;
                        rx_byte   <= {rx_shift[6:0], mosi_s};
                        rx_valid  <= 1'b1;
                    end else begin
                        bit_count <= bit_count + 3'd1;
                    end
                end else if (~sclk_s & sclk_prev) begin // sclk_fall
                    miso_shift_bit <= tx_byte[3'd7 - bit_count];
                end
            end
        end
    end

    // ============================================================
    // PROTOCOL FSM
    // ============================================================

    localparam OP_NOP       = 8'h00;
    localparam OP_WRITE_MEM = 8'h01;
    localparam OP_READ_MEM  = 8'h02;
    localparam OP_RESET     = 8'h0F;
    localparam OP_WRITE_JOB = 8'h10;
    localparam OP_STATUS    = 8'h20;
    localparam OP_REG_WRITE = 8'h30;
    localparam OP_REG_READ  = 8'h31;

    localparam ST_OPCODE  = 4'd0;
    localparam ST_JOB     = 4'd1; // collecting 16 WRITE_JOB payload bytes
    localparam ST_JOB_WAIT= 4'd2; // job_in_valid held, waiting job_in_ready
    localparam ST_MEM_ADDR= 4'd3; // collecting 4 addr bytes
    localparam ST_MEM_LEN = 4'd4; // collecting 2 length bytes
    localparam ST_MEM_WD  = 4'd5; // WRITE_MEM: collecting 2 data bytes/word
    localparam ST_MEM_WISS= 4'd6; // WRITE_MEM: issue+wait mem_req
    localparam ST_MEM_RISS= 4'd7; // READ_MEM: issue+wait mem_req
    localparam ST_MEM_ROUT= 4'd8; // READ_MEM: shifting the 2 bytes of a word out
    localparam ST_IGNORE  = 4'd9; // opcode consumed / unknown, wait for cs_rose
    localparam ST_REG_ADDR = 4'd10; // collecting 1 reg_addr byte
    localparam ST_REG_WDATA= 4'd11; // REG_WRITE: collecting 4 value bytes
    localparam ST_REG_ROUT = 4'd12; // REG_READ: shifting 4 value bytes out

    reg [3:0]  state;
    reg [7:0]  opcode;
    reg [4:0]  byte_idx;      // generic byte counter within a field (up to 15, WRITE_JOB)
    reg [15:0] len_words;
    reg [15:0] word_cnt;
    reg [15:0] cur_word;      // WRITE_MEM: assembling MSB,LSB; READ_MEM: holding readback
    reg        job_busy_r, mem_busy_r, last_job_accepted_r;
    reg [7:0]  reg_addr;
    reg [31:0] reg_wdata;     // REG_WRITE: assembling the 4 value bytes

    // ---- ROUT-exit deferral (real bug found and fixed this session,
    // see the header's own note near the physical layer): the
    // combinational "assign miso = (bit_count==0) ? tx_byte[7] :
    // miso_shift_bit" bypass exists to serve the FIRST bit of a fresh
    // byte, but bit_count ALSO reads 0 for one edge immediately AFTER
    // the LAST bit of the byte that just finished (it wraps 7->0 at
    // that same edge) -- the two cases are indistinguishable from
    // bit_count alone. If `state` (and therefore tx_byte, via tx_mux)
    // changes on that SAME edge -- exactly what a naive ROUT-exit
    // transition does -- the bypass reads the NEW (already-wrong)
    // tx_byte instead of the correctly-prepared miso_shift_bit,
    // corrupting the LAST bit of the LAST byte of a multi-byte read.
    // This was masked in READ_MEM's own existing test by coincidence
    // (the test word's last bit happened to equal the corrupted
    // substitute's bit7, both 0) until REG_READ's DEVICE_ID register
    // (whose last bit is 1) exposed it via a real bit-exact mismatch.
    // Fix: defer the state/byte_idx-clearing transition by exactly
    // one internal clk cycle past the byte that triggers it, via a
    // one-cycle pending flag -- clk runs far faster than SCLK (this
    // file's own documented >=50x minimum ratio), so a one-clk-cycle
    // delay is invisible on the SPI bus but moves the transition
    // safely off the vulnerable bit_count==0 edge.
    reg mem_rout_pending_ignore, mem_rout_pending_riss;
    reg reg_rout_pending;

    // ---- register file readback mux (combinational -- see the
    // header's REGISTER MAP for the meaning of each address) ----
    reg [31:0] reg_rdata;
    always @(*) begin
        case (reg_addr)
            8'h00:   reg_rdata = 32'h4E505601;
            8'h01:   reg_rdata = 32'h00000000;
            8'h02:   reg_rdata = {27'b0, dir_error, init_calib_complete,
                                   last_job_accepted_r, mem_busy_r, job_busy_r};
            8'h03:   reg_rdata = {24'b0, N_SLOTS[7:0]};
            default: reg_rdata = 32'hFFFFFFFF;
        endcase
    end

    // combinational tx byte mux -- STATUS response, READ_MEM data,
    // REG_READ data, everything else drives 0x00
    reg [7:0] tx_mux;
    always @(*) begin
        tx_mux = 8'h00;
        if (opcode == OP_STATUS)
            tx_mux = {5'b0, last_job_accepted_r, mem_busy_r, job_busy_r};
        else if (opcode == OP_READ_MEM && state == ST_MEM_ROUT)
            tx_mux = (byte_idx == 5'd0) ? cur_word[15:8] : cur_word[7:0];
        else if (opcode == OP_REG_READ && state == ST_REG_ROUT)
            tx_mux = reg_rdata[8*(3-byte_idx) +: 8];
    end
    assign tx_byte = tx_mux;

    always @(posedge clk) begin
        if (rst) begin
            state <= ST_OPCODE; opcode <= 8'h00; byte_idx <= 5'd0;
            len_words <= 16'd0; word_cnt <= 16'd0; cur_word <= 16'd0;
            job_in_valid <= 1'b0; job_in_node_id <= 16'd0;
            job_in_x_base <= {JOB_ADDR_WIDTH{1'b0}}; job_in_w_base <= {JOB_ADDR_WIDTH{1'b0}};
            job_in_n_tiles <= 16'd0; job_in_result_addr <= {JOB_ADDR_WIDTH{1'b0}};
            mem_req <= 1'b0; mem_wr <= 1'b0; mem_addr <= {MEM_ADDR_WIDTH{1'b0}};
            mem_wdata <= 16'd0; mem_lb_n <= 1'b0; mem_ub_n <= 1'b0;
            soft_rst_pulse <= 1'b0;
            job_busy_r <= 1'b0; mem_busy_r <= 1'b0; last_job_accepted_r <= 1'b0;
            reg_addr <= 8'h00; reg_wdata <= 32'h0;
            mem_rout_pending_ignore <= 1'b0; mem_rout_pending_riss <= 1'b0;
            reg_rout_pending <= 1'b0;
        end else begin
            mem_req        <= 1'b0;
            soft_rst_pulse <= 1'b0;

            // Same protection as spi_host_bridge.v: don't let a new CS
            // assertion reset state/byte_idx while a previous
            // transaction is still pending a backend handshake, or its
            // own not-yet-accepted fields get corrupted by the next
            // transaction's incoming bytes landing in the same
            // registers (root-caused once already in the V2 module
            // this was forked from -- carried over as a standing
            // precaution here, not re-derived from a new V3 failure).
            if (cs_fell && state != ST_JOB_WAIT && state != ST_MEM_WISS && state != ST_MEM_RISS) begin
                state    <= ST_OPCODE;
                byte_idx <= 5'd0;
            end else if (!cs_fell && rx_valid) begin
                case (state)
                    ST_OPCODE: begin
                        opcode <= rx_byte;
                        byte_idx <= 5'd0;
                        case (rx_byte)
                            OP_WRITE_JOB: state <= ST_JOB;
                            OP_WRITE_MEM: state <= ST_MEM_ADDR;
                            OP_READ_MEM:  state <= ST_MEM_ADDR;
                            OP_REG_WRITE: state <= ST_REG_ADDR;
                            OP_REG_READ:  state <= ST_REG_ADDR;
                            OP_RESET:     state <= ST_IGNORE;
                            default:      state <= ST_IGNORE; // NOP, STATUS: no MOSI payload
                        endcase
                    end

                    ST_JOB: begin
                        case (byte_idx)
                            5'd0:  job_in_node_id[15:8]      <= rx_byte;
                            5'd1:  job_in_node_id[7:0]       <= rx_byte;
                            5'd2:  job_in_x_base[25:24]      <= rx_byte[1:0];
                            5'd3:  job_in_x_base[23:16]      <= rx_byte;
                            5'd4:  job_in_x_base[15:8]       <= rx_byte;
                            5'd5:  job_in_x_base[7:0]        <= rx_byte;
                            5'd6:  job_in_w_base[25:24]      <= rx_byte[1:0];
                            5'd7:  job_in_w_base[23:16]      <= rx_byte;
                            5'd8:  job_in_w_base[15:8]       <= rx_byte;
                            5'd9:  job_in_w_base[7:0]        <= rx_byte;
                            5'd10: job_in_n_tiles[15:8]      <= rx_byte;
                            5'd11: job_in_n_tiles[7:0]       <= rx_byte;
                            5'd12: job_in_result_addr[25:24] <= rx_byte[1:0];
                            5'd13: job_in_result_addr[23:16] <= rx_byte;
                            5'd14: job_in_result_addr[15:8]  <= rx_byte;
                            5'd15: begin
                                job_in_result_addr[7:0] <= rx_byte;
                                job_in_valid             <= 1'b1;
                                last_job_accepted_r      <= 1'b0;
                                state                    <= ST_JOB_WAIT;
                            end
                        endcase
                        if (byte_idx != 5'd15) byte_idx <= byte_idx + 5'd1;
                    end

                    ST_MEM_ADDR: begin
                        case (byte_idx)
                            5'd0: mem_addr[24] <= rx_byte[0];
                            5'd1: mem_addr[23:16] <= rx_byte;
                            5'd2: mem_addr[15:8]  <= rx_byte;
                            5'd3: begin
                                mem_addr[7:0] <= rx_byte;
                                state         <= ST_MEM_LEN;
                            end
                        endcase
                        if (byte_idx != 5'd3) byte_idx <= byte_idx + 5'd1;
                        else byte_idx <= 5'd0;
                    end

                    ST_MEM_LEN: begin
                        if (byte_idx == 5'd0) begin
                            len_words[15:8] <= rx_byte;
                            byte_idx        <= 5'd1;
                        end else begin
                            len_words[7:0] <= rx_byte;
                            word_cnt       <= {len_words[15:8], rx_byte};
                            byte_idx       <= 5'd0;
                            state          <= (opcode == OP_WRITE_MEM) ? ST_MEM_WD : ST_MEM_RISS;
                        end
                    end

                    ST_MEM_WD: begin
                        if (byte_idx == 5'd0) begin
                            cur_word[15:8] <= rx_byte;
                            byte_idx       <= 5'd1;
                        end else begin
                            cur_word[7:0] <= rx_byte;
                            state         <= ST_MEM_WISS;
                        end
                    end

                    ST_REG_ADDR: begin
                        reg_addr <= rx_byte;
                        byte_idx <= 5'd0;
                        // REG_READ needs no backend handshake -- the
                        // register value is already available
                        // combinationally (reg_rdata), so it can go
                        // straight to shifting bytes out; REG_WRITE
                        // still needs 4 more MOSI bytes first.
                        state <= (opcode == OP_REG_WRITE) ? ST_REG_WDATA : ST_REG_ROUT;
                    end

                    ST_REG_WDATA: begin
                        case (byte_idx)
                            5'd0: reg_wdata[31:24] <= rx_byte;
                            5'd1: reg_wdata[23:16] <= rx_byte;
                            5'd2: reg_wdata[15:8]  <= rx_byte;
                            5'd3: begin
                                reg_wdata[7:0] <= rx_byte;
                                state          <= ST_IGNORE;
                                // apply the write immediately -- register
                                // writes are purely internal, no backend
                                // handshake to wait on. Unknown/read-only
                                // addresses are silently inert (accepted
                                // on the wire, no effect), matching this
                                // module's own "never wedges the bus"
                                // precedent for unknown opcodes.
                                if (reg_addr == 8'h01 && rx_byte[0])
                                    soft_rst_pulse <= 1'b1;
                            end
                        endcase
                        if (byte_idx != 5'd3) byte_idx <= byte_idx + 5'd1;
                    end

                    default: ; // ST_JOB_WAIT/ST_MEM_WISS/ST_MEM_RISS/ST_MEM_ROUT/ST_REG_ROUT/ST_IGNORE: no MOSI payload expected
                endcase
            end

            // ---- non-rx_valid-driven transitions ----
            if (state == ST_JOB_WAIT && job_in_valid && job_in_ready) begin
                job_in_valid         <= 1'b0;
                last_job_accepted_r  <= 1'b1;
                state                <= ST_IGNORE;
            end

            if (state == ST_MEM_WISS && !mem_req && !mem_busy_r) begin
                mem_req   <= 1'b1;
                mem_wr    <= 1'b1;
                mem_wdata <= cur_word;
                mem_lb_n  <= 1'b0;
                mem_ub_n  <= 1'b0;
                mem_busy_r <= 1'b1;
            end else if (state == ST_MEM_WISS && mem_busy_r && mem_ready) begin
                mem_busy_r <= 1'b0;
                mem_addr   <= mem_addr + 1'b1;
                word_cnt   <= word_cnt - 1'b1;
                byte_idx   <= 5'd0;
                state      <= (word_cnt == 16'd1) ? ST_IGNORE : ST_MEM_WD;
            end

            if (state == ST_MEM_RISS && !mem_req && !mem_busy_r) begin
                mem_req   <= 1'b1;
                mem_wr    <= 1'b0;
                mem_lb_n  <= 1'b0;
                mem_ub_n  <= 1'b0;
                mem_busy_r <= 1'b1;
            end else if (state == ST_MEM_RISS && mem_busy_r && mem_ready) begin
                mem_busy_r <= 1'b0;
                cur_word   <= mem_rdata;
                byte_idx   <= 5'd0;
                state      <= ST_MEM_ROUT;
            end
            if (state == ST_MEM_ROUT && rx_valid) begin
                if (byte_idx == 5'd0) begin
                    byte_idx <= 5'd1;
                end else begin
                    mem_addr <= mem_addr + 1'b1;
                    word_cnt <= word_cnt - 1'b1;
                    // defer the actual exit -- see this module's own
                    // "ROUT-exit deferral" note above -- so tx_mux
                    // keeps showing this byte's correct value through
                    // the vulnerable bit_count==0 edge.
                    if (word_cnt == 16'd1) mem_rout_pending_ignore <= 1'b1;
                    else                   mem_rout_pending_riss   <= 1'b1;
                end
            end
            if (mem_rout_pending_ignore) begin
                mem_rout_pending_ignore <= 1'b0;
                byte_idx <= 5'd0;
                state    <= ST_IGNORE;
            end
            if (mem_rout_pending_riss) begin
                mem_rout_pending_riss <= 1'b0;
                byte_idx <= 5'd0;
                state    <= ST_MEM_RISS;
            end

            if (state == ST_REG_ROUT && rx_valid) begin
                if (byte_idx == 5'd3) begin
                    reg_rout_pending <= 1'b1;
                end else begin
                    byte_idx <= byte_idx + 5'd1;
                end
            end
            if (reg_rout_pending) begin
                reg_rout_pending <= 1'b0;
                byte_idx <= 5'd0;
                state    <= ST_IGNORE;
            end

            job_busy_r <= (state == ST_JOB_WAIT);

            if (cs_rose) begin
                if (opcode == OP_RESET) soft_rst_pulse <= 1'b1;
                if (state != ST_JOB_WAIT && state != ST_MEM_WISS && state != ST_MEM_RISS)
                    state <= ST_OPCODE;
            end
        end
    end

endmodule
