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
    parameter ADDR_WIDTH = 23,
    parameter DATA_WIDTH = 8,
    parameter N_INPUTS   = 32,
    parameter N_NEURONS  = 1,
    parameter PARALLEL   = 8,
    parameter N_TOTAL    = 4096  // Phase G5: graph (Type #2) activation buffer depth, exposed via READ_CONFIG
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
    output reg  [1:0]            activation,
    output reg  [15:0]           n_inputs_real,
    output reg  [15:0]           n_neurons_real,

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
    input  wire                  seq_done,       // one-cycle pulse

    // ------------------------------------------------------------
    // graph_engine control (Phase G5: Type #2 network, dispatched by
    // RUN_NETWORK alongside layer_sequencer based on `net_type`; the
    // top level routes the `run_start` pulse above to whichever of
    // layer_sequencer/graph_engine is selected -- see
    // rtl/spi_neuron_top.v)
    // ------------------------------------------------------------

    output reg  [7:0]            net_type,        // 0x01=dense(#1) 0x02=graph(#2), default dense
    output reg  [15:0]           num_neurons_graph, // SET_BASE sel 9
    output reg  [15:0]           n_out,             // SET_BASE sel 10

    input  wire                  graph_busy,
    input  wire                  graph_done,      // one-cycle pulse
    input  wire                  graph_err,       // sticky guard-violation flag (§7)

    // ------------------------------------------------------------
    // flash_slot_manager control (Phase F5, flash-subsystem opcodes
    // §5 of the phase-plan). Command interface mirrors
    // flash_slot_manager.v's own port list directly -- see that
    // file's header for op_code 0-6 semantics. `flash_err` is a
    // STATUS-bit-only error report (STATUS.bit3, sticky-until-read,
    // same convention as status_done_sticky below) -- explicitly
    // NOT wired to irq_n/graph_err: reusing graph_err would conflate
    // two unrelated error domains (Type#2 guard violations vs flash
    // subsystem errors) into one ambiguous signal, and a flash op is
    // always host-initiated with a known opcode just issued, so
    // polling STATUS right after (as the phase-plan's own
    // "data_ready_n a fine op" convention already implies) is a
    // natural fit -- no extra async pin needed.
    // ------------------------------------------------------------
    output reg                   flash_op_start,
    output reg  [2:0]            flash_op_code,
    output reg  [3:0]            flash_slot_id,
    output reg  [23:0]           flash_new_offset,
    output reg  [23:0]           flash_new_length,
    output reg  [7:0]            flash_new_type,
    output reg  [ADDR_WIDTH-1:0] flash_ext_psram_addr,
    output reg  [23:0]           flash_ext_length,
    output reg  [23:0]           flash_raw_flash_addr,

    input  wire                  flash_busy,
    input  wire                  flash_done,      // one-cycle pulse
    input  wire                  flash_err,       // held until next flash_op_start

    output reg  [3:0]            flash_cat_read_sel, // CAT_INSPECT (added opcode, see below)
    input  wire [23:0]           flash_cat_out_offset,
    input  wire [23:0]           flash_cat_out_length,
    input  wire [7:0]            flash_cat_out_type,
    input  wire                  flash_cat_out_valid,
    input  wire [31:0]           flash_cat_out_crc,

    // ------------------------------------------------------------
    // Host attention signal (active-HIGH here; spi_neuron_top.v
    // inverts it to drive the physical active-low DATA_READY_N pin).
    // Mirrors STATUS.bit1 exactly -- same sticky-until-STATUS-read
    // latch (status_done_sticky below), so the host can either poll
    // STATUS or watch this pin (or both: reading STATUS clears the
    // pin too, they are the same flip-flop). IRQ_N is NOT driven
    // from here -- see spi_neuron_top.v, it comes straight from
    // graph_engine's own `err` (STATUS.bit2), a separate condition.
    // ------------------------------------------------------------
    output wire                  data_ready
);

    // ============================================================
    // OPCODES (docs §8.1 -- values are draft/example, see header)
    // ============================================================

    localparam OP_NOP         = 8'h00;
    localparam OP_WRITE_RAM   = 8'h01;
    localparam OP_READ_RAM    = 8'h02;
    localparam OP_RESET       = 8'h0F;
    localparam OP_SET_BASE    = 8'h10;
    localparam OP_SET_NET_TYPE = 8'h11;
    localparam OP_START       = 8'h20;
    localparam OP_STATUS      = 8'h21;
    localparam OP_READ_OUTPUT = 8'h22;
    localparam OP_RUN_NETWORK = 8'h23;
    localparam OP_READ_CONFIG = 8'h30;

    // Flash-subsystem opcodes (Phase F5, §5 of the phase-plan draft;
    // OP_CAT_INSPECT is an ADDED opcode, not in the literal draft --
    // see its own comment at ST_FLASH_PAYLOAD below for why it was
    // needed to actually deliver CAT_READ's "-> host" wording).
    localparam OP_FLASH_READ_BLOCK  = 8'h40;
    localparam OP_FLASH_WRITE_BLOCK = 8'h41;
    localparam OP_FLASH_ERASE       = 8'h42;
    localparam OP_CAT_READ          = 8'h43;
    localparam OP_CAT_WRITE_SLOT    = 8'h44;
    localparam OP_LOAD_SLOT         = 8'h45;
    localparam OP_SAVE_SLOT         = 8'h46;
    localparam OP_CAT_INSPECT       = 8'h47;

    // flash_op_code values, matching flash_slot_manager.v's own
    // op_code encoding exactly (0-3 catalog/slot ops, 4-6 raw block
    // ops -- see that file's header).
    localparam FOP_CAT_READ          = 3'd0;
    localparam FOP_CAT_WRITE_SLOT    = 3'd1;
    localparam FOP_LOAD_SLOT         = 3'd2;
    localparam FOP_SAVE_SLOT         = 3'd3;
    localparam FOP_FLASH_READ_BLOCK  = 3'd4;
    localparam FOP_FLASH_WRITE_BLOCK = 3'd5;
    localparam FOP_FLASH_ERASE       = 3'd6;

    // SET_BASE selector values
    localparam SEL_X_BASE     = 8'h00;
    localparam SEL_W_BASE     = 8'h01;
    localparam SEL_BIAS_ADDR  = 8'h02;
    localparam SEL_TABLE_BASE = 8'h03;
    localparam SEL_BUF_A_BASE = 8'h04;
    localparam SEL_BUF_B_BASE = 8'h05;
    localparam SEL_ACTIVATION = 8'h06;
    localparam SEL_N_INPUTS   = 8'h07;
    localparam SEL_N_NEURONS  = 8'h08;
    localparam SEL_NUM_NEURONS_GRAPH = 8'h09;
    localparam SEL_N_OUT             = 8'h0A;

    // net_type register values (§5)
    localparam NET_TYPE_DENSE = 8'h01;
    localparam NET_TYPE_GRAPH = 8'h02;

    // READ_CONFIG capability flags (byte 10, bit0)
    localparam GRAPH_SUPPORTED = 1'b1;

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
    localparam ST_SET_NET_TYPE = 4'd13; // SET_NET_TYPE: 1 payload byte (type)
    localparam ST_FLASH_PAYLOAD = 4'd14; // flash opcodes: 0-9 payload bytes, see below

    reg [3:0] state;
    reg [7:0] opcode;

    // ============================================================
    // Flash-subsystem opcode payload accumulator (Phase F5).
    //
    // All flash opcodes share ONE generic byte-shift accumulator
    // (same pattern as rtl/flash_slot_manager.v's own catalog-entry
    // decode: shift every incoming byte in, decode the fixed-width
    // fields out of the accumulated value on the LAST byte using
    // opcode-specific bit slices) rather than a bespoke per-opcode
    // state, since the payloads only differ in field COUNT/ORDER,
    // not in the byte-at-a-time framing mechanics.
    //
    //   FLASH_READ_BLOCK / FLASH_WRITE_BLOCK: 9 bytes (3+3+3)
    //   FLASH_ERASE:                          3 bytes
    //   CAT_READ:                             0 bytes (dispatched
    //                                          immediately at ST_OPCODE)
    //   CAT_WRITE_SLOT:                       8 bytes (1+3+3+1)
    //   LOAD_SLOT:                            4 bytes (1+3)
    //   SAVE_SLOT:                            7 bytes (1+3+3)
    //   CAT_INSPECT:                          1 byte (slot_id) --
    //     this is the ADDED opcode (not in the phase-plan's literal
    //     draft, see OP_CAT_INSPECT above): CAT_READ (0 payload
    //     bytes, matches the draft exactly) triggers a flash reload
    //     of the on-chip catalog register file and reports
    //     completion via data_ready_n like every other flash op --
    //     it does NOT itself return catalog bytes (flash ops are
    //     ms-scale and this project's whole SPI protocol is
    //     "fire-and-forget, then poll STATUS/data_ready_n", never
    //     "hold CS low across a multi-millisecond wait", so a
    //     synchronous in-transaction response wouldn't fit that
    //     model). CAT_INSPECT is the natural, already-established-
    //     pattern way to actually deliver the draft's own "-> host"
    //     wording: a SEPARATE, ordinary synchronous response opcode
    //     (like STATUS/READ_OUTPUT/READ_CONFIG already are) that
    //     reads the ALREADY-loaded on-chip register file for one
    //     slot, instantly, no wait needed.
    // ============================================================

    reg [71:0] flash_payload;     // 9-byte shift accumulator
    reg [3:0]  flash_byte_pos;    // 0..8
    reg [3:0]  flash_payload_len; // opcode-specific total byte count (0..9)

    // Generic byte-position counter for ADDR (0..2) / LEN (0..1)
    reg [1:0] byte_pos;

    reg [23:0] addr_acc;   // 3-byte accumulator, byte address
    reg [15:0] len_acc;    // 2-byte accumulator, transfer length
    reg [15:0] len_remaining;

    reg [ADDR_WIDTH-1:0] cur_addr;

    reg pending_write;
    reg [7:0] pending_wdata;

    reg [7:0] cur_read_byte;

    // Widened from [3:0] (max 15) to [4:0] (max 31) in F5: existing
    // opcodes' needs (STATUS=1, READ_OUTPUT<=N_NEURONS, READ_CONFIG=11)
    // are all still well within range, no behavior change for them --
    // only CAT_INSPECT's new 16-byte response actually needs the
    // extra bit (16 does not fit in 4 bits).
    reg [4:0] resp_index;  // response byte index
    reg [4:0] resp_len;    // total bytes for the current response opcode

    // ============================================================
    // STICKY STATUS.done LATCH
    //
    // neuron_memory.done is a one-cycle pulse; STATUS must hold it
    // until the host actually reads STATUS (or issues RESET), or a
    // slow SPI poll would almost certainly miss it. See docs §8.1.
    // ============================================================

    reg status_done_sticky;

    // Physical DATA_READY pin: the exact same flip-flop as
    // STATUS.bit1, just also wired straight to a pin. No separate
    // latch/clear logic needed -- it clears exactly when STATUS.bit1
    // does (host reads STATUS with the sticky bit set, or RESET).
    assign data_ready = status_done_sticky;

    // net_mode: set while a RUN_NETWORK (multi-layer, dense) job is
    // in flight (from the accepted opcode until layer_sequencer's
    // final seq_done), so STATUS.done latches on the sequencer's
    // seq_done rather than on each intermediate per-layer nm_done
    // pulse -- see done_event below. graph_mode is the analogous
    // flag for a RUN_NETWORK job dispatched to graph_engine instead
    // (net_type == graph); the two are mutually exclusive by
    // construction (RUN_NETWORK sets exactly one of them, §5).
    reg net_mode;
    reg graph_mode;

    wire busy_all   = nm_busy | seq_busy | graph_busy;

    // inference_done_event: UNCHANGED from before F5 -- this is a
    // MASK, not just a mutually-exclusive-source picker: while
    // net_mode is set, layer_sequencer drives neuron_memory once per
    // layer internally, so nm_done pulses once per layer too, and
    // those intermediate pulses must NOT surface as "the whole
    // RUN_NETWORK job is done" -- only the final seq_done may. Same
    // for graph_mode over both seq_done and nm_done. Verified this
    // masking is load-bearing by regressing sim/spi_engine_tb.v
    // against a naive flat OR of all four sources: TEST L
    // (RUN_NETWORK) failed immediately ("done bit set by an
    // intermediate nm_done during RUN_NETWORK") -- caught before
    // this ever reached WORKLOG.md as a false "PASS".
    wire inference_done_event = graph_mode ? graph_done : (net_mode ? seq_done : nm_done);

    // F5: flash ops run on Port D at low priority precisely so they
    // CAN overlap an inference run (mem_arbiter.v's own design
    // intent, F2's WORKLOG entry) -- flash_done is therefore ORed in
    // as a fully separate, orthogonal completion source, outside the
    // inference mask above (a flash completion must be visible
    // whether or not an inference job also happens to be in flight).
    wire done_event = inference_done_event | flash_done;

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
    //
    // bit2 = graph_err (§7 guard violation), snapshotted the same
    // way -- graph_engine.err is itself sticky until rst or the next
    // graph run_start, so no separate clear-on-read latch is needed
    // for it here (unlike status_done_sticky).
    //
    // bit3 = flash_err_sticky (F5): DOES need its own clear-on-read
    // latch, same reasoning/race as status_done_sticky itself --
    // flash_slot_manager.err is only held until the NEXT
    // flash_op_start (F4's own convention, see that file), not
    // until read, so without a sticky wrapper here a fast poll could
    // miss a one-shot error the same way a bare done pulse could.
    //
    // bit4 = flash_busy (F5): a live level, not sticky/latched --
    // deliberately NOT snapshotted, so it always reflects the
    // CURRENT state rather than the state at STATUS-opcode-accept
    // time (unlike bits 0-3, which describe a completed/completing
    // event this same STATUS read must not race).
    reg [7:0] status_snapshot;

    reg flash_err_sticky;

    always @(posedge clk) begin
        if (rst) begin
            status_done_sticky <= 1'b0;
            flash_err_sticky   <= 1'b0;
        end else if (nm_soft_rst) begin
            status_done_sticky <= 1'b0;
            flash_err_sticky   <= 1'b0;
        end else begin
            if (done_event) begin
                status_done_sticky <= 1'b1;
            end else if (status_read_now && status_snapshot[1]) begin
                status_done_sticky <= 1'b0;
            end

            if (flash_done && flash_err) begin
                flash_err_sticky <= 1'b1;
            end else if (status_read_now && status_snapshot[3]) begin
                flash_err_sticky <= 1'b0;
            end
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
                            4'd8: tx_byte_comb = N_TOTAL[15:8];  // Phase G5: graph activation buffer depth
                            4'd9: tx_byte_comb = N_TOTAL[7:0];
                            4'd10: tx_byte_comb = {7'b0, GRAPH_SUPPORTED}; // capability flags, bit0=graph
                            default: tx_byte_comb = 8'h00;
                        endcase
                    end

                    // CAT_INSPECT (F5, added opcode -- see
                    // flash_payload's declaration comment): 16-byte
                    // response, SAME byte layout as the raw catalog
                    // entry itself (tools/flash_catalog/oracle.py /
                    // rtl/flash_slot_manager.v's own header) -- MSB-
                    // first offset[3], length[3], type[1], valid[1]
                    // (0x01/0x00), crc32[4] MSB-first, reserved[4]=0.
                    OP_CAT_INSPECT: begin
                        case (resp_index)
                            5'd0:  tx_byte_comb = flash_cat_out_offset[23:16];
                            5'd1:  tx_byte_comb = flash_cat_out_offset[15:8];
                            5'd2:  tx_byte_comb = flash_cat_out_offset[7:0];
                            5'd3:  tx_byte_comb = flash_cat_out_length[23:16];
                            5'd4:  tx_byte_comb = flash_cat_out_length[15:8];
                            5'd5:  tx_byte_comb = flash_cat_out_length[7:0];
                            5'd6:  tx_byte_comb = flash_cat_out_type;
                            5'd7:  tx_byte_comb = flash_cat_out_valid ? 8'h01 : 8'h00;
                            5'd8:  tx_byte_comb = flash_cat_out_crc[31:24];
                            5'd9:  tx_byte_comb = flash_cat_out_crc[23:16];
                            5'd10: tx_byte_comb = flash_cat_out_crc[15:8];
                            5'd11: tx_byte_comb = flash_cat_out_crc[7:0];
                            default: tx_byte_comb = 8'h00; // reserved, bytes 12-15
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
            resp_index     <= 5'd0;
            resp_len       <= 5'd0;
            status_snapshot <= 8'h00;

            flash_payload      <= 72'h0;
            flash_byte_pos     <= 4'h0;
            flash_payload_len  <= 4'h0;
            flash_op_start     <= 1'b0;
            flash_op_code      <= 3'h0;
            flash_slot_id      <= 4'h0;
            flash_new_offset   <= 24'h0;
            flash_new_length   <= 24'h0;
            flash_new_type     <= 8'h0;
            flash_ext_psram_addr <= {ADDR_WIDTH{1'b0}};
            flash_ext_length     <= 24'h0;
            flash_raw_flash_addr <= 24'h0;
            flash_cat_read_sel   <= 4'h0;

            ram_req        <= 1'b0;
            ram_wr         <= 1'b0;
            ram_addr       <= {ADDR_WIDTH{1'b0}};
            ram_wdata      <= 8'sd0;

            x_base         <= {ADDR_WIDTH{1'b0}};
            w_base         <= {ADDR_WIDTH{1'b0}};
            bias_addr      <= {ADDR_WIDTH{1'b0}};
            activation     <= 2'd1; // ACT_RELU, matches neuron_parallel's own default
            n_inputs_real  <= N_INPUTS[15:0];
            n_neurons_real <= N_NEURONS[15:0];

            nm_start       <= 1'b0;
            nm_soft_rst    <= 1'b0;

            table_base     <= {ADDR_WIDTH{1'b0}};
            buf_a_base     <= {ADDR_WIDTH{1'b0}};
            buf_b_base     <= {ADDR_WIDTH{1'b0}};
            run_start      <= 1'b0;
            run_num_layers <= 8'h00;
            net_mode       <= 1'b0;

            net_type          <= NET_TYPE_DENSE; // default after RESET (§5): Type #1 tests need never emit SET_NET_TYPE
            num_neurons_graph <= 16'h0;
            n_out             <= 16'h0;
            graph_mode        <= 1'b0;

        end else begin

            // --------------------------------------------------
            // Default pulses
            // --------------------------------------------------
            ram_req     <= 1'b0;
            nm_start    <= 1'b0;
            nm_soft_rst <= 1'b0;
            run_start   <= 1'b0;
            flash_op_start <= 1'b0;

            if (seq_done) begin
                net_mode <= 1'b0;
            end

            if (graph_done) begin
                graph_mode <= 1'b0;
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
                                    graph_mode  <= 1'b0;
                                    net_type    <= NET_TYPE_DENSE;
                                    state       <= ST_IGNORE;
                                end

                                OP_SET_NET_TYPE: begin
                                    state <= ST_SET_NET_TYPE;
                                end

                                OP_STATUS: begin
                                    resp_index     <= 5'd0;
                                    resp_len       <= 5'd1;
                                    status_snapshot <= {3'b0, flash_busy, flash_err_sticky, graph_err, status_done_sticky, busy_all};
                                    state          <= ST_RESP;
                                end

                                OP_READ_OUTPUT: begin
                                    resp_index <= 4'd0;
                                    resp_len   <= N_NEURONS[3:0];
                                    state      <= ST_RESP;
                                end

                                OP_READ_CONFIG: begin
                                    resp_index <= 4'd0;
                                    resp_len   <= 4'd11;
                                    state      <= ST_RESP;
                                end

                                // =====================================
                                // Flash-subsystem opcodes (F5). All
                                // but CAT_READ (0 payload bytes) and
                                // CAT_INSPECT (dispatched, see below,
                                // straight to a synchronous ST_RESP)
                                // accumulate their payload in
                                // ST_FLASH_PAYLOAD and dispatch on
                                // its last byte.
                                // =====================================

                                OP_FLASH_READ_BLOCK, OP_FLASH_WRITE_BLOCK: begin
                                    flash_byte_pos    <= 4'h0;
                                    flash_payload_len <= 4'd9;
                                    state             <= ST_FLASH_PAYLOAD;
                                end

                                OP_FLASH_ERASE: begin
                                    flash_byte_pos    <= 4'h0;
                                    flash_payload_len <= 4'd3;
                                    state             <= ST_FLASH_PAYLOAD;
                                end

                                OP_CAT_READ: begin
                                    // 0 payload bytes: dispatch right
                                    // away. Mirrors OP_START's own
                                    // "if already busy, just ignore
                                    // the redundant start" convention
                                    // -- a well-behaved host always
                                    // waits for data_ready_n before
                                    // issuing a new flash op anyway.
                                    if (!flash_busy) begin
                                        flash_op_start <= 1'b1;
                                        flash_op_code  <= FOP_CAT_READ;
                                    end
                                    state <= ST_IGNORE;
                                end

                                OP_CAT_WRITE_SLOT: begin
                                    flash_byte_pos    <= 4'h0;
                                    flash_payload_len <= 4'd8;
                                    state             <= ST_FLASH_PAYLOAD;
                                end

                                OP_LOAD_SLOT: begin
                                    flash_byte_pos    <= 4'h0;
                                    flash_payload_len <= 4'd4;
                                    state             <= ST_FLASH_PAYLOAD;
                                end

                                OP_SAVE_SLOT: begin
                                    flash_byte_pos    <= 4'h0;
                                    flash_payload_len <= 4'd7;
                                    state             <= ST_FLASH_PAYLOAD;
                                end

                                OP_CAT_INSPECT: begin
                                    flash_byte_pos    <= 4'h0;
                                    flash_payload_len <= 4'd1;
                                    state             <= ST_FLASH_PAYLOAD;
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
                                        SEL_ACTIVATION: activation <= rx_byte[1:0]; // low 2 bits of the low addr byte
                                        SEL_N_INPUTS:   n_inputs_real  <= {addr_acc[7:0], rx_byte}; // low 2 of the 3 addr bytes, BE
                                        SEL_N_NEURONS:  n_neurons_real <= {addr_acc[7:0], rx_byte}; // low 2 of the 3 addr bytes, BE
                                        SEL_NUM_NEURONS_GRAPH: num_neurons_graph <= {addr_acc[7:0], rx_byte}; // Phase G5, graph mode
                                        SEL_N_OUT:              n_out             <= {addr_acc[7:0], rx_byte}; // Phase G5, graph mode
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
                    // RUN_NETWORK: 1 payload byte (num_layers, dense
                    // only -- ignored for graph, whose neuron count
                    // comes from SET_BASE sel 9 instead so this
                    // opcode's framing stays byte-identical for both
                    // net_type values, §5), then pulse run_start and
                    // dispatch to layer_sequencer or graph_engine
                    // based on net_type. The top level routes this
                    // single run_start pulse to whichever engine
                    // net_type selects (see rtl/spi_neuron_top.v).
                    // No-op (ignored, like OP_START) if the compute
                    // engine is already busy in any form.
                    // =============================================

                    ST_RUNNET: begin

                        if (rx_valid) begin

                            if (!busy_all) begin
                                run_start      <= 1'b1;
                                run_num_layers <= rx_byte;
                                if (net_type == NET_TYPE_GRAPH)
                                    graph_mode <= 1'b1;
                                else
                                    net_mode   <= 1'b1;
                            end

                            state <= ST_IGNORE;

                        end

                    end

                    // =============================================
                    // SET_NET_TYPE: 1 payload byte (§5)
                    // =============================================

                    ST_SET_NET_TYPE: begin

                        if (rx_valid) begin
                            // BUG-007 fix (docs/validation/bugs.md):
                            // net_type combinationally drives the
                            // arbiter Port C mux in spi_neuron_top.v
                            // (graph_engine vs. layer_sequencer) with
                            // no latch to "whichever engine started
                            // the in-flight run" -- accepting a new
                            // net_type while one of them is busy
                            // re-routes Port C out from under it
                            // mid-transaction, permanently hanging it
                            // (STATUS.busy stuck, confirmed
                            // end-to-end). Silently ignore the write
                            // while either engine is busy, same
                            // "accept the command, safe no-op"
                            // convention as WRITE_RAM/READ_RAM's
                            // len==0 guard -- the transaction still
                            // completes normally over SPI, net_type
                            // simply keeps its current value.
                            if (!graph_busy && !seq_busy)
                                net_type <= rx_byte;
                            state <= ST_IGNORE;
                        end

                    end

                    // =============================================
                    // Flash-subsystem opcode payload (F5). See the
                    // flash_payload/flash_byte_pos/flash_payload_len
                    // declarations above for the shared-accumulator
                    // rationale.
                    //
                    // `flash_payload` shifts on EVERY byte including
                    // the last; the last byte's decode below reads
                    // the PRE-update `flash_payload` (this cycle's
                    // old value, still holding the previous bytes)
                    // together with the current `rx_byte` directly --
                    // same "pre-update accumulator + current byte"
                    // pattern as rtl/flash_slot_manager.v's own
                    // catalog-entry decode, and for the same reason
                    // (the shift for THIS byte hasn't taken effect
                    // yet when this same always-block evaluation
                    // reads flash_payload combinationally).
                    // =============================================

                    ST_FLASH_PAYLOAD: begin

                        if (rx_valid) begin

                            flash_payload <= {flash_payload[63:0], rx_byte};

                            if (flash_byte_pos == flash_payload_len - 4'd1) begin

                                case (opcode)

                                    OP_FLASH_READ_BLOCK: begin
                                        if (!flash_busy) begin
                                            flash_op_start       <= 1'b1;
                                            flash_op_code         <= FOP_FLASH_READ_BLOCK;
                                            flash_raw_flash_addr  <= flash_payload[63:40];
                                            flash_ext_psram_addr  <= flash_payload[39:16];
                                            flash_ext_length      <= {flash_payload[15:0], rx_byte};
                                        end
                                    end

                                    OP_FLASH_WRITE_BLOCK: begin
                                        if (!flash_busy) begin
                                            flash_op_start       <= 1'b1;
                                            flash_op_code         <= FOP_FLASH_WRITE_BLOCK;
                                            flash_ext_psram_addr  <= flash_payload[63:40];
                                            flash_raw_flash_addr  <= flash_payload[39:16];
                                            flash_ext_length      <= {flash_payload[15:0], rx_byte};
                                        end
                                    end

                                    OP_FLASH_ERASE: begin
                                        if (!flash_busy) begin
                                            flash_op_start       <= 1'b1;
                                            flash_op_code         <= FOP_FLASH_ERASE;
                                            flash_raw_flash_addr  <= {flash_payload[15:0], rx_byte};
                                        end
                                    end

                                    OP_CAT_WRITE_SLOT: begin
                                        if (!flash_busy) begin
                                            flash_op_start   <= 1'b1;
                                            flash_op_code     <= FOP_CAT_WRITE_SLOT;
                                            // slot_id's byte occupies flash_payload[55:48];
                                            // slot_id itself is that byte's LOW nibble
                                            // (same host convention as LOAD_SLOT/SAVE_SLOT/
                                            // CAT_INSPECT's slot_id bytes below).
                                            flash_slot_id     <= flash_payload[51:48];
                                            flash_new_offset  <= flash_payload[47:24];
                                            flash_new_length  <= flash_payload[23:0];
                                            flash_new_type    <= rx_byte;
                                        end
                                    end

                                    OP_LOAD_SLOT: begin
                                        if (!flash_busy) begin
                                            flash_op_start        <= 1'b1;
                                            flash_op_code          <= FOP_LOAD_SLOT;
                                            flash_slot_id          <= flash_payload[19:16];
                                            flash_ext_psram_addr   <= {flash_payload[15:0], rx_byte};
                                        end
                                    end

                                    OP_SAVE_SLOT: begin
                                        if (!flash_busy) begin
                                            flash_op_start        <= 1'b1;
                                            flash_op_code          <= FOP_SAVE_SLOT;
                                            flash_slot_id          <= flash_payload[43:40];
                                            flash_ext_psram_addr   <= flash_payload[39:16];
                                            flash_ext_length       <= {flash_payload[15:0], rx_byte};
                                        end
                                    end

                                    OP_CAT_INSPECT: begin
                                        // Synchronous response, NOT a
                                        // flash_op_start -- reads the
                                        // already-loaded on-chip
                                        // catalog register file
                                        // directly. See the header
                                        // note at flash_payload's
                                        // declaration for why this
                                        // opcode exists.
                                        flash_cat_read_sel <= rx_byte[3:0];
                                        resp_index         <= 5'd0;
                                        resp_len            <= 5'd16;
                                    end

                                    default: ; // unreachable: only flash opcodes reach this state

                                endcase

                                state <= (opcode == OP_CAT_INSPECT) ? ST_RESP : ST_IGNORE;

                            end else begin

                                flash_byte_pos <= flash_byte_pos + 4'd1;

                            end

                        end

                    end

                    // =============================================
                    // STATUS / READ_OUTPUT / READ_CONFIG response
                    // =============================================

                    ST_RESP: begin

                        if (rx_valid) begin

                            if (resp_index == resp_len - 5'd1)
                                state <= ST_IGNORE;
                            else
                                resp_index <= resp_index + 5'd1;

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
