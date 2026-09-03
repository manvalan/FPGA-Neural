`timescale 1ns/1ps

// ================================================================
// GRAPH_ENGINE GATHER BANDWIDTH BENCHMARK
//
// Open item from the spec's final note (§11): "banda PSRAM del
// gather" was never measured quantitatively. This testbench isolates
// the marginal cost of ONE extra edge by running the SAME N-neuron
// chain twice, once with K1 edges/neuron and once with K2 (K2>K1),
// and taking the cycle-count DIFFERENCE -- this cancels out every
// fixed per-neuron cost (descriptor read, neuron_parallel compute,
// WRITE_ACT) and leaves only the marginal per-edge gather cost:
//
//   cycles_per_edge = (cycles(K2) - cycles(K1)) / (N*(K2-K1))
//
// Graph shape: N neurons (ids 1..N), each with K edges, all
// referencing id 0 (weight 0) -- content is irrelevant, only the
// EDGE COUNT drives gather traffic. K is always a PARALLEL multiple
// so there is zero padding waste to confound the measurement.
// ================================================================

module tb;

    localparam ADDR_WIDTH  = 23;
    localparam DATA_WIDTH  = 8;
    localparam MEM_DATA_WIDTH = 16;
    localparam ACC_WIDTH   = 32;
    localparam PARALLEL    = 4;
    localparam MAX_CONN    = 8;
    localparam N_TOTAL     = 4096;
    localparam CLK_FREQ_MHZ = 80;
    localparam CLK_PERIOD  = 1000.0 / CLK_FREQ_MHZ;

    localparam N_NEURONS = 16;
    localparam K1 = 4;
    localparam K2 = 8;

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
        .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH),
        .PARALLEL(PARALLEL), .MAX_CONN(MAX_CONN), .N_TOTAL(N_TOTAL)
    ) dut (
        .clk(clk), .rst(rst),
        .run_start(run_start), .busy(busy), .done(done), .err(err),
        .x_base(x_base), .table_base(table_base), .out_base(out_base),
        .n_inputs_graph(n_inputs_graph),
        .num_neurons_graph(num_neurons_graph), .n_out(n_out),
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

    int8_memory_access #(.ADDR_WIDTH(ADDR_WIDTH)) u_int8_access (
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

    memory_interface #(.ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(MEM_DATA_WIDTH)) u_memory_if (
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
        .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(MEM_DATA_WIDTH), .CLK_FREQ_MHZ(CLK_FREQ_MHZ)
    ) psram_ctrl (
        .clk(clk), .rst(rst),
        .mem_req(psram_mem_req), .mem_wr(psram_mem_wr), .mem_addr(psram_mem_addr),
        .mem_wdata(psram_mem_wdata), .mem_lb_n(psram_mem_lb_n), .mem_ub_n(psram_mem_ub_n),
        .mem_rdata(psram_mem_rdata), .mem_ready(psram_mem_ready),
        .psram_a(psram_a), .psram_dq(psram_dq),
        .psram_ce_n(psram_ce_n), .psram_oe_n(psram_oe_n), .psram_we_n(psram_we_n),
        .psram_lb_n(psram_lb_n), .psram_ub_n(psram_ub_n), .psram_zz_n(psram_zz_n)
    );

    psram_model #(.ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(MEM_DATA_WIDTH), .DEPTH(65536)) psram (
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

    localparam X_BASE     = 23'h000000;
    localparam TABLE_BASE = 23'h001000;
    localparam EDGES_BASE = 23'h004000;
    localparam OUT_BASE   = 23'h00F000;

    localparam ACT_NONE = 8'h00;

    integer i, e;
    integer cycles_k1, cycles_k2;
    reg [ADDR_WIDTH-1:0] edge_addr;

    task build_and_run_chain(input integer k, output integer cycles);
        begin
            loading = 1'b1;
            ld_req = 1'b0; ld_wr = 1'b0; ld_addr = 0; ld_wdata = 0;
            run_start = 1'b0;
            rst = 1'b1;
            repeat (5) @(posedge clk);
            rst = 1'b0;
            wait (psram_ctrl.state == psram_ctrl.STATE_IDLE);

            ld_write(X_BASE, 8'sd0); // id0 input

            for (i = 1; i <= N_NEURONS; i = i + 1) begin
                edge_addr = EDGES_BASE + (i-1)*k*4;
                write_graph_desc(TABLE_BASE + (i-1)*11, edge_addr, k[15:0], i[15:0], ACT_NONE, 8'sd0);
                for (e = 0; e < k; e = e + 1)
                    write_edge(edge_addr + e*4, 16'd0, 8'sd0);
            end

            loading = 1'b0;
            @(posedge clk);

            x_base = X_BASE; table_base = TABLE_BASE; out_base = OUT_BASE;
            n_inputs_graph = 16'd1;
            num_neurons_graph = N_NEURONS[15:0];
            n_out = 16'd1;

            run_start <= 1'b1;
            @(posedge clk);
            run_start <= 1'b0;
            @(posedge clk);

            cycles = 0;
            while (!done && !err && cycles < 200000) begin
                @(posedge clk);
                cycles = cycles + 1;
            end
        end
    endtask

    real cycles_per_edge, edges_per_sec, bytes_per_sec_gather;

    initial begin
        $display("");
        $display("========================================");
        $display("GRAPH_ENGINE GATHER BANDWIDTH BENCHMARK");
        $display("========================================");
        $display("N_NEURONS=%0d, PARALLEL=%0d, CLK_FREQ_MHZ=%0d", N_NEURONS, PARALLEL, CLK_FREQ_MHZ);
        $display("");

        build_and_run_chain(K1, cycles_k1);
        if (err) $display("FAIL: err asserted on K1=%0d run", K1);
        $display("K1=%0d edges/neuron (%0d total edges): %0d cycles", K1, N_NEURONS*K1, cycles_k1);

        build_and_run_chain(K2, cycles_k2);
        if (err) $display("FAIL: err asserted on K2=%0d run", K2);
        $display("K2=%0d edges/neuron (%0d total edges): %0d cycles", K2, N_NEURONS*K2, cycles_k2);

        cycles_per_edge = (cycles_k2 - cycles_k1) * 1.0 / (N_NEURONS * (K2 - K1));
        edges_per_sec   = (CLK_FREQ_MHZ * 1_000_000.0) / cycles_per_edge;
        bytes_per_sec_gather = edges_per_sec * 4.0; // 4 bytes/edge read from PSRAM

        $display("");
        $display("-- marginal cost per edge (isolates gather from fixed per-neuron overhead) --");
        $display("cycles/edge      = %0.2f", cycles_per_edge);
        $display("at %0d MHz: edges/sec = %0.0f, effective edge-stream bandwidth = %0.2f MB/s",
                  CLK_FREQ_MHZ, edges_per_sec, bytes_per_sec_gather / 1_000_000.0);
        $display("at 16 MHz (real oscillator, WORKLOG.md hardware target): edges/sec = %0.0f, bandwidth = %0.2f MB/s",
                  (16_000_000.0 / cycles_per_edge), (16_000_000.0 / cycles_per_edge) * 4.0 / 1_000_000.0);
        $display("");

        $finish;
    end

    initial begin
        #500000000;
        $display("TIMEOUT: benchmark did not finish in time");
        $finish;
    end

endmodule
