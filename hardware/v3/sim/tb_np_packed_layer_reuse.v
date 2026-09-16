`timescale 1ns/1ps

// ============================================================
// V3 follow-up to EXP-0058/EXP-0061 -- first real end-to-end
// integration of the weight-reuse memory path with the DSP48-packed
// compute core, ALL real synthesizable RTL (unlike EXP-0058, which
// still had a testbench-only byte-gather step):
//
//   sdram_controller.v + sdram_model.v   (real SDR SDRAM path, v2, unmodified)
//        -> layer_prefetch_ctrl.v         (real RTL, v2, unmodified)
//             -> layer_weight_buffer.v     (real RTL, v2, unmodified)
//                  -> weight_tile_gather.v  (real RTL, v3, EXP-0061)
//                       -> neural_processor_packed.v (real RTL, v3, EXP-0059)
//
// One "layer" = one resident filter (128 taps, 16 tiles), fetched
// ONCE, reused across M=8 positions PAIRED UP (pos_a, pos_b) two at a
// time into neural_processor_packed.v's own A/B job structure -- each
// pair shares ONE weight_tile_gather fetch per tile (gathered once,
// consumed by both A and B), matching the whole point of the DSP48
// packing (one weight, two independent activations).
//
// Golden model: SAME weight_byte/input_byte formulas as EXP-0058's
// own tb_neural_processor_layer_reuse.v (independently reproduced
// here, not shared code, per this project's own "third oracle"
// convention), evaluated independently for pos_a and pos_b.
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
    localparam N_INPUTS   = 128;
    localparam N_TILES    = N_INPUTS/P_IN; // 16
    localparam LAYER_BYTES = N_INPUTS;
    localparam BUFADDRW   = $clog2(LAYER_BYTES);
    localparam L = 4;   // layers
    localparam M = 8;   // reuse positions per layer (paired 2 at a time)
    localparam WORDS_PER_LAYER = LAYER_BYTES/2;

    localparam ACT_RELU = 2'd1;

    reg clk = 0;
    always #(CLK_PERIOD_NS/2.0) clk = ~clk;
    reg rst;

    integer cyc;
    always @(posedge clk) if (!rst) cyc <= cyc + 1;

    // ---- real SDRAM controller + model (v2, unmodified) ----
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
                        tt = bi*(2*BURST_LEN) + wb*2;
                        burst_data[wb*16 +: 16] = {weight_byte(li, tt+1), weight_byte(li, tt)};
                    end
                    sdram_write_burst((li*WORDS_PER_LAYER + bi*BURST_LEN), burst_data);
                end
            end
        end
    endtask

    // ---- layer_prefetch_ctrl.v (v2, real, unmodified) ----
    reg  pf_start;
    reg  [ADDR_WIDTH-1:0] pf_layer_base;
    wire pf_busy, pf_done;
    wire pf_fill_we;
    wire [BUFADDRW-1:0] pf_fill_addr;
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

    // ---- layer_weight_buffer.v (v2, real, unmodified) ----
    wire [BUFADDRW-1:0] lwb_rd_addr;
    wire [7:0]           lwb_rd_data;
    reg                  consume_done;
    wire active_sel, swapped;

    layer_weight_buffer #(.DATA_WIDTH(8), .LAYER_DEPTH(LAYER_BYTES)) u_lwb (
        .clk(clk), .rst(rst),
        .fill_we(pf_fill_we), .fill_addr(pf_fill_addr), .fill_data(pf_fill_data), .fill_done(pf_done),
        .rd_addr(lwb_rd_addr), .rd_data(lwb_rd_data), .consume_done(consume_done),
        .active_sel(active_sel), .swapped(swapped)
    );

    // ---- weight_tile_gather.v (v3, real, EXP-0061) ----
    reg                          tile_req;
    reg  [BUFADDRW-1:0]          tile_base;
    wire                         tile_valid;
    wire [DATA_WIDTH*P_IN-1:0]   tile_data;

    weight_tile_gather #(
        .DATA_WIDTH(DATA_WIDTH), .P_IN(P_IN), .BUFADDRW(BUFADDRW)
    ) u_gather (
        .clk(clk), .rst(rst),
        .tile_req(tile_req), .tile_base(tile_base),
        .tile_valid(tile_valid), .tile_data(tile_data),
        .rd_addr(lwb_rd_addr), .rd_data(lwb_rd_data)
    );

    // ---- neural_processor_packed.v (v3, real, EXP-0059) ----
    reg job_valid;
    wire job_ready;
    reg [15:0] job_node_id_a, job_node_id_b;
    reg signed [DATA_WIDTH-1:0] job_bias;
    reg [1:0] job_activation;

    reg operand_valid;
    wire operand_ready;
    reg signed [DATA_WIDTH*P_IN-1:0] input_data_a, input_data_b;
    reg [DATA_WIDTH*P_IN-1:0] weight_data;
    reg tile_last;

    wire result_valid;
    reg result_ready;
    wire signed [DATA_WIDTH-1:0] result_data_a, result_data_b;
    wire [15:0] result_node_id_a, result_node_id_b;
    wire [3:0] np_state;
    wire np_error;

    neural_processor_packed #(
        .DATA_WIDTH(DATA_WIDTH), .P_IN(P_IN), .ACC_WIDTH(ACC_WIDTH)
    ) u_np (
        .clk(clk), .rst(rst),
        .job_valid(job_valid), .job_ready(job_ready),
        .job_node_id_a(job_node_id_a), .job_node_id_b(job_node_id_b),
        .job_bias(job_bias), .job_activation(job_activation),
        .operand_valid(operand_valid), .operand_ready(operand_ready),
        .input_data_a(input_data_a), .input_data_b(input_data_b),
        .weight_data(weight_data), .tile_last(tile_last),
        .result_valid(result_valid), .result_ready(result_ready),
        .result_data_a(result_data_a), .result_data_b(result_data_b),
        .result_node_id_a(result_node_id_a), .result_node_id_b(result_node_id_b),
        .np_state(np_state), .np_error(np_error)
    );

    integer errors, tests;
    integer li_i, pp_i, t, k;
    integer acc_a, acc_b, s_a, s_b;
    reg signed [DATA_WIDTH-1:0] expected_a, expected_b;
    integer t0, total_cycles;

    task automatic run_one_pair(input integer li, input integer pos_a, input integer pos_b);
        begin
            @(posedge clk);
            tests = tests + 1;

            job_node_id_a  = li[15:8]*8'(M) + pos_a[15:0];
            job_node_id_b  = li[15:8]*8'(M) + pos_b[15:0];
            job_bias       = {DATA_WIDTH{1'b0}};
            job_activation = ACT_RELU;
            job_valid      = 1;
            while (!job_ready) @(posedge clk);
            @(posedge clk); #1;
            job_valid = 0;

            acc_a = 0; acc_b = 0;
            for (t = 0; t < N_TILES; t = t + 1) begin
                tile_req  = 1'b1;
                tile_base = (t*P_IN);
                @(posedge clk); #1;
                tile_req = 1'b0;
                while (!tile_valid) @(posedge clk);
                #1;
                weight_data = tile_data;

                for (k = 0; k < P_IN; k = k + 1) begin
                    input_data_a[k*DATA_WIDTH +: DATA_WIDTH] = input_byte(li, pos_a, t*P_IN+k);
                    input_data_b[k*DATA_WIDTH +: DATA_WIDTH] = input_byte(li, pos_b, t*P_IN+k);
                    acc_a = acc_a + (input_byte(li, pos_a, t*P_IN+k) * weight_byte(li, t*P_IN+k));
                    acc_b = acc_b + (input_byte(li, pos_b, t*P_IN+k) * weight_byte(li, t*P_IN+k));
                end
                tile_last     = (t == N_TILES - 1);
                operand_valid = 1;
                @(posedge clk);
                while (!operand_ready) @(posedge clk);
                #1;
                // operand_ready stays high continuously across the whole
                // tile stream (unlike a one-shot req/ready pulse) -- must
                // drop operand_valid THE SAME delta this handshake is
                // observed, before any further time passes, or the next
                // posedge re-samples operand_valid=1 with STILL-STALE
                // weight_data/input_data and double-consumes this tile
                // (found empirically: acc_reg_a/b came out ~9x too large,
                // root-caused via hierarchical acc_reg_a/b + valid0 trace).
                operand_valid = 1'b0;
            end
            operand_valid = 0;
            tile_last     = 0;

            result_ready = 1;
            while (!result_valid) @(posedge clk);

            s_a = acc_a; s_b = acc_b;
            if (s_a <= 0) expected_a = 0; else if (s_a > 127) expected_a = 8'sd127; else expected_a = s_a[DATA_WIDTH-1:0];
            if (s_b <= 0) expected_b = 0; else if (s_b > 127) expected_b = 8'sd127; else expected_b = s_b[DATA_WIDTH-1:0];

            if (result_data_a !== expected_a || result_data_b !== expected_b) begin
                $display("FAIL li=%0d pos_a=%0d pos_b=%0d: got_a=%0d got_b=%0d expected_a=%0d expected_b=%0d",
                          li, pos_a, pos_b, $signed(result_data_a), $signed(result_data_b), $signed(expected_a), $signed(expected_b));
                errors = errors + 1;
            end else begin
                $display("PASS li=%0d pos_a=%0d pos_b=%0d: a=%0d b=%0d (packed weight-reuse path, real RTL)",
                          li, pos_a, pos_b, $signed(result_data_a), $signed(result_data_b));
            end
            @(posedge clk);
            while (!job_ready || np_state !== 4'd0) @(posedge clk);
        end
    endtask

    initial begin
        errors = 0; tests = 0; cyc = 0;
        rst = 1; pre_active = 1'b1;
        wpre_req = 0; wpre_wr = 0; wpre_addr = 0; wpre_wdata = 0;
        pf_start = 0; pf_layer_base = 0; consume_done = 0;
        tile_req = 0; tile_base = 0;
        job_valid = 0; job_node_id_a = 0; job_node_id_b = 0; job_bias = 0; job_activation = ACT_RELU;
        operand_valid = 0; input_data_a = 0; input_data_b = 0; weight_data = 0; tile_last = 0;
        result_ready = 0;
        repeat(5) @(posedge clk);
        rst = 0;
        @(posedge clk); while (ctrl_busy) @(posedge clk);

        $display("=== preload SDRAM with %0d resident-filter weight sets (%0d taps each) ===", L, N_INPUTS);
        preload_sdram_layers;
        @(posedge clk);
        pre_active = 1'b0;

        $display("=== real RTL weight-reuse path -> neural_processor_packed.v, %0d layers x %0d positions (paired) ===", L, M);
        t0 = cyc;

        for (li_i = 0; li_i < L; li_i = li_i + 1) begin
            pf_layer_base = li_i * WORDS_PER_LAYER;
            pf_start = 1'b1; @(posedge clk); #1; pf_start = 1'b0;
            while (!pf_done) @(posedge clk);
            #1;
            consume_done = 1'b1; @(posedge clk); #1; consume_done = 1'b0;
            @(posedge clk); #1;

            for (pp_i = 0; pp_i < M; pp_i = pp_i + 2) begin
                run_one_pair(li_i, pp_i, pp_i+1);
            end
        end
        total_cycles = cyc - t0;

        $display("=== RESULT: %0d/%0d PASS, %0d errors, %0d total cycles for %0d layers x %0d positions (%0d pairs) ===",
            tests-errors, tests, errors, total_cycles, L, M, L*(M/2));
        if (errors == 0) $display("ALL TESTS PASSED (tb_np_packed_layer_reuse)");
        $finish;
    end
endmodule
