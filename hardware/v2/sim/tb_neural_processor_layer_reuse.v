`timescale 1ns/1ps

// ============================================================
// EXP-0058 -- first real end-to-end integration of the EXP-0057
// weight-reuse building blocks with the real M1 compute engine
// (neural_processor.v). Wires together, ALL real RTL except the
// per-tile weight-byte gather (see note below):
//
//   sdram_controller_openrow.v + sdram_model.v   (real DDR-less SDR SDRAM path)
//        -> layer_prefetch_ctrl.v                 (real RTL, EXP-0057b)
//             -> layer_weight_buffer.v             (real RTL, double-buffered, EXP-0057)
//                  -> [testbench byte-gather, see note]
//                       -> neural_processor.v       (real RTL, M1 compute engine)
//
// One "layer" = one resident filter (N_INPUTS=128 taps, 16 P_IN=8
// tiles) fetched ONCE from SDRAM into layer_weight_buffer.v, then
// REUSED across M independent "positions" (jobs) -- exactly modeling
// a real convolution filter held stationary while it slides across M
// different input windows, which is the whole point of EXP-0057's
// architecture. Input data for each position is synthetic (formula-
// generated, not fetched from SDRAM -- representing the activation/
// sliding-window path, which is a separate, already-existing memory
// path not the subject of this test) but deterministic and combined
// with an INDEPENDENT golden dot-product+bias+ReLU model (same
// "third oracle" style as tb_neural_processor.v's own expect_relu,
// duplicated here rather than shared, per that file's own stated
// convention).
//
// NOTE on the byte-gather step: neural_processor.v consumes one
// P_IN=8-wide (64-bit) weight_data tile per handshake cycle, but
// layer_weight_buffer.v is byte-wide (one address = one byte, already
// verified in isolation, EXP-0057). Assembling 8 sequential
// byte-wide reads into one 64-bit tile bus is done here by the
// testbench driver task. This gather step is NOT synthesizable RTL
// yet -- a real "tile gather adapter" (8:1 byte-to-tile packer) would
// be the natural next M4 Memory Manager deliverable if this
// architecture is adopted, deliberately out of scope here: this
// test's purpose is to verify DATA correctness of the weight-reuse
// path feeding the real compute engine, not to deliver the final
// gather RTL.
//
// Scope: correctness only (sequential, no prefetch/consume overlap
// across layers -- the double-buffered PERFORMANCE benefit was
// already measured in isolation, 7.16x, tb_layer_reuse_vs_zero_reuse.v,
// EXP-0057, not re-derived here).
// ============================================================
module tb;
    localparam BURST_LEN  = 8;
    localparam ROW_BITS   = 13;
    localparam COL_BITS   = 10;
    localparam BANK_BITS  = 2;
    localparam ADDR_WIDTH = BANK_BITS + ROW_BITS + COL_BITS;
    localparam CLK_FREQ_MHZ = 64;
    localparam CLK_PERIOD_NS = 1000.0/CLK_FREQ_MHZ;

    localparam DATA_WIDTH = 8;
    localparam P_IN       = 8;
    localparam ACC_WIDTH  = 32;
    localparam N_INPUTS   = 128;         // one resident filter = 128 taps
    localparam N_TILES    = N_INPUTS/P_IN; // 16
    localparam LAYER_BYTES = N_INPUTS;    // 1 byte/tap, DATA_WIDTH=8
    localparam L = 4;                     // layers (resident filters)
    localparam M = 8;                     // reuse positions per layer
    localparam WORDS_PER_LAYER = LAYER_BYTES/2;

    localparam ACT_RELU = 2'd1;

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

    // separate write-capable path to preload SDRAM with the L filters'
    // weight bytes (write and prefetch never run concurrently here)
    reg  wpre_req, wpre_wr;
    reg  [ADDR_WIDTH-1:0] wpre_addr;
    reg  [16*BURST_LEN-1:0] wpre_wdata;
    reg  pre_active;

    wire pf_ctrl_req, pf_ctrl_wr;
    wire [ADDR_WIDTH-1:0] pf_ctrl_addr;
    wire [16*BURST_LEN-1:0] pf_ctrl_wdata;
    wire [2*BURST_LEN-1:0]  pf_ctrl_wmask;

    assign ctrl_req   = pre_active ? wpre_req   : pf_ctrl_req;
    assign ctrl_wr    = pre_active ? wpre_wr    : pf_ctrl_wr;
    assign ctrl_addr  = pre_active ? wpre_addr  : pf_ctrl_addr;
    assign ctrl_wdata = pre_active ? wpre_wdata : pf_ctrl_wdata;
    assign ctrl_wmask = pre_active ? {(2*BURST_LEN){1'b0}} : pf_ctrl_wmask;

    // ---- deterministic weight/input formulas (shared between SDRAM
    // preload, the golden model, and -- for weights -- indirectly
    // verified via the real buffer read-back) ----
    function automatic signed [7:0] weight_byte(input integer li, input integer t);
        weight_byte = $signed(8'((li*17 + t*29 + 13) & 8'hFF));
    endfunction
    function automatic signed [7:0] input_byte(input integer li, input integer pos, input integer t);
        input_byte = $signed(8'((li*11 + pos*41 + t*7 + 3) & 8'hFF));
    endfunction

    task automatic sdram_write_burst(input [ADDR_WIDTH-1:0] word_addr, input [16*BURST_LEN-1:0] data);
        begin
            @(posedge clk); while (ctrl_busy) @(posedge clk);
            wpre_req = 1'b1; wpre_wr = 1'b1; wpre_addr = word_addr; wpre_wdata = data;
            @(posedge clk); wpre_req = 1'b0;
            while (!ctrl_ready) @(posedge clk);
        end
    endtask

    task automatic preload_sdram_layers;
        integer li, bi, wb, tt;
        reg [16*BURST_LEN-1:0] burst_data;
        begin
            for (li = 0; li < L; li = li + 1) begin
                for (bi = 0; bi < (LAYER_BYTES/(2*BURST_LEN)); bi = bi + 1) begin
                    for (wb = 0; wb < BURST_LEN; wb = wb + 1) begin
                        // one burst = BURST_LEN words = 2*BURST_LEN bytes/taps
                        // (1 byte/tap); word wb holds taps [bi*2*BURST_LEN+wb*2]
                        // (low byte) and [...+wb*2+1] (high byte), matching
                        // layer_prefetch_ctrl.v's own drain_cnt byte order
                        // (drain_cnt = wb*2 -> low byte, wb*2+1 -> high byte).
                        tt = bi*(2*BURST_LEN) + wb*2;
                        burst_data[wb*16 +: 16] = {weight_byte(li, tt+1), weight_byte(li, tt)};
                    end
                    sdram_write_burst((li*WORDS_PER_LAYER + bi*BURST_LEN), burst_data);
                end
            end
        end
    endtask

    // ---- layer_prefetch_ctrl.v (real RTL) ----
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

    // ---- layer_weight_buffer.v (real RTL) ----
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

    // ---- neural_processor.v (real RTL, M1 compute engine under test) ----
    reg job_valid;
    wire job_ready;
    reg [15:0] job_node_id;
    reg signed [DATA_WIDTH-1:0] job_bias;
    reg [1:0] job_activation;

    reg operand_valid;
    wire operand_ready;
    reg signed [DATA_WIDTH*P_IN-1:0] input_data, weight_data;
    reg tile_last;

    wire result_valid;
    reg result_ready;
    wire signed [DATA_WIDTH-1:0] result_data;
    wire [15:0] result_node_id;
    wire [3:0] np_state;
    wire np_error;

    neural_processor #(
        .DATA_WIDTH(DATA_WIDTH), .P_IN(P_IN), .ACC_WIDTH(ACC_WIDTH)
    ) u_np (
        .clk(clk), .rst(rst),
        .job_valid(job_valid), .job_ready(job_ready),
        .job_node_id(job_node_id), .job_bias(job_bias), .job_activation(job_activation),
        .operand_valid(operand_valid), .operand_ready(operand_ready),
        .input_data(input_data), .weight_data(weight_data), .tile_last(tile_last),
        .result_valid(result_valid), .result_ready(result_ready),
        .result_data(result_data), .result_node_id(result_node_id),
        .np_state(np_state), .np_error(np_error)
    );

    integer errors, tests;
    integer li_i, pos_i, t, k, tt;
    reg [7:0] wbyte [0:P_IN-1];
    integer acc_calc, s_calc;
    reg signed [DATA_WIDTH-1:0] expected;
    integer t0, total_cycles;

    task automatic run_one_position(input integer li, input integer pos);
        begin
            @(posedge clk);
            tests = tests + 1;

            job_node_id    = li[15:8]*8'(M) + pos[15:0];
            job_bias       = {DATA_WIDTH{1'b0}};
            job_activation = ACT_RELU;
            job_valid      = 1;
            while (!job_ready) @(posedge clk);
            @(posedge clk); #1; // handshake edge, then hold one extra delta before
                                 // clearing -- see the pulse-hardening note by
                                 // consume_done below (same class of same-edge
                                 // testbench-vs-DUT scheduling race)
            job_valid = 0;

            acc_calc = 0;
            for (t = 0; t < N_TILES; t = t + 1) begin
                // gather this tile's P_IN weight bytes from the real,
                // resident (already-swapped-in) layer_weight_buffer.v
                for (k = 0; k < P_IN; k = k + 1) begin
                    rd_addr = (t*P_IN + k);
                    #1;
                    wbyte[k] = rd_data;
                end
                input_data  = {DATA_WIDTH*P_IN{1'b0}};
                weight_data = {DATA_WIDTH*P_IN{1'b0}};
                for (k = 0; k < P_IN; k = k + 1) begin
                    tt = t*P_IN + k;
                    input_data[k*DATA_WIDTH +: DATA_WIDTH]  = input_byte(li, pos, tt);
                    weight_data[k*DATA_WIDTH +: DATA_WIDTH] = wbyte[k];
                    // real, resident buffer readback must match the
                    // formula used to preload SDRAM -- checked directly
                    // (not just indirectly via the final dot product),
                    // so a wrong buffer byte is caught even if the dot
                    // product would coincidentally still match.
                    if (wbyte[k] !== weight_byte(li, tt)) begin
                        $display("FAIL li=%0d pos=%0d t=%0d k=%0d: buffer weight byte %0d expected %0d",
                                  li, pos, t, k, $signed(wbyte[k]), weight_byte(li, tt));
                        errors = errors + 1;
                    end
                    acc_calc = acc_calc + (input_byte(li, pos, tt) * weight_byte(li, tt));
                end
                tile_last     = (t == N_TILES - 1);
                operand_valid = 1;
                while (!operand_ready) @(posedge clk);
                @(posedge clk); #1;
            end
            operand_valid = 0;
            tile_last     = 0;

            result_ready = 1;
            while (!result_valid) @(posedge clk);

            s_calc = acc_calc + 0; // job_bias == 0
            if (s_calc <= 0)        expected = {DATA_WIDTH{1'b0}};
            else if (s_calc > 127)  expected = 8'sd127;
            else                    expected = s_calc[DATA_WIDTH-1:0];

            if (result_data !== expected) begin
                $display("FAIL li=%0d pos=%0d: result=%0d expected=%0d (acc=%0d)",
                          li, pos, $signed(result_data), $signed(expected), acc_calc);
                errors = errors + 1;
            end else begin
                $display("PASS li=%0d pos=%0d: result=%0d (acc=%0d, weight-reuse path, real RTL)",
                          li, pos, $signed(result_data), acc_calc);
            end
            @(posedge clk);

            while (!job_ready || np_state !== 4'd0) @(posedge clk);
        end
    endtask

    initial begin
        errors = 0; tests = 0; cyc = 0;
        rst = 1; pre_active = 1'b1;
        wpre_req = 0; wpre_wr = 0; wpre_addr = 0; wpre_wdata = 0;
        pf_start = 0; pf_layer_base = 0; rd_addr = 0; consume_done = 0;
        job_valid = 0; job_node_id = 0; job_bias = 0; job_activation = ACT_RELU;
        operand_valid = 0; input_data = 0; weight_data = 0; tile_last = 0;
        result_ready = 0;
        repeat(5) @(posedge clk);
        rst = 0;
        @(posedge clk); while (ctrl_busy) @(posedge clk);

        $display("=== preload SDRAM with %0d resident-filter weight sets (%0d taps each) ===", L, N_INPUTS);
        preload_sdram_layers;
        @(posedge clk); // ERR-0001 workaround: sync before the first blocking
                         // assignment following a time-consuming task call,
                         // otherwise it can be invisible to other modules at
                         // the next clock edge (see tb_neural_processor.v header)
        pre_active = 1'b0; // hand control to layer_prefetch_ctrl.v

        $display("=== EXP-0058: real RTL weight-reuse path -> real neural_processor.v, %0d layers x %0d reuse positions ===", L, M);
        t0 = cyc;

        for (li_i = 0; li_i < L; li_i = li_i + 1) begin
            pf_layer_base = li_i * WORDS_PER_LAYER;
            pf_start = 1'b1; @(posedge clk); #1; pf_start = 1'b0;
            while (!pf_done) @(posedge clk);
            #1;
            // pulse-hardening: hold consume_done past its edge with a real
            // time delay before clearing, rather than clearing on the very
            // next @(posedge clk) -- otherwise the clear can land in the
            // SAME active-region pass as the edge where layer_weight_
            // buffer.v's own always block reads it, and their relative
            // order is implementation-defined, so the pulse can be silently
            // missed (found via direct $strobe tracing while debugging this
            // exact sequence in tb_layer_prefetch_ctrl.v, EXP-0058 -- see
            // that file's own longer note on this).
            consume_done = 1'b1; @(posedge clk); #1; consume_done = 1'b0; // swap into active
            @(posedge clk); #1;

            for (pos_i = 0; pos_i < M; pos_i = pos_i + 1) begin
                run_one_position(li_i, pos_i);
            end
        end
        total_cycles = cyc - t0;

        $display("=== RESULT: %0d/%0d PASS, %0d errors, %0d total cycles for %0d layers x %0d positions (EXP-0058 integration) ===",
            tests-errors, tests, errors, total_cycles, L, M);
        if (errors == 0) $display("ALL TESTS PASSED (tb_neural_processor_layer_reuse)");
        $finish;
    end
endmodule
