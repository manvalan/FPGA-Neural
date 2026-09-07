`timescale 1ns/1ps

// ================================================================
// FPGA-Neural V2 -- SPI HOST BRIDGE (STEP20, physical host interface)
//
// Replaces the 110-pin reg_*/testbench-only bus as the PHYSICAL board
// interface. The internal reg_*/mem_* ports below are UNCHANGED in
// shape/semantics from the ones nms_dataflow_core_sdram.v and
// sdram_unified_backend.v's AR port already expose -- this module is
// a pure protocol translator (SPI bytes -> the same internal signals
// simulation already drives directly), so nms_dataflow_core_sdram.v,
// dependency_manager.v, neural_processor.v and sdram_unified_backend.v
// remain byte-for-byte unchanged (STEP19/STEP20 standing constraint).
//
// Physical layer (byte shift register + CS framing + CDC synchronizers)
// re-derives the same proven design as hardware/v1/rtl/spi_slave.v
// (SPI mode 0, MSB-first, one opcode per CS-low period, double-flop
// CDC on sclk/mosi/cs_n) -- reimplemented here as a NEW, independently
// owned V2 file so V2 continues to instantiate ZERO V1 RTL (STEP19's
// own "zero V1 files in the V2 compile list" property is preserved).
//
// ---------------------------------------------------------------
// PROTOCOL (new, V2-specific -- one opcode byte, MSB-first, per
// CS-low transaction; multi-byte fields are MSB-first):
//
//   0x00 NOP           -- 0 payload bytes.
//   0x0F RESET         -- 0 payload bytes. Pulses soft_rst_pulse for
//                         one clk cycle after CS rises.
//   0x10 WRITE_JOB     -- 18 payload bytes (widened from 15 -- see
//                         "ADDRESS WIDTH" note below), registers one
//                         dependency-manager job (== one reg_valid/
//                         reg_* handshake):
//                           byte0    = {4'b0,node_id[3:0]}
//                           byte1    = {5'b0,required[2:0]}
//                           byte2:3  = producer_ids[15:0]
//                           byte4:7  = x_base[25:0]      (byte4 msb={6'b0,x_base[25:24]})
//                           byte8:11 = w_base[25:0]
//                           byte12:13= n_tiles[15:0]
//                           byte14:17= result_addr[25:0]
//                         reg_valid is asserted and HELD until the
//                         cycle reg_ready also reads 1 (same-cycle
//                         valid&&ready acceptance, matching
//                         dependency_manager.v's own combinational
//                         reg_ready contract) -- never a blind pulse.
//   0x20 STATUS        -- 0 payload bytes. Returns 1 byte on MISO
//                         (clocked out during payload byte 1):
//                           bit0 = job_busy   (WRITE_JOB waiting on reg_ready)
//                           bit1 = mem_busy   (WRITE_MEM/READ_MEM waiting on mem_ready)
//                           bit2 = last_job_accepted (sticky, cleared by next WRITE_JOB)
//                           bits[7:3] = 0 (reserved)
//   0x01 WRITE_MEM     -- 6 header bytes (widened from 5) + 2*len_words
//                         payload bytes:
//                           byte0:3 = addr[25:0]   (WORD address, matches
//                                     sdram_unified_backend's AR port
//                                     convention -- NOT a byte address;
//                                     byte0 msb={6'b0,addr[25:24]})
//                           byte4:5 = len_words[15:0] (number of 16-bit
//                                     words to write, len_words>=1)
//                           then len_words * 2 bytes of data, MSB-first
//                           per word; each word is written via one
//                           mem_req/mem_ready handshake (lb_n=ub_n=0,
//                           full 16-bit write) before the next word's
//                           bytes are accepted.
//   0x02 READ_MEM      -- 6 header bytes (addr + len_words, same shape
//                           as WRITE_MEM), 0 further MOSI payload; the
//                           2*len_words response bytes are clocked out
//                           on MISO starting at payload byte 7, MSB-
//                           first per word, one mem_req/mem_ready
//                           read per word.
//
// ADDRESS WIDTH (post-PRE-PCB-FREEZE memory upgrade): ADDR_WIDTH grew
// from 23 to 26 bits (SDRAM capacity upgrade, AS4C4M16SA-6TIN 8MB ->
// AS4C32M16SA-7TIN 64MB -- see sdram_controller.v's own header). A
// 26-bit address no longer fits in 3 bytes (24 bits) with a spare
// reserved bit the way the old 23-bit address did -- every address
// field below therefore widened from 3 to 4 bytes (6 reserved bits in
// the new top byte instead of 1), growing WRITE_JOB from 15 to 18
// payload bytes and the WRITE_MEM/READ_MEM header from 5 to 6 bytes.
//
// Any opcode byte not listed above is treated as NOP (0 payload,
// MISO drives 0x00) -- matches spi_engine.v's own "unknown opcode is
// inert, never wedges the bus" precedent.
// ================================================================

module spi_host_bridge #(
    parameter ADDR_WIDTH = 26,
    parameter N_NODES     = 16,
    parameter MAX_DEPS    = 4
)(
    input  wire clk,
    input  wire rst,

    // ---- physical SPI pins ----
    input  wire sclk,
    input  wire mosi,
    output wire miso,
    input  wire cs_n,

    // ---- job registration (-> nms_dataflow_core_sdram.v) ----
    output reg                                  reg_valid,
    input  wire                                 reg_ready,
    output reg  [$clog2(N_NODES)-1:0]           reg_node_id,
    output reg  [$clog2(MAX_DEPS+1)-1:0]        reg_required,
    output reg  [MAX_DEPS*$clog2(N_NODES)-1:0]  reg_producer_ids,
    output reg  [ADDR_WIDTH-1:0]                reg_x_base,
    output reg  [ADDR_WIDTH-1:0]                reg_w_base,
    output reg  [15:0]                          reg_n_tiles,
    output reg  [ADDR_WIDTH-1:0]                reg_result_addr,

    // ---- host raw SDRAM access (-> host-arb slot_mem_arbiter port) ----
    output reg                    mem_req,
    output reg                    mem_wr,
    output reg  [ADDR_WIDTH-1:0]  mem_addr,
    output reg  [15:0]            mem_wdata,
    output reg                    mem_lb_n,
    output reg                    mem_ub_n,
    input  wire [15:0]            mem_rdata,
    input  wire                   mem_ready,

    output reg  soft_rst_pulse
);

    localparam NODEW = $clog2(N_NODES);
    localparam REQW  = $clog2(MAX_DEPS+1);

    // ============================================================
    // SPI PHYSICAL LAYER (byte shift register + CS framing + CDC)
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

    // tx_byte is driven COMBINATIONALLY by the protocol FSM below (see
    // tx_mux) -- always reflects "the byte MISO should show next".
    //
    // IMPORTANT (found via this module's own isolated regression,
    // STEP20 -- two successive real bugs before this final design):
    //
    // Draft 1 used a conventional per-bit INCREMENTAL shift register
    // for MISO (load tx_byte once at a byte boundary, then shift one
    // position per falling edge, mirroring hardware/v1/rtl/
    // spi_slave.v's own proven convention). It failed because
    // `bit_count` (incremented on the RISING-edge detector) is ALWAYS
    // already one bit ahead of what the FALLING-edge detector sees for
    // that SAME physical bit -- a rising edge is always detected
    // before that bit's own falling edge, since both go through the
    // same CDC latency but the physical fall itself comes later in
    // time. So "prepare tx_shift for bit_count+1" at a falling edge
    // that already observes the incremented bit_count silently skips
    // a bit position, corrupting the byte by one place (root-caused
    // via this module's own tb_spi_host_bridge.v with a full internal-
    // signal trace, not by inspection).
    //
    // Draft 2 tried removing the shift register entirely (index
    // tx_byte directly by bit_count on EVERY bit, driven purely
    // combinationally). That failed a different way: sampling MISO
    // even slightly after the CDC latency that follows a bit's own
    // rising edge (normal SPI master behavior, not a torture case)
    // already sees bit_count having advanced to the NEXT index.
    //
    // Both drafts share one fact once it's made explicit: at the
    // moment ANY falling edge is internally detected, `bit_count`
    // ALREADY equals the index of the bit that is about to be
    // sampled next (not the bit whose fall just fired). The fix below
    // uses exactly that fact instead of fighting it: on every detected
    // falling edge, load `miso_shift_bit` directly from
    // tx_byte[7-bit_count] (no incremental shift, no off-by-one).
    // Between falling edges -- including an extended SCLK-idle wait,
    // a real, INTENDED use of this protocol for READ_MEM/mem_req
    // latency (see module header) -- `bit_count==0` is additionally
    // driven live/combinationally so a response that only becomes
    // known DURING the idle wait (no falling edge occurs to refresh
    // it) is still correct once the master resumes clocking.
    wire [7:0] tx_byte;
    reg        miso_shift_bit;

    assign miso = (cs_active && bit_count == 3'd0) ? tx_byte[7] : miso_shift_bit;

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

    localparam ST_OPCODE  = 4'd0;
    localparam ST_JOB     = 4'd1; // collecting 18 WRITE_JOB payload bytes
    localparam ST_JOB_WAIT= 4'd2; // reg_valid held, waiting reg_ready
    localparam ST_MEM_ADDR= 4'd3; // collecting 4 addr bytes
    localparam ST_MEM_LEN = 4'd4; // collecting 2 length bytes
    localparam ST_MEM_WD  = 4'd5; // WRITE_MEM: collecting 2 data bytes/word
    localparam ST_MEM_WISS= 4'd6; // WRITE_MEM: issue+wait mem_req
    localparam ST_MEM_RISS= 4'd7; // READ_MEM: issue+wait mem_req
    localparam ST_MEM_ROUT= 4'd8; // READ_MEM: shifting the 2 bytes of a word out
    localparam ST_IGNORE  = 4'd9; // opcode consumed / unknown, wait for cs_rose

    reg [3:0]  state;
    reg [7:0]  opcode;
    reg [4:0]  byte_idx;      // generic byte counter within a field (up to 17, WRITE_JOB)
    reg [15:0] len_words;
    reg [15:0] word_cnt;
    reg [15:0] cur_word;      // WRITE_MEM: assembling MSB,LSB; READ_MEM: holding readback
    reg        job_busy_r, mem_busy_r, last_job_accepted_r;

    // combinational tx byte mux -- STATUS response, READ_MEM data,
    // everything else drives 0x00
    reg [7:0] tx_mux;
    always @(*) begin
        tx_mux = 8'h00;
        if (opcode == OP_STATUS)
            tx_mux = {5'b0, last_job_accepted_r, mem_busy_r, job_busy_r};
        else if (opcode == OP_READ_MEM && state == ST_MEM_ROUT)
            tx_mux = (byte_idx == 5'd0) ? cur_word[15:8] : cur_word[7:0];
    end
    assign tx_byte = tx_mux;

    always @(posedge clk) begin
        if (rst) begin
            state <= ST_OPCODE; opcode <= 8'h00; byte_idx <= 5'd0;
            len_words <= 16'd0; word_cnt <= 16'd0; cur_word <= 16'd0;
            reg_valid <= 1'b0; reg_node_id <= {NODEW{1'b0}}; reg_required <= {REQW{1'b0}};
            reg_producer_ids <= {(MAX_DEPS*NODEW){1'b0}};
            reg_x_base <= {ADDR_WIDTH{1'b0}}; reg_w_base <= {ADDR_WIDTH{1'b0}};
            reg_n_tiles <= 16'd0; reg_result_addr <= {ADDR_WIDTH{1'b0}};
            mem_req <= 1'b0; mem_wr <= 1'b0; mem_addr <= {ADDR_WIDTH{1'b0}};
            mem_wdata <= 16'd0; mem_lb_n <= 1'b0; mem_ub_n <= 1'b0;
            soft_rst_pulse <= 1'b0;
            job_busy_r <= 1'b0; mem_busy_r <= 1'b0; last_job_accepted_r <= 1'b0;
        end else begin
            mem_req        <= 1'b0;
            soft_rst_pulse <= 1'b0;

            // A new CS assertion normally starts a fresh opcode byte.
            // EXCEPTION (found via this module's own board-level
            // integration smoke test, STEP20): if the PREVIOUS
            // transaction is still pending a backend handshake
            // (ST_JOB_WAIT/ST_MEM_WISS/ST_MEM_RISS -- e.g. reg_valid
            // held, waiting on dependency_manager's reg_ready, per
            // this module's own documented "hold until accepted"
            // contract), do NOT reset state/byte_idx here: a naive
            // unconditional reset lets a new WRITE_JOB's incoming
            // bytes start overwriting reg_node_id/reg_x_base/reg_
            // w_base/etc THROUGH THE SAME REGISTERS while the OLD
            // job's reg_valid is still asserted and not yet accepted,
            // corrupting the first job's dispatch with a mix of both
            // jobs' fields (confirmed: two back-to-back WRITE_JOB
            // transactions produced swapped/wrong result values,
            // root-caused via a full internal signal trace before
            // this fix). Mirrors the same protection already applied
            // to cs_rose below.
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
                            OP_RESET:     state <= ST_IGNORE;
                            default:      state <= ST_IGNORE; // NOP, STATUS: no MOSI payload
                        endcase
                    end

                    ST_JOB: begin
                        case (byte_idx)
                            5'd0:  reg_node_id                 <= rx_byte[NODEW-1:0];
                            5'd1:  reg_required                <= rx_byte[REQW-1:0];
                            5'd2:  reg_producer_ids[15:8]       <= rx_byte;
                            5'd3:  reg_producer_ids[7:0]        <= rx_byte;
                            5'd4:  reg_x_base[25:24]            <= rx_byte[1:0];
                            5'd5:  reg_x_base[23:16]            <= rx_byte;
                            5'd6:  reg_x_base[15:8]             <= rx_byte;
                            5'd7:  reg_x_base[7:0]              <= rx_byte;
                            5'd8:  reg_w_base[25:24]            <= rx_byte[1:0];
                            5'd9:  reg_w_base[23:16]            <= rx_byte;
                            5'd10: reg_w_base[15:8]             <= rx_byte;
                            5'd11: reg_w_base[7:0]              <= rx_byte;
                            5'd12: reg_n_tiles[15:8]            <= rx_byte;
                            5'd13: reg_n_tiles[7:0]             <= rx_byte;
                            5'd14: reg_result_addr[25:24]       <= rx_byte[1:0];
                            5'd15: reg_result_addr[23:16]       <= rx_byte;
                            5'd16: reg_result_addr[15:8]        <= rx_byte;
                            5'd17: begin
                                reg_result_addr[7:0] <= rx_byte;
                                reg_valid            <= 1'b1;
                                last_job_accepted_r  <= 1'b0;
                                state                <= ST_JOB_WAIT;
                            end
                        endcase
                        if (byte_idx != 5'd17) byte_idx <= byte_idx + 5'd1;
                    end

                    ST_MEM_ADDR: begin
                        case (byte_idx)
                            5'd0: mem_addr[25:24] <= rx_byte[1:0];
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

                    default: ; // ST_JOB_WAIT/ST_MEM_WISS/ST_MEM_RISS/ST_MEM_ROUT/ST_IGNORE: no MOSI payload expected
                endcase
            end

            // ---- non-rx_valid-driven transitions ----
            if (state == ST_JOB_WAIT && reg_valid && reg_ready) begin
                reg_valid            <= 1'b0;
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
                // a byte was clocked out while this state was active;
                // rx_valid pulses once per real byte transferred, so
                // it is also the correct "advance" event for MISO-side
                // bookkeeping (mirrors spi_slave's own documented
                // rx_valid-drives-advancement convention).
                if (byte_idx == 5'd0) begin
                    byte_idx <= 5'd1;
                end else begin
                    mem_addr <= mem_addr + 1'b1;
                    word_cnt <= word_cnt - 1'b1;
                    byte_idx <= 5'd0;
                    state    <= (word_cnt == 16'd1) ? ST_IGNORE : ST_MEM_RISS;
                end
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
