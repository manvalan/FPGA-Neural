`timescale 1ns/1ps

// ============================================================
// First genuine multi-core (N=2) system correctness test: real
// neural_director_packed.v (EXP-0064) dispatching to TWO real
// packed_slot.v instances (EXP-0065), sharing ONE real SDRAM
// controller through sdram_slot_arbiter2.v. All real RTL except the
// activation stand-in (same disclosed scope as EXP-0065/packed_slot.v
// itself).
//
// Jobs are submitted ONE AT A TIME through the Director's own
// job_in_* producer interface (mimicking a host/dependency manager),
// letting the Director do its own pairing (matching w_base) and
// first-free-slot dispatch -- unlike EXP-0062/0065's own tests, which
// drove pairs/slots directly. This is the first test where the
// Director's OWN scheduling decisions (verified in isolation,
// EXP-0064) determine which physical slot executes which pair.
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
    localparam N_SLOTS     = 2;
    localparam QUEUE_DEPTH = 8;

    localparam L = 3;  // layers
    localparam M = 4;  // reuse positions per layer, paired 2 at a time

    reg clk = 0;
    always #(CLK_PERIOD_NS/2.0) clk = ~clk;
    reg rst;
    integer cyc;
    always @(posedge clk) if (!rst) cyc <= cyc + 1;

    // ---- real SDRAM controller + model, shared via the arbiter ----
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

    wire arb_ctrl_req, arb_ctrl_wr;
    wire [SDRAM_ADDR_WIDTH-1:0] arb_ctrl_addr;
    wire [16*BURST_LEN-1:0] arb_ctrl_wdata;
    wire [2*BURST_LEN-1:0]  arb_ctrl_wmask;

    assign ctrl_req   = pre_active ? wpre_req   : arb_ctrl_req;
    assign ctrl_wr    = pre_active ? wpre_wr    : arb_ctrl_wr;
    assign ctrl_addr  = pre_active ? wpre_addr  : arb_ctrl_addr;
    assign ctrl_wdata = pre_active ? wpre_wdata : arb_ctrl_wdata;
    assign ctrl_wmask = pre_active ? {(2*BURST_LEN){1'b0}} : arb_ctrl_wmask;

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

    // ---- neural_director_packed.v ----
    reg                     job_in_valid;
    wire                    job_in_ready;
    reg  [ADDR_WIDTH-1:0]   job_in_x_base, job_in_w_base, job_in_result_addr;
    reg  [15:0]             job_in_n_tiles, job_in_node_id;

    wire [N_SLOTS-1:0]            slot_job_start;
    wire [ADDR_WIDTH*N_SLOTS-1:0] slot_x_base_a, slot_x_base_b, slot_w_base;
    wire [ADDR_WIDTH*N_SLOTS-1:0] slot_result_addr_a, slot_result_addr_b;
    wire [16*N_SLOTS-1:0]         slot_n_tiles, slot_node_id_a, slot_node_id_b;
    wire [N_SLOTS-1:0]            slot_job_done;

    wire                        job_out_done;
    wire [$clog2(N_SLOTS)-1:0]  job_out_slot;
    wire [3:0]                  dir_state;
    wire                        dir_error;

    neural_director_packed #(
        .ADDR_WIDTH(ADDR_WIDTH), .N_SLOTS(N_SLOTS), .QUEUE_DEPTH(QUEUE_DEPTH)
    ) u_dir (
        .clk(clk), .rst(rst),
        .job_in_valid(job_in_valid), .job_in_ready(job_in_ready),
        .job_in_x_base(job_in_x_base), .job_in_w_base(job_in_w_base),
        .job_in_n_tiles(job_in_n_tiles), .job_in_result_addr(job_in_result_addr),
        .job_in_node_id(job_in_node_id),
        .slot_job_start(slot_job_start),
        .slot_x_base_a(slot_x_base_a), .slot_x_base_b(slot_x_base_b),
        .slot_w_base(slot_w_base), .slot_n_tiles(slot_n_tiles),
        .slot_result_addr_a(slot_result_addr_a), .slot_result_addr_b(slot_result_addr_b),
        .slot_node_id_a(slot_node_id_a), .slot_node_id_b(slot_node_id_b),
        .slot_job_done(slot_job_done),
        .job_out_done(job_out_done), .job_out_slot(job_out_slot),
        .dir_state(dir_state), .dir_error(dir_error)
    );

    // ---- 2 real packed_slot.v instances + arbiter ----
    wire [1:0] mem_active;
    wire [1:0] mem_grant;
    wire [1:0] s_ctrl_req, s_ctrl_wr;
    wire [SDRAM_ADDR_WIDTH-1:0] s_ctrl_addr [0:1];
    wire [16*BURST_LEN-1:0] s_ctrl_wdata [0:1];
    wire [2*BURST_LEN-1:0]  s_ctrl_wmask [0:1];
    wire [16*BURST_LEN-1:0] s_ctrl_rdata [0:1];
    wire [1:0] s_ctrl_ready, s_ctrl_busy;

    sdram_slot_arbiter2 #(.ADDR_WIDTH(SDRAM_ADDR_WIDTH), .BURST_LEN(BURST_LEN)) u_arb (
        .clk(clk), .rst(rst),
        .slot0_active(mem_active[0]), .slot0_grant(mem_grant[0]), .slot0_req(s_ctrl_req[0]), .slot0_wr(s_ctrl_wr[0]),
        .slot0_addr(s_ctrl_addr[0]), .slot0_wdata(s_ctrl_wdata[0]), .slot0_wmask(s_ctrl_wmask[0]),
        .slot0_rdata(s_ctrl_rdata[0]), .slot0_ready(s_ctrl_ready[0]), .slot0_busy(s_ctrl_busy[0]),
        .slot1_active(mem_active[1]), .slot1_grant(mem_grant[1]), .slot1_req(s_ctrl_req[1]), .slot1_wr(s_ctrl_wr[1]),
        .slot1_addr(s_ctrl_addr[1]), .slot1_wdata(s_ctrl_wdata[1]), .slot1_wmask(s_ctrl_wmask[1]),
        .slot1_rdata(s_ctrl_rdata[1]), .slot1_ready(s_ctrl_ready[1]), .slot1_busy(s_ctrl_busy[1]),
        .ctrl_req(arb_ctrl_req), .ctrl_wr(arb_ctrl_wr), .ctrl_addr(arb_ctrl_addr),
        .ctrl_wdata(arb_ctrl_wdata), .ctrl_wmask(arb_ctrl_wmask),
        .ctrl_rdata(ctrl_rdata), .ctrl_ready(ctrl_ready), .ctrl_busy(ctrl_busy)
    );

    genvar gi;
    generate
        for (gi = 0; gi < N_SLOTS; gi = gi + 1) begin : GEN_SLOT
            wire signed [DATA_WIDTH-1:0] res_a, res_b;
            wire [15:0] res_nid_a, res_nid_b;
            wire [ADDR_WIDTH-1:0] res_addr_a_out, res_addr_b_out;
            wire [ADDR_WIDTH-1:0] act_addr_a, act_addr_b;
            wire signed [DATA_WIDTH*P_IN-1:0] act_data_a, act_data_b;

            assign act_data_a = act_lookup(act_addr_a);
            assign act_data_b = act_lookup(act_addr_b);

            packed_slot #(
                .DATA_WIDTH(DATA_WIDTH), .P_IN(P_IN), .ACC_WIDTH(ACC_WIDTH),
                .BURST_LEN(BURST_LEN), .ADDR_WIDTH(ADDR_WIDTH), .LAYER_BYTES(LAYER_BYTES)
            ) u_slot (
                .clk(clk), .rst(rst),
                .job_start(slot_job_start[gi]),
                .x_base_a(slot_x_base_a[gi*ADDR_WIDTH +: ADDR_WIDTH]),
                .x_base_b(slot_x_base_b[gi*ADDR_WIDTH +: ADDR_WIDTH]),
                .w_base(slot_w_base[gi*ADDR_WIDTH +: ADDR_WIDTH]),
                .n_tiles(slot_n_tiles[gi*16 +: 16]),
                .result_addr_a(slot_result_addr_a[gi*ADDR_WIDTH +: ADDR_WIDTH]),
                .result_addr_b(slot_result_addr_b[gi*ADDR_WIDTH +: ADDR_WIDTH]),
                .node_id_a(slot_node_id_a[gi*16 +: 16]), .node_id_b(slot_node_id_b[gi*16 +: 16]),
                .job_done(slot_job_done[gi]),
                .result_data_a(res_a), .result_data_b(res_b),
                .result_node_id_a(res_nid_a), .result_node_id_b(res_nid_b),
                .result_addr_a_out(res_addr_a_out), .result_addr_b_out(res_addr_b_out),
                .mem_active(mem_active[gi]), .mem_grant(mem_grant[gi]),
                .act_tile_addr_a(act_addr_a), .act_tile_addr_b(act_addr_b),
                .act_tile_data_a(act_data_a), .act_tile_data_b(act_data_b),
                .ctrl_req(s_ctrl_req[gi]), .ctrl_wr(s_ctrl_wr[gi]), .ctrl_addr(s_ctrl_addr[gi]),
                .ctrl_wdata(s_ctrl_wdata[gi]), .ctrl_wmask(s_ctrl_wmask[gi]),
                .ctrl_rdata(s_ctrl_rdata[gi]), .ctrl_ready(s_ctrl_ready[gi]), .ctrl_busy(s_ctrl_busy[gi])
            );
        end
    endgenerate

    integer errors, tests;

    task automatic submit_job(
        input [ADDR_WIDTH-1:0] xb, input [ADDR_WIDTH-1:0] wb,
        input [15:0] nt, input [ADDR_WIDTH-1:0] resaddr, input [15:0] nid
    );
        begin
            @(posedge clk);
            job_in_x_base = xb; job_in_w_base = wb; job_in_n_tiles = nt;
            job_in_result_addr = resaddr; job_in_node_id = nid;
            job_in_valid = 1'b1;
            while (!job_in_ready) @(posedge clk);
            @(posedge clk);
            job_in_valid = 1'b0;
        end
    endtask

    // ---- scoreboard: golden result per node_id, checked whenever
    // EITHER slot's own job_done pulses (watching both slots directly,
    // not just the Director's own lowest-index-wins job_out_done,
    // per DEC-0007's own documented simplification) ----
    reg [15:0] expect_node [0:63];
    reg signed [7:0] expect_val [0:63];
    integer n_expected;

    function automatic signed [7:0] golden_result(input integer li, input integer pos);
        integer t, acc;
        reg signed [7:0] r;
        begin
            acc = 0;
            for (t = 0; t < N_INPUTS; t = t + 1)
                acc = acc + (input_byte(li, pos, t) * weight_byte(li, t));
            if (acc <= 0) r = 0; else if (acc > 127) r = 8'sd127; else r = acc[7:0];
            golden_result = r;
        end
    endfunction

    integer completions;
    integer si;

    // Runs from time 0, independent of the main submission flow below
    // -- a slot's job_done is a ONE-CYCLE pulse, and with QUEUE_DEPTH
    // smaller than the total job count, early pairs can complete WHILE
    // later jobs are still being submitted; a watcher that only starts
    // AFTER all submissions finish would miss those pulses entirely
    // (found empirically: only 2/12 results ever got checked, root-
    // caused via hierarchical dir_state/q_count/slot state tracing
    // showing the system genuinely idle by the time the old watcher
    // loop started -- the real completions had already come and gone,
    // unobserved).
    always @(posedge clk) begin
        if (!rst) begin
            for (si = 0; si < N_SLOTS; si = si + 1) begin
                if (slot_job_done[si]) begin
                    completions = completions + 2; // covers both A and B
                    case (si)
                        0: begin
                            check_completion(0, GEN_SLOT[0].u_slot.result_node_id_a, GEN_SLOT[0].u_slot.result_data_a);
                            check_completion(0, GEN_SLOT[0].u_slot.result_node_id_b, GEN_SLOT[0].u_slot.result_data_b);
                        end
                        1: begin
                            check_completion(1, GEN_SLOT[1].u_slot.result_node_id_a, GEN_SLOT[1].u_slot.result_data_a);
                            check_completion(1, GEN_SLOT[1].u_slot.result_node_id_b, GEN_SLOT[1].u_slot.result_data_b);
                        end
                    endcase
                end
            end
        end
    end

    task automatic check_completion(input integer slot, input [15:0] nid, input signed [7:0] val);
        integer idx, found;
        begin
            found = 0;
            for (idx = 0; idx < n_expected; idx = idx + 1) begin
                if (expect_node[idx] === nid && !found) begin
                    found = 1;
                    tests = tests + 1;
                    if (expect_val[idx] !== val) begin
                        $display("FAIL slot=%0d node_id=%0d: got=%0d expected=%0d", slot, nid, $signed(val), $signed(expect_val[idx]));
                        errors = errors + 1;
                    end else begin
                        $display("PASS slot=%0d node_id=%0d: result=%0d", slot, nid, $signed(val));
                    end
                end
            end
            if (!found) begin
                $display("FAIL slot=%0d node_id=%0d: completed but was NOT an expected pending job", slot, nid);
                errors = errors + 1;
                tests = tests + 1;
            end
        end
    endtask

    integer li_i, pp_i, wd;

    initial begin
        errors = 0; tests = 0; cyc = 0; n_expected = 0; completions = 0;
        rst = 1; pre_active = 1'b1;
        wpre_req = 0; wpre_wr = 0; wpre_addr = 0; wpre_wdata = 0;
        job_in_valid = 0; job_in_x_base = 0; job_in_w_base = 0;
        job_in_n_tiles = 0; job_in_result_addr = 0; job_in_node_id = 0;
        repeat(5) @(posedge clk);
        rst = 0;
        @(posedge clk); while (ctrl_busy) @(posedge clk);

        $display("=== preload SDRAM with %0d resident-filter weight sets ===", L);
        preload_sdram_layers;
        @(posedge clk);
        pre_active = 1'b0;

        $display("=== N=2 system: submitting %0d layers x %0d positions through neural_director_packed.v ===", L, M);
        for (li_i = 0; li_i < L; li_i = li_i + 1) begin
            for (pp_i = 0; pp_i < M; pp_i = pp_i + 1) begin
                submit_job(li_i*100000 + pp_i*1000, li_i*WORDS_PER_LAYER, N_TILES[15:0],
                           26'h9000 + li_i*10 + pp_i, (li_i*M + pp_i));
                expect_node[n_expected] = (li_i*M + pp_i);
                expect_val[n_expected]  = golden_result(li_i, pp_i);
                n_expected = n_expected + 1;
            end
        end

        wd = 0;
        while (completions < n_expected && wd < 5000) begin
            @(posedge clk);
            wd = wd + 1;
        end

        if (completions < n_expected) begin
            $display("FAIL: only %0d/%0d position-results completed within watchdog", completions, n_expected);
            errors = errors + 1;
        end

        $display("=== %0d/%0d tests, %0d errors, %0d/%0d positions completed ===", tests-errors, tests, errors, completions, n_expected);
        if (errors == 0 && completions == n_expected) $display("ALL TESTS PASSED (tb_np_director_n2_system)");
        $finish;
    end
endmodule
