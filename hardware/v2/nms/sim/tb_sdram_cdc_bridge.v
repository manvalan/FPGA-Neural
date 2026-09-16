`timescale 1ns/1ps

// ============================================================
// EXP-0053 -- isolated correctness + real measured speedup for
// sdram_cdc_bridge.v. Two independent DUTs share the exact same
// transaction sequence:
//
//   dut_direct : sdram_controller.v driven directly at clk_slow
//                (64MHz) -- today's real, unchanged baseline.
//   dut_bridge : sdram_cdc_bridge.v, slow-domain interface at
//                clk_slow (64MHz), internal sdram_controller.v
//                running at clk_fast (115.2MHz, real; the RTL's own
//                CLK_FREQ_MHZ_FAST=115 parameter is deliberately
//                rounded DOWN -- see sdram_cdc_bridge.v header).
//
// clk_slow and clk_fast are free-running, independently generated,
// NON-integer-ratio (64 vs 115.2) -- deliberately the hardest case
// for a toggle-based CDC handshake (no lucky fixed phase alignment
// possible), to genuinely stress the synchronizers rather than test
// a convenient special case.
//
// Covers:
//   1) correctness battery (write->read, sequential/bank-sweep/
//      pseudo-random addresses) through the bridge, bit-exact vs the
//      same golden pattern used by tb_sdram_controller.v's own idiom.
//   2) back-to-back stress: many transactions in a tight loop with NO
//      idle gap between them, the maximum rate the existing busy/
//      ready protocol allows -- the toggle handshake must never drop,
//      duplicate, or corrupt a transaction under sustained load.
//   3) REAL measured total-cycle comparison, direct vs bridged, over
//      an identical transaction sequence -- the actual number this
//      experiment exists to produce, not an estimate.
// ============================================================
module tb;
    localparam BURST_LEN  = 8;
    localparam ROW_BITS   = 13;
    localparam COL_BITS   = 10;
    localparam BANK_BITS  = 2;
    localparam ADDR_WIDTH = BANK_BITS + ROW_BITS + COL_BITS;
    localparam ALIGN_BITS = (BURST_LEN<=1) ? 0 : $clog2(BURST_LEN);

    localparam CLK_FREQ_SLOW = 64;
    localparam real CLK_FREQ_FAST_REAL = 115.2;
    localparam SLOW_PERIOD_NS = 1000.0/CLK_FREQ_SLOW;
    localparam real FAST_PERIOD_NS = 1000.0/CLK_FREQ_FAST_REAL;

    reg clk_slow = 0;
    always #(SLOW_PERIOD_NS/2.0) clk_slow = ~clk_slow;
    reg clk_fast = 0;
    always #(FAST_PERIOD_NS/2.0) clk_fast = ~clk_fast;

    reg rst_slow, rst_fast;

    // ---- shared cycle counter (slow domain -- what actually matters
    // for real system wall-clock, since every existing caller lives
    // in the 64MHz compute domain) ----
    integer cyc;
    always @(posedge clk_slow) if (!rst_slow) cyc <= cyc + 1;

    // ================= DUT A: direct, today's baseline =================
    reg                    reqA, wrA;
    reg  [ADDR_WIDTH-1:0]  addrA;
    reg  [16*BURST_LEN-1:0] wdataA;
    reg  [2*BURST_LEN-1:0]  wmaskA;
    wire [16*BURST_LEN-1:0] rdataA;
    wire readyA, busyA;
    wire cke_A, cs_A, ras_A, cas_A, we_A;
    wire [BANK_BITS-1:0] ba_A;
    wire [ROW_BITS-1:0] a_A;
    wire [15:0] dq_A;
    wire [1:0] dqm_A;

    sdram_controller #(
        .CLK_FREQ_MHZ(CLK_FREQ_SLOW), .BURST_LEN(BURST_LEN),
        .ROW_BITS(ROW_BITS), .COL_BITS(COL_BITS), .BANK_BITS(BANK_BITS)
    ) dut_direct (
        .clk(clk_slow), .rst(rst_slow),
        .req(reqA), .wr(wrA), .addr(addrA), .wdata(wdataA), .wmask(wmaskA),
        .rdata(rdataA), .ready(readyA), .busy(busyA),
        .sdram_cke(cke_A), .sdram_cs_n(cs_A), .sdram_ras_n(ras_A),
        .sdram_cas_n(cas_A), .sdram_we_n(we_A),
        .sdram_ba(ba_A), .sdram_a(a_A), .sdram_dq(dq_A), .sdram_dqm(dqm_A)
    );
    sdram_model #(
        .CLK_FREQ_MHZ(CLK_FREQ_SLOW),
        .ROW_BITS(ROW_BITS), .COL_BITS(COL_BITS), .BANK_BITS(BANK_BITS)
    ) mem_direct (
        .clk(clk_slow), .cke(cke_A), .cs_n(cs_A), .ras_n(ras_A),
        .cas_n(cas_A), .we_n(we_A), .ba(ba_A), .a(a_A), .dq(dq_A), .dqm(dqm_A)
    );

    // ================= DUT B: bridged (64MHz iface, 115.2MHz memory) ====
    reg                    reqB, wrB;
    reg  [ADDR_WIDTH-1:0]  addrB;
    reg  [16*BURST_LEN-1:0] wdataB;
    reg  [2*BURST_LEN-1:0]  wmaskB;
    wire [16*BURST_LEN-1:0] rdataB;
    wire readyB, busyB;
    wire cke_B, cs_B, ras_B, cas_B, we_B;
    wire [BANK_BITS-1:0] ba_B;
    wire [ROW_BITS-1:0] a_B;
    wire [15:0] dq_B;
    wire [1:0] dqm_B;

    sdram_cdc_bridge #(
        .CLK_FREQ_MHZ_FAST(115), .BURST_LEN(BURST_LEN),
        .ROW_BITS(ROW_BITS), .COL_BITS(COL_BITS), .BANK_BITS(BANK_BITS)
    ) dut_bridge (
        .clk_slow(clk_slow), .rst_slow(rst_slow),
        .clk_fast(clk_fast), .rst_fast(rst_fast),
        .req(reqB), .wr(wrB), .addr(addrB), .wdata(wdataB), .wmask(wmaskB),
        .rdata(rdataB), .ready(readyB), .busy(busyB),
        .sdram_cke(cke_B), .sdram_cs_n(cs_B), .sdram_ras_n(ras_B),
        .sdram_cas_n(cas_B), .sdram_we_n(we_B),
        .sdram_ba(ba_B), .sdram_a(a_B), .sdram_dq(dq_B), .sdram_dqm(dqm_B)
    );
    sdram_model #(
        .CLK_FREQ_MHZ(115),
        .ROW_BITS(ROW_BITS), .COL_BITS(COL_BITS), .BANK_BITS(BANK_BITS)
    ) mem_bridge (
        .clk(clk_fast), .cke(cke_B), .cs_n(cs_B), .ras_n(ras_B),
        .cas_n(cas_B), .we_n(we_B), .ba(ba_B), .a(a_B), .dq(dq_B), .dqm(dqm_B)
    );

    integer errors, tests;

    task automatic do_txn_A(
        input                    t_wr,
        input [ADDR_WIDTH-1:0]   t_addr,
        input [16*BURST_LEN-1:0] t_wdata,
        output [16*BURST_LEN-1:0] t_rdata,
        output integer            t_cycles
    );
        integer t0;
        begin
            @(posedge clk_slow);
            while (busyA) @(posedge clk_slow);
            t0 = cyc;
            reqA = 1'b1; wrA = t_wr; addrA = t_addr; wdataA = t_wdata; wmaskA = {(2*BURST_LEN){1'b0}};
            @(posedge clk_slow);
            reqA = 1'b0;
            while (!readyA) @(posedge clk_slow);
            t_rdata = rdataA;
            t_cycles = cyc - t0;
        end
    endtask

    task automatic do_txn_B(
        input                    t_wr,
        input [ADDR_WIDTH-1:0]   t_addr,
        input [16*BURST_LEN-1:0] t_wdata,
        output [16*BURST_LEN-1:0] t_rdata,
        output integer            t_cycles
    );
        integer t0;
        begin
            @(posedge clk_slow);
            while (busyB) @(posedge clk_slow);
            t0 = cyc;
            reqB = 1'b1; wrB = t_wr; addrB = t_addr; wdataB = t_wdata; wmaskB = {(2*BURST_LEN){1'b0}};
            @(posedge clk_slow);
            reqB = 1'b0;
            while (!readyB) @(posedge clk_slow);
            t_rdata = rdataB;
            t_cycles = cyc - t0;
        end
    endtask

    reg [16*BURST_LEN-1:0] gotA, gotB, wpat;
    integer elapsedA, elapsedB;

    task automatic check_word_both(input [ADDR_WIDTH-1:0] a, input [15:0] pattern);
        integer k;
        begin
            for (k = 0; k < BURST_LEN; k = k + 1)
                wpat[k*16 +: 16] = pattern + k[15:0];

            do_txn_A(1'b1, a, wpat, gotA, elapsedA);
            do_txn_A(1'b0, a, {(16*BURST_LEN){1'b0}}, gotA, elapsedA);
            do_txn_B(1'b1, a, wpat, gotB, elapsedB);
            do_txn_B(1'b0, a, {(16*BURST_LEN){1'b0}}, gotB, elapsedB);

            tests = tests + 1;
            if (gotA !== wpat) begin
                $display("FAIL (direct) addr=%0d: got=%h expected=%h", a, gotA, wpat);
                errors = errors + 1;
            end
            if (gotB !== wpat) begin
                $display("FAIL (bridge) addr=%0d: got=%h expected=%h", a, gotB, wpat);
                errors = errors + 1;
            end
            if (gotA === wpat && gotB === wpat) begin
                $display("PASS addr=%0d: both bit-exact (direct=%0d cyc, bridge=%0d cyc)", a, elapsedA, elapsedB);
            end
        end
    endtask

    integer seed;
    integer i;
    reg [ADDR_WIDTH-1:0] rnd_addr;

    // ---- real measured total-cycle comparison over an identical,
    // longer sequence (TEST 3) ----
    integer total_cyc_A, total_cyc_B, t0_seq;

    initial begin
        errors = 0; tests = 0; cyc = 0; seed = 32'hFACADE;
        rst_slow = 1; rst_fast = 1;
        reqA = 0; wrA = 0; addrA = 0; wdataA = 0; wmaskA = 0;
        reqB = 0; wrB = 0; addrB = 0; wdataB = 0; wmaskB = 0;
        repeat(10) @(posedge clk_slow);
        repeat(10) @(posedge clk_fast);
        rst_slow = 0; rst_fast = 0;
        @(posedge clk_slow);
        while (busyA || busyB) @(posedge clk_slow);

        $display("=== TEST 1: correctness battery (direct vs bridge, same golden pattern) ===");
        check_word_both({ADDR_WIDTH{1'b0}}, 16'hA5A5);
        for (i = 0; i < 8; i = i + 1)
            check_word_both(i*BURST_LEN, 16'h1000 + i);
        for (i = 0; i < 4; i = i + 1)
            check_word_both((i << ALIGN_BITS) + (100 << (ALIGN_BITS+BANK_BITS)), 16'h2000 + i);
        for (i = 0; i < 24; i = i + 1) begin
            rnd_addr = ($random(seed) % ((1<<ADDR_WIDTH)/BURST_LEN)) * BURST_LEN;
            check_word_both(rnd_addr, 16'h3000 + i);
        end
        $display("  TEST 1: %0d/%0d passed so far", tests-errors, tests);

        $display("=== TEST 2: back-to-back stress (no idle gap, max rate, 100 txns) ===");
        begin : test2
            integer j;
            reg [ADDR_WIDTH-1:0] ta;
            reg [16*BURST_LEN-1:0] tw, gA, gB;
            integer eA, eB;
            for (j = 0; j < 100; j = j + 1) begin
                ta = ((j*7) % ((1<<ADDR_WIDTH)/BURST_LEN)) * BURST_LEN;
                tw = {(16*BURST_LEN){16'(16'h6000 + j)}};
                do_txn_A(1'b1, ta, tw, gA, eA);
                do_txn_A(1'b0, ta, {(16*BURST_LEN){1'b0}}, gA, eA);
                do_txn_B(1'b1, ta, tw, gB, eB);
                do_txn_B(1'b0, ta, {(16*BURST_LEN){1'b0}}, gB, eB);
                tests = tests + 1;
                if (gA !== tw || gB !== tw) begin
                    $display("FAIL TEST2 iter=%0d addr=%0d: direct=%h bridge=%h expected=%h", j, ta, gA, gB, tw);
                    errors = errors + 1;
                end
            end
            $display("  TEST2: 100/100 back-to-back transactions checked, %0d errors so far", errors);
        end

        $display("=== TEST 3: real measured total-cycle comparison, identical 40-transaction sequence ===");
        begin : test3
            integer j;
            reg [ADDR_WIDTH-1:0] ta;
            reg [16*BURST_LEN-1:0] tw, gA, gB;
            integer eA, eB;

            @(posedge clk_slow); while (busyA) @(posedge clk_slow);
            t0_seq = cyc;
            for (j = 0; j < 40; j = j + 1) begin
                ta = ((j*11) % ((1<<ADDR_WIDTH)/BURST_LEN)) * BURST_LEN;
                tw = {(16*BURST_LEN){16'(16'h7000 + j)}};
                do_txn_A(1'b1, ta, tw, gA, eA);
                do_txn_A(1'b0, ta, {(16*BURST_LEN){1'b0}}, gA, eA);
            end
            total_cyc_A = cyc - t0_seq;

            @(posedge clk_slow); while (busyB) @(posedge clk_slow);
            t0_seq = cyc;
            for (j = 0; j < 40; j = j + 1) begin
                ta = ((j*11) % ((1<<ADDR_WIDTH)/BURST_LEN)) * BURST_LEN;
                tw = {(16*BURST_LEN){16'(16'h7000 + j)}};
                do_txn_B(1'b1, ta, tw, gB, eB);
                do_txn_B(1'b0, ta, {(16*BURST_LEN){1'b0}}, gB, eB);
            end
            total_cyc_B = cyc - t0_seq;

            $display("  direct (64MHz only)      : %0d slow-domain cycles for 80 transactions (40 write+40 read)", total_cyc_A);
            $display("  bridged (64/115.2MHz)    : %0d slow-domain cycles for 80 transactions (40 write+40 read)", total_cyc_B);
            $display("  REAL measured speedup    : %0f x", total_cyc_A * 1.0 / total_cyc_B);
        end

        $display("=== %0d/%0d tests, %0d errors ===", tests-errors, tests, errors);
        if (errors == 0) $display("ALL TESTS PASSED (tb_sdram_cdc_bridge)");
        $finish;
    end
endmodule
