`timescale 1ns/1ps

// ============================================================
// M6 testbench (docs/v2-description.md §10/§20): dependency_manager.v
// -- a small DAG: node0 and node1 have no dependencies (immediately
// READY); node2 depends on BOTH node0 and node1 (required=2, "multiple
// dependencies"); node3 depends on node0 ALONE (required=1) --
// node0's single completion must satisfy BOTH node2 (partially) and
// node3 (fully), proving "risultati condivisi... piu' consumer" (a
// shared producer feeding multiple waiting consumers).
//
//        node0 --+--> node2 (needs node0 AND node1)
//               \-+--> node3 (needs node0 only)
//        node1 ---+
//
// Verified with Verilator (decisions.log DEC-0004).
// ============================================================

module tb;

    localparam N_NODES    = 8;
    localparam MAX_DEPS   = 4;
    localparam ADDR_WIDTH = 23;
    localparam NODE_IDW   = $clog2(N_NODES);

    reg clk, rst;
    initial begin clk = 0; forever #5 clk = ~clk; end

    reg                                reg_valid;
    wire                               reg_ready;
    reg  [NODE_IDW-1:0]                reg_node_id;
    reg  [$clog2(MAX_DEPS+1)-1:0]      reg_required;
    reg  [MAX_DEPS*NODE_IDW-1:0]       reg_producer_ids;
    reg  [ADDR_WIDTH-1:0]              reg_x_base, reg_w_base, reg_result_addr;
    reg  [15:0]                        reg_n_tiles;

    reg                     producer_done_valid;
    reg  [NODE_IDW-1:0]     producer_done_node_id;

    wire                    ready_valid;
    reg                     ready_ready;
    wire [NODE_IDW-1:0]     ready_node_id;
    wire [ADDR_WIDTH-1:0]   ready_x_base, ready_w_base, ready_result_addr;
    wire [15:0]             ready_n_tiles;

    dependency_manager #(
        .N_NODES(N_NODES), .MAX_DEPS(MAX_DEPS), .ADDR_WIDTH(ADDR_WIDTH)
    ) u_dm (
        .clk(clk), .rst(rst),
        .reg_valid(reg_valid), .reg_ready(reg_ready), .reg_node_id(reg_node_id),
        .reg_required(reg_required), .reg_producer_ids(reg_producer_ids),
        .reg_x_base(reg_x_base), .reg_w_base(reg_w_base), .reg_n_tiles(reg_n_tiles),
        .reg_result_addr(reg_result_addr),
        .producer_done_valid(producer_done_valid), .producer_done_node_id(producer_done_node_id),
        .ready_valid(ready_valid), .ready_ready(ready_ready), .ready_node_id(ready_node_id),
        .ready_x_base(ready_x_base), .ready_w_base(ready_w_base),
        .ready_n_tiles(ready_n_tiles), .ready_result_addr(ready_result_addr)
    );

    integer errors, tests;

    task automatic register_node(
        input [NODE_IDW-1:0] nid,
        input [$clog2(MAX_DEPS+1)-1:0] required,
        input [NODE_IDW-1:0] p0, input [NODE_IDW-1:0] p1,
        input [15:0] n_tiles_tag // used as a unique tag (via n_tiles field) to identify which node got dispatched
    );
        begin
            @(posedge clk);
            reg_node_id  = nid;
            reg_required = required;
            reg_producer_ids = {NODE_IDW*MAX_DEPS{1'b0}};
            reg_producer_ids[0*NODE_IDW +: NODE_IDW] = p0;
            reg_producer_ids[1*NODE_IDW +: NODE_IDW] = p1;
            reg_x_base = {ADDR_WIDTH{1'b0}} + nid;
            reg_w_base = {ADDR_WIDTH{1'b0}} + nid + 100;
            reg_n_tiles = n_tiles_tag;
            reg_result_addr = {ADDR_WIDTH{1'b0}} + nid + 200;
            reg_valid = 1'b1;
            while (!reg_ready) @(posedge clk);
            @(posedge clk);
            reg_valid = 1'b0;
        end
    endtask

    // Collect dispatched node ids (in order) into a small scoreboard.
    reg [NODE_IDW-1:0] dispatched [0:15];
    integer n_dispatched;

    task automatic collect_one_dispatch(input integer watchdog_max);
        integer wd;
        begin
            ready_ready = 1'b1;
            wd = 0;
            while (!ready_valid && wd < watchdog_max) begin @(posedge clk); wd = wd + 1; end
            if (!ready_valid) begin
                $display("FAIL: no ready_valid within watchdog (n_dispatched so far=%0d)", n_dispatched);
                errors = errors + 1;
            end else begin
                dispatched[n_dispatched] = ready_node_id;
                $display("DISPATCH node_id=%0d (n_tiles tag=%0d)", ready_node_id, ready_n_tiles);
                n_dispatched = n_dispatched + 1;
                @(posedge clk);
            end
        end
    endtask

    integer i;

    initial begin
        errors = 0; tests = 0; n_dispatched = 0;
        rst = 1; reg_valid = 0; producer_done_valid = 0; ready_ready = 0;
        reg_node_id = 0; reg_required = 0; reg_producer_ids = 0;
        reg_x_base = 0; reg_w_base = 0; reg_n_tiles = 0; reg_result_addr = 0;
        producer_done_node_id = 0;
        repeat(4) @(posedge clk);
        rst = 0;
        @(posedge clk);

        // node0, node1: no dependencies -> immediately READY
        register_node(0, 0, 0, 0, 16'd1000);
        register_node(1, 0, 0, 0, 16'd1001);
        // node2: depends on BOTH node0 and node1 (multiple dependencies)
        register_node(2, 2, 0, 1, 16'd1002);
        // node3: depends on node0 ONLY (shared producer, multiple consumers)
        register_node(3, 1, 0, 0, 16'd1003);

        // ---- TEST 1: node0 and node1 must both be dispatched first
        // (they were already READY at registration) -- order between
        // them is not asserted (both are simultaneously ready,
        // first-found scan is deterministic but not part of the
        // contract), just that BOTH appear before node2/node3. ----
        tests = tests + 1;
        collect_one_dispatch(50);
        collect_one_dispatch(50);
        if (!((dispatched[0] == 0 && dispatched[1] == 1) || (dispatched[0] == 1 && dispatched[1] == 0))) begin
            $display("FAIL: expected node0+node1 dispatched first (in either order), got %0d,%0d", dispatched[0], dispatched[1]);
            errors = errors + 1;
        end else $display("PASS: node0 and node1 (no dependencies) dispatched first, in either order");

        // node2/node3 must NOT be ready yet (still WAITING)
        tests = tests + 1;
        ready_ready = 1'b0;
        repeat(5) @(posedge clk);
        if (ready_valid) begin
            $display("FAIL: a node became ready before any producer_done -- got node_id=%0d", ready_node_id);
            errors = errors + 1;
        end else $display("PASS: node2/node3 correctly still WAITING (no producer_done yet)");

        // ---- TEST 2: node0 completes -> node3 (needs only node0)
        // becomes READY; node2 (needs node0 AND node1) does NOT yet. ----
        tests = tests + 1;
        producer_done_node_id = 0;
        producer_done_valid = 1'b1;
        @(posedge clk);
        producer_done_valid = 1'b0;
        collect_one_dispatch(50);
        if (dispatched[2] !== 3) begin
            $display("FAIL: expected node3 to become ready right after node0 completed, got node_id=%0d", dispatched[2]);
            errors = errors + 1;
        end else $display("PASS: node3 (single dependency on node0) became READY right after node0 completed");

        ready_ready = 1'b0;
        repeat(5) @(posedge clk);
        if (ready_valid) begin
            $display("FAIL: node2 became ready after only ONE of its two dependencies (node0) completed -- got node_id=%0d", ready_node_id);
            errors = errors + 1;
        end else $display("PASS: node2 correctly still WAITING (only 1/2 dependencies resolved)");

        // ---- TEST 3: node1 completes -> node2 (needed BOTH) now
        // becomes READY -- "multiple dependencies" fully resolved. ----
        tests = tests + 1;
        producer_done_node_id = 1;
        producer_done_valid = 1'b1;
        @(posedge clk);
        producer_done_valid = 1'b0;
        collect_one_dispatch(50);
        if (dispatched[3] !== 2) begin
            $display("FAIL: expected node2 to become ready after BOTH node0 and node1 completed, got node_id=%0d", dispatched[3]);
            errors = errors + 1;
        end else $display("PASS: node2 (two dependencies, node0+node1) became READY only after BOTH completed");

        $display("========================================");
        if (errors == 0)
            $display("ALL %0d TESTS PASSED (dependency_manager -- multi-dependency + shared-producer/multi-consumer wake-up)", tests);
        else
            $display("FAILED: %0d/%0d test(s) had errors -- see messages above", errors, tests);
        $display("========================================");
        $finish;
    end

endmodule
