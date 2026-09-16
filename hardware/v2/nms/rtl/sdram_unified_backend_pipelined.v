`timescale 1ns/1ps

// ============================================================
// EXPERIMENTAL fork of sdram_unified_backend.v -- the ONLY change is
// instantiating sdram_controller_pipelined.v instead of sdram_
// controller.v. W-port cache, arbitration, and the W/AR top-level FSM
// are ALL byte-for-byte unchanged. See sdram_controller_pipelined.v's
// own header for what changed at the controller level and why, and
// hardware/v2/logs/experiments.log (search "pipelin") for why this
// fork exists: testing whether bank-interleaved command pipelining
// recovers any of the ~77-78% Bank-W busy ceiling EXP-0051 measured.
// ============================================================
module sdram_unified_backend_pipelined #(
    parameter ADDR_WIDTH   = 26,
    parameter CLK_FREQ_MHZ = 64,
    parameter W_ENTRIES    = 4,
    parameter ROW_BITS     = 13,
    parameter COL_BITS     = 10,
    parameter BANK_BITS    = 2
)(
    input  wire clk,
    input  wire rst,

    input  wire                   w_req,
    input  wire [ADDR_WIDTH-1:0]  w_addr,
    output reg  [63:0]            w_rdata,
    output reg                    w_ready,

    input  wire                   ar_req,
    input  wire                   ar_wr,
    input  wire [ADDR_WIDTH-1:0]  ar_addr,
    input  wire [15:0]            ar_wdata,
    input  wire                   ar_lb_n,
    input  wire                   ar_ub_n,
    output reg  [15:0]            ar_rdata,
    output reg                    ar_ready,

    output wire        sdram_cke,
    output wire        sdram_cs_n,
    output wire        sdram_ras_n,
    output wire        sdram_cas_n,
    output wire        sdram_we_n,
    output wire [BANK_BITS-1:0] sdram_ba,
    output wire [ROW_BITS-1:0]  sdram_a,
    inout  wire [15:0] sdram_dq,
    output wire [1:0]  sdram_dqm
);

    initial if (ADDR_WIDTH != BANK_BITS + ROW_BITS + COL_BITS + 1) begin
        $display("FATAL sdram_unified_backend_pipelined: ADDR_WIDTH(%0d) != BANK_BITS(%0d)+ROW_BITS(%0d)+COL_BITS(%0d)+1",
            ADDR_WIDTH, BANK_BITS, ROW_BITS, COL_BITS);
        $finish;
    end

    localparam WEIDXW = (W_ENTRIES <= 1) ? 1 : $clog2(W_ENTRIES);
    reg                  w_cache_valid [0:W_ENTRIES-1];
    reg [ADDR_WIDTH-1:0] w_cache_addr  [0:W_ENTRIES-1];
    reg [63:0]           w_cache_data  [0:W_ENTRIES-1];
    reg [WEIDXW-1:0]     w_alloc_ptr;

    wire [W_ENTRIES-1:0] w_match_oh;
    genvar wgi;
    generate
        for (wgi = 0; wgi < W_ENTRIES; wgi = wgi + 1) begin : GEN_WMATCH
            assign w_match_oh[wgi] = w_cache_valid[wgi] && (w_cache_addr[wgi] == w_addr);
        end
    endgenerate

    reg               w_hit_found_c;
    reg [WEIDXW-1:0]  w_hit_idx_c;
    integer ei;
    generate
        if (W_ENTRIES == 4) begin : GEN_WHIT_FLAT
            always @(*) begin
                w_hit_found_c = |w_match_oh;
                casez (w_match_oh)
                    4'b1???: w_hit_idx_c = 2'd3;
                    4'b01??: w_hit_idx_c = 2'd2;
                    4'b001?: w_hit_idx_c = 2'd1;
                    4'b0001: w_hit_idx_c = 2'd0;
                    default: w_hit_idx_c = {WEIDXW{1'b0}};
                endcase
            end
        end else begin : GEN_WHIT_FALLBACK
            always @(*) begin
                w_hit_found_c = 1'b0;
                w_hit_idx_c   = {WEIDXW{1'b0}};
                for (ei = 0; ei < W_ENTRIES; ei = ei + 1) begin
                    if (w_cache_valid[ei] && w_cache_addr[ei] == w_addr) begin
                        w_hit_found_c = 1'b1;
                        w_hit_idx_c   = ei[WEIDXW-1:0];
                    end
                end
            end
        end
    endgenerate
    wire w_cache_hit = w_hit_found_c && w_req;

    reg          ctrl_req;
    reg          ctrl_wr;
    reg  [ADDR_WIDTH-2:0]  ctrl_addr;
    reg  [127:0] ctrl_wdata;
    reg  [15:0]  ctrl_wmask;
    wire [127:0] ctrl_rdata;
    wire         ctrl_ready;
    wire         ctrl_busy;

    sdram_controller_pipelined #(
        .CLK_FREQ_MHZ(CLK_FREQ_MHZ), .BURST_LEN(8),
        .ROW_BITS(ROW_BITS), .COL_BITS(COL_BITS), .BANK_BITS(BANK_BITS)
    ) u_sdram_ctrl (
        .clk(clk), .rst(rst),
        .req(ctrl_req), .wr(ctrl_wr), .addr(ctrl_addr),
        .wdata(ctrl_wdata), .wmask(ctrl_wmask),
        .rdata(ctrl_rdata), .ready(ctrl_ready), .busy(ctrl_busy),
        .sdram_cke(sdram_cke), .sdram_cs_n(sdram_cs_n), .sdram_ras_n(sdram_ras_n),
        .sdram_cas_n(sdram_cas_n), .sdram_we_n(sdram_we_n),
        .sdram_ba(sdram_ba), .sdram_a(sdram_a), .sdram_dq(sdram_dq), .sdram_dqm(sdram_dqm)
    );

    localparam S_IDLE      = 3'd0,
               S_W_WAIT     = 3'd1,
               S_AR_RD_WAIT = 3'd2,
               S_AR_WR_WAIT = 3'd3;
    reg [2:0] state;
    reg       w_pending_upper_half;
    reg [ADDR_WIDTH-1:0] w_pending_addr;
    reg [2:0] ar_pending_word;

    reg                   w_req_pending;
    reg [ADDR_WIDTH-1:0]  w_req_addr_lat;
    reg                   ar_req_pending;
    reg                   ar_req_wr_lat;
    reg [ADDR_WIDTH-1:0]  ar_req_addr_lat;
    reg [15:0]            ar_req_wdata_lat;
    reg                   ar_req_lbn_lat, ar_req_ubn_lat;

    wire                  w_eff_req  = w_req || w_req_pending;
    wire [ADDR_WIDTH-1:0] w_eff_addr = w_req ? w_addr : w_req_addr_lat;
    wire                  ar_eff_req  = ar_req || ar_req_pending;
    wire                  ar_eff_wr   = ar_req ? ar_wr    : ar_req_wr_lat;
    wire [ADDR_WIDTH-1:0] ar_eff_addr = ar_req ? ar_addr  : ar_req_addr_lat;
    wire [15:0]           ar_eff_wdata= ar_req ? ar_wdata : ar_req_wdata_lat;
    wire                  ar_eff_lbn  = ar_req ? ar_lb_n  : ar_req_lbn_lat;
    wire                  ar_eff_ubn  = ar_req ? ar_ub_n  : ar_req_ubn_lat;

    wire [ADDR_WIDTH-2:0] w_eff_aligned_word_addr  = {w_eff_addr[ADDR_WIDTH-1:4], 3'b000};
    wire        w_eff_addr_is_upper_half = w_eff_addr[3];
    wire [ADDR_WIDTH-2:0] ar_eff_block_base   = {ar_eff_addr[ADDR_WIDTH-2:3], 3'b000};
    wire [2:0]  ar_eff_word_in_blk  = ar_eff_addr[2:0];

    integer ri;
    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            for (ri = 0; ri < W_ENTRIES; ri = ri + 1) w_cache_valid[ri] <= 1'b0;
            w_alloc_ptr <= {WEIDXW{1'b0}};
            ctrl_req <= 1'b0; ctrl_wr <= 1'b0; ctrl_addr <= {(ADDR_WIDTH-1){1'b0}};
            ctrl_wdata <= 128'h0; ctrl_wmask <= 16'hFFFF;
            w_ready <= 1'b0; w_rdata <= 64'h0;
            ar_ready <= 1'b0; ar_rdata <= 16'h0;
            w_pending_upper_half <= 1'b0; w_pending_addr <= {ADDR_WIDTH{1'b0}};
            ar_pending_word <= 3'h0;
            w_req_pending <= 1'b0; w_req_addr_lat <= {ADDR_WIDTH{1'b0}};
            ar_req_pending <= 1'b0; ar_req_wr_lat <= 1'b0;
            ar_req_addr_lat <= {ADDR_WIDTH{1'b0}}; ar_req_wdata_lat <= 16'h0;
            ar_req_lbn_lat <= 1'b1; ar_req_ubn_lat <= 1'b1;
        end else begin
            ctrl_req  <= 1'b0;
            w_ready   <= 1'b0;
            ar_ready  <= 1'b0;

            if (w_req) begin
                w_req_addr_lat <= w_addr;
                w_req_pending  <= 1'b1;
            end
            if (ar_req) begin
                ar_req_wr_lat    <= ar_wr;
                ar_req_addr_lat  <= ar_addr;
                ar_req_wdata_lat <= ar_wdata;
                ar_req_lbn_lat   <= ar_lb_n;
                ar_req_ubn_lat   <= ar_ub_n;
                ar_req_pending   <= 1'b1;
            end

            case (state)
                S_IDLE: begin
                    if (w_cache_hit) begin
                        w_rdata              <= w_cache_data[w_hit_idx_c];
                        w_ready               <= 1'b1;
                        w_cache_valid[w_hit_idx_c] <= 1'b0;
                        w_req_pending         <= 1'b0;
                    end else if (w_eff_req) begin
                        ctrl_req  <= 1'b1;
                        ctrl_wr   <= 1'b0;
                        ctrl_addr <= w_eff_aligned_word_addr;
                        ctrl_wmask <= 16'h0000;
                        w_pending_upper_half <= w_eff_addr_is_upper_half;
                        w_pending_addr       <= w_eff_addr;
                        w_req_pending        <= 1'b0;
                        state <= S_W_WAIT;
                    end else if (ar_eff_req && !ar_eff_wr) begin
                        ctrl_req  <= 1'b1;
                        ctrl_wr   <= 1'b0;
                        ctrl_addr <= ar_eff_block_base;
                        ctrl_wmask <= 16'h0000;
                        ar_pending_word <= ar_eff_word_in_blk;
                        ar_req_pending  <= 1'b0;
                        state <= S_AR_RD_WAIT;
                    end else if (ar_eff_req && ar_eff_wr) begin
                        ctrl_req  <= 1'b1;
                        ctrl_wr   <= 1'b1;
                        ctrl_addr <= ar_eff_block_base;
                        ctrl_wdata <= {8{ar_eff_wdata}};
                        ctrl_wmask <= {16{1'b1}} & ~(16'h0003 << (ar_eff_word_in_blk*2)) | ({14'b0, ar_eff_ubn, ar_eff_lbn} << (ar_eff_word_in_blk*2));
                        ar_req_pending <= 1'b0;
                        state <= S_AR_WR_WAIT;
                    end
                end
                S_W_WAIT: begin
                    if (ctrl_ready) begin
                        if (w_pending_upper_half) begin
                            w_rdata <= ctrl_rdata[127:64];
                            w_cache_data[w_alloc_ptr] <= ctrl_rdata[63:0];
                            w_cache_addr[w_alloc_ptr] <= w_pending_addr - {{(ADDR_WIDTH-4){1'b0}}, 4'd8};
                        end else begin
                            w_rdata <= ctrl_rdata[63:0];
                            w_cache_data[w_alloc_ptr] <= ctrl_rdata[127:64];
                            w_cache_addr[w_alloc_ptr] <= w_pending_addr + {{(ADDR_WIDTH-4){1'b0}}, 4'd8};
                        end
                        w_cache_valid[w_alloc_ptr] <= 1'b1;
                        w_alloc_ptr <= (w_alloc_ptr == W_ENTRIES[WEIDXW-1:0]-1'b1) ? {WEIDXW{1'b0}} : w_alloc_ptr + 1'b1;
                        w_ready <= 1'b1;
                        state   <= S_IDLE;
                    end
                end
                S_AR_RD_WAIT: begin
                    if (ctrl_ready) begin
                        ar_rdata <= ctrl_rdata[ar_pending_word*16 +: 16];
                        ar_ready <= 1'b1;
                        state    <= S_IDLE;
                    end
                end
                S_AR_WR_WAIT: begin
                    if (ctrl_ready) begin
                        ar_ready <= 1'b1;
                        state    <= S_IDLE;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
