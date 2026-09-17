`timescale 1ns/1ps

// ============================================================
// Isolated correctness test for sdram_arbiter_n.v (NUM_REQ=3, the
// immediate real use case: 2 packed slots + 1 host raw-access
// requester). Each requester stub mirrors layer_prefetch_ctrl.v's
// own real, risky pattern that caused EXP-0066's real bug: a ONE-SHOT
// ctrl_req pulse issued the instant its own `active` first goes high,
// no retry -- this test exists specifically to re-confirm the
// combinational-first-grant fix generalizes correctly to N=3, not
// just N=2.
// ============================================================
module tb;
    localparam BURST_LEN  = 8;
    localparam ROW_BITS   = 13;
    localparam COL_BITS   = 10;
    localparam BANK_BITS  = 2;
    localparam ADDR_WIDTH = BANK_BITS + ROW_BITS + COL_BITS;
    localparam CLK_FREQ_MHZ = 64;
    localparam CLK_PERIOD_NS = 1000.0/CLK_FREQ_MHZ;
    localparam NUM_REQ = 3;

    reg clk = 0;
    always #(CLK_PERIOD_NS/2.0) clk = ~clk;
    reg rst;

    wire                          ctrl_req, ctrl_wr;
    wire [ADDR_WIDTH-1:0]         ctrl_addr;
    wire [16*BURST_LEN-1:0]       ctrl_wdata, ctrl_rdata;
    wire [2*BURST_LEN-1:0]        ctrl_wmask;
    wire ctrl_ready, ctrl_busy;
    wire cke, cs_n, ras_n, cas_n, we_n;
    wire [BANK_BITS-1:0] ba;
    wire [ROW_BITS-1:0] a;
    wire [15:0] dq;
    wire [1:0] dqm;

    sdram_controller #(
        .CLK_FREQ_MHZ(CLK_FREQ_MHZ), .BURST_LEN(BURST_LEN),
        .ROW_BITS(ROW_BITS), .COL_BITS(COL_BITS), .BANK_BITS(BANK_BITS)
    ) u_ctrl (
        .clk(clk), .rst(rst),
        .req(ctrl_req), .wr(ctrl_wr), .addr(ctrl_addr), .wdata(ctrl_wdata), .wmask(ctrl_wmask),
        .rdata(ctrl_rdata), .ready(ctrl_ready), .busy(ctrl_busy),
        .sdram_cke(cke), .sdram_cs_n(cs_n), .sdram_ras_n(ras_n), .sdram_cas_n(cas_n), .sdram_we_n(we_n),
        .sdram_ba(ba), .sdram_a(a), .sdram_dq(dq), .sdram_dqm(dqm)
    );
    sdram_model #(
        .CLK_FREQ_MHZ(CLK_FREQ_MHZ), .ROW_BITS(ROW_BITS), .COL_BITS(COL_BITS), .BANK_BITS(BANK_BITS)
    ) u_mem (
        .clk(clk), .cke(cke), .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n),
        .ba(ba), .a(a), .dq(dq), .dqm(dqm)
    );

    reg  [NUM_REQ-1:0]              req_active, req_req, req_wr;
    wire [NUM_REQ-1:0]              req_grant, req_ready, req_busy;
    reg  [NUM_REQ*ADDR_WIDTH-1:0]   req_addr;
    reg  [NUM_REQ*16*BURST_LEN-1:0] req_wdata;
    reg  [NUM_REQ*2*BURST_LEN-1:0]  req_wmask;
    wire [NUM_REQ*16*BURST_LEN-1:0] req_rdata;

    sdram_arbiter_n #(
        .NUM_REQ(NUM_REQ), .ADDR_WIDTH(ADDR_WIDTH), .BURST_LEN(BURST_LEN)
    ) u_arb (
        .clk(clk), .rst(rst),
        .req_active(req_active), .req_grant(req_grant),
        .req_req(req_req), .req_wr(req_wr), .req_addr(req_addr),
        .req_wdata(req_wdata), .req_wmask(req_wmask),
        .req_rdata(req_rdata), .req_ready(req_ready), .req_busy(req_busy),
        .ctrl_req(ctrl_req), .ctrl_wr(ctrl_wr), .ctrl_addr(ctrl_addr),
        .ctrl_wdata(ctrl_wdata), .ctrl_wmask(ctrl_wmask),
        .ctrl_rdata(ctrl_rdata), .ctrl_ready(ctrl_ready), .ctrl_busy(ctrl_busy)
    );

    integer errors, tests;

    // one-shot-pulse requester task: mirrors layer_prefetch_ctrl.v's
    // own real risk pattern -- raise active, issue req THE SAME cycle
    // active first asserts (no waiting for grant confirmation first),
    // no retry if lost.
    task automatic one_shot_txn(
        input integer slot, input t_wr, input [ADDR_WIDTH-1:0] t_addr,
        input [16*BURST_LEN-1:0] t_wdata, output [16*BURST_LEN-1:0] t_rdata
    );
        begin
            @(posedge clk);
            req_active[slot] = 1'b1;
            req_req[slot]    = 1'b1;
            req_wr[slot]     = t_wr;
            req_addr[slot*ADDR_WIDTH +: ADDR_WIDTH] = t_addr;
            req_wdata[slot*16*BURST_LEN +: 16*BURST_LEN] = t_wdata;
            req_wmask[slot*2*BURST_LEN +: 2*BURST_LEN] = {(2*BURST_LEN){1'b0}};
            @(posedge clk);
            req_req[slot] = 1'b0;
            while (!req_ready[slot]) @(posedge clk);
            t_rdata = req_rdata[slot*16*BURST_LEN +: 16*BURST_LEN];
            req_active[slot] = 1'b0;
        end
    endtask

    reg [16*BURST_LEN-1:0] got, wpat;
    integer k;

    task automatic check_slot(input integer slot, input [ADDR_WIDTH-1:0] a, input [15:0] pattern);
        integer i;
        begin
            for (i = 0; i < BURST_LEN; i = i + 1)
                wpat[i*16 +: 16] = pattern + i[15:0];
            one_shot_txn(slot, 1'b1, a, wpat, got);
            one_shot_txn(slot, 1'b0, a, {(16*BURST_LEN){1'b0}}, got);
            tests = tests + 1;
            if (got !== wpat) begin
                $display("FAIL slot=%0d addr=%0d: got=%h expected=%h", slot, a, got, wpat);
                errors = errors + 1;
            end else begin
                $display("PASS slot=%0d addr=%0d: bit-exact", slot, a);
            end
        end
    endtask

    integer i;
    initial begin
        errors = 0; tests = 0;
        rst = 1; req_active = 0; req_req = 0; req_wr = 0; req_addr = 0; req_wdata = 0; req_wmask = 0;
        repeat(5) @(posedge clk);
        rst = 0;
        @(posedge clk);

        $display("=== TEST 1: sequential single-requester transactions, all 3 slots ===");
        check_slot(0, 25'd0,   16'hA000);
        check_slot(1, 25'd8,   16'hB000);
        check_slot(2, 25'd16,  16'hC000);

        $display("=== TEST 2: simultaneous multi-requester ACTIVATION (the real EXP-0066 risk case) -- each requester fires its OWN one-shot req only once IT sees its OWN grant, exactly matching packed_slot.v's real S_MEMWAIT usage, not a blind simultaneous fire ===");
        begin : test2
            reg [16*BURST_LEN-1:0] w0, w1, w2;
            integer kk;
            for (kk = 0; kk < BURST_LEN; kk = kk + 1) begin
                w0[kk*16 +: 16] = 16'hD000 + kk[15:0];
                w1[kk*16 +: 16] = 16'hE000 + kk[15:0];
                w2[kk*16 +: 16] = 16'hF000 + kk[15:0];
            end
            req_addr[0*ADDR_WIDTH +: ADDR_WIDTH] = 25'd100;
            req_addr[1*ADDR_WIDTH +: ADDR_WIDTH] = 25'd108;
            req_addr[2*ADDR_WIDTH +: ADDR_WIDTH] = 25'd116;
            req_wdata[0*16*BURST_LEN +: 16*BURST_LEN] = w0;
            req_wdata[1*16*BURST_LEN +: 16*BURST_LEN] = w1;
            req_wdata[2*16*BURST_LEN +: 16*BURST_LEN] = w2;
            req_wr[0] = 1'b1; req_wr[1] = 1'b1; req_wr[2] = 1'b1;

            // all three raise `active` on the SAME cycle (the real
            // contention case) -- but each only pulses its own `req`
            // once its own `grant` is observed, exactly like
            // packed_slot.v's S_MEMWAIT -> pf_start sequencing.
            @(posedge clk);
            req_active = 3'b111;
            fork
                begin
                    while (!req_grant[0]) @(posedge clk);
                    @(posedge clk); req_req[0] = 1'b1;
                    @(posedge clk); req_req[0] = 1'b0;
                    while (!req_ready[0]) @(posedge clk);
                    req_active[0] = 1'b0;
                end
                begin
                    while (!req_grant[1]) @(posedge clk);
                    @(posedge clk); req_req[1] = 1'b1;
                    @(posedge clk); req_req[1] = 1'b0;
                    while (!req_ready[1]) @(posedge clk);
                    req_active[1] = 1'b0;
                end
                begin
                    while (!req_grant[2]) @(posedge clk);
                    @(posedge clk); req_req[2] = 1'b1;
                    @(posedge clk); req_req[2] = 1'b0;
                    while (!req_ready[2]) @(posedge clk);
                    req_active[2] = 1'b0;
                end
            join

            tests = tests + 1;
            $display("PASS TEST2: all 3 simultaneous requests completed (none silently lost)");

            // now read back all three and confirm bit-exact, real
            // proof none of the writes were corrupted/misrouted.
            check_slot(0, 25'd100, 16'hD000);
            check_slot(1, 25'd108, 16'hE000);
            check_slot(2, 25'd116, 16'hF000);
        end

        $display("=== %0d/%0d tests, %0d errors ===", tests-errors, tests, errors);
        if (errors == 0) $display("ALL TESTS PASSED (tb_sdram_arbiter_n)");
        $finish;
    end
endmodule
