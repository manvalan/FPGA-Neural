`timescale 1ns/1ps

// ============================================================
// EXP-0057 -- real-RTL version of tb_layer_reuse_vs_zero_reuse.v's
// own prefetch_layer task: layer_prefetch_ctrl.v (real synthesizable
// FSM) driving layer_weight_buffer.v through the real sdram_
// controller_openrow.v + sdram_model.v. Same golden pattern, same
// L=16 layers, verifies bit-exact AND reports real cycles/layer for
// direct comparison against the task-based measurement (3777 cycles
// / 16 layers = ~236 cycles/layer average) already logged in
// experiments.log EXP-0057.
// ============================================================
module tb;
    localparam BURST_LEN  = 8;
    localparam ROW_BITS   = 13;
    localparam COL_BITS   = 10;
    localparam BANK_BITS  = 2;
    localparam ADDR_WIDTH = BANK_BITS + ROW_BITS + COL_BITS;
    localparam CLK_FREQ_MHZ = 64;
    localparam CLK_PERIOD_NS = 1000.0/CLK_FREQ_MHZ;

    localparam LAYER_BYTES = 128;
    localparam L = 16;
    localparam WORDS_PER_LAYER = LAYER_BYTES/2;

    reg clk = 0;
    always #(CLK_PERIOD_NS/2.0) clk = ~clk;
    reg rst;

    integer cyc;
    always @(posedge clk) if (!rst) cyc <= cyc + 1;

    // ---- real SDRAM controller + model ----
    wire                    ctrl_req, ctrl_wr;
    wire [ADDR_WIDTH-1:0]   ctrl_addr;
    wire [16*BURST_LEN-1:0] ctrl_wdata;
    wire [2*BURST_LEN-1:0]  ctrl_wmask;
    wire [16*BURST_LEN-1:0] ctrl_rdata;
    wire ctrl_ready, ctrl_busy;
    wire cke, cs_n, ras_n, cas_n, we_n;
    wire [BANK_BITS-1:0] ba;
    wire [ROW_BITS-1:0] a;
    wire [15:0] dq;
    wire [1:0] dqm;

    sdram_controller_openrow #(
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

    // separate write-capable path to preload SDRAM (reuse the same
    // controller -- write and prefetch never run concurrently here)
    reg  wpre_req, wpre_wr;
    reg  [ADDR_WIDTH-1:0] wpre_addr;
    reg  [16*BURST_LEN-1:0] wpre_wdata;
    reg  pre_active;

    task automatic sdram_write_burst(input [ADDR_WIDTH-1:0] word_addr, input [16*BURST_LEN-1:0] data);
        begin
            @(posedge clk); while (ctrl_busy) @(posedge clk);
            wpre_req = 1'b1; wpre_wr = 1'b1; wpre_addr = word_addr; wpre_wdata = data;
            @(posedge clk); wpre_req = 1'b0;
            while (!ctrl_ready) @(posedge clk);
        end
    endtask

    task automatic preload_sdram_layers;
        integer li, bi, wb;
        reg [16*BURST_LEN-1:0] burst_data;
        begin
            for (li = 0; li < L; li = li + 1) begin
                for (bi = 0; bi < (LAYER_BYTES/(2*BURST_LEN)); bi = bi + 1) begin
                    for (wb = 0; wb < BURST_LEN; wb = wb + 1)
                        burst_data[wb*16 +: 16] = {8'(8'h20+li), 8'(bi*BURST_LEN+wb)};
                    sdram_write_burst((li*WORDS_PER_LAYER + bi*BURST_LEN), burst_data);
                end
            end
        end
    endtask

    // ---- layer_prefetch_ctrl.v (real RTL under test) ----
    wire pf_ctrl_req, pf_ctrl_wr;
    wire [ADDR_WIDTH-1:0] pf_ctrl_addr;
    wire [16*BURST_LEN-1:0] pf_ctrl_wdata;
    wire [2*BURST_LEN-1:0]  pf_ctrl_wmask;

    // moved here (below the pf_ctrl_* declarations above) -- iverilog's
    // current elaboration requires a continuous assign's RHS names to be
    // declared earlier in the module than the assign itself, which the
    // original position (right after wpre_*/pre_active, before pf_ctrl_*
    // existed textually) violated; found while re-verifying this file for
    // EXP-0058, see this file's own note by pre_active's assignment below.
    assign ctrl_req   = pre_active ? wpre_req   : pf_ctrl_req;
    assign ctrl_wr    = pre_active ? wpre_wr    : pf_ctrl_wr;
    assign ctrl_addr  = pre_active ? wpre_addr  : pf_ctrl_addr;
    assign ctrl_wdata = pre_active ? wpre_wdata : pf_ctrl_wdata;
    assign ctrl_wmask = pre_active ? {(2*BURST_LEN){1'b0}} : pf_ctrl_wmask;

    reg  pf_start;
    reg  [ADDR_WIDTH-1:0] pf_layer_base;
    wire pf_busy, pf_done;
    wire pf_fill_we;
    wire [$clog2(LAYER_BYTES)-1:0] pf_fill_addr;
    wire [7:0] pf_fill_data;

    layer_prefetch_ctrl #(
        .DATA_WIDTH(8), .LAYER_BYTES(LAYER_BYTES), .BURST_LEN(BURST_LEN), .ADDR_WIDTH(ADDR_WIDTH)
    ) u_pf (
        .clk(clk), .rst(rst),
        .start(pf_start), .layer_base(pf_layer_base), .busy(pf_busy), .done(pf_done),
        .fill_we(pf_fill_we), .fill_addr(pf_fill_addr), .fill_data(pf_fill_data),
        .ctrl_req(pf_ctrl_req), .ctrl_wr(pf_ctrl_wr), .ctrl_addr(pf_ctrl_addr),
        .ctrl_wdata(pf_ctrl_wdata), .ctrl_wmask(pf_ctrl_wmask),
        .ctrl_rdata(ctrl_rdata), .ctrl_ready(ctrl_ready), .ctrl_busy(ctrl_busy)
    );

    // ---- layer_weight_buffer.v ----
    reg  [$clog2(LAYER_BYTES)-1:0] rd_addr;
    wire [7:0] rd_data;
    reg  consume_done;
    wire active_sel, swapped;

    layer_weight_buffer #(.DATA_WIDTH(8), .LAYER_DEPTH(LAYER_BYTES)) u_lwb (
        .clk(clk), .rst(rst),
        .fill_we(pf_fill_we), .fill_addr(pf_fill_addr), .fill_data(pf_fill_data), .fill_done(pf_done),
        .rd_addr(rd_addr), .rd_data(rd_data), .consume_done(consume_done),
        .active_sel(active_sel), .swapped(swapped)
    );

    integer errors, tests, li_i, t0, total_cycles;
    reg [7:0] expected;
    integer r, k;

    initial begin
        errors = 0; tests = 0; cyc = 0;
        rst = 1; pre_active = 1'b1;
        wpre_req = 0; wpre_wr = 0; wpre_addr = 0; wpre_wdata = 0;
        pf_start = 0; pf_layer_base = 0; rd_addr = 0; consume_done = 0;
        repeat(5) @(posedge clk);
        rst = 0;
        @(posedge clk); while (ctrl_busy) @(posedge clk);

        $display("=== preload SDRAM with %0d distinct layer patterns ===", L);
        preload_sdram_layers;
        @(posedge clk); // ERR-0001 workaround: sync before the first blocking
                         // assignment following a time-consuming task call --
                         // without this, pre_active's switchover was not
                         // reliably visible to the ctrl_* mux at the next
                         // clock edge, so layer_prefetch_ctrl.v's own
                         // ctrl_req never actually reached the real SDRAM
                         // controller and this whole test hung on "while
                         // (!pf_done)" forever instead of ever producing a
                         // result (found while integrating this module into
                         // tb_neural_processor_layer_reuse.v, EXP-0058 --
                         // this file's own real-hardware run had never
                         // actually completed before that).
        pre_active = 1'b0; // hand control to layer_prefetch_ctrl.v

        // NOTE: sequential (no prefetch/consume overlap) -- this test
        // exists to confirm layer_prefetch_ctrl.v (real RTL) correctly
        // composes with layer_weight_buffer.v end-to-end, data-wise.
        // The real DOUBLE-BUFFERED (overlapped) performance benefit
        // (7.16x) was already measured and verified separately via
        // tb_layer_reuse_vs_zero_reuse.v's own task-based driver,
        // which does not have this testbench's own fork/join
        // complexity -- not re-derived here to avoid re-debugging
        // testbench-only concurrency timing a second time for no new
        // information.
        $display("=== real-RTL prefetch + reuse, %0d layers, sequential (correctness only) ===", L);
        t0 = cyc;
        pf_layer_base = 0; pf_start = 1'b1; @(posedge clk); #1; pf_start = 1'b0;
        while (!pf_done) @(posedge clk);
        // Clock-edge-adjacent pulse idiom, hardened: setting a pulse then
        // clearing it on the VERY NEXT @(posedge clk) puts the clear in the
        // SAME active-region pass as the edge where a receiving module's own
        // synchronous always block reads it -- their relative execution
        // order at that shared edge is implementation-defined (Icarus does
        // not guarantee testbench-thread-vs-DUT-always-block ordering), so
        // the clear can occasionally run before the DUT's read and the pulse
        // is silently missed (found via direct $strobe tracing while
        // integrating this module for EXP-0058 -- layer_weight_buffer.v's
        // own consume_done_latched stayed 0 even though this exact sequence
        // visibly drove consume_done=1 for a full clock period). Fixed by
        // holding the pulse past the edge with a real time delay (#1) before
        // clearing, so the clear unambiguously lands in a later time step
        // than every process that reacted to the edge.
        consume_done = 1'b1; @(posedge clk); #1; consume_done = 1'b0; // initial swap
        @(posedge clk); #1;

        for (li_i = 0; li_i < L; li_i = li_i + 1) begin
            for (r = 0; r < 4; r = r + 1) begin
                for (k = 0; k < LAYER_BYTES; k = k + 1) begin
                    rd_addr = k[$clog2(LAYER_BYTES)-1:0];
                    #1;
                    tests = tests + 1;
                    if (k[0] == 1'b0) expected = {1'b0, k[7:1]};
                    else               expected = 8'(8'h20+li_i);
                    if (rd_data !== expected) begin
                        $display("FAIL layer=%0d reuse=%0d k=%0d: expected %h got %h", li_i, r, k, expected, rd_data);
                        errors = errors + 1;
                    end
                    @(posedge clk);
                end
            end
            consume_done = 1'b1; @(posedge clk); #1; consume_done = 1'b0; // same pulse-hardening as the initial swap above

            if (li_i+1 < L) begin
                pf_layer_base = (li_i+1)*WORDS_PER_LAYER;
                pf_start = 1'b1; @(posedge clk); #1; pf_start = 1'b0;
                while (!pf_done) @(posedge clk);
            end
            @(posedge clk); #1; // let the swap settle before the next iteration reads
        end
        total_cycles = cyc - t0;

        $display("=== RESULT: %0d/%0d bit-exact, %0d errors, %0d total cycles for %0d layers (real RTL prefetch controller) ===",
            tests-errors, tests, errors, total_cycles, L);
        if (errors == 0) $display("ALL TESTS PASSED (tb_layer_prefetch_ctrl)");
        $finish;
    end
endmodule
