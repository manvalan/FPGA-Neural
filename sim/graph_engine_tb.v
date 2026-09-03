`timescale 1ns/1ps

// ================================================================
// GRAPH_ENGINE TESTBENCH (Phase G3)
//
// End-to-end test of graph_engine through the REAL memory stack
// (int8_memory_access + memory_interface + psram_controller +
// psram_model), same harness style as sim/graph_format_tb.v.
//
// Graph under test (§3 worked example, hand-computed):
//   4 inputs: x0=10, x1=1, x2=4, x3=0 (unused by any edge).
//   n4 (out_id=4, ACT_RELU, bias=2): 2 real edges (src=0,w=5),
//     (src=1,w=-3), PARALLEL=4 so n_conn_padded=4 -> 2 host-inserted
//     zero-weight padding edges (src=0,w=0) x2. Exercises §2.6
//     padding end to end, not just as a format detail.
//       sum = 10*5 + 1*(-3) + 0 + 0 = 47; +bias(2) = 49; relu -> 49.
//   n5 (out_id=5, ACT_NONE, bias=0), the sole OUTPUT (n_out=1): 2
//     real edges (src=4,w=2) [n4's own output, src_id<out_id holds:
//     4<5], (src=2,w=7), same PARALLEL=4 padding (2x (src=0,w=0)).
//       sum = 49*2 + 4*7 + 0 + 0 = 126; +bias(0) = 126; none,
//       no saturation (126 <= 127) -> 126.
//
// Verifies (via hierarchical peeks at the DUT's private act_buffer
// and at the psram_model backing store, consistent with this
// repo's existing testbench style, e.g. psram_ctrl.state elsewhere):
//   - act_buf[0..3] hold the copied-in inputs.
//   - act_buf[4] == 49, act_buf[5] == 126 (gather + neuron_parallel
//     + padding all correct).
//   - the single output byte at out_base == 126 (folded WRITE_OUTPUTS
//     copy for the sink neuron).
//   - busy/done handshake behaves like the rest of the project's
//     orchestration modules.
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

    // ============================================================
    // graph_engine
    // ============================================================

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

    // ============================================================
    // Real memory stack, shared between two masters: the testbench
    // itself (for loading the graph before run_start) and
    // graph_engine (during the run). Mutually exclusive in time
    // (the tb only drives loader_* before run_start / after done),
    // so a simple wire-OR style mux keyed on `loading` is enough --
    // no arbiter needed for a unit-level testbench.
    // ============================================================

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

    // ============================================================
    // Loader tasks (testbench-side master, active only while
    // `loading` is asserted and graph_engine is idle)
    // ============================================================

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
    localparam N4_EDGES   = 23'h003000;
    localparam N5_EDGES   = 23'h003100;
    localparam OUT_BASE   = 23'h004000;

    integer errors;

    task check_word(input [ADDR_WIDTH-1:0] w_addr, input signed [15:0] expected, input [255:0] name);
        reg signed [15:0] got;
        begin
            got = psram.mem[w_addr >> 1];
            if (got !== expected) begin
                $display("FAIL %0s: word_addr=0x%06x expected=%0d got=%0d", name, w_addr>>1, expected, got);
                errors = errors + 1;
            end else begin
                $display("PASS %0s: value=%0d", name, got);
            end
        end
    endtask

    task check_act(input [11:0] id, input signed [7:0] expected, input [255:0] name);
        reg signed [7:0] got;
        begin
            got = dut.u_act_buffer.mem[id];
            if (got !== expected) begin
                $display("FAIL %0s: act_buf[%0d] expected=%0d got=%0d", name, id, expected, got);
                errors = errors + 1;
            end else begin
                $display("PASS %0s: act_buf[%0d]=%0d", name, id, got);
            end
        end
    endtask

    task check_out_byte(input [ADDR_WIDTH-1:0] byte_addr, input signed [7:0] expected, input [255:0] name);
        reg [15:0] w;
        reg signed [7:0] got;
        begin
            w = psram.mem[byte_addr >> 1];
            got = byte_addr[0] ? w[15:8] : w[7:0];
            if (got !== expected) begin
                $display("FAIL %0s: byte_addr=0x%06x expected=%0d got=%0d", name, byte_addr, expected, got);
                errors = errors + 1;
            end else begin
                $display("PASS %0s: value=%0d", name, got);
            end
        end
    endtask

    integer timeout;

    initial begin

        errors  = 0;
        loading = 1'b1;
        ld_req = 1'b0; ld_wr = 1'b0; ld_addr = 0; ld_wdata = 0;
        run_start = 1'b0;
        x_base = X_BASE; table_base = TABLE_BASE; out_base = OUT_BASE;
        n_inputs_graph = 16'd4;
        num_neurons_graph = 16'd2;
        n_out = 16'd1;

        rst = 1'b1;
        repeat (5) @(posedge clk);
        rst = 1'b0;

        wait (psram_ctrl.state == psram_ctrl.STATE_IDLE);

        $display("");
        $display("========================================");
        $display("GRAPH_ENGINE CORE TEST (Phase G3)");
        $display("========================================");
        $display("");

        // ---- load inputs ----
        ld_write(X_BASE+0, 8'sd10); // x0
        ld_write(X_BASE+1, 8'sd1);  // x1
        ld_write(X_BASE+2, 8'sd4);  // x2
        ld_write(X_BASE+3, 8'sd0);  // x3 (unused)

        // ---- descriptor table (out_id ascending: n4 then n5) ----
        write_graph_desc(TABLE_BASE+0*11, N4_EDGES, 16'd2, 16'd4, {6'b0, ACT_RELU}, 8'sd2);
        write_graph_desc(TABLE_BASE+1*11, N5_EDGES, 16'd2, 16'd5, {6'b0, ACT_NONE}, 8'sd0);

        // ---- n4 edges: 2 real + 2 host-inserted zero-weight padding ----
        write_edge(N4_EDGES+0*4,  16'd0, 8'sd5);
        write_edge(N4_EDGES+1*4,  16'd1, -8'sd3);
        write_edge(N4_EDGES+2*4,  16'd0, 8'sd0); // padding
        write_edge(N4_EDGES+3*4,  16'd0, 8'sd0); // padding

        // ---- n5 edges: 2 real (incl. src=n4's own out_id=4) + 2 padding ----
        write_edge(N5_EDGES+0*4,  16'd4, 8'sd2);
        write_edge(N5_EDGES+1*4,  16'd2, 8'sd7);
        write_edge(N5_EDGES+2*4,  16'd0, 8'sd0); // padding
        write_edge(N5_EDGES+3*4,  16'd0, 8'sd0); // padding

        loading = 1'b0;
        @(posedge clk);

        $display("-- load done, starting graph run --");
        $display("");

        // ---- run ----
        run_start <= 1'b1;
        @(posedge clk);
        run_start <= 1'b0;

        timeout = 0;
        while (!done && timeout < 5000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end

        if (timeout >= 5000) begin
            $display("FAIL: TIMEOUT waiting for done (busy=%0b err=%0b)", busy, err);
            errors = errors + 1;
        end else begin
            $display("PASS: done asserted after %0d cycles (err=%0b)", timeout, err);
        end

        if (err !== 1'b0) begin
            $display("FAIL: err unexpectedly asserted on a valid graph");
            errors = errors + 1;
        end

        @(posedge clk);
        if (busy !== 1'b0) begin
            $display("FAIL: busy did not drop after done");
            errors = errors + 1;
        end

        $display("");
        $display("-- checking activation buffer --");

        check_act(0, 8'sd10, "act_buf input id0");
        check_act(1, 8'sd1,  "act_buf input id1");
        check_act(2, 8'sd4,  "act_buf input id2");
        check_act(3, 8'sd0,  "act_buf input id3");
        check_act(4, 8'sd49, "act_buf n4 output (id4)");
        check_act(5, 8'sd126,"act_buf n5 output (id5)");

        $display("");
        $display("-- checking output copy to out_base --");

        // resume tb mastership to peek via a fresh read, but the
        // psram_model backing store can be inspected directly
        // regardless of which master last touched the bus.
        check_out_byte(OUT_BASE+0, 8'sd126, "out_base[0] (n5, the sole output)");

        $display("");
        if (errors == 0) begin
            $display("========================================");
            $display("GRAPH_ENGINE CORE TEST PASSED (0 errors)");
            $display("========================================");
        end else begin
            $display("========================================");
            $display("GRAPH_ENGINE CORE TEST FAILED (%0d errors)", errors);
            $display("========================================");
            $fatal;
        end

        $finish;
    end

endmodule
