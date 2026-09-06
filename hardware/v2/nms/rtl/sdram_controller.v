`timescale 1ns/1ps

// ============================================================
// NMS STEP16 -- minimal, CORRECT-FIRST SDR SDRAM controller.
//
// MEMORY UPGRADE (post-PRE-PCB-FREEZE capacity/throughput review):
// retargeted from Alliance Memory AS4C4M16SA-6TIN (64Mbit/8MB) to
// Alliance Memory AS4C32M16SA-7TIN (512Mbit/64MB, x16, -7 speed
// grade: tCK=7ns/143MHz max, CAS latency 2 or 3), the largest
// same-family, same-package (54-pin TSOP-II, 3.3V) SDR SDRAM
// Alliance Memory offers. Confirmed via the real manufacturer
// datasheet (Alliance Memory AS4C32M16SA Rev 2.0): organization is
// 4 banks x 8192 rows x 1024 columns x16 bits (row address A0-A12,
// 13 bits; column address A0-A9, 10 bits; bank BA0/BA1, 2 bits) --
// ROW_BITS/COL_BITS/BANK_BITS below are now real parameters (not
// hardcoded 12/8/2) so this same RTL supports either device by
// parameter alone. Real -7-grade AC timing (all well inside this
// design's 64-100MHz target, itself far below the part's own
// 143MHz max): tRCD=15ns min, tRP=15ns min, tRAS=45ns min/100000ns
// max, tRC=65ns min, tMRD=2 CLK (fixed, explicitly stated in CLK
// units by this datasheet -- no unit ambiguity, unlike the smaller
// AS4C4M16SA's own datasheet that triggered ERR-0026), tWR=2 CLK
// (also explicitly CLK units), tREFI=64ms/8192 rows=7.8125us (HALF
// the previous part's 15.625us, since this part has 2x the rows to
// refresh in the same 64ms window -- a real, meaningful difference,
// not a rounding artifact).
//
// Design priority explicitly stated by the governing spec:
// correctness > performance > elegance. This controller therefore:
//   - ALWAYS uses auto-precharge (A10=1 on every READ/WRITE) --
//     every transaction activates a row, bursts BURST_LEN words, and
//     closes the row again before the next transaction. This is NOT
//     the fastest possible design (no page-hit/keep-row-open
//     optimization, unlike psram_controller.v's own real page-mode),
//     but it is trivially correct: no per-row state to track, no
//     risk of a stale-open-row bug, exactly one code path for every
//     transaction regardless of address history.
//   - Real JEDEC SDR SDRAM command encoding (CS#/RAS#/CAS#/WE#),
//     real power-up sequence (200us wait, PRECHARGE ALL, 8x AUTO
//     REFRESH, LOAD MODE REGISTER), real periodic AUTO REFRESH
//     insertion between transactions (tREFI = rows / 64ms, ROW_BITS-
//     dependent -- see T_REFI below).
//   - Real, standard SDR SDRAM timing (datasheet-standard values,
//     not vendor-specific tuning), re-derived per CLK_FREQ_MHZ so the
//     same RTL is reused across every tested frequency (STEP16's own
//     explicit "measure, do not estimate" requirement).
//
// Address format: word address (16-bit words), decomposed as
// {bank[BANK_BITS-1:0], row[ROW_BITS-1:0], col[COL_BITS-1:0]} --
// default ROW_BITS=13/COL_BITS=10/BANK_BITS=2 matches the REAL
// AS4C32M16SA's own 4-bank x 8192-row x 1024-column x16 organization
// (4*8192*1024 = 32M words = 64MB, confirmed against the real
// datasheet capacity).
//
// External protocol matches this project's own established
// mem_req/mem_wr/mem_addr/mem_wdata/mem_rdata/mem_ready convention
// (same idiom as psram_controller.v), generalized to a BURST: one
// req initiates a full BURST_LEN-word transaction (the natural unit
// for this workload -- one weight TILE = P_IN*DATA_WIDTH/16 = 4
// words at BURST_LEN=4, an exact match, not a coincidence chosen
// after the fact -- STEP16 Phase 1 identified this exact byte count
// per tile before any RTL was written).
// ============================================================
module sdram_controller #(
    parameter CLK_FREQ_MHZ = 64,
    parameter BURST_LEN    = 4,   // 1, 4, or 8 -- Phase 4 sweep parameter
    parameter ROW_BITS     = 13,  // AS4C32M16SA: row address A0-A12
    parameter COL_BITS     = 10,  // AS4C32M16SA: column address A0-A9
    parameter BANK_BITS    = 2,   // BA0,BA1 -- fixed across this whole Alliance SDR family
    // word address width; default derived from ROW_BITS/COL_BITS/
    // BANK_BITS above -- if overridden independently, must still equal
    // BANK_BITS+ROW_BITS+COL_BITS (asserted at elaboration below)
    parameter ADDR_WIDTH   = BANK_BITS + ROW_BITS + COL_BITS
)(
    input  wire        clk,
    input  wire        rst,

    input  wire                    req,
    input  wire                    wr,
    input  wire [ADDR_WIDTH-1:0]   addr,       // burst-aligned word address
    input  wire [16*BURST_LEN-1:0] wdata,      // BURST_LEN words, word0 first
    // STEP19: per-burst-word DQM write mask, 2 bits/word (bit0=low
    // byte, bit1=high byte, real SDR SDRAM DQM polarity: 1=masked/
    // NOT written, memory array retains its old value for that byte;
    // 0=written). Ties to {2*BURST_LEN{1'b0}} (never mask, i.e.
    // "always write full word") reproduces this module's own STEP16
    // behavior exactly -- every existing caller (sdram_weight_
    // backend.v, sdram_weight_backend_pack128.v, tb_sdram_controller.v)
    // was updated to pass that literal tie-off, so read/weight-fetch
    // behavior is byte-for-byte unchanged. Only meaningful for `wr`
    // transactions; ignored for reads (dqm is forced 0 during reads
    // regardless, since real SDR SDRAM masks READ OUTPUT with DQM too,
    // and this controller always wants valid read data back).
    input  wire [2*BURST_LEN-1:0]  wmask,
    output reg  [16*BURST_LEN-1:0] rdata,      // valid the same cycle `ready` pulses
    output reg                     ready,      // pulses once, whole burst transaction done
    output reg                     busy,

    // ---- real SDRAM physical pins ----
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

    // elaboration-time consistency check: ADDR_WIDTH must always equal
    // the sum of its own row/col/bank widths, whether left at its
    // derived default or overridden explicitly -- catches a mismatched
    // override immediately rather than silently mis-decoding addresses.
    initial if (ADDR_WIDTH != BANK_BITS + ROW_BITS + COL_BITS) begin
        $display("FATAL sdram_controller: ADDR_WIDTH=%0d != BANK_BITS(%0d)+ROW_BITS(%0d)+COL_BITS(%0d)=%0d",
            ADDR_WIDTH, BANK_BITS, ROW_BITS, COL_BITS, BANK_BITS+ROW_BITS+COL_BITS);
        $finish;
    end

    // ---- real, standard -6-speed-grade timing, re-derived per
    // CLK_FREQ_MHZ (ceiling division: never UNDER-count a real ns
    // requirement) ----
    function integer ns_to_cycles;
        input integer ns;
        begin
            ns_to_cycles = (ns * CLK_FREQ_MHZ + 999) / 1000;
        end
    endfunction
    localparam T_RCD    = ns_to_cycles(15);   // ACTIVE -> READ/WRITE (AS4C32M16SA: 15ns min)
    localparam T_RP     = ns_to_cycles(15);   // PRECHARGE -> ACTIVE (AS4C32M16SA: 15ns min)
    // ACTIVE->PRECHARGE minimum (tRAS=45ns min, AS4C32M16SA) is not
    // separately waited on: this design's own fixed sequencing
    // (tRCD + CAS_LATENCY + BURST_LEN data cycles) already comfortably
    // exceeds it by construction before auto-precharge can begin
    // internally, at every frequency this design actually targets
    // (64-100MHz) -- re-verified this session for the new part's own
    // 45ns real minimum (was 42ns for the previous, smaller part):
    // at CAS_LATENCY=3 and the default BURST_LEN=4, the minimum
    // possible sequence is T_RCD(>=1 cycle)+3+4=8 cycles, i.e. >=8
    // cycles*period; even at 100MHz (10ns period) that is 80ns >=
    // 45ns. This margin narrows at higher frequency and/or smaller
    // BURST_LEN, and is NOT re-derived symbolically here -- confirmed
    // instead by this session's own real simulation regression at
    // every frequency actually used (64/80/100MHz), per this
    // project's own "measure, do not estimate" standard.
    //
    // tMRD and tWR are BOTH specified by the real AS4C32M16SA
    // datasheet in explicit CLK units (2 CLK each) -- no unit
    // ambiguity this time (unlike the smaller AS4C4M16SA's own
    // datasheet, which stated tMRD in ns-at-max-frequency and caused
    // ERR-0026). Hardcoded directly as fixed cycle counts, matching
    // how CAS_LATENCY is already modeled.
    localparam T_MRD    = 2;                  // LOAD MODE REGISTER -> any command (tMRD = 2 CLK, fixed)
    localparam T_INIT_US= 200;                // power-up wait, real datasheet value (unchanged)
    localparam T_INIT   = T_INIT_US * CLK_FREQ_MHZ;
    localparam CAS_LATENCY = 3;               // fixed for this part/speed grade (CL=2 or 3 supported; 3 chosen, matches the previous part)
    // real refresh interval: AS4C32M16SA has 8192 rows (ROW_BITS=13),
    // each must be refreshed within 64ms -> one AUTO REFRESH at least
    // every 64e6ns/8192 = 7812.5ns, rounded UP to 7813ns (never under-
    // count). HALF the previous, smaller part's own 15625ns interval,
    // since this part has 2x the rows to refresh in the same 64ms
    // window -- a real, meaningful difference (not a rounding
    // artifact), re-derived from ROW_BITS so this stays correct if
    // ROW_BITS is ever changed again for a different device.
    localparam T_REFI    = ns_to_cycles(64000000 / (1 << ROW_BITS) + 1);

    localparam CNTW = $clog2((T_INIT>T_REFI ? T_INIT : T_REFI) + 1);

    // JEDEC SDR SDRAM commands are encoded directly in the FSM below
    // via named signal drives (cs_n/ras_n/cas_n/we_n), not a lookup
    // table -- clearer to review against the real datasheet's own
    // command truth table line by line.

    // tRC (ACTIVATE-to-ACTIVATE minimum, same bank), used by both the
    // init-refresh and steady-state refresh wait. AS4C32M16SA: 65ns min.
    function [CNTW-1:0] T_RC_MINUS1;
        localparam integer T_RC = ns_to_cycles(65);
        begin
            T_RC_MINUS1 = T_RC[CNTW-1:0] - 1'b1;
        end
    endfunction

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

    wire [BANK_BITS-1:0] addr_bank = addr[ADDR_WIDTH-1 -: BANK_BITS];
    wire [ROW_BITS-1:0]  addr_row  = addr[ADDR_WIDTH-BANK_BITS-1 -: ROW_BITS];
    wire [COL_BITS-1:0]  addr_col  = addr[COL_BITS-1:0];

    // req_pending: latches a req that arrives in S_IDLE on the SAME
    // cycle a periodic AUTO REFRESH is also due. Without this, a
    // single-cycle req pulse (this project's own established
    // mem_req convention -- see weight_prefetch_engine.v's own header
    // comment) would be silently dropped whenever refresh wins
    // arbitration that cycle: the caller only holds req high for one
    // cycle, has no idea refresh was chosen instead, and then waits
    // forever for a `ready` that will never come -- a real,
    // frequency/burst-alignment-dependent deadlock found by STEP16's
    // own Phase 4 100/133/166MHz sweep (reproduced at BURST_LEN=1,
    // CLK_FREQ_MHZ=133, but the race is general, not specific to that
    // combination -- it is a matter of which absolute cycle each test
    // vector's req happens to land on).
    reg         req_pending;
    wire               eff_wr   = req ? wr        : req_wr_reg;
    wire [BANK_BITS-1:0] eff_bank = req ? addr_bank : req_bank_reg;
    wire [ROW_BITS-1:0]  eff_row  = req ? addr_row  : req_row_reg;
    wire [COL_BITS-1:0]  eff_col  = req ? addr_col  : req_col_reg;
    wire [16*BURST_LEN-1:0] eff_wdata = req ? wdata : wdata_reg;
    wire [2*BURST_LEN-1:0]  eff_wmask = req ? wmask : wmask_reg;

    // tri-state DQ: driven only during a write burst
    reg dq_out_en;
    reg [15:0] dq_out;
    assign sdram_dq = dq_out_en ? dq_out : 16'hzzzz;

    // Mode register value: burst length code + sequential burst type
    // (A3=0) + CAS latency 3 (A6:4=011) + standard write burst (A9=0,
    // "WBL" -- bit position within the reserved/test-mode region above
    // A6:4 varies slightly by device row-width across this Alliance
    // family, but is always 0/"burst" for every variant, so this
    // function's own "everything above bit 6 is 0" construction is
    // correct regardless of that exact bit-name mapping). Width is
    // ROW_BITS (matches sdram_a), zero-padded above bit 6 for any
    // ROW_BITS value.
    function [ROW_BITS-1:0] mrs_value;
        input integer burst_len;
        reg [2:0] bl_code;
        reg [ROW_BITS-1:0] v;
        begin
            bl_code = (burst_len==1) ? 3'b000 :
                      (burst_len==2) ? 3'b001 :
                      (burst_len==4) ? 3'b010 :
                      (burst_len==8) ? 3'b011 : 3'b111; // 111 = full page, unused here
            v = {ROW_BITS{1'b0}};
            v[6:4] = 3'b011;  // CAS Latency = 3 (matches this controller's own fixed CAS_LATENCY)
            v[3]   = 1'b0;    // Burst Type = sequential
            v[2:0] = bl_code; // Burst Length
            mrs_value = v;
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            state         <= S_INIT_WAIT;
            wait_cnt      <= T_INIT[CNTW-1:0];
            init_ref_cnt  <= 4'd0;
            refresh_timer <= T_REFI[CNTW-1:0];
            sdram_cke     <= 1'b1; // held high throughout, real part supports CKE-always-high operation
            sdram_cs_n    <= 1'b1;
            sdram_ras_n   <= 1'b1;
            sdram_cas_n   <= 1'b1;
            sdram_we_n    <= 1'b1;
            sdram_ba      <= 2'b00;
            sdram_a       <= {ROW_BITS{1'b0}};
            sdram_dqm     <= 2'b00; // both byte lanes always enabled (weight/tile fetch always full-word)
            dq_out_en     <= 1'b0;
            ready         <= 1'b0;
            busy          <= 1'b1;
            req_pending   <= 1'b0;
        end else begin
            // default: NOP every cycle unless a state below overrides it
            sdram_cs_n  <= 1'b0;
            sdram_ras_n <= 1'b1;
            sdram_cas_n <= 1'b1;
            sdram_we_n  <= 1'b1;
            ready       <= 1'b0;
            dq_out_en   <= 1'b0;
            sdram_dqm   <= 2'b00; // default: no mask (reads always want valid data; writes override below per-word)

            if (refresh_timer != 0) refresh_timer <= refresh_timer - 1'b1;

            // Latch a fresh req's fields UNCONDITIONALLY, every cycle,
            // regardless of what state the controller is currently in
            // -- not just while in S_IDLE. ERR-0019's own fix only
            // covered "refresh wins arbitration the SAME cycle S_IDLE
            // sees req" -- but a real caller (e.g. slot_mem_arbiter_
            // wide.v) can pulse req for exactly one cycle at ANY time,
            // including a cycle where the controller is mid-refresh
            // (S_REFRESH_WAIT) or finishing a PREVIOUS transaction's
            // own PRECHARGE_WAIT tail -- i.e. NOT in S_IDLE at all that
            // cycle. The old S_IDLE-only latch silently missed those,
            // permanently starving whichever requester's pulse landed
            // there (found via the real N=2 D-Stress integration
            // benchmark, EXP-0042: both slots' memory managers hung
            // forever at tile_idx=0 while the arbiter's own `owner`
            // stayed locked on a grant the controller had already
            // forgotten -- a real, reproducible full-system deadlock,
            // not merely a slower run).
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
                        // PRECHARGE ALL: RAS#=0,CAS#=1,WE#=0, A10=1
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
                    // AUTO REFRESH: RAS#=0,CAS#=0,WE#=1
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
                        // LOAD MODE REGISTER: RAS#=0,CAS#=0,WE#=0, addr=mode value
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
                    // req (if any) was already latched into req_pending
                    // unconditionally above, regardless of state -- see
                    // that latch's own comment for why it must not be
                    // scoped to only this state.
                    if (refresh_timer == 0) begin
                        // periodic AUTO REFRESH -- no row is ever left
                        // open between transactions (auto-precharge
                        // always used), so we can refresh immediately,
                        // no PRECHARGE-ALL needed here.
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
                        // ACTIVATE: RAS#=0,CAS#=1,WE#=1, ba=bank, a=row
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
                        // READ or WRITE with auto-precharge (A10=1):
                        // CAS#=0, WE#=(0 for write /1 for read), ba=bank,
                        // a[COL_BITS-1:0]=col, a[10]=1 (auto-precharge,
                        // always at bit 10 across this whole Alliance
                        // SDR family regardless of ROW_BITS/COL_BITS --
                        // safe as long as COL_BITS<=10, true for every
                        // device this controller has ever targeted, so
                        // the column field [COL_BITS-1:0] never
                        // overlaps bit 10)
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
                            // Cycle-exact derivation (not assumed --
                            // see the module's own design log /
                            // EXP-0040 for the full walkthrough):
                            // cas_n=0 becomes VISIBLE to the real chip
                            // one cycle after this NBA (call that
                            // cycle "C"). Entering S_CAS_WAIT also
                            // takes effect at cycle C, with wait_cnt
                            // set here. The state's own "wait_cnt==0"
                            // capture branch first fires at cycle
                            // C + wait_cnt_initial. We want that to be
                            // C + CAS_LATENCY (data must be valid
                            // exactly CAS_LATENCY real clocks after
                            // the command is sampled) -- so
                            // wait_cnt_initial = CAS_LATENCY exactly,
                            // no adjustment.
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
                        // BURST_LEN==1 is a real, distinct edge case:
                        // word0 IS the whole (only) burst -- go
                        // straight to precharge-wait. Routing it
                        // through S_BURST_READ instead (burst_idx
                        // already at 1, one past the only valid
                        // index) was a real deadlock, found and fixed
                        // via the Phase 3 burst=1 test (EXP-0040):
                        // S_BURST_READ's own "burst_idx==BURST_LEN-1"
                        // exit check (==0) can never be true again
                        // once burst_idx has already advanced to 1.
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
                    // burst_idx's own width (BURST_IDXW=clog2(BURST_
                    // LEN)) can only ever represent 0..BURST_LEN-1 --
                    // capture therefore happens unconditionally every
                    // cycle spent in this state (an explicit "<
                    // BURST_LEN" guard here would always be true by
                    // construction and was removed as dead logic).
                    rdata[burst_idx*16 +: 16] <= sdram_dq;
                    if (burst_idx == BURST_LEN[BURST_IDXW-1:0] - 1'b1) begin
                        ready <= 1'b1;
                        // auto-precharge already running internally;
                        // enforce tRP before the next ACTIVATE.
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
                        wait_cnt <= T_RP[CNTW-1:0] + 1'b1; // tWR folded in conservatively
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
