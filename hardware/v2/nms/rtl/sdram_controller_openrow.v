`timescale 1ns/1ps

// ============================================================
// EXP-0054 -- open-row (page-hit) SDR SDRAM controller, forked from
// sdram_controller.v (STEP16). Implements the "page-hit/keep-row-open
// optimization" that sdram_controller.v's own header explicitly
// deferred:
//   "ALWAYS uses auto-precharge... NOT the fastest possible design
//   (no page-hit/keep-row-open optimization, unlike psram_
//   controller.v's own real page-mode), but it is trivially correct"
//
// MOTIVATION: weight_prefetch_engine_wide.v (real production traffic,
// instantiated by nms_dataflow_core_sdram.v, PREFETCH_DISTANCE=8)
// already issues a stream of STRICTLY SEQUENTIAL tile addresses per
// job. With ROW_BITS=13/COL_BITS=10 (AS4C32M16SA: 1024 columns/row,
// 4 words/tile at 16-bit words -- see sdram_controller.v's own TILE
// comment), a single row holds 256 consecutive tiles before crossing
// a row boundary -- most real jobs' weight streams never leave the
// row they started in. Closing and reopening that row on EVERY single
// tile (today's fixed auto-precharge policy) pays tRP+tRCD twice per
// transaction for no reason when the next transaction is going to hit
// the SAME row anyway.
//
// POLICY: never auto-precharge (A10=0 on every READ/WRITE). Track the
// single currently-open bank+row (this controller has always modeled
// "one transaction in flight" -- this experiment keeps that same
// single-open-row scope, not per-bank tracking across multiple
// simultaneously-open banks, matching the project's own established
// risk posture). On the NEXT request (evaluated in S_IDLE, exactly
// where every prior request was already evaluated):
//   - SAME bank+row as currently open ("row hit"): skip ACTIVATE
//     entirely -- issue READ/WRITE directly, saving tRCD.
//   - DIFFERENT bank+row while a row IS open ("row miss"): issue an
//     explicit PRECHARGE first (this controller no longer gets that
//     for free via auto-precharge), wait tRP, THEN activate the new
//     row exactly as before -- same total cost as today's design,
//     just paid on-demand instead of unconditionally after every
//     transaction.
//   - no row open (e.g. right after reset/refresh): activate directly,
//     unchanged from today.
//
// REFRESH INTERACTION (the one real correctness hazard this policy
// introduces, absent from the original always-precharged design):
// JEDEC AUTO REFRESH requires ALL banks precharged first. The
// original S_IDLE refresh branch's own comment ("no row is ever left
// open between transactions... so we can refresh immediately") is no
// longer true under this policy -- fixed here by precharging first
// (S_PRE_THEN_REF_WAIT) whenever row_open is set at the moment
// refresh comes due, before issuing AUTO REFRESH exactly as before.
//
// WRITE RECOVERY (tWR): the original design folded tWR into its
// always-paid post-burst precharge wait ("T_RP + 1'b1 // tWR folded
// in conservatively"). This design no longer precharges after every
// write, so tWR is now paid explicitly and alone (T_WR=2 CLK, real
// AS4C32M16SA datasheet value, same explicit-CLK-units treatment as
// T_MRD) via a new S_WRITE_RECOVERY_WAIT state, before the row-open
// path returns to S_IDLE and can accept a same-row follow-on command.
//
// DISCLOSED, NOT INDEPENDENTLY VERIFIED: read-burst-end -> next
// command (read-to-read or read-to-write, same open row) has NO extra
// wait beyond the existing 1-cycle-minimum S_IDLE turnaround, on the
// reasoning that JEDEC SDR SDRAM page-mode reads support back-to-back
// column access with no additional bubble. sdram_model.v (this
// project's own real-command-sequence checker) does NOT itself assert
// tCCD/tRTW/tWTR -- it only checks ACTIVATE-while-active, tRP, tRAS
// (min), refresh spacing, and access-with-no-active-row (see its own
// VIOLATION messages). tb_sdram_controller_openrow.v exercises
// read-after-read and write-after-read same-row sequences explicitly
// and checks DATA correctness, but a genuine read-to-write DQ bus
// turnaround hazard would not be caught by sdram_model.v itself if
// present -- flagged here exactly as this project's own convention
// requires, not silently assumed safe.
//
// Every timing constant, the mrs_value encoding, the req_pending
// unconditional-latch fix, and the address decomposition are carried
// over UNCHANGED from sdram_controller.v -- only the state machine's
// precharge policy and the two new wait states are new.
// ============================================================
module sdram_controller_openrow #(
    parameter CLK_FREQ_MHZ = 64,
    parameter BURST_LEN    = 4,   // 1, 4, or 8 -- same real scope as sdram_controller.v (see its own mrs_value)
    parameter ROW_BITS     = 13,
    parameter COL_BITS     = 10,
    parameter BANK_BITS    = 2,
    parameter ADDR_WIDTH   = BANK_BITS + ROW_BITS + COL_BITS
)(
    input  wire        clk,
    input  wire        rst,

    input  wire                    req,
    input  wire                    wr,
    input  wire [ADDR_WIDTH-1:0]   addr,
    input  wire [16*BURST_LEN-1:0] wdata,
    input  wire [2*BURST_LEN-1:0]  wmask,
    output reg  [16*BURST_LEN-1:0] rdata,
    output reg                     ready,
    output reg                     busy,

    output reg          sdram_cke,
    output reg          sdram_cs_n,
    output reg          sdram_ras_n,
    output reg          sdram_cas_n,
    output reg          sdram_we_n,
    output reg  [1:0]        sdram_ba,
    output reg  [ROW_BITS-1:0] sdram_a,
    inout  wire [15:0]  sdram_dq,
    output reg  [1:0]   sdram_dqm
);

    localparam BURST_IDXW = (BURST_LEN <= 1) ? 1 : $clog2(BURST_LEN);

    initial if (ADDR_WIDTH != BANK_BITS + ROW_BITS + COL_BITS) begin
        $display("FATAL sdram_controller_openrow: ADDR_WIDTH=%0d != BANK_BITS(%0d)+ROW_BITS(%0d)+COL_BITS(%0d)=%0d",
            ADDR_WIDTH, BANK_BITS, ROW_BITS, COL_BITS, BANK_BITS+ROW_BITS+COL_BITS);
        $finish;
    end

    function integer ns_to_cycles;
        input integer ns;
        begin
            ns_to_cycles = (ns * CLK_FREQ_MHZ + 999) / 1000;
        end
    endfunction
    localparam T_RCD    = ns_to_cycles(15);
    localparam T_RP     = ns_to_cycles(15);
    localparam T_MRD    = 2;
    localparam T_WR     = 2;   // real AS4C32M16SA datasheet value, explicit CLK units (same treatment as T_MRD)
    localparam T_INIT_US= 200;
    localparam T_INIT   = T_INIT_US * CLK_FREQ_MHZ;
    localparam CAS_LATENCY = 3;
    localparam T_REFI    = ns_to_cycles(64000000 / (1 << ROW_BITS) + 1);

    localparam CNTW = $clog2((T_INIT>T_REFI ? T_INIT : T_REFI) + 1);

    function [CNTW-1:0] T_RC_MINUS1;
        localparam integer T_RC = ns_to_cycles(65);
        begin
            T_RC_MINUS1 = T_RC[CNTW-1:0] - 1'b1;
        end
    endfunction

    localparam
        S_INIT_WAIT          = 5'd0,
        S_INIT_PRE_WAIT      = 5'd2,
        S_INIT_REF           = 5'd3,
        S_INIT_REF_WAIT      = 5'd4,
        S_INIT_MRS_WAIT      = 5'd6,
        S_IDLE               = 5'd7,
        S_REFRESH_WAIT       = 5'd9,
        S_ACTIVATE_WAIT      = 5'd11,
        S_CAS_WAIT           = 5'd13,
        S_BURST_READ         = 5'd14,
        S_BURST_WRITE        = 5'd15,
        S_PRE_THEN_ACT_WAIT  = 5'd17,
        S_PRE_THEN_REF_WAIT  = 5'd18,
        S_WRITE_RECOVERY_WAIT= 5'd19;

    reg [4:0] state;
    reg [CNTW-1:0] wait_cnt;
    reg [3:0] init_ref_cnt;
    reg [CNTW-1:0] refresh_timer;
    reg [BURST_IDXW-1:0] burst_idx;
    reg req_wr_reg;
    reg [BANK_BITS-1:0] req_bank_reg;
    reg [ROW_BITS-1:0]  req_row_reg;
    reg [COL_BITS-1:0]  req_col_reg;
    reg [16*BURST_LEN-1:0] wdata_reg;
    reg [2*BURST_LEN-1:0]  wmask_reg;

    // ---- open-row tracking (new vs sdram_controller.v) ----
    reg                  row_open;
    reg [BANK_BITS-1:0]  open_bank;
    reg [ROW_BITS-1:0]   open_row;

    wire [BANK_BITS-1:0] addr_bank = addr[ADDR_WIDTH-1 -: BANK_BITS];
    wire [ROW_BITS-1:0]  addr_row  = addr[ADDR_WIDTH-BANK_BITS-1 -: ROW_BITS];
    wire [COL_BITS-1:0]  addr_col  = addr[COL_BITS-1:0];

    reg         req_pending;
    wire               eff_wr   = req ? wr        : req_wr_reg;
    wire [BANK_BITS-1:0] eff_bank = req ? addr_bank : req_bank_reg;
    wire [ROW_BITS-1:0]  eff_row  = req ? addr_row  : req_row_reg;
    wire [COL_BITS-1:0]  eff_col  = req ? addr_col  : req_col_reg;
    wire [16*BURST_LEN-1:0] eff_wdata = req ? wdata : wdata_reg;
    wire [2*BURST_LEN-1:0]  eff_wmask = req ? wmask : wmask_reg;

    reg dq_out_en;
    reg [15:0] dq_out;
    assign sdram_dq = dq_out_en ? dq_out : 16'hzzzz;

    function [ROW_BITS-1:0] mrs_value;
        input integer burst_len;
        reg [2:0] bl_code;
        reg [ROW_BITS-1:0] v;
        begin
            bl_code = (burst_len==1) ? 3'b000 :
                      (burst_len==2) ? 3'b001 :
                      (burst_len==4) ? 3'b010 :
                      (burst_len==8) ? 3'b011 : 3'b111;
            v = {ROW_BITS{1'b0}};
            v[6:4] = 3'b011;
            v[3]   = 1'b0;
            v[2:0] = bl_code;
            mrs_value = v;
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            state         <= S_INIT_WAIT;
            wait_cnt      <= T_INIT[CNTW-1:0];
            init_ref_cnt  <= 4'd0;
            refresh_timer <= T_REFI[CNTW-1:0];
            sdram_cke     <= 1'b1;
            sdram_cs_n    <= 1'b1;
            sdram_ras_n   <= 1'b1;
            sdram_cas_n   <= 1'b1;
            sdram_we_n    <= 1'b1;
            sdram_ba      <= 2'b00;
            sdram_a       <= {ROW_BITS{1'b0}};
            sdram_dqm     <= 2'b00;
            dq_out_en     <= 1'b0;
            ready         <= 1'b0;
            busy          <= 1'b1;
            req_pending   <= 1'b0;
            row_open      <= 1'b0;
            open_bank     <= {BANK_BITS{1'b0}};
            open_row      <= {ROW_BITS{1'b0}};
        end else begin
            sdram_cs_n  <= 1'b0;
            sdram_ras_n <= 1'b1;
            sdram_cas_n <= 1'b1;
            sdram_we_n  <= 1'b1;
            ready       <= 1'b0;
            dq_out_en   <= 1'b0;
            sdram_dqm   <= 2'b00;

            if (refresh_timer != 0) refresh_timer <= refresh_timer - 1'b1;

            if (req) begin
                req_wr_reg   <= wr;
                req_bank_reg <= addr_bank;
                req_row_reg  <= addr_row;
                req_col_reg  <= addr_col;
                wdata_reg    <= wdata;
                wmask_reg    <= wmask;
                req_pending  <= 1'b1;
            end

            case (state)
                S_INIT_WAIT: begin
                    busy <= 1'b1;
                    if (wait_cnt != 0) wait_cnt <= wait_cnt - 1'b1;
                    else begin
                        sdram_ras_n <= 1'b0; sdram_we_n <= 1'b0;
                        sdram_a[10] <= 1'b1;
                        wait_cnt <= T_RP[CNTW-1:0] - 1'b1;
                        state <= S_INIT_PRE_WAIT;
                    end
                end
                S_INIT_PRE_WAIT: begin
                    if (wait_cnt != 0) wait_cnt <= wait_cnt - 1'b1;
                    else state <= S_INIT_REF;
                end
                S_INIT_REF: begin
                    sdram_ras_n <= 1'b0; sdram_cas_n <= 1'b0;
                    wait_cnt <= T_RC_MINUS1();
                    state <= S_INIT_REF_WAIT;
                end
                S_INIT_REF_WAIT: begin
                    if (wait_cnt != 0) wait_cnt <= wait_cnt - 1'b1;
                    else if (init_ref_cnt < 4'd7) begin
                        init_ref_cnt <= init_ref_cnt + 1'b1;
                        state <= S_INIT_REF;
                    end else begin
                        sdram_ras_n <= 1'b0; sdram_cas_n <= 1'b0; sdram_we_n <= 1'b0;
                        sdram_ba <= 2'b00;
                        sdram_a  <= mrs_value(BURST_LEN);
                        wait_cnt <= T_MRD[CNTW-1:0] - 1'b1;
                        state <= S_INIT_MRS_WAIT;
                    end
                end
                S_INIT_MRS_WAIT: begin
                    if (wait_cnt != 0) wait_cnt <= wait_cnt - 1'b1;
                    else begin
                        busy  <= 1'b0;
                        state <= S_IDLE;
                    end
                end

                S_IDLE: begin
                    busy <= 1'b0;
                    if (refresh_timer == 0) begin
                        busy <= 1'b1;
                        if (row_open) begin
                            // JEDEC: all banks must be precharged before
                            // AUTO REFRESH -- no longer free/automatic
                            // under the open-row policy (see header).
                            sdram_ras_n <= 1'b0; sdram_we_n <= 1'b0;
                            sdram_ba    <= open_bank;
                            sdram_a[10] <= 1'b1;
                            row_open    <= 1'b0;
                            wait_cnt    <= T_RP[CNTW-1:0] - 1'b1;
                            state       <= S_PRE_THEN_REF_WAIT;
                        end else begin
                            sdram_ras_n <= 1'b0; sdram_cas_n <= 1'b0;
                            wait_cnt <= T_RC_MINUS1();
                            refresh_timer <= T_REFI[CNTW-1:0];
                            state <= S_REFRESH_WAIT;
                        end
                    end else if (req || req_pending) begin
                        busy <= 1'b1;
                        req_wr_reg   <= eff_wr;
                        req_bank_reg <= eff_bank;
                        req_row_reg  <= eff_row;
                        req_col_reg  <= eff_col;
                        wdata_reg    <= eff_wdata;
                        wmask_reg    <= eff_wmask;
                        req_pending  <= 1'b0;

                        if (row_open && eff_bank == open_bank && eff_row == open_row) begin
                            // ROW HIT: skip ACTIVATE entirely, saves tRCD.
                            burst_idx   <= {BURST_IDXW{1'b0}};
                            sdram_cas_n <= 1'b0;
                            sdram_we_n  <= eff_wr ? 1'b0 : 1'b1;
                            sdram_ba    <= eff_bank;
                            sdram_a     <= {{(ROW_BITS-11){1'b0}}, 1'b0, {(10-COL_BITS){1'b0}}, eff_col}; // A10=0: no auto-precharge
                            if (eff_wr) begin
                                dq_out_en <= 1'b1;
                                dq_out    <= eff_wdata[15:0];
                                sdram_dqm <= eff_wmask[1:0];
                                state <= S_BURST_WRITE;
                            end else begin
                                wait_cnt <= CAS_LATENCY[CNTW-1:0];
                                state <= S_CAS_WAIT;
                            end
                        end else if (row_open) begin
                            // ROW MISS, a different row is open: precharge
                            // it first (paid on-demand, same total cost as
                            // today's unconditional auto-precharge, just
                            // deferred until actually needed).
                            sdram_ras_n <= 1'b0; sdram_we_n <= 1'b0;
                            sdram_ba    <= open_bank;
                            sdram_a[10] <= 1'b1;
                            row_open    <= 1'b0;
                            wait_cnt    <= T_RP[CNTW-1:0] - 1'b1;
                            state       <= S_PRE_THEN_ACT_WAIT;
                        end else begin
                            // no row open at all: activate directly.
                            sdram_ras_n <= 1'b0;
                            sdram_ba <= eff_bank;
                            sdram_a  <= eff_row;
                            wait_cnt <= T_RCD[CNTW-1:0] - 1'b1;
                            state <= S_ACTIVATE_WAIT;
                        end
                    end
                end

                S_PRE_THEN_REF_WAIT: begin
                    if (wait_cnt != 0) wait_cnt <= wait_cnt - 1'b1;
                    else begin
                        sdram_ras_n <= 1'b0; sdram_cas_n <= 1'b0;
                        wait_cnt <= T_RC_MINUS1();
                        refresh_timer <= T_REFI[CNTW-1:0];
                        state <= S_REFRESH_WAIT;
                    end
                end

                S_PRE_THEN_ACT_WAIT: begin
                    if (wait_cnt != 0) wait_cnt <= wait_cnt - 1'b1;
                    else begin
                        sdram_ras_n <= 1'b0;
                        sdram_ba <= req_bank_reg;
                        sdram_a  <= req_row_reg;
                        wait_cnt <= T_RCD[CNTW-1:0] - 1'b1;
                        state <= S_ACTIVATE_WAIT;
                    end
                end

                S_REFRESH_WAIT: begin
                    if (wait_cnt != 0) wait_cnt <= wait_cnt - 1'b1;
                    else state <= S_IDLE;
                end

                S_ACTIVATE_WAIT: begin
                    if (wait_cnt != 0) begin
                        wait_cnt <= wait_cnt - 1'b1;
                    end else begin
                        sdram_cas_n <= 1'b0;
                        sdram_we_n  <= req_wr_reg ? 1'b0 : 1'b1;
                        sdram_ba    <= req_bank_reg;
                        sdram_a     <= {{(ROW_BITS-11){1'b0}}, 1'b0, {(10-COL_BITS){1'b0}}, req_col_reg}; // A10=0
                        burst_idx   <= {BURST_IDXW{1'b0}};
                        row_open    <= 1'b1;
                        open_bank   <= req_bank_reg;
                        open_row    <= req_row_reg;
                        if (req_wr_reg) begin
                            dq_out_en <= 1'b1;
                            dq_out    <= wdata_reg[15:0];
                            sdram_dqm <= wmask_reg[1:0];
                            state <= S_BURST_WRITE;
                        end else begin
                            wait_cnt <= CAS_LATENCY[CNTW-1:0];
                            state <= S_CAS_WAIT;
                        end
                    end
                end

                S_CAS_WAIT: begin
                    if (wait_cnt != 0) begin
                        wait_cnt <= wait_cnt - 1'b1;
                    end else begin
                        rdata[0 +: 16] <= sdram_dq;
                        if (BURST_LEN == 1) begin
                            ready <= 1'b1;
                            state <= S_IDLE; // row stays open, no precharge
                        end else begin
                            burst_idx <= burst_idx + 1'b1;
                            state     <= S_BURST_READ;
                        end
                    end
                end

                S_BURST_READ: begin
                    rdata[burst_idx*16 +: 16] <= sdram_dq;
                    if (burst_idx == BURST_LEN[BURST_IDXW-1:0] - 1'b1) begin
                        ready <= 1'b1;
                        state <= S_IDLE; // row stays open, no precharge
                    end else begin
                        burst_idx <= burst_idx + 1'b1;
                    end
                end

                S_BURST_WRITE: begin
                    if (burst_idx < BURST_LEN[BURST_IDXW-1:0] - 1'b1) begin
                        burst_idx <= burst_idx + 1'b1;
                        dq_out_en <= 1'b1;
                        dq_out    <= wdata_reg[(burst_idx+1'b1)*16 +: 16];
                        sdram_dqm <= wmask_reg[(burst_idx+1'b1)*2 +: 2];
                    end else begin
                        ready <= 1'b1;
                        // tWR now paid alone (no longer folded with tRP,
                        // since we no longer precharge unconditionally --
                        // see header).
                        wait_cnt <= T_WR[CNTW-1:0] - 1'b1;
                        state <= S_WRITE_RECOVERY_WAIT;
                    end
                end

                S_WRITE_RECOVERY_WAIT: begin
                    if (wait_cnt != 0) wait_cnt <= wait_cnt - 1'b1;
                    else state <= S_IDLE; // row stays open, no precharge
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
