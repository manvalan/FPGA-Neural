`timescale 1ns/1ps

// ================================================================
// PHASE 3 - NEURON_MEMORY MULTI-NEURON TEST
//
// neuron_memory.v originally only handled N_NEURONS=1. It now
// loops over N_NEURONS, reading X once (shared) and re-reading W
// and bias per neuron from memory (neuron-major layout, same
// convention as layer.v's weights_bus/bias_bus), reusing a single
// neuron_parallel instance. This bench validates that loop end to
// end through the full memory stack (memory_interface + PSRAM
// controller + PSRAM model), not just the RTL in isolation.
//
// N_NEURONS = 3, N_INPUTS = 32:
//   X shared, all inputs = 1
//   Neuron 0: W=1,  bias=0  -> 32
//   Neuron 1: W=2,  bias=0  -> 64
//   Neuron 2: W=-1, bias=0  -> -32 -> ReLU -> 0
// ================================================================

module tb;

    localparam ADDR_WIDTH = 23;
    localparam DATA_WIDTH = 16;
    localparam CLK_PERIOD = 12.5; // 80 MHz

    localparam N_NEURONS = 3;
    localparam N_INPUTS  = 32;

    // ============================================================
    // CLOCK / RESET
    // ============================================================

    reg clk;
    reg rst;

    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD / 2.0) clk = ~clk;
    end

    // ============================================================
    // NEURON MEMORY
    // ============================================================

    reg start;

    reg [ADDR_WIDTH-1:0] x_base;
    reg [ADDR_WIDTH-1:0] w_base;
    reg [ADDR_WIDTH-1:0] bias_addr;

    wire signed [DATA_WIDTH/2*N_NEURONS-1:0] y_bus;
    wire busy;
    wire done;

    // neuron_memory -> memory_interface
    wire                   neuron_mem_req;
    wire                   neuron_mem_wr;
    wire [ADDR_WIDTH-1:0]  neuron_mem_addr;
    wire signed [7:0]      neuron_mem_wdata;

    wire signed [7:0]      neuron_mem_rdata;
    wire                   neuron_mem_ready;

    // ============================================================
    // TB PRELOAD MASTER
    //
    // Direct 16-bit master.
    // Used only before starting neuron_memory.
    // ============================================================

    reg                   tb_mem_req;
    reg                   tb_mem_wr;
    reg [ADDR_WIDTH-1:0]  tb_mem_addr;
    reg [DATA_WIDTH-1:0]  tb_mem_wdata;
    reg                   tb_mem_lb_n;
    reg                   tb_mem_ub_n;

    wire [DATA_WIDTH-1:0] tb_mem_rdata;
    wire                  tb_mem_ready;

    // ============================================================
    // SINGLE MASTER MUX
    //
    // 0 = TB preload master
    // 1 = neuron_memory master
    // ============================================================

    reg use_neuron_master;

    wire                   master_req;
    wire                   master_wr;
    wire [ADDR_WIDTH-1:0]  master_addr;
    wire [DATA_WIDTH-1:0]  master_wdata;
    wire                   master_lb_n;
    wire                   master_ub_n;

    // ============================================================
    // MEMORY INTERFACE
    // ============================================================

    wire [DATA_WIDTH-1:0] memory_rdata;
    wire                  memory_ready;

    wire                  memory_mem_req;
    wire                  memory_mem_wr;
    wire [ADDR_WIDTH-1:0] memory_mem_addr;
    wire [DATA_WIDTH-1:0] memory_mem_wdata;
    wire                  memory_mem_lb_n;
    wire                  memory_mem_ub_n;

    wire [DATA_WIDTH-1:0] psram_mem_rdata;
    wire                  psram_mem_ready;

    assign master_req =
        use_neuron_master ? neuron_mem_req : tb_mem_req;

    assign master_wr =
        use_neuron_master ? neuron_mem_wr : tb_mem_wr;

    assign master_addr =
        use_neuron_master ? (neuron_mem_addr >> 1) : tb_mem_addr;

    assign master_wdata =
        use_neuron_master
            ? (neuron_mem_addr[0]
                ? {neuron_mem_wdata, 8'h00}
                : {8'h00, neuron_mem_wdata})
            : tb_mem_wdata;

    assign master_lb_n =
        use_neuron_master
            ? (neuron_mem_addr[0] ? 1'b1 : 1'b0)
            : tb_mem_lb_n;

    assign master_ub_n =
        use_neuron_master
            ? (neuron_mem_addr[0] ? 1'b0 : 1'b1)
            : tb_mem_ub_n;

    // Return path
    assign tb_mem_rdata = memory_rdata;
    assign tb_mem_ready = memory_ready;

    assign neuron_mem_rdata =
        neuron_mem_addr[0]
            ? memory_rdata[15:8]
            : memory_rdata[7:0];

    assign neuron_mem_ready = memory_ready;

    memory_interface #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH)
    ) u_memory_if (
        .clk(clk),
        .rst(rst),

        .req(master_req),
        .wr(master_wr),
        .addr(master_addr),
        .wdata(master_wdata),
        .lb_n(master_lb_n),
        .ub_n(master_ub_n),

        .rdata(memory_rdata),
        .ready(memory_ready),

        .mem_req(memory_mem_req),
        .mem_wr(memory_mem_wr),
        .mem_addr(memory_mem_addr),
        .mem_wdata(memory_mem_wdata),
        .mem_lb_n(memory_mem_lb_n),
        .mem_ub_n(memory_mem_ub_n),

        .mem_rdata(psram_mem_rdata),
        .mem_ready(psram_mem_ready)
    );

    // ============================================================
    // PSRAM PHYSICAL INTERFACE
    // ============================================================

    wire [ADDR_WIDTH-1:0] psram_a;
    wire [DATA_WIDTH-1:0] psram_dq;

    wire psram_ce_n;
    wire psram_oe_n;
    wire psram_we_n;
    wire psram_lb_n;
    wire psram_ub_n;
    wire psram_zz_n;

    // ============================================================
    // PSRAM CONTROLLER
    // ============================================================

    psram_controller #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .CLK_FREQ_MHZ(80)
    ) u_psram_ctrl (
        .clk(clk),
        .rst(rst),

        .mem_req(memory_mem_req),
        .mem_wr(memory_mem_wr),
        .mem_addr(memory_mem_addr),
        .mem_wdata(memory_mem_wdata),
        .mem_lb_n(memory_mem_lb_n),
        .mem_ub_n(memory_mem_ub_n),

        .mem_rdata(psram_mem_rdata),
        .mem_ready(psram_mem_ready),

        .psram_a(psram_a),
        .psram_dq(psram_dq),
        .psram_ce_n(psram_ce_n),
        .psram_oe_n(psram_oe_n),
        .psram_we_n(psram_we_n),
        .psram_lb_n(psram_lb_n),
        .psram_ub_n(psram_ub_n),
        .psram_zz_n(psram_zz_n)
    );

    // ============================================================
    // PSRAM MODEL
    // ============================================================

    psram_model #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .DEPTH(16384)
    ) u_psram (
        .clk(clk),
        .a(psram_a),
        .dq(psram_dq),
        .ce_n(psram_ce_n),
        .oe_n(psram_oe_n),
        .we_n(psram_we_n),
        .lb_n(psram_lb_n),
        .ub_n(psram_ub_n),
        .zz_n(psram_zz_n)
    );

    // ============================================================
    // NEURON MEMORY (N_NEURONS = 3)
    // ============================================================

    neuron_memory #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(8),
        .N_INPUTS(N_INPUTS),
        .N_NEURONS(N_NEURONS),
        .PARALLEL(8),
        .ACC_WIDTH(32)
    ) u_neuron (
        .clk(clk),
        .rst(rst),
        .start(start),

        .mem_req(neuron_mem_req),
        .mem_wr(neuron_mem_wr),
        .mem_addr(neuron_mem_addr),
        .mem_wdata(neuron_mem_wdata),

        .mem_rdata(neuron_mem_rdata),
        .mem_ready(neuron_mem_ready),

        .x_base(x_base),
        .w_base(w_base),
        .bias_addr(bias_addr),

        .y_bus(y_bus),
        .busy(busy),
        .done(done)
    );

    // ============================================================
    // TB WORD WRITE
    // ============================================================

    task tb_write_word;

        input [ADDR_WIDTH-1:0] addr_i;
        input [15:0] data_i;

        begin

            @(posedge clk);

            tb_mem_addr  <= addr_i;
            tb_mem_wdata <= data_i;
            tb_mem_wr    <= 1'b1;
            tb_mem_lb_n  <= 1'b0;
            tb_mem_ub_n  <= 1'b0;
            tb_mem_req   <= 1'b1;

            @(posedge clk);

            tb_mem_req <= 1'b0;

            wait (tb_mem_ready);

            @(posedge clk);

        end

    endtask

    // ============================================================
    // PRELOAD X (shared, all 32 inputs = 1)
    // ============================================================

    task preload_x;

        input [ADDR_WIDTH-1:0] base;

        integer k;

        begin

            for (k = 0; k < N_INPUTS; k = k + 2) begin
                tb_write_word((base >> 1) + (k >> 1), {8'sd1, 8'sd1});
            end

        end

    endtask

    // ============================================================
    // PRELOAD WEIGHTS FOR ONE NEURON
    //
    // Neuron n's weights live at w_base + n*N_INPUTS bytes
    // (neuron-major layout, same as layer.v's weights_bus).
    // ============================================================

    task preload_weights_n;

        input [ADDR_WIDTH-1:0] base;
        input integer n;
        input signed [7:0] value;

        integer k;
        reg [ADDR_WIDTH-1:0] neuron_base;

        begin

            neuron_base = base + n * N_INPUTS;

            for (k = 0; k < N_INPUTS; k = k + 2) begin
                tb_write_word((neuron_base >> 1) + (k >> 1), {value, value});
            end

        end

    endtask

    // ============================================================
    // PRELOAD BIAS FOR ALL 3 NEURONS
    //
    // Bias is 1 byte per neuron, contiguous: bias_addr + n.
    // Packs b0/b1 into one word, b2 alone into the next.
    // ============================================================

    task preload_bias_3;

        input [ADDR_WIDTH-1:0] base;
        input signed [7:0] b0;
        input signed [7:0] b1;
        input signed [7:0] b2;

        begin

            tb_write_word(base >> 1, {b1, b0});
            tb_write_word((base >> 1) + 1, {8'h00, b2});

        end

    endtask

    // ============================================================
    // RUN NEURON MEMORY AND CHECK ALL N_NEURONS OUTPUTS
    // ============================================================

    task run_and_check;

        input signed [7:0] expected0;
        input signed [7:0] expected1;
        input signed [7:0] expected2;

        integer errors_local;

        begin

            errors_local = 0;

            @(posedge clk);
            start <= 1'b1;

            @(posedge clk);
            start <= 1'b0;

            wait (done);

            $display("");
            $display("Neuron 0 = %0d   expected = %0d", $signed(y_bus[0*8 +: 8]), expected0);
            $display("Neuron 1 = %0d   expected = %0d", $signed(y_bus[1*8 +: 8]), expected1);
            $display("Neuron 2 = %0d   expected = %0d", $signed(y_bus[2*8 +: 8]), expected2);

            if ($signed(y_bus[0*8 +: 8]) !== expected0) errors_local = errors_local + 1;
            if ($signed(y_bus[1*8 +: 8]) !== expected1) errors_local = errors_local + 1;
            if ($signed(y_bus[2*8 +: 8]) !== expected2) errors_local = errors_local + 1;

            if (busy !== 1'b0) begin
                $display("FAIL: busy still active after done");
                errors_local = errors_local + 1;
            end

            if (errors_local == 0) begin
                $display("PASS - MULTI-NEURON (N_NEURONS=%0d)", N_NEURONS);
            end else begin
                $display("FAIL - MULTI-NEURON: %0d mismatches", errors_local);
                $fatal;
            end

            @(posedge clk);

        end

    endtask

    // ============================================================
    // TEST
    // ============================================================

    initial begin

        start = 1'b0;

        x_base    = 22'h000000;
        w_base    = 22'h000100;
        bias_addr = 22'h000200;

        tb_mem_req   = 1'b0;
        tb_mem_wr    = 1'b0;
        tb_mem_addr  = 0;
        tb_mem_wdata = 0;
        tb_mem_lb_n  = 1'b1;
        tb_mem_ub_n  = 1'b1;

        use_neuron_master = 1'b0;

        rst = 1'b1;

        $dumpfile("sim/neuron_memory_multi.vcd");
        $dumpvars(0, tb);

        repeat (5)
            @(posedge clk);

        rst = 1'b0;

        wait (u_psram_ctrl.state == u_psram_ctrl.STATE_IDLE);

        $display("");
        $display("========================================");
        $display("NEURON MEMORY MULTI-NEURON TEST (N_NEURONS=%0d)", N_NEURONS);
        $display("========================================");
        $display("");

        // --------------------------------------------------------
        // PRELOAD
        //
        // X shared = 1 (all 32 inputs)
        // Neuron 0: W=1,  bias=0  -> 32
        // Neuron 1: W=2,  bias=0  -> 64
        // Neuron 2: W=-1, bias=0  -> -32 -> ReLU -> 0
        // --------------------------------------------------------

        $display("PRELOAD: X = 1 (shared)");
        preload_x(x_base);

        $display("PRELOAD: W0 = 1, W1 = 2, W2 = -1");
        preload_weights_n(w_base, 0, 8'sd1);
        preload_weights_n(w_base, 1, 8'sd2);
        preload_weights_n(w_base, 2, -8'sd1);

        $display("PRELOAD: bias0 = 0, bias1 = 0, bias2 = 0");
        preload_bias_3(bias_addr, 8'sd0, 8'sd0, 8'sd0);

        use_neuron_master = 1'b1;

        $display("");
        $display("MEMORY MASTER -> neuron_memory");

        run_and_check(8'sd32, 8'sd64, 8'sd0);

        $display("");
        $display("========================================");
        $display("NEURON MEMORY MULTI-NEURON TEST PASSED");
        $display("========================================");
        $display("");

        $finish;

    end

endmodule
