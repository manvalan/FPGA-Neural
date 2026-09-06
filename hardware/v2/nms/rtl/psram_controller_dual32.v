`timescale 1ns/1ps

// ============================================================
// NMS STEP15 (continuation) -- REAL 32-bit physical memory
// interface: two independent, real, UNMODIFIED
// hardware/v1/rtl/psram_controller.v instances (each driving its
// own physical 16-bit ISSI IS66WVE4M16EBLL-70BLI chip), presenting
// a single, coherent 32-bit mem_req/mem_addr/mem_wdata/mem_rdata/
// mem_ready interface to the rest of the NMS.
//
// ARCHITECTURE DECISION (not assumed -- evaluated against the
// alternatives STEP15's own governing spec explicitly listed):
//   - "one widened controller": REJECTED. psram_controller.v's own
//     internal state machine (STATE_INIT/CR_INIT/IDLE/READ/
//     PAGE_OPEN/PAGE_CLOSE/PAGE_REOPEN/WRITE/WRITE_WAIT) is written
//     around a DATA_WIDTH-parametrized single physical DQ bus
//     (psram_dq is `inout [DATA_WIDTH-1:0]`) -- widening DATA_WIDTH
//     to 32 in a SINGLE instance would drive ONE 32-bit inout bus,
//     which does not correspond to two SEPARATE physical chips each
//     with their OWN independent DQ pins, CE#, OE#, WE# etc. Two
//     real, separate physical chips cannot share one inout bus.
//   - "interleaved controllers" (alternate words to alternate
//     chips): REJECTED. This would double the ADDRESSABLE space
//     seen by the LOGICAL 32-bit interface without doubling the
//     WIDTH of a single transaction -- it solves a different
//     problem (more capacity at the same per-transfer width) than
//     what STEP15 asked for (wider per-transfer width at the same
//     tile-fetch granularity).
//   - "duplicated controller instances, shared control, duplicated
//     data path" -- SELECTED. Two full, real, byte-for-byte
//     UNMODIFIED psram_controller.v instances, each wired to its own
//     physical chip. Both instances receive IDENTICAL clk/rst/
//     mem_req/mem_wr/mem_addr every cycle (broadcast) -- since both
//     instances are the exact same RTL executing the exact same real
//     timing FSM against the exact same inputs, they are
//     STRUCTURALLY, CYCLE-EXACT synchronized by construction, not by
//     any added synchronization logic. This preserves
//     psram_controller.v's own real page/open/close timing
//     semantics EXACTLY (DEC requirement: "preserve existing memory
//     timing behavior") -- neither instance's own internal state
//     machine is touched at all.
//
// Address mapping: this module's own external mem_addr is the BYTE
// address of the 32-bit transaction (matching
// weight_prefetch_engine_wide.v's own established byte-address
// convention, STEP14 -- so it plugs in without modifying that
// already-validated module). Internally, mem_addr[ADDR_WIDTH-1:2]
// (a right-shift by 2, i.e. divide by 4 bytes/32-bit-word) is fed
// IDENTICALLY to both real psram_controller.v instances as THEIR own
// required per-chip WORD address (2 bytes/word each) -- i.e. logical
// 32-bit word W is stored as chip0's own word W (bits [15:0]) and
// chip1's own word W (bits [31:16]). This is the standard byte-lane
// "bus-widening" mapping (NOT address interleaving): the combined
// interface holds the SAME NUMBER of 32-bit words as either chip
// alone holds 16-bit words (matching real DEC-0029's own "2 parallel
// chips, shared address bus" architecture). An earlier draft fed
// mem_addr to both instances UNSHIFTED (treating a byte address as if
// it were already a word address) -- a real bug, caught by the bit-
// exact regression (tb_psram_dual32.v): every byte beyond the very
// first tile's own lane 0 read back as 0 (uninitialized), because the
// real controllers were being addressed ~4x further out than
// intended. Fixed by adding the explicit >>2 conversion here.
//
// mem_ready: both instances' own mem_ready are asserted the SAME
// cycle by construction (see above) -- output is chip0's own
// mem_ready, with a real, synthesizable assertion checking chip1's
// mem_ready never diverges (STEP15's own explicit "verify
// simultaneous read/write timing, latency matching" requirement).
// ============================================================
module psram_controller_dual32 #(
    parameter ADDR_WIDTH   = 23,   // word address width, PER CHIP (same value fed to both)
    parameter CLK_FREQ_MHZ = 80
)(
    input  wire                   clk,
    input  wire                   rst,

    // ---- 32-bit logical interface ----
    input  wire                   mem_req,
    input  wire                   mem_wr,
    input  wire [ADDR_WIDTH-1:0]  mem_addr,
    input  wire [31:0]            mem_wdata,
    input  wire [1:0]             mem_lb_n,   // [0]=chip0 low-byte enable#, [1]=chip1 low-byte enable#
    input  wire [1:0]             mem_ub_n,   // [0]=chip0 high-byte enable#, [1]=chip1 high-byte enable#

    output wire [31:0]            mem_rdata,
    output wire                   mem_ready,
    output reg                    lane_sync_error, // latched, real assertion: should NEVER go high

    // ---- physical interface, chip 0 (bits [15:0]) ----
    output wire [ADDR_WIDTH-1:0]  psram0_a,
    inout  wire [15:0]            psram0_dq,
    output wire                   psram0_ce_n,
    output wire                   psram0_oe_n,
    output wire                   psram0_we_n,
    output wire                   psram0_lb_n,
    output wire                   psram0_ub_n,
    output wire                   psram0_zz_n,

    // ---- physical interface, chip 1 (bits [31:16]) ----
    output wire [ADDR_WIDTH-1:0]  psram1_a,
    inout  wire [15:0]            psram1_dq,
    output wire                   psram1_ce_n,
    output wire                   psram1_oe_n,
    output wire                   psram1_we_n,
    output wire                   psram1_lb_n,
    output wire                   psram1_ub_n,
    output wire                   psram1_zz_n
);

    wire [15:0] rdata0, rdata1;
    wire ready0, ready1;

    // mem_addr (this module's own external contract) is the BYTE
    // address of the 32-bit transaction -- matching
    // weight_prefetch_engine_wide.v's own established convention
    // (STEP14), so it plugs in without modifying that already-
    // validated module. The REAL psram_controller.v instances, in
    // contrast, each expect a per-chip WORD address (2 bytes/word) --
    // exactly like weight_prefetch_engine.v's own real, original
    // 16-bit usage, which explicitly converts via `w_base[ADDR_WIDTH-
    // 1:1]` before using it as mem_addr. For this 32-bit interface
    // (4 bytes/logical word, mapped straight across both 16-bit
    // chips at the SAME per-chip word index), the equivalent
    // conversion is a right-shift by 2, not 1 -- byte address bits
    // [1:0] select which of the 4 bytes within the 32-bit word (not
    // meaningful to the per-chip word address itself, only to
    // mem_lb_n/mem_ub_n lane selection, already handled separately
    // by the caller).
    wire [ADDR_WIDTH-1:0] chip_word_addr = mem_addr[ADDR_WIDTH-1:2];

    psram_controller #(.ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(16), .CLK_FREQ_MHZ(CLK_FREQ_MHZ)) u_ctrl0 (
        .clk(clk), .rst(rst),
        .mem_req(mem_req), .mem_wr(mem_wr), .mem_addr(chip_word_addr),
        .mem_wdata(mem_wdata[15:0]), .mem_lb_n(mem_lb_n[0]), .mem_ub_n(mem_ub_n[0]),
        .mem_rdata(rdata0), .mem_ready(ready0),
        .psram_a(psram0_a), .psram_dq(psram0_dq),
        .psram_ce_n(psram0_ce_n), .psram_oe_n(psram0_oe_n), .psram_we_n(psram0_we_n),
        .psram_lb_n(psram0_lb_n), .psram_ub_n(psram0_ub_n), .psram_zz_n(psram0_zz_n)
    );

    psram_controller #(.ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(16), .CLK_FREQ_MHZ(CLK_FREQ_MHZ)) u_ctrl1 (
        .clk(clk), .rst(rst),
        .mem_req(mem_req), .mem_wr(mem_wr), .mem_addr(chip_word_addr),
        .mem_wdata(mem_wdata[31:16]), .mem_lb_n(mem_lb_n[1]), .mem_ub_n(mem_ub_n[1]),
        .mem_rdata(rdata1), .mem_ready(ready1),
        .psram_a(psram1_a), .psram_dq(psram1_dq),
        .psram_ce_n(psram1_ce_n), .psram_oe_n(psram1_oe_n), .psram_we_n(psram1_we_n),
        .psram_lb_n(psram1_lb_n), .psram_ub_n(psram1_ub_n), .psram_zz_n(psram1_zz_n)
    );

    assign mem_rdata = {rdata1, rdata0};

    // mem_ready must be COMBINATIONAL, passed straight through from
    // ready0 -- NOT registered. An earlier draft registered it
    // (`mem_ready <= ready0`), adding one cycle of spurious latency
    // relative to mem_rdata (which reflects the controllers' own
    // CURRENT output combinationally) -- a real timing misalignment
    // caught by the bit-exact regression (every byte beyond tile 0's
    // own coincidental zero read back wrong): the caller sampled
    // mem_rdata one cycle before the (delayed) ready pulse told it to,
    // capturing stale/settling data. Fixed by making mem_ready a
    // simple continuous assignment, matching the real, single-chip
    // psram_controller.v's own timing exactly (which this module must
    // preserve, per its own design goal).
    assign mem_ready = ready0;

    always @(posedge clk) begin
        if (rst) begin
            lane_sync_error <= 1'b0;
        end else begin
            // Real, synthesizable cross-check: both instances are fed
            // byte-for-byte identical control/address every cycle, so
            // their own real timing FSMs MUST assert ready the same
            // cycle. This is not expected to ever fire; if it does,
            // the two physical chips have gone out of lockstep (e.g.
            // a real hardware fault or a genuine RTL bug), and
            // lane_sync_error latches permanently until reset.
            if (ready0 !== ready1) lane_sync_error <= 1'b1;
        end
    end

endmodule
