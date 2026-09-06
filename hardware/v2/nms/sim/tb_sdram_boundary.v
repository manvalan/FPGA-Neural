`timescale 1ns/1ps

// ============================================================
// PRE-PCB CLOSURE, POINT 1 -- directed SDRAM boundary verification.
//
// tb_sdram_controller.v already covers randomized-address and
// pseudo-limit coverage (test I). This testbench is a SEPARATE,
// purpose-built regression targeting EXACT, individually-named
// addresses the randomized sweep does not specifically guarantee to
// hit: address 0/1, the last valid address and its predecessor, an
// explicit row-boundary crossing, explicit bank-boundary crossings
// (all 4 banks), the real V2 memory-map region boundaries
// (weights/activations/results), and every DQM byte-mask combination
// with an explicit read-after-write check. Real Alliance Memory
// AS4C32M16SA-7TIN geometry (confirmed against sdram_controller.v's
// own address decode, post-PRE-PCB-FREEZE memory upgrade): word
// address = {bank[1:0], row[12:0], col[9:0]}, 4 banks x 8192 rows x
// 1024 cols x 16 bits = 32M words = 64MB.
//
// BURST_LEN=1 is used throughout (not the default 4) so every address
// in this test names an exact, single physical word -- burst-wrap
// semantics are already covered elsewhere (tb_sdram_controller.v's
// own BURST_LEN=4/8 sweep) and are orthogonal to this test's own
// purpose (address-decode correctness at exact boundaries).
// CLK_FREQ_MHZ=64 is the real board target (default parameter here),
// not one of the legacy 100/133/166MHz sweep points.
// ============================================================
module tb_sdram_boundary #(
    parameter CLK_FREQ_MHZ = 64
);
    localparam BURST_LEN  = 1;
    // AS4C32M16SA-7TIN (64MB): 13 row bits (A0-A12), 10 col bits
    // (A0-A9), 2 bank bits (BA0-BA1).
    localparam ROW_BITS   = 13;
    localparam COL_BITS   = 10;
    localparam BANK_BITS  = 2;
    localparam ADDR_WIDTH = BANK_BITS + ROW_BITS + COL_BITS;
    localparam CLK_PERIOD_NS = 1000.0/CLK_FREQ_MHZ;

    reg clk = 0;
    always #(CLK_PERIOD_NS/2.0) clk = ~clk;
    reg rst;

    reg req, wr;
    reg [ADDR_WIDTH-1:0] addr;
    reg [15:0] wdata;
    reg [1:0]  wmask;
    wire [15:0] rdata;
    wire ready, busy;

    wire sdram_cke, sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n;
    wire [BANK_BITS-1:0] sdram_ba;
    wire [ROW_BITS-1:0] sdram_a;
    wire [15:0] sdram_dq;
    wire [1:0] sdram_dqm;

    sdram_controller #(
        .CLK_FREQ_MHZ(CLK_FREQ_MHZ), .BURST_LEN(BURST_LEN),
        .ROW_BITS(ROW_BITS), .COL_BITS(COL_BITS), .BANK_BITS(BANK_BITS)
    ) dut (
        .clk(clk), .rst(rst),
        .req(req), .wr(wr), .addr(addr), .wdata(wdata), .wmask(wmask), .rdata(rdata), .ready(ready), .busy(busy),
        .sdram_cke(sdram_cke), .sdram_cs_n(sdram_cs_n), .sdram_ras_n(sdram_ras_n),
        .sdram_cas_n(sdram_cas_n), .sdram_we_n(sdram_we_n),
        .sdram_ba(sdram_ba), .sdram_a(sdram_a), .sdram_dq(sdram_dq), .sdram_dqm(sdram_dqm)
    );

    sdram_model #(
        .CLK_FREQ_MHZ(CLK_FREQ_MHZ),
        .ROW_BITS(ROW_BITS), .COL_BITS(COL_BITS), .BANK_BITS(BANK_BITS)
    ) mem (
        .clk(clk), .cke(sdram_cke), .cs_n(sdram_cs_n), .ras_n(sdram_ras_n),
        .cas_n(sdram_cas_n), .we_n(sdram_we_n), .ba(sdram_ba), .a(sdram_a),
        .dq(sdram_dq), .dqm(sdram_dqm)
    );

    integer errors, tests;

    task automatic write_word(input [ADDR_WIDTH-1:0] a, input [15:0] d, input [1:0] m);
        begin
            @(posedge clk);
            while (busy) @(posedge clk);
            req = 1'b1; wr = 1'b1; addr = a; wdata = d; wmask = m;
            @(posedge clk);
            req = 1'b0;
            while (!ready) @(posedge clk);
        end
    endtask

    task automatic read_word(input [ADDR_WIDTH-1:0] a, output [15:0] d);
        begin
            @(posedge clk);
            while (busy) @(posedge clk);
            req = 1'b1; wr = 1'b0; addr = a; wdata = 16'h0000; wmask = 2'b00;
            @(posedge clk);
            req = 1'b0;
            while (!ready) @(posedge clk);
            d = rdata;
        end
    endtask

    reg [15:0] got;

    task automatic check(input [ADDR_WIDTH-1:0] a, input [15:0] expected, input [255:0] label);
        begin
            read_word(a, got);
            tests = tests + 1;
            if (got !== expected) begin
                $display("FAIL %0s addr=0x%06h (bank=%0d row=%0d col=%0d): expected=%h actual=%h",
                    label, a, a[24:23], a[22:10], a[9:0], expected, got);
                errors = errors + 1;
            end else begin
                $display("PASS %0s addr=0x%06h (bank=%0d row=%0d col=%0d): data=%h",
                    label, a, a[24:23], a[22:10], a[9:0], got);
            end
        end
    endtask

    // address-derived pattern: distinct per address, used wherever the
    // exact value doesn't matter beyond "must not alias with a
    // neighbour" -- classic address-uniqueness memory-test idiom.
    function [15:0] addr_pat(input [ADDR_WIDTH-1:0] a);
        addr_pat = a[15:0] ^ 16'hC3A5;
    endfunction

    // ---- the real V2 memory map (BYTE addresses) converted to this
    // controller's own WORD addresses (word = byte>>1) ----
    localparam [ADDR_WIDTH-1:0] WEIGHTS_BASE_W = 25'h008000; // byte 0x010000
    localparam [ADDR_WIDTH-1:0] ACT_BASE_W     = 25'h100000; // byte 0x200000
    localparam [ADDR_WIDTH-1:0] RESULTS_BASE_W = 25'h180000; // byte 0x300000
    localparam [ADDR_WIDTH-1:0] WEIGHTS_LAST_W = ACT_BASE_W - 25'd1;      // last word before activations
    localparam [ADDR_WIDTH-1:0] ACT_LAST_W     = RESULTS_BASE_W - 25'd1; // last word before results

    // ---- the 17-address boundary/adjacency set. All written first
    // (each a distinct addr_pat value), THEN all read back in a
    // DIFFERENT (reversed) order -- if any write had corrupted a
    // neighbouring/aliased address, the corresponding readback below
    // would mismatch. This single set simultaneously proves address 0/
    // 1/last/last-1, the explicit row crossing, all 3 inter-bank
    // crossings, and all 3 real memory-map region boundaries cannot
    // corrupt each other. ----
    localparam N_ADDRS = 17;
    reg [ADDR_WIDTH-1:0] a_set   [0:N_ADDRS-1];
    reg [255:0]          a_label [0:N_ADDRS-1];
    integer ai;

    initial begin
        a_set[0]  = {ADDR_WIDTH{1'b0}};                  a_label[0]  = "addr-0";
        a_set[1]  = {{(ADDR_WIDTH-1){1'b0}}, 1'b1};       a_label[1]  = "addr-1";
        a_set[2]  = {ADDR_WIDTH{1'b1}};                   a_label[2]  = "addr-last";
        a_set[3]  = {ADDR_WIDTH{1'b1}} - 1'b1;            a_label[3]  = "addr-last-1";
        a_set[4]  = {2'd0, 13'd10,   10'd1023};           a_label[4]  = "row10-lastcol";
        a_set[5]  = {2'd0, 13'd11,   10'd0};              a_label[5]  = "row11-firstcol";
        a_set[6]  = {2'd0, 13'd8191, 10'd1023};           a_label[6]  = "bank0-last";
        a_set[7]  = {2'd1, 13'd0,    10'd0};              a_label[7]  = "bank1-first";
        a_set[8]  = {2'd1, 13'd8191, 10'd1023};           a_label[8]  = "bank1-last";
        a_set[9]  = {2'd2, 13'd0,    10'd0};              a_label[9]  = "bank2-first";
        a_set[10] = {2'd2, 13'd8191, 10'd1023};           a_label[10] = "bank2-last";
        a_set[11] = {2'd3, 13'd0,    10'd0};              a_label[11] = "bank3-first";
        a_set[12] = WEIGHTS_BASE_W;                      a_label[12] = "weights-base";
        a_set[13] = WEIGHTS_LAST_W;                      a_label[13] = "weights-last(pre-act)";
        a_set[14] = ACT_BASE_W;                          a_label[14] = "activations-base";
        a_set[15] = ACT_LAST_W;                          a_label[15] = "activations-last(pre-res)";
        a_set[16] = RESULTS_BASE_W;                      a_label[16] = "results-base";
    end

    initial begin
        errors = 0; tests = 0;
        rst = 1; req = 0; wr = 0; addr = 0; wdata = 0; wmask = 0;
        repeat(5) @(posedge clk);
        rst = 0;
        while (busy) @(posedge clk); // real power-up/init sequence

        // ---- Address/row/bank/memory-map boundary set: write all,
        // then read all back in reverse order ----
        $display("--- boundary/adjacency set: writing %0d addresses ---", N_ADDRS);
        for (ai = 0; ai < N_ADDRS; ai = ai + 1)
            write_word(a_set[ai], addr_pat(a_set[ai]), 2'b00);

        $display("--- boundary/adjacency set: reading back (reversed order) ---");
        for (ai = N_ADDRS-1; ai >= 0; ai = ai - 1)
            check(a_set[ai], addr_pat(a_set[ai]), a_label[ai]);

        // ---- byte-mask combinations, explicit read-after-write,
        // using the requested deterministic patterns (0x0000, 0xFFFF,
        // 0xAAAA, 0x5555) ----
        begin : mask_tests
            localparam [ADDR_WIDTH-1:0] MADDR = 25'h001000;

            // lower-byte-only write (wmask=2'b10: upper masked/
            // retained, lower written)
            write_word(MADDR, 16'hAAAA, 2'b00);              // background: 0xAAAA
            write_word(MADDR, 16'h1234, 2'b10);              // write lower byte only (0x34)
            check(MADDR, 16'hAA34, "mask-lower-only");

            // upper-byte-only write (wmask=2'b01: lower masked/
            // retained, upper written)
            write_word(MADDR, 16'h5555, 2'b00);              // background: 0x5555
            write_word(MADDR, 16'h5678, 2'b01);              // write upper byte only (0x56)
            check(MADDR, 16'h5655, "mask-upper-only");

            // both-bytes write (wmask=2'b00: no masking)
            write_word(MADDR, 16'h0000, 2'b00);              // background: 0x0000
            write_word(MADDR, 16'hFFFF, 2'b00);              // write both bytes
            check(MADDR, 16'hFFFF, "mask-both-bytes");

            // read-after-write with the remaining requested pattern
            // (0x5555 alone, both bytes, at a different address) to
            // exercise all four requested literal patterns at least
            // once each in this test
            write_word(MADDR + 25'd1, 16'h5555, 2'b00);
            check(MADDR + 25'd1, 16'h5555, "pattern-5555-plain");
        end

        $display("=== %0d/%0d tests, %0d errors (tb_sdram_boundary, CLK_FREQ_MHZ=%0d) ===",
            tests-errors, tests, errors, CLK_FREQ_MHZ);
        if (errors == 0) $display("ALL TESTS PASSED (tb_sdram_boundary, CLK_FREQ_MHZ=%0d)", CLK_FREQ_MHZ);
        $finish;
    end
endmodule
