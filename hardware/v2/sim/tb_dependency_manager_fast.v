`timescale 1ns/1ps

// ============================================================
// EXP-0056 -- bit-exact equivalence check: dependency_manager.v
// (baseline) vs dependency_manager_fast.v (priority_encoder_lsb.v
// fix), at N_NODES=1024 -- the REAL config this project's own
// D-Stress benchmark uses, not the small hand-crafted DAG the
// original tb_dependency_manager.v exercises. Both DUTs driven by the
// IDENTICAL random stimulus every cycle (registration + producer-done
// events), every output compared cycle-by-cycle. Pure random
// (required/producer_ids need not form a realistic DAG -- this
// module's own behavior is well-defined for ANY input sequence, and
// bit-exact equivalence for ANY sequence is exactly the property that
// needs proving here).
// ============================================================
module tb;
    localparam N_NODES    = 1024;
    localparam MAX_DEPS   = 4;
    localparam ADDR_WIDTH = 26;
    localparam NODE_IDW   = $clog2(N_NODES);

    reg clk, rst;
    initial begin clk = 0; forever #5 clk = ~clk; end

    reg                                reg_valid;
    reg  [NODE_IDW-1:0]                reg_node_id;
    reg  [$clog2(MAX_DEPS+1)-1:0]      reg_required;
    reg  [MAX_DEPS*NODE_IDW-1:0]       reg_producer_ids;
    reg  [ADDR_WIDTH-1:0]              reg_x_base, reg_w_base, reg_result_addr;
    reg  [15:0]                        reg_n_tiles;

    reg                     producer_done_valid;
    reg  [NODE_IDW-1:0]     producer_done_node_id;

    reg                     ready_ready;

    wire reg_ready_a, reg_ready_b;
    wire ready_valid_a, ready_valid_b;
    wire [NODE_IDW-1:0]   ready_node_id_a, ready_node_id_b;
    wire [ADDR_WIDTH-1:0] ready_x_base_a, ready_x_base_b;
    wire [ADDR_WIDTH-1:0] ready_w_base_a, ready_w_base_b;
    wire [15:0]            ready_n_tiles_a, ready_n_tiles_b;
    wire [ADDR_WIDTH-1:0] ready_result_addr_a, ready_result_addr_b;
    wire any_pending_a, any_pending_b;

    dependency_manager #(
        .N_NODES(N_NODES), .MAX_DEPS(MAX_DEPS), .ADDR_WIDTH(ADDR_WIDTH)
    ) dut_base (
        .clk(clk), .rst(rst),
        .reg_valid(reg_valid), .reg_ready(reg_ready_a), .reg_node_id(reg_node_id),
        .reg_required(reg_required), .reg_producer_ids(reg_producer_ids),
        .reg_x_base(reg_x_base), .reg_w_base(reg_w_base), .reg_n_tiles(reg_n_tiles),
        .reg_result_addr(reg_result_addr),
        .producer_done_valid(producer_done_valid), .producer_done_node_id(producer_done_node_id),
        .ready_valid(ready_valid_a), .ready_ready(ready_ready), .ready_node_id(ready_node_id_a),
        .ready_x_base(ready_x_base_a), .ready_w_base(ready_w_base_a),
        .ready_n_tiles(ready_n_tiles_a), .ready_result_addr(ready_result_addr_a),
        .any_pending(any_pending_a)
    );

    dependency_manager_fast #(
        .N_NODES(N_NODES), .MAX_DEPS(MAX_DEPS), .ADDR_WIDTH(ADDR_WIDTH)
    ) dut_fast (
        .clk(clk), .rst(rst),
        .reg_valid(reg_valid), .reg_ready(reg_ready_b), .reg_node_id(reg_node_id),
        .reg_required(reg_required), .reg_producer_ids(reg_producer_ids),
        .reg_x_base(reg_x_base), .reg_w_base(reg_w_base), .reg_n_tiles(reg_n_tiles),
        .reg_result_addr(reg_result_addr),
        .producer_done_valid(producer_done_valid), .producer_done_node_id(producer_done_node_id),
        .ready_valid(ready_valid_b), .ready_ready(ready_ready), .ready_node_id(ready_node_id_b),
        .ready_x_base(ready_x_base_b), .ready_w_base(ready_w_base_b),
        .ready_n_tiles(ready_n_tiles_b), .ready_result_addr(ready_result_addr_b),
        .any_pending(any_pending_b)
    );

    integer errors, tests, cyc;
    integer seed, i;
    integer next_id;
    reg [NODE_IDW-1:0] rnd_id;

    task automatic check_equal;
        begin
            tests = tests + 1;
            if (reg_ready_a !== reg_ready_b || ready_valid_a !== ready_valid_b ||
                any_pending_a !== any_pending_b ||
                (ready_valid_a && (ready_node_id_a !== ready_node_id_b ||
                                    ready_x_base_a !== ready_x_base_b ||
                                    ready_w_base_a !== ready_w_base_b ||
                                    ready_n_tiles_a !== ready_n_tiles_b ||
                                    ready_result_addr_a !== ready_result_addr_b))) begin
                $display("FAIL @cycle %0d: base(reg_ready=%b ready_valid=%b node=%0d any_pending=%b) fast(reg_ready=%b ready_valid=%b node=%0d any_pending=%b)",
                    cyc, reg_ready_a, ready_valid_a, ready_node_id_a, any_pending_a,
                         reg_ready_b, ready_valid_b, ready_node_id_b, any_pending_b);
                errors = errors + 1;
            end
        end
    endtask

    always @(posedge clk) if (!rst) cyc <= cyc + 1;

    initial begin
        errors = 0; tests = 0; cyc = 0; seed = 32'hFEEDFACE;
        rst = 1; reg_valid = 0; reg_node_id = 0; reg_required = 0; reg_producer_ids = 0;
        reg_x_base = 0; reg_w_base = 0; reg_n_tiles = 0; reg_result_addr = 0;
        producer_done_valid = 0; producer_done_node_id = 0;
        ready_ready = 1;
        repeat(5) @(posedge clk);
        rst = 0;

        $display("=== random stimulus, N_NODES=1024, 20000 cycles ===");
        next_id = 0;
        for (i = 0; i < 20000; i = i + 1) begin
            @(posedge clk);
            #1; // let combinational outputs settle before sampling/comparing

            // registration: ~15% of cycles, sequential node_id (avoids
            // double-registering the same id, which the module itself
            // does not need to tolerate -- caller's own responsibility,
            // same as the real Director/graph-loader upstream)
            reg_valid = (($random(seed) % 100) < 15) && (next_id < N_NODES);
            if (reg_valid) begin
                reg_node_id      = next_id[NODE_IDW-1:0];
                reg_required     = $random(seed) % (MAX_DEPS+1);
                reg_x_base       = $random(seed);
                reg_w_base       = $random(seed);
                reg_n_tiles      = $random(seed);
                reg_result_addr  = $random(seed);
                reg_producer_ids = {$random(seed), $random(seed)}; // random bits, need not be a valid/realistic producer graph
                next_id = next_id + 1;
            end

            // producer-done: ~10% of cycles, random already-issued id
            producer_done_valid = (($random(seed) % 100) < 10) && (next_id > 0);
            if (producer_done_valid) begin
                rnd_id = ($random(seed) % next_id);
                producer_done_node_id = rnd_id;
            end

            // ready_ready: randomly withhold backpressure sometimes,
            // to exercise the "ready_valid held, not yet accepted" path
            ready_ready = (($random(seed) % 100) < 80);

            check_equal;
        end

        $display("=== %0d/%0d cycles matched, %0d mismatches ===", tests-errors, tests, errors);
        if (errors == 0) $display("ALL TESTS PASSED (tb_dependency_manager_fast, bit-exact vs baseline)");
        $finish;
    end
endmodule
