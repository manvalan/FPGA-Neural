`timescale 1ns/1ps

// ============================================================
// V3 -- adapter between this project's own established memory-
// controller contract (req/wr/addr/wdata/wmask -> rdata/ready/busy,
// BURST_LEN=8 16-bit words = 128 bits/transaction, the SAME shape
// sdram_controller.v has presented everywhere in this project since
// STEP16) and the REAL Xilinx MIG 7-series native "app" user
// interface (PG063), generated for this project's actual DDR3 target
// (mig_7series_0, XC7A100T, MT41J128M16JT-125:K, PHY:Controller
// ratio 2:1).
//
// Runs entirely in the ui_clk domain -- MIG's own generated clock is
// this design's new system clock (the standard way MIG-based designs
// are built; matches every real MIG reference design, not a
// deviation this project is inventing). rst must already be
// synchronized to ui_clk by the caller.
//
// ADDRESSING (real, derived from THIS project's actual generated MIG
// config, not assumed): Data Width=16, Phy:Controller ratio 2:1 =>
// nCK_PER_CLK=2 => app data width = 16*8/2 = 64 bits, matching the
// real generated mig_7series_0.v port widths exactly (app_wdf_data
// [63:0], app_rd_data[63:0]). One app_addr/app_cmd issuance moves a
// FULL BURST_LEN=8 (128-bit) DDR3 burst, delivered as TWO 64-bit
// beats on the app data bus -- so app_addr increments in the SAME
// unit as this project's own existing ctrl_addr (one BURST_LEN=8
// chunk per increment), no address scaling needed at this boundary.
//
// Sequencing is deliberately fully sequential, not pipelined
// (correctness first): the command is issued and accepted (app_en/
// app_rdy) BEFORE any write-data beat is asserted, and each of the
// two write-data beats (real MIG allows the address and write-data
// channels to accept independently/concurrently -- not used here) is
// held until its own app_wdf_rdy fires.
//
// app_cmd encoding (000=Write, 001=Read) is the standard, stable MIG
// convention -- NOT taken on faith alone: hardware/v3/sim/
// tb_mig_native_adapter.v verifies this adapter against MIG's own
// real, vendor-provided ddr3_model.sv (write, real DDR3 behavioral
// model, real read-back, bit-exact compare), so a wrong assumption
// here would show up as a real, observed data mismatch, not silently
// trusted.
// ============================================================
module mig_native_adapter #(
    parameter BURST_LEN  = 8,
    parameter ADDR_WIDTH = 25   // matches this project's own word-address convention
)(
    input  wire clk,   // = ui_clk
    input  wire rst,   // pre-synchronized to ui_clk

    // ---- this project's own established memory-controller contract ----
    input  wire                    req,
    input  wire                    wr,
    input  wire [ADDR_WIDTH-1:0]   addr,
    input  wire [16*BURST_LEN-1:0] wdata,
    input  wire [2*BURST_LEN-1:0]  wmask,
    output reg  [16*BURST_LEN-1:0] rdata,
    output reg                     ready,
    output wire                    busy,

    // ---- MIG native "app" interface (real generated port widths) ----
    output reg  [27:0] app_addr,
    output reg  [2:0]  app_cmd,
    output reg         app_en,
    input  wire        app_rdy,

    output reg  [63:0] app_wdf_data,
    output reg         app_wdf_end,
    output reg  [7:0]  app_wdf_mask,
    output reg         app_wdf_wren,
    input  wire        app_wdf_rdy,

    input  wire [63:0] app_rd_data,
    input  wire        app_rd_data_end,
    input  wire        app_rd_data_valid
);
    localparam CMD_WRITE = 3'b000;
    localparam CMD_READ  = 3'b001;

    localparam S_IDLE     = 3'd0,
               S_CMD_WAIT = 3'd1,
               S_WDF0     = 3'd2,
               S_WDF1     = 3'd3,
               S_RD_WAIT  = 3'd4,
               S_DONE     = 3'd5;

    reg [2:0] state;
    reg       wr_lat;
    reg [16*BURST_LEN-1:0] wdata_lat;
    reg [2*BURST_LEN-1:0]  wmask_lat;

    assign busy = (state != S_IDLE);

    always @(posedge clk) begin
        if (rst) begin
            state        <= S_IDLE;
            app_en       <= 1'b0;
            app_wdf_wren <= 1'b0;
            app_wdf_end  <= 1'b0;
            ready        <= 1'b0;
            rdata        <= {(16*BURST_LEN){1'b0}};
            app_addr     <= 28'h0;
            app_cmd      <= CMD_READ;
            app_wdf_data <= 64'h0;
            app_wdf_mask <= 8'h0;
        end else begin
            ready <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (req) begin
                        wr_lat    <= wr;
                        wdata_lat <= wdata;
                        wmask_lat <= wmask;
                        app_addr  <= {{(28-ADDR_WIDTH){1'b0}}, addr};
                        app_cmd   <= wr ? CMD_WRITE : CMD_READ;
                        app_en    <= 1'b1;
                        state     <= S_CMD_WAIT;
                    end
                end

                S_CMD_WAIT: begin
                    if (app_rdy) begin
                        app_en <= 1'b0;
                        if (wr_lat) begin
                            app_wdf_data <= wdata_lat[63:0];
                            app_wdf_mask <= wmask_lat[7:0];
                            app_wdf_end  <= 1'b0;
                            app_wdf_wren <= 1'b1;
                            state        <= S_WDF0;
                        end else begin
                            state <= S_RD_WAIT;
                        end
                    end
                end

                S_WDF0: begin
                    if (app_wdf_rdy) begin
                        app_wdf_data <= wdata_lat[127:64];
                        app_wdf_mask <= wmask_lat[15:8];
                        app_wdf_end  <= 1'b1;
                        app_wdf_wren <= 1'b1;
                        state        <= S_WDF1;
                    end
                end

                S_WDF1: begin
                    if (app_wdf_rdy) begin
                        app_wdf_wren <= 1'b0;
                        app_wdf_end  <= 1'b0;
                        state        <= S_DONE;
                    end
                end

                S_RD_WAIT: begin
                    if (app_rd_data_valid) begin
                        if (!app_rd_data_end) begin
                            rdata[63:0] <= app_rd_data;
                        end else begin
                            rdata[127:64] <= app_rd_data;
                            state         <= S_DONE;
                        end
                    end
                end

                S_DONE: begin
                    ready <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
