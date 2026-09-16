`timescale 1ns/1ps

// ============================================================
// V3 -- real synthesizable tile-gather adapter, the piece EXP-0058's
// own log entry flagged as still missing ("a real 'tile gather
// adapter' (8:1 byte-to-tile packer) would be the natural next M4
// Memory Manager deliverable if this architecture is adopted for the
// real board" -- tb_neural_processor_layer_reuse.v did this step in
// the testbench only, not in RTL).
//
// Sits between layer_weight_buffer.v's byte-wide read port (one
// address = one byte) and neural_processor_packed.v's P_IN-wide
// weight_data tile bus. Sequences P_IN reads, one byte/cycle, and
// assembles them via a FIXED (compile-time-constant) shift-concat --
// deliberately NOT a runtime-indexed part-select into the wide
// tile_data register. This project has already been bitten by that
// exact anti-pattern twice (neural_director.v's own slot_x_base_r
// fix, ERR-0027-class: a variable-indexed write into a wide packed
// register synthesizes as a real hard-multiplier-fed crossbar, real
// measured Fmax collapse 68.51->~40-47MHz) -- avoided here from the
// start rather than found and fixed later.
//
// Byte read at tile_base+i lands at tile_data[i*DATA_WIDTH +:
// DATA_WIDTH] (i=0 is the FIRST byte read, ends at the LSB end) --
// matches neural_processor_packed.v's own w0[gi] <=
// weight_data[gi*DATA_WIDTH +: DATA_WIDTH] indexing exactly.
//
// Latency: P_IN+1 cycles from tile_req to tile_valid (1 address-setup
// cycle + P_IN capture-and-advance cycles) -- correctness-first, not
// yet pipelined/overlapped; matches this project's own staged
// performance-after-correctness discipline.
// ============================================================
module weight_tile_gather #(
    parameter DATA_WIDTH = 8,
    parameter P_IN       = 8,
    parameter BUFADDRW   = 7
)(
    input  wire clk,
    input  wire rst,

    // ---- control: gather the tile starting at tile_base ----
    input  wire                       tile_req,
    input  wire [BUFADDRW-1:0]        tile_base,
    output reg                        tile_valid,  // one-cycle pulse
    output reg  [DATA_WIDTH*P_IN-1:0] tile_data,

    // ---- layer_weight_buffer.v read port ----
    output reg  [BUFADDRW-1:0]        rd_addr,
    input  wire [DATA_WIDTH-1:0]      rd_data
);
    localparam CNTW   = $clog2(P_IN+1);
    localparam G_IDLE = 1'b0, G_RUN = 1'b1;

    reg             g_state;
    reg [CNTW-1:0]  byte_cnt;

    always @(posedge clk) begin
        if (rst) begin
            g_state    <= G_IDLE;
            tile_valid <= 1'b0;
            rd_addr    <= {BUFADDRW{1'b0}};
            byte_cnt   <= {CNTW{1'b0}};
            tile_data  <= {(DATA_WIDTH*P_IN){1'b0}};
        end else begin
            tile_valid <= 1'b0;
            case (g_state)
                G_IDLE: begin
                    if (tile_req) begin
                        rd_addr  <= tile_base;
                        byte_cnt <= {CNTW{1'b0}};
                        g_state  <= G_RUN;
                    end
                end
                G_RUN: begin
                    // rd_data reflects the rd_addr driven last cycle
                    // (layer_weight_buffer.v's read is combinational).
                    tile_data <= {rd_data, tile_data[DATA_WIDTH*P_IN-1:DATA_WIDTH]};
                    if (byte_cnt == P_IN[CNTW-1:0] - 1'b1) begin
                        tile_valid <= 1'b1;
                        g_state    <= G_IDLE;
                    end else begin
                        rd_addr  <= tile_base + byte_cnt + 1'b1;
                        byte_cnt <= byte_cnt + 1'b1;
                    end
                end
                default: g_state <= G_IDLE;
            endcase
        end
    end
endmodule
