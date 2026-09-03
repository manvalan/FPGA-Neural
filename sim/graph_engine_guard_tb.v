`timescale 1ns/1ps

// ================================================================
// GRAPH_ENGINE GUARD TESTBENCH (Phase G4)
//
// Deliberately invalid graphs, one per §7 load-time check, each run
// against the REAL memory stack (same harness as
// sim/graph_engine_tb.v). Expected behavior for every case: `err`
// goes high, `busy` drops, `done` is NEVER asserted -- the run
// stops instead of silently producing a wrong result.
//
//   TEST A - src_id >= out_id (self-reference: neuron references
//            its own not-yet-computed output as a source).
//   TEST B - out_id >= N_TOTAL (descriptor's own output id does not
//            fit the activation buffer).
//   TEST C - n_conn_padded == 0 (n_conn=0 neuron -- would forward
//            n_inputs_real=0 to neuron_parallel and hang it).
//
// A `rst` pulse between sub-tests clears `err`/state so each test
// starts clean; TEST D then checks the DOCUMENTED recovery path
// (§7 / graph_engine.v header): a fresh run_start on a VALID graph,
// issued right after an error without an intervening `rst`, clears
// `err` and completes normally.
// ================================================================

module tb;

    localparam ADDR_WIDTH  = 23;
    localparam DATA_WIDTH  = 8;
    localparam MEM_DATA_WIDTH = 16;
    localparam ACC_WIDTH   = 32;
    localparam PARALLEL    = 4;
    localparam MAX_CONN    = 8;
    localparam N_TOTAL     = 4096;
    localparam CLK_PERIOD  = 12.5; // 80 MHz

    localparam ACT_NONE = 2'd0;
    localparam ACT_RELU = 2'd1;

    reg clk;
    reg rst;

    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD / 2.0) clk = ~clk;
    end

    reg                    run_start;
    wire                   busy;
    wire                   done;
    wire                   err;

    reg  [ADDR_WIDTH-1:0]  x_base;
    reg  [ADDR_WIDTH-1:0]  table_base;
    reg  [ADDR_WIDTH-1:0]  out_base;
    reg  [15:0]            n_inputs_graph;
    reg  [15:0]            num_neurons_graph;
    reg  [15:0]            n_out;

    wire                   ge_ram_req;
    wire                   ge_ram_wr;
    wire [ADDR_WIDTH-1:0]  ge_ram_addr;
    wire signed [7:0]      ge_ram_wdata;
    wire signed [7:0]      ge_ram_rdata;
    wire                   ge_ram_ready;

    graph_engine #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .ACC_WIDTH(ACC_WIDTH),
        .PARALLEL(PARALLEL),
        .MAX_CONN(MAX_CONN),
        .N_TOTAL(N_TOTAL)
    ) dut (
        .clk(clk), .rst(rst),
        .run_start(run_start), .busy(busy), .done(done), .err(err),
        .x_base(x_base), .table_base(table_base), .out_base(out_base),
        .n_inputs_graph(n_inputs_graph),
        .num_neurons_graph(num_neurons_graph),
        .n_out(n_out),
        .ram_req(ge_ram_req), .ram_wr(ge_ram_wr),
        .ram_addr(ge_ram_addr), .ram_wdata(ge_ram_wdata),
        .ram_rdata(ge_ram_rdata), .ram_ready(ge_ram_ready)
    );

    reg                    loading;
    reg                    ld_req;
    reg                    ld_wr;
    reg  [ADDR_WIDTH-1:0]  ld_addr;
    reg  signed [7:0]      ld_wdata;

    wire                   mem_req   = loading ? ld_req   : ge_ram_req;
    wire                   mem_wr    = loading ? ld_wr    : ge_ram_wr;
    wire [ADDR_WIDTH-1:0]  mem_addr  = loading ? ld_addr  : ge_ram_addr;
    wire signed [7:0]      mem_wdata = loading ? ld_wdata : ge_ram_wdata;

    wire signed [7:0]      mem_rdata;
    wire                   mem_ready;

    assign ge_ram_rdata = mem_rdata;
    assign ge_ram_ready = mem_ready;

    wire                       i8_mem_req, i8_mem_wr, i8_mem_lb_n, i8_mem_ub_n;
    wire [ADDR_WIDTH-1:0]      i8_mem_addr;
    wire [MEM_DATA_WIDTH-1:0]  i8_mem_wdata, i8_mem_rdata;
    wire                       i8_mem_ready;

    int8_memory_access #(
        .ADDR_WIDTH(ADDR_WIDTH)
    ) u_int8_access (
        .clk(clk), .rst(rst),
        .req(mem_req), .wr(mem_wr), .addr(mem_addr), .wdata(mem_wdata),
        .rdata(mem_rdata), .ready(mem_ready),
        .mem_req(i8_mem_req), .mem_wr(i8_mem_wr), .mem_addr(i8_mem_addr),
        .mem_wdata(i8_mem_wdata), .mem_lb_n(i8_mem_lb_n), .mem_ub_n(i8_mem_ub_n),
        .mem_rdata(i8_mem_rdata), .mem_ready(i8_mem_ready)
    );

    wire                       psram_mem_req, psram_mem_wr, psram_mem_lb_n, psram_mem_ub_n;
    wire [ADDR_WIDTH-1:0]      psram_mem_addr;
    wire [MEM_DATA_WIDTH-1:0]  psram_mem_wdata, psram_mem_rdata;
    wire                       psram_mem_ready;

    memory_interface #(
        .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(MEM_DATA_WIDTH)
    ) u_memory_if (
        .clk(clk), .rst(rst),
        .req(i8_mem_req), .wr(i8_mem_wr), .addr(i8_mem_addr), .wdata(i8_mem_wdata),
        .lb_n(i8_mem_lb_n), .ub_n(i8_mem_ub_n),
        .rdata(i8_mem_rdata), .ready(i8_mem_ready),
        .mem_req(psram_mem_req), .mem_wr(psram_mem_wr), .mem_addr(psram_mem_addr),
        .mem_wdata(psram_mem_wdata), .mem_lb_n(psram_mem_lb_n), .mem_ub_n(psram_mem_ub_n),
        .mem_rdata(psram_mem_rdata), .mem_ready(psram_mem_ready)
    );

    wire [ADDR_WIDTH-1:0]      psram_a;
    wire [MEM_DATA_WIDTH-1:0]  psram_dq;
    wire psram_ce_n, psram_oe_n, psram_we_n, psram_lb_n, psram_ub_n, psram_zz_n;

    psram_controller #(
        .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(MEM_DATA_WIDTH), .CLK_FREQ_MHZ(80)
    ) psram_ctrl (
        .clk(clk), .rst(rst),
        .mem_req(psram_mem_req), .mem_wr(psram_mem_wr), .mem_addr(psram_mem_addr),
        .mem_wdata(psram_mem_wdata), .mem_lb_n(psram_mem_lb_n), .mem_ub_n(psram_mem_ub_n),
        .mem_rdata(psram_mem_rdata), .mem_ready(psram_mem_ready),
        .psram_a(psram_a), .psram_dq(psram_dq),
        .psram_ce_n(psram_ce_n), .psram_oe_n(psram_oe_n), .psram_we_n(psram_we_n),
        .psram_lb_n(psram_lb_n), .psram_ub_n(psram_ub_n), .psram_zz_n(psram_zz_n)
    );

    psram_model #(
        .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(MEM_DATA_WIDTH), .DEPTH(16384)
    ) psram (
        .clk(clk), .a(psram_a), .dq(psram_dq),
        .ce_n(psram_ce_n), .oe_n(psram_oe_n), .we_n(psram_we_n),
        .lb_n(psram_lb_n), .ub_n(psram_ub_n), .zz_n(psram_zz_n)
    );

    task ld_write(input [ADDR_WIDTH-1:0] a, input [7:0] d);
        begin
            @(posedge clk);
            ld_addr <= a; ld_wdata <= $signed(d); ld_wr <= 1'b1; ld_req <= 1'b1;
            @(posedge clk);
            ld_req <= 1'b0;
            wait (mem_ready);
            @(posedge clk);
        end
    endtask

    task write_graph_desc(
        input [ADDR_WIDTH-1:0] base, input [23:0] conn_ptr, input [15:0] n_conn,
        input [15:0] out_id, input [7:0] activation, input [7:0] bias
    );
        begin
            ld_write(base+0,  conn_ptr[23:16]);
            ld_write(base+1,  conn_ptr[15:8]);
            ld_write(base+2,  conn_ptr[7:0]);
            ld_write(base+3,  n_conn[15:8]);
            ld_write(base+4,  n_conn[7:0]);
            ld_write(base+5,  out_id[15:8]);
            ld_write(base+6,  out_id[7:0]);
            ld_write(base+7,  activation);
            ld_write(base+8,  bias);
            ld_write(base+9,  8'h00);
            ld_write(base+10, 8'h00);
        end
    endtask

    task write_edge(input [ADDR_WIDTH-1:0] base, input [15:0] src_id, input [7:0] weight);
        begin
            ld_write(base+0, src_id[15:8]);
            ld_write(base+1, src_id[7:0]);
            ld_write(base+2, weight);
            ld_write(base+3, 8'h00);
        end
    endtask

    localparam X_BASE     = 23'h001000;
    localparam TABLE_BASE = 23'h002000;
    localparam EDGES      = 23'h003000;
    localparam OUT_BASE   = 23'h004000;

    integer errors;
    integer timeout;
    reg      done_latched; // `done` is a one-cycle pulse; latch it at
                            // loop-exit time so the trailing settle
                            // cycle below (which reads live `busy`/
                            // `err`, both sticky, safely) doesn't miss it.

    task do_reset;
        begin
            loading = 1'b1;
            ld_req = 1'b0; ld_wr = 1'b0; ld_addr = 0; ld_wdata = 0;
            run_start <= 1'b0;
            rst = 1'b1;
            repeat (5) @(posedge clk);
            rst = 1'b0;
            wait (psram_ctrl.state == psram_ctrl.STATE_IDLE);
        end
    endtask

    task run_and_wait;
        begin
            run_start <= 1'b1;
            @(posedge clk);
            run_start <= 1'b0;
            // One more edge so the DUT's own nonblocking updates from
            // the run_start edge (state/busy, and err/done clearing on
            // a post-error recovery) are visible before the loop's
            // first condition check -- otherwise that check can race
            // against this same edge and read err/done's stale
            // pre-clear value (seen empirically on the TEST D recovery
            // path, where err was still 1 from the previous sub-test).
            @(posedge clk);
            timeout = 0;
            while (!done && !err && timeout < 5000) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            done_latched = done;
            @(posedge clk); // let busy/err settle one more cycle
        end
    endtask

    task expect_guard_violation(input [255:0] name);
        begin
            if (timeout >= 5000) begin
                $display("FAIL %0s: TIMEOUT, neither done nor err ever asserted", name);
                errors = errors + 1;
            end else if (done_latched) begin
                $display("FAIL %0s: done asserted on an INVALID graph (guard did not trigger)", name);
                errors = errors + 1;
            end else if (!err) begin
                $display("FAIL %0s: err never asserted", name);
                errors = errors + 1;
            end else if (busy) begin
                $display("FAIL %0s: err asserted but busy is still high (execution did not stop)", name);
                errors = errors + 1;
            end else begin
                $display("PASS %0s: err=1, busy=0, done=0 after %0d cycles", name, timeout);
            end
        end
    endtask

    initial begin

        errors = 0;

        // ============================================================
        // TEST A - src_id >= out_id (self-reference)
        // ============================================================

        do_reset;

        x_base = X_BASE; table_base = TABLE_BASE; out_base = OUT_BASE;
        n_inputs_graph = 16'd1;
        num_neurons_graph = 16'd1;
        n_out = 16'd1;

        ld_write(X_BASE+0, 8'sd0);

        // out_id=4, edge0 src_id=4 (== out_id: invalid, self-reference)
        write_graph_desc(TABLE_BASE, EDGES, 16'd1, 16'd4, {6'b0, ACT_RELU}, 8'sd0);
        write_edge(EDGES+0*4, 16'd4, 8'sd1);
        write_edge(EDGES+1*4, 16'd0, 8'sd0);
        write_edge(EDGES+2*4, 16'd0, 8'sd0);
        write_edge(EDGES+3*4, 16'd0, 8'sd0);

        loading = 1'b0;
        @(posedge clk);

        run_and_wait;
        expect_guard_violation("TEST A (src_id >= out_id)");

        // ============================================================
        // TEST B - out_id >= N_TOTAL
        // ============================================================

        do_reset;

        x_base = X_BASE; table_base = TABLE_BASE; out_base = OUT_BASE;
        n_inputs_graph = 16'd1;
        num_neurons_graph = 16'd1;
        n_out = 16'd1;

        ld_write(X_BASE+0, 8'sd0);

        // out_id = N_TOTAL (4096): out of range, src_id=0 is otherwise fine
        write_graph_desc(TABLE_BASE, EDGES, 16'd1, N_TOTAL[15:0], {6'b0, ACT_RELU}, 8'sd0);
        write_edge(EDGES+0*4, 16'd0, 8'sd1);
        write_edge(EDGES+1*4, 16'd0, 8'sd0);
        write_edge(EDGES+2*4, 16'd0, 8'sd0);
        write_edge(EDGES+3*4, 16'd0, 8'sd0);

        loading = 1'b0;
        @(posedge clk);

        run_and_wait;
        expect_guard_violation("TEST B (out_id >= N_TOTAL)");

        // ============================================================
        // TEST C - n_conn_padded == 0 (n_conn=0)
        // ============================================================

        do_reset;

        x_base = X_BASE; table_base = TABLE_BASE; out_base = OUT_BASE;
        n_inputs_graph = 16'd1;
        num_neurons_graph = 16'd1;
        n_out = 16'd1;

        ld_write(X_BASE+0, 8'sd0);

        // n_conn=0 -> n_conn_padded=0, no edges to read at all
        write_graph_desc(TABLE_BASE, EDGES, 16'd0, 16'd4, {6'b0, ACT_RELU}, 8'sd0);

        loading = 1'b0;
        @(posedge clk);

        run_and_wait;
        expect_guard_violation("TEST C (n_conn_padded == 0)");

        // ============================================================
        // TEST D - recovery: a fresh run_start on a VALID graph right
        // after an error (no intervening rst) clears err and completes.
        // ============================================================

        loading = 1'b1;
        x_base = X_BASE; table_base = TABLE_BASE; out_base = OUT_BASE;
        n_inputs_graph = 16'd1;
        num_neurons_graph = 16'd1;
        n_out = 16'd1;

        // valid single neuron: out_id=4, src_id=0 (0 < 4, in range)
        write_graph_desc(TABLE_BASE, EDGES, 16'd1, 16'd4, {6'b0, ACT_RELU}, 8'sd3);
        write_edge(EDGES+0*4, 16'd0, 8'sd2);
        write_edge(EDGES+1*4, 16'd0, 8'sd0);
        write_edge(EDGES+2*4, 16'd0, 8'sd0);
        write_edge(EDGES+3*4, 16'd0, 8'sd0);

        loading = 1'b0;
        @(posedge clk);

        run_and_wait;

        if (!done_latched || err) begin
            $display("FAIL TEST D (recovery): expected done=1 err=0 got done=%0b err=%0b", done_latched, err);
            errors = errors + 1;
        end else begin
            $display("PASS TEST D (recovery): run_start after an error, with no rst, cleared err and completed (%0d cycles)", timeout);
        end

        $display("");
        if (errors == 0) begin
            $display("========================================");
            $display("GRAPH_ENGINE GUARD TEST PASSED (0 errors)");
            $display("========================================");
        end else begin
            $display("========================================");
            $display("GRAPH_ENGINE GUARD TEST FAILED (%0d errors)", errors);
            $display("========================================");
            $fatal;
        end

        $finish;
    end

endmodule
