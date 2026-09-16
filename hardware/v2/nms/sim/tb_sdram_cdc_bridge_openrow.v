`timescale 1ns/1ps

// ============================================================
// EXP-0055 -- isolated correctness + real measured COMBINED speedup
// for sdram_cdc_bridge_openrow.v (CDC to 115.2MHz + page-hit policy
// together), vs today's real single-clock, always-precharge baseline
// (sdram_controller.v @ 64MHz). Same dual-clock-domain rigor as
// tb_sdram_cdc_bridge.v (EXP-0053): clk_slow/clk_fast independently
// generated, non-integer ratio (64 vs 115.2MHz).
//
// This does NOT re-run every turnaround edge case already covered by
// tb_sdram_controller_openrow.v (EXP-0054, single-clock) -- that
// already established the FSM's own correctness independent of
// clocking. This testbench checks that composing the two mechanisms
// (CDC handshake + page-hit policy) together does not interact badly,
// and measures the REAL combined number.
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

    integer cyc;
    always @(posedge clk_slow) if (!rst_slow) cyc <= cyc + 1;

    // ================= DUT A: today's real baseline (single clock) =====
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
    ) dut_base (
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
    ) mem_base (
        .clk(clk_slow), .cke(cke_A), .cs_n(cs_A), .ras_n(ras_A),
        .cas_n(cas_A), .we_n(we_A), .ba(ba_A), .a(a_A), .dq(dq_A), .dqm(dqm_A)
    );

    // ================= DUT B: combined (CDC 115.2MHz + open-row) =======
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

    sdram_cdc_bridge_openrow #(
        .CLK_FREQ_MHZ_FAST(115), .BURST_LEN(BURST_LEN),
        .ROW_BITS(ROW_BITS), .COL_BITS(COL_BITS), .BANK_BITS(BANK_BITS)
    ) dut_combined (
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
    ) mem_combined (
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
                $display("FAIL (base) addr=%0d: got=%h expected=%h", a, gotA, wpat);
                errors = errors + 1;
            end
            if (gotB !== wpat) begin
                $display("FAIL (combined) addr=%0d: got=%h expected=%h", a, gotB, wpat);
                errors = errors + 1;
            end
            if (gotA === wpat && gotB === wpat) begin
                $display("PASS addr=%0d: both bit-exact (base=%0d cyc, combined=%0d cyc)", a, elapsedA, elapsedB);
            end
        end
    endtask

    integer seed;
    integer i;
    reg [ADDR_WIDTH-1:0] rnd_addr;

    initial begin
        errors = 0; tests = 0; cyc = 0; seed = 32'hC0DE1234;
        rst_slow = 1; rst_fast = 1;
        reqA = 0; wrA = 0; addrA = 0; wdataA = 0; wmaskA = 0;
        reqB = 0; wrB = 0; addrB = 0; wdataB = 0; wmaskB = 0;
        repeat(10) @(posedge clk_slow);
        repeat(10) @(posedge clk_fast);
        rst_slow = 0; rst_fast = 0;
        @(posedge clk_slow);
        while (busyA || busyB) @(posedge clk_slow);

        $display("=== TEST 1: correctness battery (base vs combined) ===");
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

        $display("=== TEST 2: real measured COMBINED speedup, same-row sequential (real weight-fetch pattern) ===");
        begin : test2
            integer j, N_TILES;
            reg [ADDR_WIDTH-1:0] base_addr, ta;
            reg [16*BURST_LEN-1:0] tw, gA, gB;
            integer eA, eB, totA, totB, t0A, t0B;
            N_TILES = 32;
            base_addr = (200 << (ALIGN_BITS+BANK_BITS));

            for (j = 0; j < N_TILES; j = j + 1) begin
                ta = base_addr + (j << ALIGN_BITS);
                tw = {BURST_LEN{16'(16'h4000 + j)}};
                do_txn_A(1'b1, ta, tw, gA, eA);
                do_txn_B(1'b1, ta, tw, gB, eB);
            end

            @(posedge clk_slow); while (busyA) @(posedge clk_slow);
            t0A = cyc;
            for (j = 0; j < N_TILES; j = j + 1) begin
                ta = base_addr + (j << ALIGN_BITS);
                do_txn_A(1'b0, ta, {(16*BURST_LEN){1'b0}}, gA, eA);
            end
            totA = cyc - t0A;

            @(posedge clk_slow); while (busyB) @(posedge clk_slow);
            t0B = cyc;
            for (j = 0; j < N_TILES; j = j + 1) begin
                ta = base_addr + (j << ALIGN_BITS);
                do_txn_B(1'b0, ta, {(16*BURST_LEN){1'b0}}, gB, eB);
                tests = tests + 1;
                if (gB !== {BURST_LEN{16'(16'h4000 + j)}}) begin
                    $display("FAIL TEST2 tile=%0d: combined got=%h", j, gB);
                    errors = errors + 1;
                end
            end
            totB = cyc - t0B;

            $display("  base     (64MHz, always precharge)         : %0d cycles for %0d sequential same-row reads", totA, N_TILES);
            $display("  combined (64/115.2MHz CDC + page-hit)       : %0d cycles for %0d sequential same-row reads", totB, N_TILES);
            $display("  REAL measured COMBINED speedup              : %0f x", totA * 1.0 / totB);
        end

        $display("=== TEST 3: refresh spanning while row open, ACROSS clock domains (watch for VIOLATION/WARNING) ===");
        begin : test3
            integer j;
            reg [ADDR_WIDTH-1:0] ta;
            reg [16*BURST_LEN-1:0] tw, gB;
            integer eB;
            ta = (500 << (ALIGN_BITS+BANK_BITS));
            for (j = 0; j < 80; j = j + 1) begin
                tw = {BURST_LEN{16'(16'h7000 + j)}};
                do_txn_B(1'b1, ta, tw, gB, eB);
                do_txn_B(1'b0, ta, {(16*BURST_LEN){1'b0}}, gB, eB);
                tests = tests + 1;
                if (gB !== tw) begin
                    $display("FAIL TEST3 iter=%0d: got=%h expected=%h", j, gB, tw);
                    errors = errors + 1;
                end
            end
            $display("  TEST3: 80 same-row write/read pairs completed spanning real tREFI, across clock domains");
        end

        $display("=== %0d/%0d tests, %0d errors ===", tests-errors, tests, errors);
        if (errors == 0) $display("ALL TESTS PASSED (tb_sdram_cdc_bridge_openrow)");
        $finish;
    end
endmodule
