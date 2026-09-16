`timescale 1ns/1ps

// ============================================================
// NMS -- EXPERIMENTAL bank-interleaved-pipelining fork of
// sdram_controller.v, built to test whether the ~77-78% Bank-W
// busy-cycle ceiling EXP-0051 measured (see hardware/v2/logs/
// experiments.log) can be reduced by overlapping the NEXT
// transaction's ACTIVATE/tRCD with the CURRENT transaction's own
// tail (CAS latency + burst + auto-precharge), when the two target
// DIFFERENT internal SDRAM banks. Real SDR SDRAM banks are
// electrically independent -- a real chip supports this exact kind
// of overlap (issuing ACTIVATE to bank B while bank A is still mid-
// burst/mid-precharge), it is simply never exploited by the
// original, deliberately linear, one-transaction-at-a-time
// sdram_controller.v (STEP16's own explicit, documented scope
// boundary: "exactly one physical SDRAM transaction in flight at a
// time").
//
// TWO changes vs sdram_controller.v, both additive/isolated (every
// existing state/signal/behavior for the ORIGINAL usage pattern --
// one req, wait for ready, THEN issue the next -- is byte-for-byte
// unchanged):
//
// (1) Address->bank decomposition moved from the TOP bits (original:
//     addr_bank = addr[ADDR_WIDTH-1 -: BANK_BITS], meaning the
//     project's own compact, single-region weight/activation memory
//     map always lands on bank 0 -- confirmed by inspection, this is
//     WHY no interleaving opportunity could ever exist under the
//     original decomposition) to bits immediately ABOVE the fixed-
//     zero burst-alignment low bits: addr_bank = addr[ALIGN_BITS +:
//     BANK_BITS], where ALIGN_BITS = clog2(BURST_LEN). Since every
//     real caller always increments the word address by exactly
//     BURST_LEN between consecutive real transactions (see
//     sdram_unified_backend.v's own w_eff_aligned_word_addr/
//     ar_eff_block_base computation), this makes CONSECUTIVE real
//     transactions round-robin across all BANK_BITS**2 banks
//     automatically, with zero change needed at any caller. This is
//     a pure re-slicing of the SAME flat word-address bits into a
//     DIFFERENT (bank,row,col) triple -- still a bijection over the
//     full address space (each of the 2**ADDR_WIDTH addresses maps
//     to exactly one (bank,row,col) and vice versa), so read-after-
//     write correctness is unaffected; only the caller-visible flat
//     address <-> physical-location mapping changes, which is why
//     any INTEGRATION testbench built around this module must apply
//     the SAME decomposition in its own backdoor peek/poke helpers
//     (see tb_nms_dstress_sdram_pipelined.v's own header note) or
//     use sdram_model.v's own explicit backdoor_read/backdoor_write
//     tasks (bank/row/col-addressed, decomposition-agnostic) instead
//     of computing a flat array index by hand.
//
// (2) A single-depth "shadow" pipeline slot (pipe_valid/pipe_*_reg/
//     pipe_wait_cnt): while the CURRENT transaction is in S_CAS_WAIT,
//     S_BURST_READ, S_BURST_WRITE, or S_PRECHARGE_WAIT (i.e. its own
//     ACTIVATE has already been sent and the command bus is
//     otherwise idle -- confirmed by inspection: none of those four
//     states drive sdram_ras_n/sdram_ba/sdram_a), a NEW `req` for a
//     DIFFERENT bank than the current transaction's own req_bank_reg
//     is captured into the shadow slot AND its ACTIVATE command is
//     issued immediately (overlapping its own tRCD with whatever of
//     the current transaction's tail remains), instead of going
//     through the original req_pending latch (which would otherwise
//     wait for a full return to S_IDLE before even starting the
//     ACTIVATE). A `req` for the SAME bank as the current transaction
//     -- or arriving in any state OTHER than those four, or arriving
//     while the shadow slot is already occupied -- falls through to
//     the ORIGINAL, unmodified req_pending path, so that case behaves
//     EXACTLY as in sdram_controller.v (no regression, verified in
//     tb_sdram_controller_pipelined.v's own "same-bank" test).
//
//     REAL PROTOCOL CONSTRAINT respected: AUTO REFRESH requires EVERY
//     bank precharged first (a real JEDEC rule sdram_model.v itself
//     does NOT currently check/enforce -- confirmed by inspection, a
//     real, disclosed gap in that model, not exploited here). This
//     design avoids ever violating it by construction: S_IDLE's own
//     priority order checks `pipe_valid` BEFORE `refresh_timer==0` --
//     a still-open shadow bank is always promoted/closed (via its own
//     ordinary auto-precharge) before any refresh is allowed to fire,
//     so refresh can only ever run when EVERY bank (primary transaction,
//     always auto-precharged by construction -- A10=1 on every real
//     command, unchanged from the original design -- and any shadow
//     transaction) is already closed. The resulting refresh delay is
//     bounded by one shadow transaction's own worst-case duration
//     (~16 cycles at CLK_FREQ_MHZ=80/BURST_LEN=8), a small fraction of
//     T_REFI (~625 cycles at the same frequency) -- verified, not
//     assumed, by tb_sdram_controller_pipelined.v's own refresh-
//     during-interleaving test.
//
// THEORETICAL CEILING (derived here, confirmed by measurement in
// tb_sdram_controller_pipelined.v -- disclosed up front so the result
// isn't oversold): only tRCD can ever be hidden by this scheme, since
// the shared DQ bus means the NEXT transaction's own CAS/burst can
// never start before the CURRENT transaction's burst fully drains,
// regardless of banking. At CLK_FREQ_MHZ=80/BURST_LEN=8, tRCD is only
// ~2 of a real transaction's ~16 total cycles (the dominant cost,
// CAS_LATENCY+BURST_LEN=11 cycles/69%, is serial DATA transfer that
// NO command-level bank interleaving can shorten) -- so the best case
// for a long chain of alternating-bank transactions is each one AFTER
// the first costing ~14 instead of ~16 cycles, an asymptotic ~12.5%
// per-transaction ceiling, not a multiple-x speedup.
// ============================================================
module sdram_controller_pipelined #(
    parameter CLK_FREQ_MHZ = 64,
    parameter BURST_LEN    = 4,
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
    // unclamped log2 (0 for BURST_LEN=1), used ONLY for the bank-slice
    // position -- see header note (1).
    localparam ALIGN_BITS = $clog2(BURST_LEN);

    initial if (ADDR_WIDTH != BANK_BITS + ROW_BITS + COL_BITS) begin
        $display("FATAL sdram_controller_pipelined: ADDR_WIDTH=%0d != BANK_BITS(%0d)+ROW_BITS(%0d)+COL_BITS(%0d)=%0d",
            ADDR_WIDTH, BANK_BITS, ROW_BITS, COL_BITS, BANK_BITS+ROW_BITS+COL_BITS);
        $finish;
    end
    initial if (ALIGN_BITS + BANK_BITS > COL_BITS) begin
        $display("FATAL sdram_controller_pipelined: ALIGN_BITS(%0d)+BANK_BITS(%0d) > COL_BITS(%0d) -- bank slice does not fit below row field",
            ALIGN_BITS, BANK_BITS, COL_BITS);
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
    localparam T_INIT_US= 200;
    localparam T_INIT   = T_INIT_US * CLK_FREQ_MHZ;
    localparam CAS_LATENCY = 3;
    localparam T_REFI    = ns_to_cycles(64000000 / (1 << ROW_BITS) + 1);

    localparam CNTW = $clog2((T_INIT>T_REFI ? T_INIT : T_REFI) + 1);

    localparam
        S_INIT_WAIT      = 5'd0,
        S_INIT_PRE_WAIT  = 5'd2,
        S_INIT_REF       = 5'd3,
        S_INIT_REF_WAIT  = 5'd4,
        S_INIT_MRS_WAIT  = 5'd6,
        S_IDLE           = 5'd7,
        S_REFRESH_WAIT   = 5'd9,
        S_ACTIVATE_WAIT  = 5'd11,
        S_CAS_WAIT       = 5'd13,
        S_BURST_READ     = 5'd14,
        S_BURST_WRITE    = 5'd15,
        S_PRECHARGE_WAIT = 5'd16;

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

    // ---- (1) re-sliced address decomposition -- see header note ----
    wire [BANK_BITS-1:0] addr_bank = addr[ALIGN_BITS +: BANK_BITS];
    wire [COL_BITS-1:0]  addr_col  = (ALIGN_BITS == 0) ? addr[ALIGN_BITS+BANK_BITS +: COL_BITS]
                                    : {addr[ALIGN_BITS+BANK_BITS +: (COL_BITS-ALIGN_BITS)], addr[ALIGN_BITS-1:0]};
    wire [ROW_BITS-1:0]  addr_row  = addr[ADDR_WIDTH-1 -: ROW_BITS];

    // ---- (2) shadow pipeline slot ----
    reg                    pipe_valid;
    reg                    pipe_wr_reg;
    reg [BANK_BITS-1:0]    pipe_bank_reg;
    reg [ROW_BITS-1:0]     pipe_row_reg;
    reg [COL_BITS-1:0]     pipe_col_reg;
    reg [16*BURST_LEN-1:0] pipe_wdata_reg;
    reg [2*BURST_LEN-1:0]  pipe_wmask_reg;
    reg [CNTW-1:0]         pipe_wait_cnt;

    wire shadow_capturable_state = (state==S_CAS_WAIT) || (state==S_BURST_READ) ||
                                    (state==S_BURST_WRITE) || (state==S_PRECHARGE_WAIT);
    wire shadow_capture_now = req && shadow_capturable_state && !pipe_valid &&
                              (addr_bank != req_bank_reg);

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

    function [CNTW-1:0] T_RC_MINUS1;
        localparam integer T_RC = ns_to_cycles(65);
        begin
            T_RC_MINUS1 = T_RC[CNTW-1:0] - 1'b1;
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
            pipe_valid    <= 1'b0;
            pipe_wait_cnt <= {CNTW{1'b0}};
        end else begin
            sdram_cs_n  <= 1'b0;
            sdram_ras_n <= 1'b1;
            sdram_cas_n <= 1'b1;
            sdram_we_n  <= 1'b1;
            ready       <= 1'b0;
            dq_out_en   <= 1'b0;
            sdram_dqm   <= 2'b00;

            if (refresh_timer != 0) refresh_timer <= refresh_timer - 1'b1;
            // shadow's own tRCD countdown runs independently of `state`
            // (it tracks a DIFFERENT, already-open bank than whatever
            // the primary FSM below is doing) -- see header note (2).
            if (pipe_valid && pipe_wait_cnt != 0) pipe_wait_cnt <= pipe_wait_cnt - 1'b1;

            if (req) begin
                if (shadow_capture_now) begin
                    // capture into the shadow slot INSTEAD OF the
                    // original req_pending latch (so wdata_reg/
                    // wmask_reg/req_bank_reg etc, still owned by the
                    // CURRENTLY in-flight transaction, are never
                    // touched) -- and issue its real ACTIVATE command
                    // this very cycle (command bus is idle in every
                    // shadow_capturable_state, confirmed by inspection:
                    // none of those four states drive ras_n/ba/a).
                    pipe_wr_reg    <= wr;
                    pipe_bank_reg  <= addr_bank;
                    pipe_row_reg   <= addr_row;
                    pipe_col_reg   <= addr_col;
                    pipe_wdata_reg <= wdata;
                    pipe_wmask_reg <= wmask;
                    pipe_wait_cnt  <= T_RCD[CNTW-1:0] - 1'b1;
                    pipe_valid     <= 1'b1;
                    sdram_ras_n    <= 1'b0;
                    sdram_ba       <= addr_bank;
                    sdram_a        <= addr_row;
                end else begin
                    // ORIGINAL, unmodified path -- byte-for-byte
                    // identical to sdram_controller.v.
                    req_wr_reg   <= wr;
                    req_bank_reg <= addr_bank;
                    req_row_reg  <= addr_row;
                    req_col_reg  <= addr_col;
                    wdata_reg    <= wdata;
                    wmask_reg    <= wmask;
                    req_pending  <= 1'b1;
                end
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
                    else begin
                        state <= S_INIT_REF;
                    end
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
                    // Priority: (1) a still-open SHADOW bank must be
                    // promoted/closed before anything else -- see
                    // header note (2) on why this ordering is the
                    // thing that keeps AUTO REFRESH from ever firing
                    // with an open row. (2) periodic refresh, exactly
                    // as sdram_controller.v. (3) the original req/
                    // req_pending path, exactly as sdram_controller.v.
                    if (pipe_valid) begin
                        busy <= 1'b1;
                        req_wr_reg   <= pipe_wr_reg;
                        req_bank_reg <= pipe_bank_reg;
                        req_row_reg  <= pipe_row_reg;
                        req_col_reg  <= pipe_col_reg;
                        wdata_reg    <= pipe_wdata_reg;
                        wmask_reg    <= pipe_wmask_reg;
                        wait_cnt     <= pipe_wait_cnt; // remaining tRCD, may already be 0
                        pipe_valid   <= 1'b0;
                        state        <= S_ACTIVATE_WAIT;
                        // NOTE: ACTIVATE for this bank was ALREADY
                        // issued at shadow-capture time -- do not
                        // re-issue it here (ras_n stays at its default
                        // NOP drive this cycle).
                    end else if (refresh_timer == 0) begin
                        busy <= 1'b1;
                        sdram_ras_n <= 1'b0; sdram_cas_n <= 1'b0;
                        wait_cnt <= T_RC_MINUS1();
                        refresh_timer <= T_REFI[CNTW-1:0];
                        state <= S_REFRESH_WAIT;
                    end else if (req || req_pending) begin
                        busy <= 1'b1;
                        req_wr_reg   <= eff_wr;
                        req_bank_reg <= eff_bank;
                        req_row_reg  <= eff_row;
                        req_col_reg  <= eff_col;
                        wdata_reg    <= eff_wdata;
                        wmask_reg    <= eff_wmask;
                        req_pending  <= 1'b0;
                        sdram_ras_n <= 1'b0;
                        sdram_ba <= eff_bank;
                        sdram_a  <= eff_row;
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
                        sdram_a     <= {{(ROW_BITS-11){1'b0}}, 1'b1, {(10-COL_BITS){1'b0}}, req_col_reg};
                        burst_idx   <= {BURST_IDXW{1'b0}};
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
                            ready    <= 1'b1;
                            wait_cnt <= T_RP[CNTW-1:0] - 1'b1;
                            state    <= S_PRECHARGE_WAIT;
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
                        wait_cnt <= T_RP[CNTW-1:0] - 1'b1;
                        state <= S_PRECHARGE_WAIT;
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
                        wait_cnt <= T_RP[CNTW-1:0] + 1'b1;
                        state <= S_PRECHARGE_WAIT;
                    end
                end

                S_PRECHARGE_WAIT: begin
                    if (wait_cnt != 0) wait_cnt <= wait_cnt - 1'b1;
                    else state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
