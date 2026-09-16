`timescale 1ns/1ps

// ============================================================
// EXP-0057 -- layer prefetch controller: bulk-sequential fetch of one
// layer's weights from the real SDRAM controller (sdram_controller_
// openrow.v's own req/wr/addr/wdata/wmask -> rdata/ready/busy
// contract, BURST_LEN words per transaction) into a layer_weight_
// buffer.v's inactive side. Real RTL version of the exact access
// pattern tb_layer_reuse_vs_zero_reuse.v's own prefetch_layer task
// already measured (7.16x real memory-side speedup vs zero-reuse,
// same hardware, see that testbench's own header).
//
// One layer = LAYER_BYTES bytes, fetched as LAYER_BYTES/(2*BURST_LEN)
// back-to-back BURST_LEN-word transactions starting at layer_base
// (word address). Sequential -> lands in the SAME open row for any
// layer that fits within one row (1024 columns = 256 tile-blocks at
// BURST_LEN=8 -- true for any real layer size this project's own
// target models use), so this composes directly with EXP-0054's
// open-row policy without needing anything special here.
//
// Each captured burst (ctrl_rdata, 16*BURST_LEN bits) is LATCHED
// locally before draining -- does not assume the controller holds
// rdata stable beyond the cycle `ready` pulses (its own documented
// contract is "valid the same cycle ready pulses", nothing more).
// Drained one byte/cycle via a flat byte-index counter (drain_cnt)
// indexing directly into the latched burst -- no separate word/byte
// sub-counters to keep in sync, deliberately simpler than a first
// draft of this module that tracked them separately and was harder to
// convince correct by inspection.
// ============================================================
module layer_prefetch_ctrl #(
    parameter DATA_WIDTH  = 8,
    parameter LAYER_BYTES = 128,
    parameter BURST_LEN   = 8,
    parameter ADDR_WIDTH  = 25,   // matches sdram_controller_openrow.v's own word-address convention
    parameter BUFADDRW    = (LAYER_BYTES <= 1) ? 1 : $clog2(LAYER_BYTES)
)(
    input  wire clk,
    input  wire rst,

    // ---- job control ----
    input  wire                   start,       // pulse: begin fetching `layer_base` into the inactive buffer
    input  wire [ADDR_WIDTH-1:0]  layer_base,  // word address of this layer's weights in SDRAM
    output reg                    busy,
    output reg                    done,        // pulse: matches layer_weight_buffer.v's own fill_done

    // ---- layer_weight_buffer.v fill side ----
    output reg                    fill_we,
    output reg  [BUFADDRW-1:0]    fill_addr,
    output reg  [DATA_WIDTH-1:0]  fill_data,

    // ---- sdram_controller_openrow.v (or plain sdram_controller.v --
    // identical port contract) ----
    output reg                     ctrl_req,
    output wire                    ctrl_wr,     // always 0: read-only
    output reg  [ADDR_WIDTH-1:0]   ctrl_addr,
    output wire [16*BURST_LEN-1:0] ctrl_wdata,  // unused (read-only), tied off
    output wire [2*BURST_LEN-1:0]  ctrl_wmask,  // unused (read-only), tied off
    input  wire [16*BURST_LEN-1:0] ctrl_rdata,
    input  wire                    ctrl_ready,
    input  wire                    ctrl_busy
);
    localparam BYTES_PER_BURST  = 2*BURST_LEN;
    localparam BURSTS_PER_LAYER = LAYER_BYTES/BYTES_PER_BURST;
    localparam BIDXW = (BURSTS_PER_LAYER <= 1) ? 1 : $clog2(BURSTS_PER_LAYER);
    localparam DIDXW = $clog2(BYTES_PER_BURST);

    assign ctrl_wr    = 1'b0;
    assign ctrl_wdata = {(16*BURST_LEN){1'b0}};
    assign ctrl_wmask = {(2*BURST_LEN){1'b0}};

    localparam S_IDLE  = 3'd0,
               S_WAIT  = 3'd1,
               S_DRAIN = 3'd2,
               S_TAIL  = 3'd3;

    reg [2:0]            state;
    reg [BIDXW-1:0]      burst_idx;
    reg [DIDXW-1:0]      drain_cnt;
    reg [ADDR_WIDTH-1:0] base_lat;
    reg [16*BURST_LEN-1:0] burst_lat;

    // combinational: which byte of the layer is currently being drained
    wire [BUFADDRW-1:0] cur_fill_addr = burst_idx * BYTES_PER_BURST + drain_cnt;

    always @(posedge clk) begin
        if (rst) begin
            state     <= S_IDLE;
            busy      <= 1'b0;
            done      <= 1'b0;
            fill_we   <= 1'b0;
            fill_addr <= {BUFADDRW{1'b0}};
            fill_data <= {DATA_WIDTH{1'b0}};
            ctrl_req  <= 1'b0;
            ctrl_addr <= {ADDR_WIDTH{1'b0}};
            burst_idx <= {BIDXW{1'b0}};
            drain_cnt <= {DIDXW{1'b0}};
            base_lat  <= {ADDR_WIDTH{1'b0}};
            burst_lat <= {(16*BURST_LEN){1'b0}};
        end else begin
            ctrl_req <= 1'b0;
            fill_we  <= 1'b0;
            done     <= 1'b0;

            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy      <= 1'b1;
                        base_lat  <= layer_base;
                        burst_idx <= {BIDXW{1'b0}};
                        ctrl_req  <= 1'b1;
                        ctrl_addr <= layer_base;
                        state     <= S_WAIT;
                    end
                end
                S_WAIT: begin
                    if (ctrl_ready) begin
                        burst_lat <= ctrl_rdata;
                        drain_cnt <= {DIDXW{1'b0}};
                        state     <= S_DRAIN;
                    end
                end
                S_DRAIN: begin
                    fill_we   <= 1'b1;
                    fill_addr <= cur_fill_addr;
                    fill_data <= burst_lat[drain_cnt*8 +: 8];

                    if (drain_cnt == BYTES_PER_BURST - 1) begin
                        // this cycle drains the LAST byte of this burst
                        if (burst_idx == BURSTS_PER_LAYER - 1) begin
                            // last burst of the layer too -- one more
                            // cycle for this final fill_we to land, then done
                            state <= S_IDLE; // will be overridden below to a tail state
                        end else begin
                            burst_idx <= burst_idx + 1'b1;
                            ctrl_req  <= 1'b1;
                            ctrl_addr <= base_lat + ((burst_idx + 1'b1) * BURST_LEN[ADDR_WIDTH-1:0]);
                            state     <= S_WAIT;
                        end
                    end else begin
                        drain_cnt <= drain_cnt + 1'b1;
                    end

                    if (drain_cnt == BYTES_PER_BURST - 1 &&
                        burst_idx == BURSTS_PER_LAYER - 1) begin
                        state <= S_TAIL;
                    end
                end
                S_TAIL: begin
                    // the last fill_we (asserted combinationally in the
                    // S_DRAIN cycle above) is landing on THIS clock edge's
                    // rising edge as far as layer_weight_buffer.v is
                    // concerned (fill_we/_addr/_data were registered
                    // outputs of the previous cycle) -- signal done now.
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    state <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
