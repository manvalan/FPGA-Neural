`timescale 1ns/1ps

module tb;

    localparam ADDR_WIDTH = 22;
    localparam DATA_WIDTH = 16;
    localparam CLK_PERIOD = 12.5; // 80 MHz

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

    wire signed [7:0] y;
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
    // NEURON MEMORY
    // ============================================================

    neuron_memory #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(8),
        .N_INPUTS(32),
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

        .y(y),
        .busy(busy),
        .done(done)
    );

    // ============================================================
    // TB WORD WRITE
    //
    // Directly through:
    //
    // TB -> memory_interface -> psram_controller -> PSRAM
    //
    // No force.
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
    // PRELOAD 32 INT8 VALUES
    //
    // Two INT8 values per PSRAM word.
    // ============================================================

    task preload_vector;

        input [ADDR_WIDTH-1:0] base;
        input signed [7:0] value;

        integer k;

        begin

            for (k = 0; k < 32; k = k + 2) begin

                tb_write_word(
                    base + (k >> 1),
                    {value, value}
                );

            end

        end

    endtask

    // ============================================================
    // PRELOAD WEIGHTS
    // ============================================================

    task preload_weights;

        input [ADDR_WIDTH-1:0] base;
        input signed [7:0] value;

        integer k;

        begin

            for (k = 0; k < 32; k = k + 2) begin

                tb_write_word(
                    base + (k >> 1),
                    {value, value}
                );

            end

        end

    endtask

    // ============================================================
    // PRELOAD BIAS
    // ============================================================

    task preload_bias;

        input [ADDR_WIDTH-1:0] addr_i;
        input signed [7:0] value;

        begin

            // Bias address is a BYTE address.
            // Write a full word containing bias in low byte.

            tb_write_word(
                addr_i >> 1,
                {8'h00, value}
            );

        end

    endtask

    // ============================================================
    // RUN NEURON
    // ============================================================

    task run_neuron;

        input signed [7:0] expected;
        input [127:0] test_name;

        begin

            @(posedge clk);

            start <= 1'b1;

            @(posedge clk);

            start <= 1'b0;

            wait (done);

            if (y !== expected) begin

                $display("");
                $display("FAIL %s", test_name);
                $display(
                    "  got      = %0d (0x%02x)",
                    y,
                    y
                );
                $display(
                    "  expected = %0d (0x%02x)",
                    expected,
                    expected
                );
                $fatal;

            end else begin

                $display(
                    "PASS %-16s y=%0d (0x%02x)",
                    test_name,
                    y,
                    y
                );

            end

            @(posedge clk);

        end

    endtask

    // ============================================================
    // TEST
    // ============================================================

    integer i;

    initial begin

        // --------------------------------------------------------
        // Initial values
        // --------------------------------------------------------

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

        // --------------------------------------------------------
        // VCD
        // --------------------------------------------------------

        $dumpfile("sim/neuron_memory.vcd");
        $dumpvars(0, tb);

        repeat (5)
            @(posedge clk);

        rst = 1'b0;

        // --------------------------------------------------------
        // Wait PSRAM initialization
        // --------------------------------------------------------

        wait (u_psram_ctrl.state == u_psram_ctrl.STATE_IDLE);

        $display("");
        $display("========================================");
        $display("NEURON MEMORY END-TO-END TEST");
        $display("========================================");
        $display("");

        // ========================================================
        // PRELOAD PHASE
        //
        // TB is the ONLY memory master.
        // ========================================================

        $display("PRELOAD: X = 1");
        preload_vector(
            x_base,
            8'sd1
        );

        $display("PRELOAD: W = 1");
        preload_weights(
            w_base,
            8'sd1
        );

        $display("PRELOAD: BIAS = 0");
        preload_bias(
            bias_addr,
            8'sd0
        );

        // ========================================================
        // HAND OVER MEMORY BUS
        //
        // From this point neuron_memory is the only master.
        // ========================================================

        use_neuron_master = 1'b1;

        $display("");
        $display("MEMORY MASTER -> neuron_memory");
        $display("");

        // ========================================================
        // TEST 1
        //
        // 32 * 1 * 1 + 0 = 32
        // ========================================================

        run_neuron(
            8'sd32,
            "SUM=32"
        );

        // ========================================================
        // TEST 2
        //
        // 32 * 1 * 4 = 128
        // Saturated to 127.
        //
        // We must return control to TB to modify weights.
        // ========================================================

        use_neuron_master = 1'b0;

        preload_weights(
            w_base,
            8'sd4
        );

        preload_bias(
            bias_addr,
            8'sd0
        );

        use_neuron_master = 1'b1;

        run_neuron(
            8'sd127,
            "SATURATION"
        );

        // ========================================================
        // TEST 3
        //
        // 32 * 1 * (-1) = -32
        // ReLU -> 0
        // ========================================================

        use_neuron_master = 1'b0;

        preload_weights(
            w_base,
            -8'sd1
        );

        preload_bias(
            bias_addr,
            8'sd0
        );

        use_neuron_master = 1'b1;

        run_neuron(
            8'sd0,
            "RELU"
        );

        // ========================================================
        // TEST 4
        //
        // 32 * 1 * 1 + 10 = 42
        // ========================================================

        use_neuron_master = 1'b0;

        preload_weights(
            w_base,
            8'sd1
        );

        preload_bias(
            bias_addr,
            8'sd10
        );

        use_neuron_master = 1'b1;

        run_neuron(
            8'sd42,
            "BIAS=10"
        );

        // ========================================================
        // FINAL
        // ========================================================

        $display("");
        $display("========================================");
        $display("NEURON MEMORY TEST PASSED");
        $display("========================================");
        $display("PSRAM -> INT8 -> NEURON : PASS");
        $display("SUM                    : PASS");
        $display("BIAS                   : PASS");
        $display("ReLU                   : PASS");
        $display("SATURATION             : PASS");
        $display("========================================");
        $display("");

        $finish;

    end

endmodule