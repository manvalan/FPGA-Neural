`timescale 1ns/1ps

// ============================================================
// Isolated correctness test for packed_slot.v -- same golden formulas
// as EXP-0062's tb_np_packed_layer_reuse.v (independently reproduced,
// not shared, per this project's "third oracle" convention), but now
// driving packed_slot.v's OWN real sequencing FSM instead of a
// testbench procedurally driving each sub-module -- confirms the
// promotion from testbench-sequence to real RTL (EXP-0062 -> this)
// preserves bit-exact correctness.
//
// Activation stand-in (see packed_slot.v's own header): a simple
// combinational behavioral memory here, addressed by act_tile_addr_a/b
// (tile-index-based, matching packed_slot.v's own addressing:
// x_base + tile_count), standing in for the real (not yet built)
// activation fetch engine.
// ============================================================
module tb;
    localparam BURST_LEN  = 8;
    localparam ROW_BITS   = 13;
    localparam COL_BITS   = 10;
    localparam BANK_BITS  = 2;
    localparam SDRAM_ADDR_WIDTH = BANK_BITS + ROW_BITS + COL_BITS; // 25
    localparam CLK_FREQ_MHZ = 64;
    localparam CLK_PERIOD_NS = 1000.0/CLK_FREQ_MHZ;

    localparam DATA_WIDTH  = 8;
    localparam P_IN        = 8;
    localparam ACC_WIDTH   = 32;
    localparam ADDR_WIDTH  = 26;
    localparam N_INPUTS    = 128;
    localparam N_TILES     = N_INPUTS/P_IN;
    localparam LAYER_BYTES = N_INPUTS;
    localparam WORDS_PER_LAYER = LAYER_BYTES/2;
    localparam L = 3;  // layers
    localparam M = 6;  // reuse positions per layer, paired 2 at a time

    reg clk = 0;
    always #(CLK_PERIOD_NS/2.0) clk = ~clk;
    reg rst;
    integer cyc;
    always @(posedge clk) if (!rst) cyc <= cyc + 1;

    // ---- real SDRAM controller + model ----
    wire                          ctrl_req, ctrl_wr;
    wire [SDRAM_ADDR_WIDTH-1:0]   ctrl_addr;
    wire [16*BURST_LEN-1:0]       ctrl_wdata;
    wire [2*BURST_LEN-1:0]        ctrl_wmask;
    wire [16*BURST_LEN-1:0]       ctrl_rdata;
    wire ctrl_ready, ctrl_busy;
    wire cke, cs_n, ras_n, cas_n, we_n;
    wire [BANK_BITS-1:0] ba;
    wire [ROW_BITS-1:0] a;
    wire [15:0] dq;
    wire [1:0] dqm;

    reg  wpre_req, wpre_wr;
    reg  [SDRAM_ADDR_WIDTH-1:0] wpre_addr;
    reg  [16*BURST_LEN-1:0] wpre_wdata;
    reg  pre_active;

    wire slot_ctrl_req, slot_ctrl_wr;
    wire [SDRAM_ADDR_WIDTH-1:0] slot_ctrl_addr;
    wire [16*BURST_LEN-1:0] slot_ctrl_wdata;
    wire [2*BURST_LEN-1:0]  slot_ctrl_wmask;

    assign ctrl_req   = pre_active ? wpre_req   : slot_ctrl_req;
    assign ctrl_wr    = pre_active ? wpre_wr    : slot_ctrl_wr;
    assign ctrl_addr  = pre_active ? wpre_addr  : slot_ctrl_addr;
    assign ctrl_wdata = pre_active ? wpre_wdata : slot_ctrl_wdata;
    assign ctrl_wmask = pre_active ? {(2*BURST_LEN){1'b0}} : slot_ctrl_wmask;

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

    function automatic signed [7:0] weight_byte(input integer li, input integer t);
        weight_byte = $signed(8'((li*17 + t*29 + 13) & 8'hFF));
    endfunction
    function automatic signed [7:0] input_byte(input integer li, input integer pos, input integer t);
        input_byte = $signed(8'((li*11 + pos*41 + t*7 + 3) & 8'hFF));
    endfunction

    task automatic sdram_write_burst(input [SDRAM_ADDR_WIDTH-1:0] word_addr, input [16*BURST_LEN-1:0] data);
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

    // ---- activation stand-in: act_tile_addr = x_base + tile_index
    // (packed_slot.v's own addressing) -- x_base itself is chosen as
    // li*1000 + pos*100 below so a simple decode recovers (li,pos,t) ----
    reg signed [DATA_WIDTH*P_IN-1:0] act_data_a, act_data_b;
    wire [ADDR_WIDTH-1:0] act_addr_a, act_addr_b;

    // act_tile_addr = x_base + tile_index (packed_slot.v's own
    // addressing); x_base itself encodes (li,pos) as li*100000+pos*1000
    // so tile_index occupies the low 3 decimal digits directly.

    // ---- packed_slot.v (DUT) ----
    reg  job_start;
    reg  [ADDR_WIDTH-1:0] x_base_a, x_base_b, w_base;
    reg  [15:0] n_tiles_in;
    reg  [ADDR_WIDTH-1:0] result_addr_a, result_addr_b;
    reg  [15:0] node_id_a, node_id_b;
    wire job_done;
    wire signed [DATA_WIDTH-1:0] result_data_a, result_data_b;
    wire [15:0] result_node_id_a, result_node_id_b;
    wire [ADDR_WIDTH-1:0] result_addr_a_out, result_addr_b_out;

    packed_slot #(
        .DATA_WIDTH(DATA_WIDTH), .P_IN(P_IN), .ACC_WIDTH(ACC_WIDTH),
        .BURST_LEN(BURST_LEN), .ADDR_WIDTH(ADDR_WIDTH), .LAYER_BYTES(LAYER_BYTES)
    ) dut (
        .clk(clk), .rst(rst),
        .job_start(job_start), .x_base_a(x_base_a), .x_base_b(x_base_b), .w_base(w_base),
        .n_tiles(n_tiles_in), .result_addr_a(result_addr_a), .result_addr_b(result_addr_b),
        .node_id_a(node_id_a), .node_id_b(node_id_b), .job_done(job_done),
        .result_data_a(result_data_a), .result_data_b(result_data_b),
        .result_node_id_a(result_node_id_a), .result_node_id_b(result_node_id_b),
        .result_addr_a_out(result_addr_a_out), .result_addr_b_out(result_addr_b_out),
        .act_tile_addr_a(act_addr_a), .act_tile_addr_b(act_addr_b),
        .act_tile_data_a(act_data_a), .act_tile_data_b(act_data_b),
        .mem_grant(1'b1), // no arbiter in this single-slot test
        .ctrl_req(slot_ctrl_req), .ctrl_wr(slot_ctrl_wr), .ctrl_addr(slot_ctrl_addr),
        .ctrl_wdata(slot_ctrl_wdata), .ctrl_wmask(slot_ctrl_wmask),
        .ctrl_rdata(ctrl_rdata), .ctrl_ready(ctrl_ready), .ctrl_busy(ctrl_busy)
    );

    // real activation decode: x_base encodes (li,pos) as li*100000+pos*1000;
    // act_tile_addr = x_base + tile_index (0..N_TILES-1), so
    // tile_index = act_addr % 1000, pos = (act_addr/1000) % 100, li = act_addr/100000
    function automatic signed [DATA_WIDTH*P_IN-1:0] act_lookup(input [ADDR_WIDTH-1:0] addr);
        integer li_d, pos_d, tidx_d, k;
        reg signed [DATA_WIDTH*P_IN-1:0] r;
        begin
            li_d   = addr / 100000;
            pos_d  = (addr / 1000) % 100;
            tidx_d = addr % 1000;
            for (k = 0; k < P_IN; k = k + 1)
                r[k*DATA_WIDTH +: DATA_WIDTH] = input_byte(li_d, pos_d, tidx_d*P_IN + k);
            act_lookup = r;
        end
    endfunction

    always @(*) act_data_a = act_lookup(act_addr_a);
    always @(*) act_data_b = act_lookup(act_addr_b);

    integer errors, tests;
    integer li_i, pp_i;
    integer acc_a, acc_b, s_a, s_b, k, tt;
    reg signed [DATA_WIDTH-1:0] expected_a, expected_b;
    integer wd;

    task automatic run_one_pair(input integer li, input integer pos_a, input integer pos_b);
        begin
            tests = tests + 1;
            @(posedge clk);
            job_start     = 1'b1;
            x_base_a      = li*100000 + pos_a*1000;
            x_base_b      = li*100000 + pos_b*1000;
            w_base        = li*WORDS_PER_LAYER; // WORD address, matching layer_prefetch_ctrl.v's
                                                 // own convention (EXP-0057/58/62) and this
                                                 // testbench's own preload_sdram_layers addressing
            n_tiles_in    = N_TILES[15:0];
            result_addr_a = 26'h9000 + pos_a;
            result_addr_b = 26'h9000 + pos_b;
            node_id_a     = li[15:8]*8'(M) + pos_a[15:0];
            node_id_b     = li[15:8]*8'(M) + pos_b[15:0];
            @(posedge clk);
            job_start = 1'b0;

            acc_a = 0; acc_b = 0;
            for (tt = 0; tt < N_INPUTS; tt = tt + 1) begin
                acc_a = acc_a + (input_byte(li, pos_a, tt) * weight_byte(li, tt));
                acc_b = acc_b + (input_byte(li, pos_b, tt) * weight_byte(li, tt));
            end
            s_a = acc_a; s_b = acc_b;
            if (s_a <= 0) expected_a = 0; else if (s_a > 127) expected_a = 8'sd127; else expected_a = s_a[DATA_WIDTH-1:0];
            if (s_b <= 0) expected_b = 0; else if (s_b > 127) expected_b = 8'sd127; else expected_b = s_b[DATA_WIDTH-1:0];

            wd = 0;
            while (!job_done && wd < 2000) begin @(posedge clk); wd = wd + 1; end
            if (!job_done) begin
                $display("FAIL li=%0d pos_a=%0d pos_b=%0d: TIMEOUT waiting for job_done", li, pos_a, pos_b);
                errors = errors + 1;
            end else if (result_data_a !== expected_a || result_data_b !== expected_b) begin
                $display("FAIL li=%0d pos_a=%0d pos_b=%0d: got_a=%0d got_b=%0d expected_a=%0d expected_b=%0d",
                          li, pos_a, pos_b, $signed(result_data_a), $signed(result_data_b), $signed(expected_a), $signed(expected_b));
                errors = errors + 1;
            end else if (result_node_id_a !== node_id_a || result_node_id_b !== node_id_b ||
                         result_addr_a_out !== result_addr_a || result_addr_b_out !== result_addr_b) begin
                $display("FAIL li=%0d pos_a=%0d pos_b=%0d: metadata passthrough mismatch (node_a=%0d/%0d node_b=%0d/%0d addr_a=%0d/%0d addr_b=%0d/%0d)",
                          li, pos_a, pos_b, result_node_id_a, node_id_a, result_node_id_b, node_id_b,
                          result_addr_a_out, result_addr_a, result_addr_b_out, result_addr_b);
                errors = errors + 1;
            end else begin
                $display("PASS li=%0d pos_a=%0d pos_b=%0d: a=%0d b=%0d (packed_slot.v real sequencer)",
                          li, pos_a, pos_b, $signed(result_data_a), $signed(result_data_b));
            end
        end
    endtask

    initial begin
        errors = 0; tests = 0; cyc = 0;
        rst = 1; pre_active = 1'b1;
        wpre_req = 0; wpre_wr = 0; wpre_addr = 0; wpre_wdata = 0;
        job_start = 0; x_base_a = 0; x_base_b = 0; w_base = 0; n_tiles_in = 0;
        result_addr_a = 0; result_addr_b = 0; node_id_a = 0; node_id_b = 0;
        repeat(5) @(posedge clk);
        rst = 0;
        @(posedge clk); while (ctrl_busy) @(posedge clk);

        $display("=== preload SDRAM with %0d resident-filter weight sets ===", L);
        preload_sdram_layers;
        @(posedge clk);
        pre_active = 1'b0;

        $display("=== packed_slot.v real sequencer: %0d layers x %0d positions (paired) ===", L, M);
        for (li_i = 0; li_i < L; li_i = li_i + 1) begin
            for (pp_i = 0; pp_i < M; pp_i = pp_i + 2) begin
                run_one_pair(li_i, pp_i, pp_i+1);
            end
        end

        $display("=== %0d/%0d tests, %0d errors ===", tests-errors, tests, errors);
        if (errors == 0) $display("ALL TESTS PASSED (tb_packed_slot)");
        $finish;
    end
endmodule
