`timescale 1ns/1ps

// ============================================================
// V3 -- 2-way arbiter between packed_slot.v's own weight-fetch ctrl
// port and ONE real, shared sdram_controller.v.
//
// Grants LOCK for the whole duration of a slot's mem_active (its
// entire multi-burst layer fetch), not per-transaction -- a slot's
// own layer_prefetch_ctrl.v issues MANY back-to-back ctrl_req bursts
// per fetch, and interleaving those with the OTHER slot's bursts
// would corrupt both (neither is designed to have its own multi-burst
// sequence interrupted mid-flight). First-active-wins priority; the
// other slot's ctrl_ready is held at 0 (never pulses) while not
// granted, so its own req/ready FSM simply waits, harmlessly, exactly
// like it already does for ordinary controller busy cycles.
// ============================================================
module sdram_slot_arbiter2 #(
    parameter ADDR_WIDTH  = 25,
    parameter BURST_LEN   = 8
)(
    input  wire clk,
    input  wire rst,

    input  wire                    slot0_active,
    output wire                    slot0_grant,
    input  wire                    slot0_req,
    input  wire                    slot0_wr,
    input  wire [ADDR_WIDTH-1:0]   slot0_addr,
    input  wire [16*BURST_LEN-1:0] slot0_wdata,
    input  wire [2*BURST_LEN-1:0]  slot0_wmask,
    output wire [16*BURST_LEN-1:0] slot0_rdata,
    output wire                    slot0_ready,
    output wire                    slot0_busy,

    input  wire                    slot1_active,
    output wire                    slot1_grant,
    input  wire                    slot1_req,
    input  wire                    slot1_wr,
    input  wire [ADDR_WIDTH-1:0]   slot1_addr,
    input  wire [16*BURST_LEN-1:0] slot1_wdata,
    input  wire [2*BURST_LEN-1:0]  slot1_wmask,
    output wire [16*BURST_LEN-1:0] slot1_rdata,
    output wire                    slot1_ready,
    output wire                    slot1_busy,

    output wire                    ctrl_req,
    output wire                    ctrl_wr,
    output wire [ADDR_WIDTH-1:0]   ctrl_addr,
    output wire [16*BURST_LEN-1:0] ctrl_wdata,
    output wire [2*BURST_LEN-1:0]  ctrl_wmask,
    input  wire [16*BURST_LEN-1:0] ctrl_rdata,
    input  wire                    ctrl_ready,
    input  wire                    ctrl_busy
);
    // grant_now is COMBINATIONAL, not registered: layer_prefetch_ctrl.v
    // issues ctrl_req as a genuine one-shot pulse (it has only ever
    // been used wired DIRECTLY to a controller before this arbiter --
    // EXP-0057/58/62/65 -- so it assumes immediate visibility, not a
    // registered/one-cycle-late grant). A purely-registered arbiter
    // (grant decided AT the clock edge, valid only the FOLLOWING
    // cycle) misses that first pulse entirely -- found empirically:
    // slot1 hung forever in its own S_WAIT state, ctrl_req correctly
    // pulsed for exactly one cycle then dropped, but the registered
    // grant hadn't caught up yet, so the real controller never saw it
    // and ctrl_ready never came. `locked`/`grant_reg` below only
    // LATCH a decision already available combinationally this same
    // cycle, purely to keep it sticky once BOTH slots are active
    // (prevents switching mid-fetch), never to delay the FIRST grant.
    reg locked;
    reg grant_reg;

    wire grant_now = locked ? grant_reg : (slot0_active ? 1'b0 : 1'b1);
    wire either_active = slot0_active || slot1_active;

    always @(posedge clk) begin
        if (rst) begin
            locked   <= 1'b0;
            grant_reg<= 1'b0;
        end else begin
            if (!locked) begin
                if (either_active) begin
                    locked    <= 1'b1;
                    grant_reg <= grant_now;
                end
            end else begin
                if (grant_reg == 1'b0 && !slot0_active) locked <= 1'b0;
                if (grant_reg == 1'b1 && !slot1_active) locked <= 1'b0;
            end
        end
    end

    wire sel0 = either_active && (grant_now == 1'b0);
    wire sel1 = either_active && (grant_now == 1'b1);

    // combinational grant feedback: a slot must see its OWN grant
    // asserted (in response to its own mem_active going high, same
    // cycle) before it may pulse layer_prefetch_ctrl.v's one-shot
    // ctrl_req -- see packed_slot.v's own S_MEMWAIT state.
    assign slot0_grant = sel0;
    assign slot1_grant = sel1;

    assign ctrl_req   = sel0 ? slot0_req   : (sel1 ? slot1_req   : 1'b0);
    assign ctrl_wr    = sel0 ? slot0_wr    : (sel1 ? slot1_wr    : 1'b0);
    assign ctrl_addr  = sel0 ? slot0_addr  : (sel1 ? slot1_addr  : {ADDR_WIDTH{1'b0}});
    assign ctrl_wdata = sel0 ? slot0_wdata : (sel1 ? slot1_wdata : {(16*BURST_LEN){1'b0}});
    assign ctrl_wmask = sel0 ? slot0_wmask : (sel1 ? slot1_wmask : {(2*BURST_LEN){1'b0}});

    assign slot0_rdata = ctrl_rdata;
    assign slot0_ready = sel0 ? ctrl_ready : 1'b0;
    assign slot0_busy  = sel0 ? ctrl_busy  : 1'b1;

    assign slot1_rdata = ctrl_rdata;
    assign slot1_ready = sel1 ? ctrl_ready : 1'b0;
    assign slot1_busy  = sel1 ? ctrl_busy  : 1'b1;
endmodule
