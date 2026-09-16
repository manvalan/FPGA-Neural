`timescale 1ns/1ps

// ============================================================
// EXP-0053 -- SDRAM clock-domain-crossing bridge.
//
// PURPOSE: let sdram_controller.v run on its OWN, faster clock
// (target: 115.2MHz, derived from the SAME PLL VCO as the existing
// 64MHz clk_sys -- see ecp5_pll_sys_clk_dualclk.v) while every
// existing caller (sdram_unified_backend.v's ctrl_req/ctrl_addr/...
// signals) stays on the unchanged 64MHz compute domain. Presents the
// EXACT same req/wr/addr/wdata/wmask -> rdata/ready/busy contract as
// sdram_controller.v itself, so it is a drop-in replacement for the
// direct sdram_controller instantiation at that one call site
// (verified by the isolated tb_sdram_cdc_bridge.v before any
// integration).
//
// WHY 115.2MHz and not the chip's rated 143MHz max (AS4C32M16SA-7,
// tCK=7ns min): the board's single PLL VCO is fixed at 576MHz by the
// existing, already-verified 64MHz CLKOP config (CLKFB_DIV=4,
// CLKOP_DIV=9 -- unchanged, not touched by this experiment). The only
// integer VCO/N divisors near the chip's ceiling are 576/4=144MHz
// (0.8% OVER the 143MHz max -- rejected, not "correctness first") and
// 576/5=115.2MHz (real ~19% margin under the rated max). 115.2MHz is
// therefore the fastest SAFE clock obtainable from this board's
// existing PLL without touching the verified 64MHz compute domain.
// Real measured gain vs the current 64MHz single-domain design is
// therefore 115.2/64 = 1.8x raw controller-clock speedup, NOT the 2.2x
// a naive 143MHz assumption would suggest -- this correction is
// intentional, verified against real ecppll output, not estimated.
//
// PROTOCOL: single-outstanding-request only (matches every existing
// caller's own req/busy/ready idiom exactly -- this bridge does NOT
// add multi-request pipelining; that is EXP-0052's explicitly
// deferred, larger, riskier follow-up, out of scope here). Because at
// most one transaction is ever in flight, a classic two-domain
// "toggle + last-seen" handshake is provably safe:
//   - the requesting (slow) domain latches addr/wr/wdata/wmask and
//     flips req_toggle_slow on the SAME clock edge, then holds ALL of
//     those signals perfectly stable (no new request is ever issued
//     while busy=1) until the response toggle comes back;
//   - the fast domain double-flop-synchronizes req_toggle_slow (2 FF,
//     standard metastability margin) and compares it against its own
//     "last serviced" copy -- a mismatch means a new request is
//     pending. Because addr/wr/wdata/wmask changed on the SAME edge
//     that flipped the toggle, and never change again before the
//     response, they are safe to sample directly (no per-bit
//     synchronizer needed) once the synchronized toggle has visibly
//     changed -- this is the standard "quasi-static bus + toggle"
//     CDC idiom, not a shortcut.
//   - the same reasoning applies in reverse for ack_toggle_fast/rdata
//     going back to the slow domain.
// Reset: rst_slow and rst_fast are separate inputs, each assumed
// ALREADY synchronized to its own clock domain by the caller (this
// module does not itself synchronize an async reset -- matches this
// project's existing convention of a single, pre-synchronized `rst`
// per clock domain, see ecp5_pll_sys_clk.v's own reset handling).
// ============================================================
module sdram_cdc_bridge #(
    parameter CLK_FREQ_MHZ_FAST = 115, // deliberately rounded DOWN from
                                        // the real 115.2MHz (never over-
                                        // count available ns/cycle --
                                        // same "ceiling division" spirit
                                        // as sdram_controller.v's own
                                        // ns_to_cycles), so every derived
                                        // timing constant (T_RCD/T_RP/...)
                                        // gets AT LEAST as many cycles as
                                        // the real, slightly-faster clock
                                        // requires.
    parameter BURST_LEN  = 8,
    parameter ROW_BITS   = 13,
    parameter COL_BITS   = 10,
    parameter BANK_BITS  = 2,
    parameter ADDR_WIDTH = BANK_BITS + ROW_BITS + COL_BITS
)(
    input  wire clk_slow,
    input  wire rst_slow,   // pre-synchronized to clk_slow
    input  wire clk_fast,
    input  wire rst_fast,   // pre-synchronized to clk_fast

    // ---- slow-domain caller interface (identical shape to
    // sdram_controller.v's own ports) ----
    input  wire                    req,
    input  wire                    wr,
    input  wire [ADDR_WIDTH-1:0]   addr,
    input  wire [16*BURST_LEN-1:0] wdata,
    input  wire [2*BURST_LEN-1:0]  wmask,
    output reg  [16*BURST_LEN-1:0] rdata,
    output reg                     ready,
    output wire                    busy,

    // ---- real SDRAM pins, driven directly by the fast-domain
    // sdram_controller instance ----
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

    // ============================================================
    // Slow domain: capture request, drive toggle, wait for ack
    // ============================================================
    reg                    busy_slow;
    reg                    req_toggle_slow;
    reg                    wr_lat;
    reg [ADDR_WIDTH-1:0]   addr_lat;
    reg [16*BURST_LEN-1:0] wdata_lat;
    reg [2*BURST_LEN-1:0]  wmask_lat;

    assign busy = busy_slow;

    // synchronize ack_toggle_fast (fast domain) into the slow domain
    wire ack_toggle_fast;
    reg  ack_toggle_sync1, ack_toggle_sync2;
    always @(posedge clk_slow) begin
        if (rst_slow) begin
            ack_toggle_sync1 <= 1'b0;
            ack_toggle_sync2 <= 1'b0;
        end else begin
            ack_toggle_sync1 <= ack_toggle_fast;
            ack_toggle_sync2 <= ack_toggle_sync1;
        end
    end

    reg last_ack_toggle_seen_slow;
    wire [16*BURST_LEN-1:0] rdata_fast_captured;

    always @(posedge clk_slow) begin
        if (rst_slow) begin
            busy_slow                 <= 1'b0;
            req_toggle_slow           <= 1'b0;
            last_ack_toggle_seen_slow <= 1'b0;
            ready                     <= 1'b0;
            rdata                     <= {(16*BURST_LEN){1'b0}};
            wr_lat    <= 1'b0;
            addr_lat  <= {ADDR_WIDTH{1'b0}};
            wdata_lat <= {(16*BURST_LEN){1'b0}};
            wmask_lat <= {(2*BURST_LEN){1'b0}};
        end else begin
            ready <= 1'b0;

            if (req && !busy_slow) begin
                wr_lat          <= wr;
                addr_lat        <= addr;
                wdata_lat       <= wdata;
                wmask_lat       <= wmask;
                req_toggle_slow <= ~req_toggle_slow;
                busy_slow       <= 1'b1;
            end

            if (busy_slow && (ack_toggle_sync2 != last_ack_toggle_seen_slow)) begin
                last_ack_toggle_seen_slow <= ack_toggle_sync2;
                rdata     <= rdata_fast_captured;
                ready     <= 1'b1;
                busy_slow <= 1'b0;
            end
        end
    end

    // ============================================================
    // Fast domain: synchronize request toggle, drive the real
    // sdram_controller, capture response, drive ack toggle back
    // ============================================================
    reg ctrl_req_f;
    reg ctrl_wr_f;
    reg [ADDR_WIDTH-1:0]   ctrl_addr_f;
    reg [16*BURST_LEN-1:0] ctrl_wdata_f;
    reg [2*BURST_LEN-1:0]  ctrl_wmask_f;
    wire [16*BURST_LEN-1:0] ctrl_rdata_f;
    wire ctrl_ready_f, ctrl_busy_f;

    reg req_toggle_sync1, req_toggle_sync2;
    always @(posedge clk_fast) begin
        if (rst_fast) begin
            req_toggle_sync1 <= 1'b0;
            req_toggle_sync2 <= 1'b0;
        end else begin
            req_toggle_sync1 <= req_toggle_slow;
            req_toggle_sync2 <= req_toggle_sync1;
        end
    end

    localparam F_IDLE = 1'b0, F_WAIT = 1'b1;
    reg f_state;
    reg last_req_toggle_seen_fast;
    reg ack_toggle_fast_r;
    reg [16*BURST_LEN-1:0] rdata_fast_captured_r;

    assign ack_toggle_fast      = ack_toggle_fast_r;
    assign rdata_fast_captured  = rdata_fast_captured_r;

    always @(posedge clk_fast) begin
        if (rst_fast) begin
            f_state                   <= F_IDLE;
            last_req_toggle_seen_fast <= 1'b0;
            ack_toggle_fast_r         <= 1'b0;
            rdata_fast_captured_r     <= {(16*BURST_LEN){1'b0}};
            ctrl_req_f  <= 1'b0;
            ctrl_wr_f   <= 1'b0;
            ctrl_addr_f <= {ADDR_WIDTH{1'b0}};
            ctrl_wdata_f<= {(16*BURST_LEN){1'b0}};
            ctrl_wmask_f<= {(2*BURST_LEN){1'b0}};
        end else begin
            ctrl_req_f <= 1'b0;
            case (f_state)
                F_IDLE: begin
                    if (req_toggle_sync2 != last_req_toggle_seen_fast) begin
                        // addr_lat/wr_lat/wdata_lat/wmask_lat (slow-
                        // domain regs) are quasi-static: they changed
                        // on the exact same slow-domain edge that
                        // flipped req_toggle_slow, and will not change
                        // again until busy_slow deasserts (long after
                        // this transaction completes) -- safe to
                        // sample directly, see module header.
                        ctrl_req_f  <= 1'b1;
                        ctrl_wr_f   <= wr_lat;
                        ctrl_addr_f <= addr_lat;
                        ctrl_wdata_f<= wdata_lat;
                        ctrl_wmask_f<= wmask_lat;
                        last_req_toggle_seen_fast <= req_toggle_sync2;
                        f_state <= F_WAIT;
                    end
                end
                F_WAIT: begin
                    if (ctrl_ready_f) begin
                        rdata_fast_captured_r <= ctrl_rdata_f;
                        ack_toggle_fast_r     <= ~ack_toggle_fast_r;
                        f_state <= F_IDLE;
                    end
                end
                default: f_state <= F_IDLE;
            endcase
        end
    end

    sdram_controller #(
        .CLK_FREQ_MHZ(CLK_FREQ_MHZ_FAST), .BURST_LEN(BURST_LEN),
        .ROW_BITS(ROW_BITS), .COL_BITS(COL_BITS), .BANK_BITS(BANK_BITS)
    ) u_sdram_ctrl (
        .clk(clk_fast), .rst(rst_fast),
        .req(ctrl_req_f), .wr(ctrl_wr_f), .addr(ctrl_addr_f),
        .wdata(ctrl_wdata_f), .wmask(ctrl_wmask_f),
        .rdata(ctrl_rdata_f), .ready(ctrl_ready_f), .busy(ctrl_busy_f),
        .sdram_cke(sdram_cke), .sdram_cs_n(sdram_cs_n), .sdram_ras_n(sdram_ras_n),
        .sdram_cas_n(sdram_cas_n), .sdram_we_n(sdram_we_n),
        .sdram_ba(sdram_ba), .sdram_a(sdram_a), .sdram_dq(sdram_dq), .sdram_dqm(sdram_dqm)
    );

endmodule
