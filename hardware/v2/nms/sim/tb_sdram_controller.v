`timescale 1ns/1ps

// ============================================================
// NMS STEP16 Phase 3 -- isolated correctness regression for
// sdram_controller.v against the real-timing-checked sdram_model.v.
//
// Covers all nine required scenarios:
//   A) write -> read, single word
//   B) sequential addresses (many consecutive tiles)
//   C/D) burst length 4 / 8 (parametrized, compiled separately)
//   E) row change (same bank, different row)
//   F) bank change (different bank)
//   G) refresh during activity (long-running test forces >=1 real
//      periodic AUTO REFRESH to interleave with real transactions)
//   H) pseudo-random address pattern
//   I) addresses at the memory's own limits (row 0/4095, bank 0/3,
//      col 0/(BURST_LEN-aligned near 255))
// ============================================================
module tb #(
    parameter BURST_LEN = 4,
    parameter CLK_FREQ_MHZ = 166
);
    localparam ADDR_WIDTH = 22;
    localparam CLK_PERIOD_NS = 1000.0/CLK_FREQ_MHZ;

    reg clk = 0;
    always #(CLK_PERIOD_NS/2.0) clk = ~clk;
    reg rst;

    reg req, wr;
    reg [ADDR_WIDTH-1:0] addr;
    reg [16*BURST_LEN-1:0] wdata;
    reg [2*BURST_LEN-1:0] wmask;
    wire [16*BURST_LEN-1:0] rdata;
    wire ready, busy;

    wire sdram_cke, sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n;
    wire [1:0] sdram_ba;
    wire [11:0] sdram_a;
    wire [15:0] sdram_dq;
    wire [1:0] sdram_dqm;

    sdram_controller #(.CLK_FREQ_MHZ(CLK_FREQ_MHZ), .BURST_LEN(BURST_LEN), .ADDR_WIDTH(ADDR_WIDTH)) dut (
        .clk(clk), .rst(rst),
        .req(req), .wr(wr), .addr(addr), .wdata(wdata), .wmask(wmask), .rdata(rdata), .ready(ready), .busy(busy),
        .sdram_cke(sdram_cke), .sdram_cs_n(sdram_cs_n), .sdram_ras_n(sdram_ras_n),
        .sdram_cas_n(sdram_cas_n), .sdram_we_n(sdram_we_n),
        .sdram_ba(sdram_ba), .sdram_a(sdram_a), .sdram_dq(sdram_dq), .sdram_dqm(sdram_dqm)
    );

    sdram_model #(.CLK_FREQ_MHZ(CLK_FREQ_MHZ)) mem (
        .clk(clk), .cke(sdram_cke), .cs_n(sdram_cs_n), .ras_n(sdram_ras_n),
        .cas_n(sdram_cas_n), .we_n(sdram_we_n), .ba(sdram_ba), .a(sdram_a),
        .dq(sdram_dq), .dqm(sdram_dqm)
    );

    integer errors, tests;
    integer cyc;
    always @(posedge clk) if (!rst) cyc <= cyc + 1;
    reg trace_on;
    reg [4:0] state_prev;
    always @(posedge clk) begin
        if (trace_on && dut.state !== state_prev)
            $display("  [%0d] state->%0d busy=%0d ready=%0d req=%0d burst_idx=%0d",
                cyc, dut.state, busy, ready, req, dut.burst_idx);
        state_prev <= dut.state;
    end

    // one full burst transaction: issue req, wait for ready, return
    // elapsed cycles and rdata via output args (Verilog tasks use
    // output ports for this)
    task automatic do_transaction(
        input                    t_wr,
        input [ADDR_WIDTH-1:0]   t_addr,
        input [16*BURST_LEN-1:0] t_wdata,
        output [16*BURST_LEN-1:0] t_rdata,
        output integer            t_cycles
    );
        integer t0;
        begin
            @(posedge clk);
            while (busy) @(posedge clk);
            t0 = cyc;
            req = 1'b1; wr = t_wr; addr = t_addr; wdata = t_wdata;
            @(posedge clk);
            req = 1'b0;
            while (!ready) @(posedge clk);
            t_rdata = rdata;
            t_cycles = cyc - t0;
        end
    endtask

    reg [16*BURST_LEN-1:0] got, expect_pattern;
    integer elapsed;

    task automatic check_word(input [ADDR_WIDTH-1:0] a, input [15:0] pattern);
        reg [16*BURST_LEN-1:0] wpat;
        integer k;
        begin
            for (k = 0; k < BURST_LEN; k = k + 1)
                wpat[k*16 +: 16] = pattern + k[15:0];
            do_transaction(1'b1, a, wpat, got, elapsed);
            do_transaction(1'b0, a, {(16*BURST_LEN){1'b0}}, got, elapsed);
            tests = tests + 1;
            if (got !== wpat) begin
                $display("FAIL addr=%0d: got=%h expected=%h", a, got, wpat);
                errors = errors + 1;
            end else begin
                $display("PASS addr=%0d: burst=%0d bit-exact, cycles=%0d", a, BURST_LEN, elapsed);
            end
        end
    endtask

    integer seed;
    integer i;
    reg [ADDR_WIDTH-1:0] rnd_addr;

    initial begin
        errors = 0; tests = 0; cyc = 0; seed = 32'hC0FFEE;
        rst = 1; req = 0; wr = 0; addr = 0; wdata = 0; wmask = 0; trace_on = 0;
        repeat(5) @(posedge clk);
        rst = 0;
        while (busy) @(posedge clk); // real power-up/init sequence

        // ---- A: write -> read single ----
        check_word(22'd0, 16'hA5A5);

        // ---- B: sequential addresses ----
        trace_on = 1'b1;
        for (i = 0; i < 3; i = i + 1)
            check_word(i*BURST_LEN, 16'h1000 + i);
        trace_on = 1'b0;
        for (i = 3; i < 16; i = i + 1)
            check_word(i*BURST_LEN, 16'h1000 + i);

        // ---- E: row change (same bank 0, different row) ----
        check_word({2'b00, 12'd0,   8'd0}, 16'h2000);
        check_word({2'b00, 12'd1,   8'd0}, 16'h2001);
        check_word({2'b00, 12'd100, 8'd0}, 16'h2002);

        // ---- F: bank change ----
        check_word({2'b00, 12'd5, 8'd0}, 16'h3000);
        check_word({2'b01, 12'd5, 8'd0}, 16'h3001);
        check_word({2'b10, 12'd5, 8'd0}, 16'h3002);
        check_word({2'b11, 12'd5, 8'd0}, 16'h3003);

        // ---- I: address limits ----
        check_word({2'b00, 12'd0,    8'd0}, 16'h4000);              // row 0, col 0
        check_word({2'b11, 12'd4095, 8'(256-BURST_LEN)}, 16'h4001); // max bank/row, last valid burst-aligned col
        check_word({2'b00, 12'd4095, 8'd0}, 16'h4002);
        check_word({2'b11, 12'd0,    8'd0}, 16'h4003);

        // ---- H: pseudo-random pattern ----
        for (i = 0; i < 32; i = i + 1) begin
            rnd_addr = ($random(seed) % (4*4096*256/BURST_LEN)) * BURST_LEN;
            check_word(rnd_addr, 16'h5000 + i);
        end

        // ---- G: refresh during activity -- run enough back-to-back
        // transactions to span well past one real tREFI interval
        // (2605 cycles @166MHz), confirming the controller correctly
        // interleaves periodic AUTO REFRESH with real read/write
        // traffic with zero data loss/corruption ----
        for (i = 0; i < 400; i = i + 1)
            check_word((i*7 % (4*4096*256/BURST_LEN))*BURST_LEN, 16'h6000 + i);

        // ---- J: real DQM byte-write masking (STEP19 -- the single-
        // SDRAM unified memory subsystem needs true byte-addressable
        // writes for result writeback; verify the controller's own
        // per-burst-word wmask correctly masks OUT the bytes it's told
        // to mask (memory retains its old value there) and writes
        // through the bytes it's told to write, for every burst word
        // position, not just word 0 ----
        begin : test_j
            reg [16*BURST_LEN-1:0] full_pat, masked_pat, readback;
            reg [2*BURST_LEN-1:0]  m;
            integer w, elapsed_j;
            reg [ADDR_WIDTH-1:0] addr_j;
            addr_j = 22'd50000;
            // seed a known full pattern first (no masking)
            for (w = 0; w < BURST_LEN; w = w + 1) full_pat[w*16 +: 16] = 16'h7000 + w[15:0];
            wmask = {(2*BURST_LEN){1'b0}};
            do_transaction(1'b1, addr_j, full_pat, got, elapsed);

            // now write a DIFFERENT pattern but mask OUT every other
            // word (odd word indices), so only even words should
            // actually change
            for (w = 0; w < BURST_LEN; w = w + 1) masked_pat[w*16 +: 16] = 16'h8000 + w[15:0];
            m = {(2*BURST_LEN){1'b0}};
            for (w = 1; w < BURST_LEN; w = w + 2) m[w*2 +: 2] = 2'b11; // mask both bytes of odd words
            wmask = m;
            do_transaction(1'b1, addr_j, masked_pat, got, elapsed_j);
            wmask = {(2*BURST_LEN){1'b0}};

            do_transaction(1'b0, addr_j, {(16*BURST_LEN){1'b0}}, readback, elapsed);
            tests = tests + 1;
            begin : check_j
                integer ok; reg [15:0] exp_w, got_w;
                ok = 1;
                for (w = 0; w < BURST_LEN; w = w + 1) begin
                    got_w = readback[w*16 +: 16];
                    exp_w = (w % 2 == 0) ? masked_pat[w*16 +: 16] : full_pat[w*16 +: 16];
                    if (got_w !== exp_w) begin
                        $display("FAIL J-mask word%0d: got=%h expected=%h (masked-write correctness)", w, got_w, exp_w);
                        ok = 0;
                    end
                end
                if (ok) $display("PASS J-mask addr=%0d: byte-masked write bit-exact, cycles=%0d", addr_j, elapsed_j);
                else errors = errors + 1;
            end
        end

        $display("=== %0d/%0d tests, %0d errors (BURST_LEN=%0d, CLK_FREQ_MHZ=%0d) ===",
            tests-errors, tests, errors, BURST_LEN, CLK_FREQ_MHZ);
        if (errors == 0) $display("ALL TESTS PASSED (tb_sdram_controller, BURST_LEN=%0d, CLK_FREQ_MHZ=%0d)", BURST_LEN, CLK_FREQ_MHZ);
        $finish;
    end
endmodule
