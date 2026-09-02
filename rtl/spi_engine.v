`timescale 1ns/1ps

// ================================================================
// SPI_ENGINE - opcode/protocol FSM + register bank
//
// Implements the v1 draft protocol in docs/FPGA-NeuralNetwork-Engine.md
// §8.1 on top of the byte-level interface exposed by spi_slave.v.
// One opcode byte per CS-low transaction (§8.1 framing).
//
// IMPORTANT (see rtl/spi_slave.v for the full contract):
//   - tx_byte is driven COMBINATIONALLY from current state, so it is
//     always correct whenever spi_slave.v prefetches it (at cs_fell
//     and at every byte boundary) -- no explicit reaction needed.
//   - Any stateful pointer (RAM address, response byte index) is
//     advanced on rx_valid, which fires exactly once per REAL byte
//     transferred -- never on tx_byte_req, which fires one extra
//     "phantom" time after the last byte of a transaction.
//
// RAM byte-level master port uses the same convention as
// neuron_memory.v's external mem_* port (byte address, byte data,
// req/ready handshake) so it can share an arbiter + int8_memory_access
// + memory_interface chain with neuron_memory at the top level.
//
// v1 LIMITATION (documented, not yet solved): WRITE_RAM/READ_RAM
// have no backpressure to the SPI master. Each received/produced
// byte must be fully processed by this engine before the next
// SCLK-driven byte boundary arrives, i.e. the host must not clock
// RAM-touching commands faster than one RAM transaction (a handful
// of `clk` cycles) per SPI byte period. This is a reasonable
// constraint for bulk-loading weights/bias/input at initialization,
// not a real-time path.
// ================================================================

module spi_engine #(
    parameter ADDR_WIDTH = 22,
    parameter DATA_WIDTH = 8,
    parameter N_INPUTS   = 32,
    parameter N_NEURONS  = 1,
    parameter PARALLEL   = 8
)(
    input wire clk,
    input wire rst,

    // ------------------------------------------------------------
    // Byte-level interface from/to spi_slave.v
    // ------------------------------------------------------------

    input  wire [7:0] rx_byte,
    input  wire        rx_valid,
    input  wire         cs_start,
    input  wire         cs_end,

    output wire [7:0]  tx_byte,
    input  wire         tx_byte_req,   // unused on purpose, see header note

    // ------------------------------------------------------------
    // RAM byte-level master port (byte address, byte data)
    // ------------------------------------------------------------

    output reg                    ram_req,
    output reg                    ram_wr,
    output reg  [ADDR_WIDTH-1:0]  ram_addr,
    output reg  signed [7:0]      ram_wdata,

    input  wire signed [7:0]      ram_rdata,
    input  wire                   ram_ready,

    // ------------------------------------------------------------
    // neuron_memory control
    // ------------------------------------------------------------

    output reg  [ADDR_WIDTH-1:0] x_base,
    output reg  [ADDR_WIDTH-1:0] w_base,
    output reg  [ADDR_WIDTH-1:0] bias_addr,

    output reg                   nm_start,
    input  wire                  nm_busy,
    input  wire                  nm_done,   // one-cycle pulse

    input  wire signed [DATA_WIDTH*N_NEURONS-1:0] y_bus,

    output reg                   nm_soft_rst,

    // ------------------------------------------------------------
    // layer_sequencer control (Phase 5: RUN_NETWORK opcode)
    // ------------------------------------------------------------

    output reg  [ADDR_WIDTH-1:0] table_base,
    output reg  [ADDR_WIDTH-1:0] buf_a_base,
    output reg  [ADDR_WIDTH-1:0] buf_b_base,

    output reg                   run_start,      // one-cycle pulse
    output reg  [7:0]            run_num_layers,

    input  wire                  seq_busy,
    input  wire                  seq_done        // one-cycle pulse
);

    // ============================================================
    // OPCODES (docs §8.1 -- values are draft/example, see header)
    // ============================================================

    localparam OP_NOP         = 8'h00;
    localparam OP_WRITE_RAM   = 8'h01;
    localparam OP_READ_RAM    = 8'h02;
    localparam OP_RESET       = 8'h0F;
    localparam OP_SET_BASE    = 8'h10;
    localparam OP_START       = 8'h20;
    localparam OP_STATUS      = 8'h21;
    localparam OP_READ_OUTPUT = 8'h22;
    localparam OP_RUN_NETWORK = 8'h23;
    localparam OP_READ_CONFIG = 8'h30;

    // SET_BASE selector values
    localparam SEL_X_BASE     = 8'h00;
    localparam SEL_W_BASE     = 8'h01;
    localparam SEL_BIAS_ADDR  = 8'h02;
    localparam SEL_TABLE_BASE = 8'h03;
    localparam SEL_BUF_A_BASE = 8'h04;
    localparam SEL_BUF_B_BASE = 8'h05;

    // ============================================================
    // STATES
    // ============================================================

    localparam ST_OPCODE       = 4'd0;
    localparam ST_SETBASE_SEL  = 4'd1;
    localparam ST_ADDR         = 4'd2; // 3 bytes, MSB first
    localparam ST_LEN          = 4'd3; // 2 bytes, MSB first
    localparam ST_WRITE_DATA   = 4'd4;
    localparam ST_WRITE_ISSUE  = 4'd5;
    localparam ST_WRITE_WAIT   = 4'd6;
    localparam ST_READ_ISSUE   = 4'd7;
    localparam ST_READ_WAIT    = 4'd8;
    localparam ST_READ_DATA    = 4'd9;
    localparam ST_RESP         = 4'd10; // STATUS / READ_OUTPUT / READ_CONFIG
    localparam ST_IGNORE       = 4'd11;
    localparam ST_RUNNET       = 4'd12; // RUN_NETWORK: 1 payload byte (num_layers)

    reg [3:0] state;
    reg [7:0] opcode;

    // Generic byte-position counter for ADDR (0..2) / LEN (0..1)
    reg [1:0] byte_pos;

    reg [23:0] addr_acc;   // 3-byte accumulator, byte address
    reg [15:0] len_acc;    // 2-byte accumulator, transfer length
    reg [15:0] len_remaining;

    reg [ADDR_WIDTH-1:0] cur_addr;

    reg pending_write;
    reg [7:0] pending_wdata;

    reg [7:0] cur_read_byte;

    reg [3:0] resp_index;  // response byte index (max needed: 8, READ_CONFIG)
    reg [3:0] resp_len;    // total bytes for the current response opcode

    // ============================================================
    // STICKY STATUS.done LATCH
    //
    // neuron_memory.done is a one-cycle pulse; STATUS must hold it
    // until the host actually reads STATUS (or issues RESET), or a
    // slow SPI poll would almost certainly miss it. See docs §8.1.
    // ============================================================

    reg status_done_sticky;

    // net_mode: set while a RUN_NETWORK (multi-layer) job is in
    // flight (from the accepted opcode until layer_sequencer's
    // final seq_done), so STATUS.done latches on the sequencer's
    // seq_done rather than on each intermediate per-layer nm_done
    // pulse -- see done_event below.
    reg net_mode;

    wire busy_all   = nm_busy | seq_busy;
    wire done_event = net_mode ? seq_done : nm_done;

    wire status_read_now = (state == ST_RESP) && (opcode == OP_STATUS) && rx_valid;

    // status_snapshot: the STATUS byte is latched once, when the
    // OP_STATUS opcode itself is accepted (ST_OPCODE, below), not
    // read live/combinationally throughout ST_RESP. Without this,
    // a done_event landing WHILE a STATUS response byte is already
    // mid-transmission races the clear-on-read logic: the host can
    // end up shifting out a stale pre-done byte while this engine
    // simultaneously treats the sticky bit as "delivered" and
    // clears it -- silently dropping the done transition forever
    // (found via sim/spi_neuron_top_runnetwork_tb.v: a done_event
    // landing mid-poll during continuous STATUS polling reproduces
    // this every time). Freezing the byte at opcode-accept time and
    // gating the clear on what was ACTUALLY snapshotted (below)
    // closes the race: a done_event that lands too late to make it
    // into this snapshot is simply reported on the next poll
    // instead of being lost.
    reg [7:0] status_snapshot;

    always @(posedge clk) begin
        if (rst) begin
            status_done_sticky <= 1'b0;
        end else if (nm_soft_rst) begin
            status_done_sticky <= 1'b0;
        end else if (done_event) begin
            status_done_sticky <= 1'b1;
        end else if (status_read_now && status_snapshot[1]) begin
            status_done_sticky <= 1'b0;
        end
    end

    // ============================================================
    // tx_byte: fully combinational, always reflects "the byte to
    // send right now" for the current state/response index. This
    // is what spi_slave.v prefetches via tx_byte_req -- see the
    // module header for why this must not depend on tx_byte_req.
    // ============================================================

    reg [7:0] tx_byte_comb;

    always @(*) begin
        tx_byte_comb = 8'h00;

        case (state)

            ST_READ_DATA: tx_byte_comb = cur_read_byte;

            ST_RESP: begin
                case (opcode)

                    OP_STATUS: tx_byte_comb = status_snapshot;

                    OP_READ_OUTPUT: begin
                        if (resp_index < N_NEURONS)
                            tx_byte_comb = y_bus[resp_index*DATA_WIDTH +: DATA_WIDTH];
                        else
                            tx_byte_comb = 8'h00;
                    end

                    OP_READ_CONFIG: begin
                        case (resp_index)
                            4'd0: tx_byte_comb = ADDR_WIDTH[7:0];
                            4'd1: tx_byte_comb = N_INPUTS[15:8];
                            4'd2: tx_byte_comb = N_INPUTS[7:0];
                            4'd3: tx_byte_comb = N_NEURONS[7:0];
                            4'd4: tx_byte_comb = PARALLEL[7:0];
                            4'd5: tx_byte_comb = DATA_WIDTH[7:0];
                            4'd6: tx_byte_comb = 8'h00; // protocol version 0x0001, high byte
                            4'd7: tx_byte_comb = 8'h01; // protocol version 0x0001, low byte
                            default: tx_byte_comb = 8'h00;
                        endcase
                    end

                    default: tx_byte_comb = 8'h00;

                endcase
            end

            default: tx_byte_comb = 8'h00;

        endcase
    end

    assign tx_byte = tx_byte_comb;

    // ============================================================
    // MAIN FSM
    // ============================================================

    always @(posedge clk) begin

        if (rst) begin

            state          <= ST_OPCODE;
            opcode         <= 8'h00;
            byte_pos       <= 2'd0;
            addr_acc       <= 24'h0;
            len_acc        <= 16'h0;
            len_remaining  <= 16'h0;
            cur_addr       <= {ADDR_WIDTH{1'b0}};
            pending_write  <= 1'b0;
            pending_wdata  <= 8'h00;
            cur_read_byte  <= 8'h00;
            resp_index     <= 4'd0;
            resp_len       <= 4'd0;
            status_snapshot <= 8'h00;

            ram_req        <= 1'b0;
            ram_wr         <= 1'b0;
            ram_addr       <= {ADDR_WIDTH{1'b0}};
            ram_wdata      <= 8'sd0;

            x_base         <= {ADDR_WIDTH{1'b0}};
            w_base         <= {ADDR_WIDTH{1'b0}};
            bias_addr      <= {ADDR_WIDTH{1'b0}};

            nm_start       <= 1'b0;
            nm_soft_rst    <= 1'b0;

            table_base     <= {ADDR_WIDTH{1'b0}};
            buf_a_base     <= {ADDR_WIDTH{1'b0}};
            buf_b_base     <= {ADDR_WIDTH{1'b0}};
            run_start      <= 1'b0;
            run_num_layers <= 8'h00;
            net_mode       <= 1'b0;

        end else begin

            // --------------------------------------------------
            // Default pulses
            // --------------------------------------------------
            ram_req     <= 1'b0;
            nm_start    <= 1'b0;
            nm_soft_rst <= 1'b0;
            run_start   <= 1'b0;

            if (seq_done) begin
                net_mode <= 1'b0;
            end

            if (cs_end) begin

                // End of transaction: always return to opcode wait,
                // regardless of where we were (defensive: a short
                // or malformed transaction cannot wedge the engine).
                state <= ST_OPCODE;

            end else begin

                case (state)

                    // =============================================
                    // OPCODE
                    // =============================================

                    ST_OPCODE: begin

                        if (rx_valid) begin

                            opcode   <= rx_byte;
                            byte_pos <= 2'd0;

                            case (rx_byte)

                                OP_WRITE_RAM, OP_READ_RAM: begin
                                    addr_acc <= 24'h0;
                                    state    <= ST_ADDR;
                                end

                                OP_SET_BASE: begin
                                    state <= ST_SETBASE_SEL;
                                end

                                OP_START: begin
                                    if (!busy_all)
                                        nm_start <= 1'b1;
                                    state <= ST_IGNORE;
                                end

                                OP_RUN_NETWORK: begin
                                    state <= ST_RUNNET;
                                end

                                OP_RESET: begin
                                    nm_soft_rst <= 1'b1;
                                    net_mode    <= 1'b0;
                                    state       <= ST_IGNORE;
                                end

                                OP_STATUS: begin
                                    resp_index     <= 4'd0;
                                    resp_len       <= 4'd1;
                                    status_snapshot <= {6'b0, status_done_sticky, busy_all};
                                    state          <= ST_RESP;
                                end

                                OP_READ_OUTPUT: begin
                                    resp_index <= 4'd0;
                                    resp_len   <= N_NEURONS[3:0];
                                    state      <= ST_RESP;
                                end

                                OP_READ_CONFIG: begin
                                    resp_index <= 4'd0;
                                    resp_len   <= 4'd8;
                                    state      <= ST_RESP;
                                end

                                default: begin // OP_NOP and unknown opcodes
                                    state <= ST_IGNORE;
                                end

                            endcase

                        end

                    end

                    // =============================================
                    // SET_BASE: 1 selector byte, then 3 addr bytes
                    // =============================================

                    ST_SETBASE_SEL: begin

                        if (rx_valid) begin
                            addr_acc <= 24'h0;
                            // Reuse `len_acc[7:0]` as a 1-byte stash
                            // for the selector between states.
                            len_acc[7:0] <= rx_byte;
                            state    <= ST_ADDR;
                        end

                    end

                    // =============================================
                    // ADDR: 3 bytes, MSB first
                    // Shared by WRITE_RAM / READ_RAM / SET_BASE.
                    // =============================================

                    ST_ADDR: begin

                        if (rx_valid) begin

                            addr_acc <= {addr_acc[15:0], rx_byte};

                            if (byte_pos == 2'd2) begin

                                byte_pos <= 2'd0;

                                if (opcode == OP_SET_BASE) begin

                                    case (len_acc[7:0])
                                        SEL_X_BASE:     x_base     <= {addr_acc[15:0], rx_byte};
                                        SEL_W_BASE:     w_base     <= {addr_acc[15:0], rx_byte};
                                        SEL_BIAS_ADDR:  bias_addr  <= {addr_acc[15:0], rx_byte};
                                        SEL_TABLE_BASE: table_base <= {addr_acc[15:0], rx_byte};
                                        SEL_BUF_A_BASE: buf_a_base <= {addr_acc[15:0], rx_byte};
                                        SEL_BUF_B_BASE: buf_b_base <= {addr_acc[15:0], rx_byte};
                                        default: ; // reserved selector: ignored
                                    endcase

                                    state <= ST_IGNORE;

                                end else begin

                                    cur_addr <= {addr_acc[15:0], rx_byte};
                                    len_acc  <= 16'h0;
                                    state    <= ST_LEN;

                                end

                            end else begin

                                byte_pos <= byte_pos + 2'd1;

                            end

                        end

                    end

                    // =============================================
                    // LEN: 2 bytes, MSB first (WRITE_RAM / READ_RAM)
                    // =============================================

                    ST_LEN: begin

                        if (rx_valid) begin

                            len_acc <= {len_acc[7:0], rx_byte};

                            if (byte_pos == 2'd1) begin

                                len_remaining <= {len_acc[7:0], rx_byte};
                                byte_pos      <= 2'd0;

                                if ({len_acc[7:0], rx_byte} == 16'h0) begin

                                    state <= ST_IGNORE;

                                end else if (opcode == OP_WRITE_RAM) begin

                                    state <= ST_WRITE_DATA;

                                end else begin // OP_READ_RAM

                                    state <= ST_READ_ISSUE;

                                end

                            end else begin

                                byte_pos <= byte_pos + 2'd1;

                            end

                        end

                    end

                    // =============================================
                    // WRITE_RAM: accept one data byte, write it,
                    // repeat for len_remaining bytes.
                    // =============================================

                    ST_WRITE_DATA: begin

                        if (rx_valid) begin
                            pending_wdata <= rx_byte;
                            state         <= ST_WRITE_ISSUE;
                        end

                    end

                    ST_WRITE_ISSUE: begin

                        ram_req   <= 1'b1;
                        ram_wr    <= 1'b1;
                        ram_addr  <= cur_addr;
                        ram_wdata <= $signed(pending_wdata);

                        state <= ST_WRITE_WAIT;

                    end

                    ST_WRITE_WAIT: begin

                        if (ram_ready) begin

                            cur_addr      <= cur_addr + 1'b1;
                            len_remaining <= len_remaining - 16'd1;

                            if (len_remaining == 16'd1)
                                state <= ST_IGNORE;
                            else
                                state <= ST_WRITE_DATA;

                        end

                    end

                    // =============================================
                    // READ_RAM: prefetch one byte, serve it, repeat.
                    // =============================================

                    ST_READ_ISSUE: begin

                        ram_req  <= 1'b1;
                        ram_wr   <= 1'b0;
                        ram_addr <= cur_addr;

                        state <= ST_READ_WAIT;

                    end

                    ST_READ_WAIT: begin

                        if (ram_ready) begin
                            cur_read_byte <= ram_rdata[7:0];
                            state         <= ST_READ_DATA;
                        end

                    end

                    ST_READ_DATA: begin

                        // rx_valid marks that the response byte
                        // currently on tx_byte has been shifted out
                        // and a (dummy) MOSI byte was received in
                        // exchange -- advance to the next one.
                        if (rx_valid) begin

                            cur_addr      <= cur_addr + 1'b1;
                            len_remaining <= len_remaining - 16'd1;

                            if (len_remaining == 16'd1)
                                state <= ST_IGNORE;
                            else
                                state <= ST_READ_ISSUE;

                        end

                    end

                    // =============================================
                    // RUN_NETWORK: 1 payload byte (num_layers),
                    // then pulse run_start for layer_sequencer.
                    // No-op (ignored, like OP_START) if the compute
                    // engine is already busy in any form.
                    // =============================================

                    ST_RUNNET: begin

                        if (rx_valid) begin

                            if (!busy_all) begin
                                run_start      <= 1'b1;
                                run_num_layers <= rx_byte;
                                net_mode       <= 1'b1;
                            end

                            state <= ST_IGNORE;

                        end

                    end

                    // =============================================
                    // STATUS / READ_OUTPUT / READ_CONFIG response
                    // =============================================

                    ST_RESP: begin

                        if (rx_valid) begin

                            if (resp_index == resp_len - 4'd1)
                                state <= ST_IGNORE;
                            else
                                resp_index <= resp_index + 4'd1;

                        end

                    end

                    // =============================================
                    // IGNORE: transaction's meaningful bytes are
                    // done; ignore anything else until cs_end.
                    // =============================================

                    ST_IGNORE: begin
                        // intentionally empty
                    end

                    default: begin
                        state <= ST_OPCODE;
                    end

                endcase

            end

        end

    end

endmodule
