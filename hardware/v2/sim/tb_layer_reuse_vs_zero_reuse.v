`timescale 1ns/1ps

// ============================================================
// EXP-0057 -- real measured comparison: weight-stationary layer reuse
// (layer_weight_buffer.v, double-buffered, background-prefetched)
// vs the zero-reuse D-Stress-style pattern (every read is its own
// independent external fetch), BOTH driven through the SAME real,
// already-verified open-row SDR SDRAM controller (sdram_controller_
// openrow.v, EXP-0054) and behavioral chip model (sdram_model.v) --
// no DDR3, no clock change, the exact hardware this project already
// has. Answers directly: does weight reuse alone (no new memory
// hardware) close enough of the gap that DDR3 stops being necessary
// for a workload class that actually has reuse (e.g. a CNN layer),
// as opposed to D-Stress's own deliberately zero-reuse worst case?
//
// SAME total useful-byte-consumption for both cases (fair
// comparison): L=16 "layers" x M=16 reuses x LAYER_DEPTH=128 bytes =
// 32768 total byte-reads -- identical to D-Stress's own 256x128=32768
// total bytes this whole project has been benchmarked against all
// session.
//   REUSE case:      L x LAYER_DEPTH = 2048 bytes actually fetched from
//                     SDRAM (each layer's weights fetched ONCE, reused
//                     M times from the local double buffer).
//   ZERO-REUSE case:  L x M x LAYER_DEPTH = 32768 bytes fetched (every
//                     single read is independent, matching D-Stress).
// ============================================================
module tb;
    localparam BURST_LEN  = 8;
    localparam ROW_BITS   = 13;
    localparam COL_BITS   = 10;
    localparam BANK_BITS  = 2;
    localparam ADDR_WIDTH = BANK_BITS + ROW_BITS + COL_BITS;
    localparam ALIGN_BITS = $clog2(BURST_LEN);
    localparam CLK_FREQ_MHZ = 64;
    localparam CLK_PERIOD_NS = 1000.0/CLK_FREQ_MHZ;

    localparam LAYER_DEPTH = 128; // bytes/layer weight block (matches P_IN*MAX_TILES=8*16 tile convention)
    localparam L = 16;             // number of layers
    localparam M = 16;             // reuses per layer (e.g. spatial positions a filter slides across)
    localparam WORDS_PER_LAYER = LAYER_DEPTH/2; // sdram_controller word=16-bit
    localparam BURSTS_PER_LAYER = LAYER_DEPTH/(2*BURST_LEN); // 16-byte (8-word) transactions per layer

    reg clk = 0;
    always #(CLK_PERIOD_NS/2.0) clk = ~clk;
    reg rst;

    integer cyc;
    always @(posedge clk) if (!rst) cyc <= cyc + 1;

    // ================= shared physical SDRAM (real open-row controller) =================
    reg                    ctrl_req, ctrl_wr;
    reg  [ADDR_WIDTH-1:0]  ctrl_addr;
    reg  [16*BURST_LEN-1:0] ctrl_wdata;
    reg  [2*BURST_LEN-1:0]  ctrl_wmask;
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

    // Pulse-hardening note (found while debugging this exact file,
    // EXP-0058 follow-up): clearing ctrl_req on the very next
    // @(posedge clk) after setting it puts the clear in the SAME
    // active-region pass as the edge sdram_controller_openrow.v's own
    // synchronous `if (req) req_pending <= 1'b1;` latch needs to sample
    // it at -- their relative execution order is implementation-
    // defined, so the one-cycle req pulse can be silently missed
    // (confirmed via direct state/req tracing: the controller sat in
    // S_IDLE with busy=0 forever after the first burst, never latching
    // req_pending for the second). Same class of bug as the
    // consume_done/pf_start races fixed in tb_layer_prefetch_ctrl.v
    // and tb_neural_processor_layer_reuse.v -- fixed the same way, by
    // holding the pulse past the edge with a real time delay (#1)
    // before clearing.
    task automatic sdram_write_burst(input [ADDR_WIDTH-1:0] word_addr, input [16*BURST_LEN-1:0] data);
        begin
            @(posedge clk); while (ctrl_busy) @(posedge clk);
            ctrl_req = 1'b1; ctrl_wr = 1'b1; ctrl_addr = word_addr; ctrl_wdata = data; ctrl_wmask = {(2*BURST_LEN){1'b0}};
            @(posedge clk); #1; ctrl_req = 1'b0;
            while (!ctrl_ready) @(posedge clk);
        end
    endtask
    task automatic sdram_read_burst(input [ADDR_WIDTH-1:0] word_addr, output [16*BURST_LEN-1:0] data);
        begin
            @(posedge clk); while (ctrl_busy) @(posedge clk);
            ctrl_req = 1'b1; ctrl_wr = 1'b0; ctrl_addr = word_addr; ctrl_wmask = {(2*BURST_LEN){1'b0}};
            @(posedge clk); #1; ctrl_req = 1'b0;
            while (!ctrl_ready) @(posedge clk);
            data = ctrl_rdata;
        end
    endtask

    // ================= layer_weight_buffer under test =================
    reg                    fill_we;
    reg  [$clog2(LAYER_DEPTH)-1:0] fill_addr;
    reg  [7:0]             fill_data;
    reg                    fill_done;
    reg  [$clog2(LAYER_DEPTH)-1:0] rd_addr;
    wire [7:0]             rd_data;
    reg                    consume_done;
    wire                   active_sel, swapped;

    layer_weight_buffer #(.DATA_WIDTH(8), .LAYER_DEPTH(LAYER_DEPTH)) u_lwb (
        .clk(clk), .rst(rst),
        .fill_we(fill_we), .fill_addr(fill_addr), .fill_data(fill_data), .fill_done(fill_done),
        .rd_addr(rd_addr), .rd_data(rd_data), .consume_done(consume_done),
        .active_sel(active_sel), .swapped(swapped)
    );

    integer errors, tests;

    // pre-load SDRAM with L distinct layer patterns, at word address layer_idx*WORDS_PER_LAYER
    task automatic preload_sdram_layers;
        integer li, bi;
        reg [16*BURST_LEN-1:0] burst_data;
        integer wb;
        begin
            for (li = 0; li < L; li = li + 1) begin
                for (bi = 0; bi < BURSTS_PER_LAYER; bi = bi + 1) begin
                    for (wb = 0; wb < BURST_LEN; wb = wb + 1)
                        burst_data[wb*16 +: 16] = {8'(8'h20+li), 8'(bi*BURST_LEN+wb)};
                    sdram_write_burst((li*WORDS_PER_LAYER + bi*BURST_LEN), burst_data);
                end
            end
        end
    endtask

    // fetch layer li's weights (bulk sequential, BURSTS_PER_LAYER transactions)
    // into the layer_weight_buffer's inactive side
    task automatic prefetch_layer(input integer li);
        integer bi, wb;
        reg [16*BURST_LEN-1:0] burst_data;
        begin
            for (bi = 0; bi < BURSTS_PER_LAYER; bi = bi + 1) begin
                sdram_read_burst((li*WORDS_PER_LAYER + bi*BURST_LEN), burst_data);
                for (wb = 0; wb < BURST_LEN; wb = wb + 1) begin
                    @(posedge clk);
                    fill_we = 1'b1;
                    fill_addr = (bi*BURST_LEN + wb) & (2*BURST_LEN-1) | (bi*2*BURST_LEN); // byte index within layer
                    fill_addr = bi*(2*BURST_LEN) + wb*2;      // low byte of word wb
                    fill_data = burst_data[wb*16 +: 8];
                    @(posedge clk);
                    fill_addr = bi*(2*BURST_LEN) + wb*2 + 1;  // high byte of word wb
                    fill_data = burst_data[wb*16+8 +: 8];
                end
            end
            @(posedge clk); fill_we = 1'b0;
            fill_done = 1'b1; @(posedge clk); #1; fill_done = 1'b0;
        end
    endtask

    task automatic consume_layer_check(input integer li, input integer errors_before, output integer errors_after);
        integer r, k;
        reg [7:0] expected;
        begin
            errors_after = errors_before;
            for (r = 0; r < M; r = r + 1) begin
                for (k = 0; k < LAYER_DEPTH; k = k + 1) begin
                    rd_addr = k[$clog2(LAYER_DEPTH)-1:0];
                    #1;
                    tests = tests + 1;
                    expected = 8'(8'h20+li) ; // high byte of the 16-bit word pattern for even k, low byte pattern for odd k -- see preload
                    // preload packed {8'h20+li, byte_idx} per WORD (16-bit): low byte = byte_idx, high byte = 8'h20+li
                    if (k[0] == 1'b0) expected = {1'b0, k[7:1]}; // low byte of word = WORD index (bi*BURST_LEN+wb), i.e. k/2 -- see preload_sdram_layers
                    else               expected = 8'(8'h20+li);  // high byte of word = layer tag
                    if (rd_data !== expected) begin
                        $display("FAIL layer=%0d reuse=%0d k=%0d: expected %h got %h", li, r, k, expected, rd_data);
                        errors_after = errors_after + 1;
                    end
                    @(posedge clk);
                end
            end
            consume_done = 1'b1; @(posedge clk); #1; consume_done = 1'b0;
        end
    endtask

    integer li_i;
    integer t0, total_cycles_reuse, total_cycles_zeroreuse;

    // zero-reuse baseline: L*M independent reads, each LAYER_DEPTH bytes,
    // NO local buffering -- every single "reuse" goes straight to SDRAM,
    // matching D-Stress's own access pattern exactly (through the SAME
    // real open-row controller).
    task automatic zero_reuse_baseline;
        integer li, r, bi;
        reg [16*BURST_LEN-1:0] junk;
        begin
            for (li = 0; li < L; li = li + 1) begin
                for (r = 0; r < M; r = r + 1) begin
                    for (bi = 0; bi < BURSTS_PER_LAYER; bi = bi + 1) begin
                        sdram_read_burst((li*WORDS_PER_LAYER + bi*BURST_LEN), junk);
                    end
                end
            end
        end
    endtask

    initial begin
        errors = 0; tests = 0; cyc = 0;
        rst = 1; ctrl_req = 0; ctrl_wr = 0; ctrl_addr = 0; ctrl_wdata = 0; ctrl_wmask = 0;
        fill_we = 0; fill_addr = 0; fill_data = 0; fill_done = 0; rd_addr = 0; consume_done = 0;
        repeat(5) @(posedge clk);
        rst = 0;
        @(posedge clk); while (ctrl_busy) @(posedge clk);

        $display("=== preload SDRAM with %0d distinct layer patterns ===", L);
        preload_sdram_layers;

        $display("=== REUSE case correctness pass: %0d layers x %0d reuses, double-buffered background prefetch (data check only, not timed) ===", L, M);
        prefetch_layer(0);
        consume_done = 1'b1; @(posedge clk); #1; consume_done = 1'b0; // trigger initial swap
        for (li_i = 0; li_i < L; li_i = li_i + 1) begin
            fork
                consume_layer_check(li_i, errors, errors);
                begin
                    if (li_i+1 < L) prefetch_layer(li_i+1);
                end
            join
        end
        $display("  correctness: %0d/%0d, %0d errors", tests-errors, tests, errors);

        // ---- FAIR timing comparison: measure ONLY the real SDRAM
        // fetch cost in each case (the actual question this benchmark
        // exists to answer -- how much does reuse reduce dependence on
        // external memory bandwidth). Compute-side consumption cost is
        // deliberately excluded from BOTH measurements here -- it is
        // identical in both cases (same neural_processor.v pipeline
        // rate regardless of where weights come from) and including it
        // asymmetrically was a real bug in an earlier version of this
        // testbench (see EXP-0057 writeup). ----
        $display("=== REUSE case: pure SDRAM fetch time for %0d layers (%0d bytes total) ===", L, L*LAYER_DEPTH);
        @(posedge clk); while (ctrl_busy) @(posedge clk);
        t0 = cyc;
        for (li_i = 0; li_i < L; li_i = li_i + 1) prefetch_layer(li_i);
        total_cycles_reuse = cyc - t0;
        $display("  REUSE: %0d cycles to fetch %0d bytes from SDRAM (each layer fetched ONCE, reused %0d x locally)",
            total_cycles_reuse, L*LAYER_DEPTH, M);

        $display("=== ZERO-REUSE baseline: pure SDRAM fetch time for %0d bytes (every reuse fetched independently) ===", L*M*LAYER_DEPTH);
        @(posedge clk); while (ctrl_busy) @(posedge clk);
        t0 = cyc;
        zero_reuse_baseline;
        total_cycles_zeroreuse = cyc - t0;
        $display("  ZERO-REUSE: %0d cycles to fetch %0d bytes from SDRAM",
            total_cycles_zeroreuse, L*M*LAYER_DEPTH);

        $display("=== RESULT ===");
        $display("  REUSE case data correctness: %0d/%0d, %0d errors", tests-errors, tests, errors);
        $display("  REAL measured speedup from weight reuse alone (SAME hardware, no DDR3, no clock change): %0f x",
            total_cycles_zeroreuse * 1.0 / total_cycles_reuse);

        if (errors == 0) $display("ALL DATA CHECKS PASSED (tb_layer_reuse_vs_zero_reuse)");
        $finish;
    end
endmodule
