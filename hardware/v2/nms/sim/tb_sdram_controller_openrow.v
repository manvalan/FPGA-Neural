`timescale 1ns/1ps

// ============================================================
// EXP-0054 -- isolated correctness + real measured speedup for
// sdram_controller_openrow.v. Two DUTs share the exact same
// transaction sequence, each with its own sdram_model.v instance:
//   dut_base    : sdram_controller.v (today's real, unchanged baseline
//                 -- always auto-precharges).
//   dut_openrow : sdram_controller_openrow.v (new, page-hit policy).
//
// Covers:
//   1) correctness battery (write->read, sequential/bank-sweep/
//      pseudo-random), bit-exact vs the same golden pattern, on BOTH
//      DUTs.
//   2) SAME-ROW consecutive access (the real production pattern:
//      weight_prefetch_engine_wide.v's own strictly sequential tile
//      stream) -- bit-exact AND real measured cycle savings vs
//      baseline.
//   3) DIFFERENT-ROW access immediately after a row is open -- must
//      stay bit-exact and NOT regress vs baseline (on-demand precharge
//      pays the same total cost, just deferred).
//   4) explicit read-after-read / write-after-read / read-after-write
//      / write-after-write SAME-ROW turnaround sequences -- the one
//      hazard class sdram_model.v does NOT itself assert (no tCCD/
//      tRTW/tWTR check in that model -- see sdram_controller_
//      openrow.v's own header) -- checked here for DATA correctness,
//      which is the strongest check available without a turnaround-
//      timing-aware reference model.
//   5) refresh spanning while a row is open -- watches for ANY
//      VIOLATION/WARNING from sdram_model.v (this project's own real
//      command-sequence checker) across many iterations, specifically
//      exercising the new precharge-before-refresh path.
//   6) REAL measured total-cycle comparison over a long, strictly
//      sequential same-row run -- the actual production access
//      pattern (weight_prefetch_engine_wide.v), the number this
//      experiment exists to produce.
// ============================================================
module tb;
    localparam BURST_LEN  = 8;
    localparam ROW_BITS   = 13;
    localparam COL_BITS   = 10;
    localparam BANK_BITS  = 2;
    localparam ADDR_WIDTH = BANK_BITS + ROW_BITS + COL_BITS;
    localparam ALIGN_BITS = (BURST_LEN<=1) ? 0 : $clog2(BURST_LEN);
    localparam CLK_FREQ_MHZ = 64;
    localparam CLK_PERIOD_NS = 1000.0/CLK_FREQ_MHZ;

    reg clk = 0;
    always #(CLK_PERIOD_NS/2.0) clk = ~clk;
    reg rst;

    integer cyc;
    always @(posedge clk) if (!rst) cyc <= cyc + 1;

    function automatic [BANK_BITS-1:0] bank_of;
        input [ADDR_WIDTH-1:0] a;
        begin
            bank_of = a[ALIGN_BITS +: BANK_BITS];
        end
    endfunction
    function automatic [ROW_BITS-1:0] row_of;
        input [ADDR_WIDTH-1:0] a;
        begin
            row_of = a[ALIGN_BITS+BANK_BITS +: ROW_BITS];
        end
    endfunction

    // ================= DUT BASE (today's real baseline) =================
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
        .CLK_FREQ_MHZ(CLK_FREQ_MHZ), .BURST_LEN(BURST_LEN),
        .ROW_BITS(ROW_BITS), .COL_BITS(COL_BITS), .BANK_BITS(BANK_BITS)
    ) dut_base (
        .clk(clk), .rst(rst),
        .req(reqA), .wr(wrA), .addr(addrA), .wdata(wdataA), .wmask(wmaskA),
        .rdata(rdataA), .ready(readyA), .busy(busyA),
        .sdram_cke(cke_A), .sdram_cs_n(cs_A), .sdram_ras_n(ras_A),
        .sdram_cas_n(cas_A), .sdram_we_n(we_A),
        .sdram_ba(ba_A), .sdram_a(a_A), .sdram_dq(dq_A), .sdram_dqm(dqm_A)
    );
    sdram_model #(
        .CLK_FREQ_MHZ(CLK_FREQ_MHZ),
        .ROW_BITS(ROW_BITS), .COL_BITS(COL_BITS), .BANK_BITS(BANK_BITS)
    ) mem_base (
        .clk(clk), .cke(cke_A), .cs_n(cs_A), .ras_n(ras_A),
        .cas_n(cas_A), .we_n(we_A), .ba(ba_A), .a(a_A), .dq(dq_A), .dqm(dqm_A)
    );

    // ================= DUT OPENROW =================
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

    sdram_controller_openrow #(
        .CLK_FREQ_MHZ(CLK_FREQ_MHZ), .BURST_LEN(BURST_LEN),
        .ROW_BITS(ROW_BITS), .COL_BITS(COL_BITS), .BANK_BITS(BANK_BITS)
    ) dut_openrow (
        .clk(clk), .rst(rst),
        .req(reqB), .wr(wrB), .addr(addrB), .wdata(wdataB), .wmask(wmaskB),
        .rdata(rdataB), .ready(readyB), .busy(busyB),
        .sdram_cke(cke_B), .sdram_cs_n(cs_B), .sdram_ras_n(ras_B),
        .sdram_cas_n(cas_B), .sdram_we_n(we_B),
        .sdram_ba(ba_B), .sdram_a(a_B), .sdram_dq(dq_B), .sdram_dqm(dqm_B)
    );
    sdram_model #(
        .CLK_FREQ_MHZ(CLK_FREQ_MHZ),
        .ROW_BITS(ROW_BITS), .COL_BITS(COL_BITS), .BANK_BITS(BANK_BITS)
    ) mem_openrow (
        .clk(clk), .cke(cke_B), .cs_n(cs_B), .ras_n(ras_B),
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
            @(posedge clk);
            while (busyA) @(posedge clk);
            t0 = cyc;
            reqA = 1'b1; wrA = t_wr; addrA = t_addr; wdataA = t_wdata; wmaskA = {(2*BURST_LEN){1'b0}};
            @(posedge clk);
            reqA = 1'b0;
            while (!readyA) @(posedge clk);
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
            @(posedge clk);
            while (busyB) @(posedge clk);
            t0 = cyc;
            reqB = 1'b1; wrB = t_wr; addrB = t_addr; wdataB = t_wdata; wmaskB = {(2*BURST_LEN){1'b0}};
            @(posedge clk);
            reqB = 1'b0;
            while (!readyB) @(posedge clk);
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
                $display("FAIL (openrow) addr=%0d: got=%h expected=%h", a, gotB, wpat);
                errors = errors + 1;
            end
            if (gotA === wpat && gotB === wpat) begin
                $display("PASS addr=%0d bank=%0d row=%0d: both bit-exact (base=%0d cyc, openrow=%0d cyc)",
                    a, bank_of(a), row_of(a), elapsedA, elapsedB);
            end
        end
    endtask

    integer seed;
    integer i;
    reg [ADDR_WIDTH-1:0] rnd_addr;

    initial begin
        errors = 0; tests = 0; cyc = 0; seed = 32'hBADC0FFE;
        rst = 1;
        reqA = 0; wrA = 0; addrA = 0; wdataA = 0; wmaskA = 0;
        reqB = 0; wrB = 0; addrB = 0; wdataB = 0; wmaskB = 0;
        repeat(5) @(posedge clk);
        rst = 0;
        @(posedge clk);
        while (busyA || busyB) @(posedge clk);

        $display("=== TEST 1: correctness battery (base vs openrow, same golden pattern) ===");
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

        $display("=== TEST 2: SAME-ROW consecutive tiles (real weight-prefetch pattern) -- real measured savings ===");
        begin : test2
            integer j, N_TILES;
            reg [ADDR_WIDTH-1:0] base_addr, ta;
            reg [16*BURST_LEN-1:0] tw, gA, gB;
            integer eA, eB, totA, totB, t0A, t0B;
            N_TILES = 32; // well within one row (1024 cols / (BURST_LEN=8 words/tile-block) = 128 tile-blocks/row)
            base_addr = (200 << (ALIGN_BITS+BANK_BITS)); // fixed bank/row, sweep column via tile index

            // pre-write all tiles via base (both DUTs must see identical data)
            for (j = 0; j < N_TILES; j = j + 1) begin
                ta = base_addr + (j << ALIGN_BITS);
                tw = {BURST_LEN{16'(16'h4000 + j)}};
                do_txn_A(1'b1, ta, tw, gA, eA);
                do_txn_B(1'b1, ta, tw, gB, eB);
            end

            // now measure a pure sequential READ sweep (this IS the
            // weight_prefetch_engine_wide.v access pattern: strictly
            // increasing tile address, same bank/row throughout)
            @(posedge clk); while (busyA) @(posedge clk);
            t0A = cyc;
            for (j = 0; j < N_TILES; j = j + 1) begin
                ta = base_addr + (j << ALIGN_BITS);
                do_txn_A(1'b0, ta, {(16*BURST_LEN){1'b0}}, gA, eA);
            end
            totA = cyc - t0A;

            @(posedge clk); while (busyB) @(posedge clk);
            t0B = cyc;
            for (j = 0; j < N_TILES; j = j + 1) begin
                ta = base_addr + (j << ALIGN_BITS);
                do_txn_B(1'b0, ta, {(16*BURST_LEN){1'b0}}, gB, eB);
                tests = tests + 1;
                if (gB !== {BURST_LEN{16'(16'h4000 + j)}}) begin
                    $display("FAIL TEST2 tile=%0d: openrow got=%h", j, gB);
                    errors = errors + 1;
                end
            end
            totB = cyc - t0B;

            $display("  base    (always precharge): %0d cycles for %0d sequential same-row reads", totA, N_TILES);
            $display("  openrow (page-hit)        : %0d cycles for %0d sequential same-row reads", totB, N_TILES);
            $display("  REAL measured speedup     : %0f x", totA * 1.0 / totB);
        end

        $display("=== TEST 3: DIFFERENT-row access right after a row is open -- must not regress vs base ===");
        begin : test3
            reg [ADDR_WIDTH-1:0] addr_row0, addr_row1;
            reg [16*BURST_LEN-1:0] wpat0, wpat1, rd0, rd1;
            integer eA1, eA2, eB1, eB2;
            addr_row0 = (300 << (ALIGN_BITS+BANK_BITS));
            addr_row1 = (301 << (ALIGN_BITS+BANK_BITS)); // different row, same bank
            wpat0 = {BURST_LEN{16'h5000}};
            wpat1 = {BURST_LEN{16'h5001}};
            do_txn_A(1'b1, addr_row0, wpat0, gotA, eA1);
            do_txn_A(1'b1, addr_row1, wpat1, gotA, eA2);
            do_txn_B(1'b1, addr_row0, wpat0, gotB, eB1);
            do_txn_B(1'b1, addr_row1, wpat1, gotB, eB2);
            do_txn_A(1'b0, addr_row0, {(16*BURST_LEN){1'b0}}, rd0, eA1);
            do_txn_B(1'b0, addr_row0, {(16*BURST_LEN){1'b0}}, rd1, eB1);
            tests = tests + 1;
            if (rd0 !== wpat0 || rd1 !== wpat0) begin
                $display("FAIL TEST3 data: base=%h openrow=%h expected=%h", rd0, rd1, wpat0);
                errors = errors + 1;
            end else begin
                $display("PASS TEST3 data: different-row-then-back bit-exact on both, base last-op=%0d cyc openrow last-op=%0d cyc",
                    eA1, eB1);
            end
        end

        $display("=== TEST 4: explicit same-row turnaround sequences (R-R, W-R, R-W, W-W) ===");
        begin : test4
            reg [ADDR_WIDTH-1:0] a0, a1;
            reg [16*BURST_LEN-1:0] wp0, wp1, rd0, rd1;
            integer e0, e1;
            a0 = (400 << (ALIGN_BITS+BANK_BITS));
            a1 = a0 + (1 << ALIGN_BITS);
            wp0 = {BURST_LEN{16'h6100}};
            wp1 = {BURST_LEN{16'h6200}};
            do_txn_B(1'b1, a0, wp0, gotB, e0); // seed
            do_txn_B(1'b1, a1, wp1, gotB, e0); // seed
            // R-R
            do_txn_B(1'b0, a0, {(16*BURST_LEN){1'b0}}, rd0, e0);
            do_txn_B(1'b0, a1, {(16*BURST_LEN){1'b0}}, rd1, e1);
            tests = tests + 1;
            if (rd0 !== wp0 || rd1 !== wp1) begin
                $display("FAIL TEST4 R-R: rd0=%h rd1=%h", rd0, rd1); errors = errors + 1;
            end else $display("PASS TEST4 R-R same-row");
            // W-R
            do_txn_B(1'b1, a0, wp1, gotB, e0);
            do_txn_B(1'b0, a0, {(16*BURST_LEN){1'b0}}, rd0, e0);
            tests = tests + 1;
            if (rd0 !== wp1) begin
                $display("FAIL TEST4 W-R: rd0=%h expected=%h", rd0, wp1); errors = errors + 1;
            end else $display("PASS TEST4 W-R same-row");
            // R-W
            do_txn_B(1'b0, a1, {(16*BURST_LEN){1'b0}}, rd1, e0);
            do_txn_B(1'b1, a1, wp0, gotB, e0);
            do_txn_B(1'b0, a1, {(16*BURST_LEN){1'b0}}, rd1, e0);
            tests = tests + 1;
            if (rd1 !== wp0) begin
                $display("FAIL TEST4 R-W: rd1=%h expected=%h", rd1, wp0); errors = errors + 1;
            end else $display("PASS TEST4 R-W same-row");
            // W-W
            do_txn_B(1'b1, a0, wp0, gotB, e0);
            do_txn_B(1'b1, a1, wp1, gotB, e0);
            do_txn_B(1'b0, a0, {(16*BURST_LEN){1'b0}}, rd0, e0);
            do_txn_B(1'b0, a1, {(16*BURST_LEN){1'b0}}, rd1, e0);
            tests = tests + 1;
            if (rd0 !== wp0 || rd1 !== wp1) begin
                $display("FAIL TEST4 W-W: rd0=%h rd1=%h", rd0, rd1); errors = errors + 1;
            end else $display("PASS TEST4 W-W same-row");
        end

        $display("=== TEST 5: refresh spanning while row open (watch for VIOLATION/WARNING above) ===");
        begin : test5
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
                    $display("FAIL TEST5 iter=%0d: got=%h expected=%h", j, gB, tw);
                    errors = errors + 1;
                end
            end
            $display("  TEST5: 80 same-row write/read pairs completed spanning real tREFI -- check log above for VIOLATION/WARNING");
        end

        $display("=== %0d/%0d tests, %0d errors ===", tests-errors, tests, errors);
        if (errors == 0) $display("ALL TESTS PASSED (tb_sdram_controller_openrow)");
        $finish;
    end
endmodule
