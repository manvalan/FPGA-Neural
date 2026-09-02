`timescale 1ns/1ps

// ================================================================
// LAYER_SEQUENCER TESTBENCH
//
// Direct unit test of rtl/layer_sequencer.v (Phase 5), same style
// as sim/spi_engine_tb.v: a synthetic byte-RAM model (fixed 2-cycle
// latency) for the descriptor table + ping-pong buffers, and a
// manually-driven neuron_memory mock (nm_busy/nm_done/y_bus driven
// by the test, nm_x_base/nm_w_base/nm_bias_addr/nm_start observed).
//
// Runs a 2-layer network (N_WIDTH=4) end to end and checks:
//   - the descriptor table (w_base/bias_addr per layer) is read
//     correctly and drives neuron_memory's w_base/bias_addr;
//   - layer 0 reads from the external x_base; layer 1 reads from
//     the ping-pong buffer layer 0 wrote to (the actual point of
//     the ping-pong scheme -- verified by address, not just value);
//   - each layer's y_bus is copied byte-for-byte into the correct
//     ping-pong buffer in RAM;
//   - seq_busy stays asserted for the whole 2-layer run and does
//     NOT drop between layers;
//   - seq_done pulses exactly once, after the LAST layer only (an
//     intermediate per-layer nm_done must not trigger it).
// ================================================================

module tb;

    localparam ADDR_WIDTH = 22;
    localparam DATA_WIDTH = 8;
    localparam N_WIDTH    = 4;
    localparam N_LAYERS   = 4;

    localparam CLK_PERIOD = 12.5; // 80 MHz

    reg clk;
    reg rst;

    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD / 2.0) clk = ~clk;
    end

    // ============================================================
    // DUT
    // ============================================================

    reg                   run_start;
    reg  [7:0]            run_num_layers;

    wire                  seq_busy;
    wire                  seq_done;

    reg  [ADDR_WIDTH-1:0] x_base;
    reg  [ADDR_WIDTH-1:0] table_base;
    reg  [ADDR_WIDTH-1:0] buf_a_base;
    reg  [ADDR_WIDTH-1:0] buf_b_base;

    wire [ADDR_WIDTH-1:0] nm_x_base;
    wire [ADDR_WIDTH-1:0] nm_w_base;
    wire [ADDR_WIDTH-1:0] nm_bias_addr;
    wire [1:0]            nm_activation;
    wire [15:0]           nm_n_inputs;
    wire [15:0]           nm_n_neurons;
    wire                  nm_start;

    reg                   nm_busy;
    reg                   nm_done;

    reg signed [DATA_WIDTH*N_WIDTH-1:0] y_bus;

    wire                   ram_req;
    wire                   ram_wr;
    wire [ADDR_WIDTH-1:0]  ram_addr;
    wire signed [7:0]      ram_wdata;

    reg signed [7:0]      ram_rdata;
    reg                   ram_ready;

    layer_sequencer #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .N_WIDTH(N_WIDTH),
        .N_LAYERS(N_LAYERS)
    ) u_dut (
        .clk(clk), .rst(rst),

        .run_start(run_start), .run_num_layers(run_num_layers),
        .seq_busy(seq_busy), .seq_done(seq_done),

        .x_base(x_base), .table_base(table_base),
        .buf_a_base(buf_a_base), .buf_b_base(buf_b_base),

        .nm_x_base(nm_x_base), .nm_w_base(nm_w_base),
        .nm_bias_addr(nm_bias_addr), .nm_activation(nm_activation),
        .nm_n_inputs(nm_n_inputs), .nm_n_neurons(nm_n_neurons),
        .nm_start(nm_start),

        .nm_busy(nm_busy), .nm_done(nm_done),
        .y_bus(y_bus),

        .ram_req(ram_req), .ram_wr(ram_wr),
        .ram_addr(ram_addr), .ram_wdata(ram_wdata),
        .ram_rdata(ram_rdata), .ram_ready(ram_ready)
    );

    // ============================================================
    // SYNTHETIC BYTE-RAM MODEL (same pattern as spi_engine_tb.v)
    // ============================================================

    reg [7:0] ram_mem [0:4095];

    localparam RAM_IDLE = 1'b0;
    localparam RAM_WAIT = 1'b1;
    reg ram_state;
    reg [ADDR_WIDTH-1:0] ram_addr_latched;
    reg ram_wr_latched;
    reg signed [7:0] ram_wdata_latched;

    always @(posedge clk) begin
        if (rst) begin
            ram_state <= RAM_IDLE;
            ram_ready <= 1'b0;
            ram_rdata <= 8'sd0;
        end else begin

            ram_ready <= 1'b0;

            case (ram_state)

                RAM_IDLE: begin
                    if (ram_req) begin
                        ram_addr_latched  <= ram_addr;
                        ram_wr_latched    <= ram_wr;
                        ram_wdata_latched <= ram_wdata;
                        ram_state         <= RAM_WAIT;
                    end
                end

                RAM_WAIT: begin
                    if (ram_wr_latched)
                        ram_mem[ram_addr_latched] <= ram_wdata_latched;
                    else
                        ram_rdata <= $signed(ram_mem[ram_addr_latched]);

                    ram_ready <= 1'b1;
                    ram_state <= RAM_IDLE;
                end

            endcase

        end
    end

    // ============================================================
    // neuron_memory MOCK
    //
    // On nm_start: goes busy for a few cycles, then pulses nm_done
    // for exactly one cycle with whatever y_bus the test has staged
    // via `stage_layer_output`.
    // ============================================================

    reg [DATA_WIDTH*N_WIDTH-1:0] staged_y;

    task stage_layer_output;
        input [DATA_WIDTH*N_WIDTH-1:0] val;
        begin
            staged_y = val;
        end
    endtask

    integer nm_delay;

    always @(posedge clk) begin
        if (rst) begin
            nm_busy <= 1'b0;
            nm_done <= 1'b0;
            y_bus   <= 0;
        end else begin

            nm_done <= 1'b0;

            if (nm_start && !nm_busy) begin
                nm_busy <= 1'b1;
                nm_delay <= 3;
            end else if (nm_busy) begin
                if (nm_delay == 0) begin
                    nm_busy <= 1'b0;
                    nm_done <= 1'b1;
                    y_bus   <= staged_y;
                end else begin
                    nm_delay <= nm_delay - 1;
                end
            end

        end
    end

    // ============================================================
    // seq_busy / seq_done monitors
    // ============================================================

    integer seq_done_count;
    reg     seq_busy_dropped_early;

    always @(posedge clk) begin
        if (rst) begin
            seq_done_count          <= 0;
            seq_busy_dropped_early  <= 1'b0;
        end else begin
            if (seq_done) seq_done_count <= seq_done_count + 1;
        end
    end

    // ============================================================
    // MAIN
    // ============================================================

    integer errors;
    integer errors_before;
    integer i;

    task clk_wait;
        input integer n;
        integer k;
        begin
            for (k = 0; k < n; k = k + 1)
                @(posedge clk);
        end
    endtask

    task report;
        input [511:0] label;
        begin
            $display("");
            if (errors == errors_before)
                $display("%0s: PASS", label);
            else
                $display("%0s: FAIL", label);
        end
    endtask

    // Byte addresses used by this test.
    localparam [ADDR_WIDTH-1:0] TABLE_BASE = 22'h000100;
    localparam [ADDR_WIDTH-1:0] X_BASE     = 22'h000010;
    localparam [ADDR_WIDTH-1:0] BUF_A_BASE = 22'h000200;
    localparam [ADDR_WIDTH-1:0] BUF_B_BASE = 22'h000300;

    localparam [ADDR_WIDTH-1:0] L0_W_BASE    = 22'h001000;
    localparam [ADDR_WIDTH-1:0] L0_BIAS_ADDR = 22'h002000;
    localparam [ADDR_WIDTH-1:0] L1_W_BASE    = 22'h003000;
    localparam [ADDR_WIDTH-1:0] L1_BIAS_ADDR = 22'h004000;

    initial begin

        $dumpfile("sim/layer_sequencer.vcd");
        $dumpvars(0, tb);

        rst            = 1'b1;
        run_start      = 1'b0;
        run_num_layers = 8'h00;
        nm_busy        = 1'b0;
        nm_done        = 1'b0;
        y_bus          = 0;
        errors         = 0;

        x_base     = X_BASE;
        table_base = TABLE_BASE;
        buf_a_base = BUF_A_BASE;
        buf_b_base = BUF_B_BASE;

        for (i = 0; i < 4096; i = i + 1)
            ram_mem[i] = 8'h00;

        // Descriptor table: 2 layers x 11 bytes (w_base(3B),
        // bias_addr(3B), activation(1B), n_inputs_real(2B),
        // n_neurons_real(2B)), MSB-first. Layer 0 uses ACT_NONE(0)
        // and a REDUCED n_neurons_real=2 (of N_WIDTH=4) -- proving
        // both the field routing (nm_n_inputs/nm_n_neurons) and that
        // the ping-pong copy loop only writes n_neurons_real bytes,
        // not the full N_WIDTH. Layer 1 uses ACT_RELU(1),
        // n_inputs_real=2 (matching layer 0's real output count) and
        // n_neurons_real=4 (full, back to build width for the final
        // output).
        ram_mem[TABLE_BASE+0] = L0_W_BASE[23:16];
        ram_mem[TABLE_BASE+1] = L0_W_BASE[15:8];
        ram_mem[TABLE_BASE+2] = L0_W_BASE[7:0];
        ram_mem[TABLE_BASE+3] = L0_BIAS_ADDR[23:16];
        ram_mem[TABLE_BASE+4] = L0_BIAS_ADDR[15:8];
        ram_mem[TABLE_BASE+5] = L0_BIAS_ADDR[7:0];
        ram_mem[TABLE_BASE+6] = 8'h00; // ACT_NONE
        ram_mem[TABLE_BASE+7] = 8'h00; ram_mem[TABLE_BASE+8]  = 8'd4; // n_inputs_real = 4 (full)
        ram_mem[TABLE_BASE+9] = 8'h00; ram_mem[TABLE_BASE+10] = 8'd2; // n_neurons_real = 2 (reduced)

        ram_mem[TABLE_BASE+11] = L1_W_BASE[23:16];
        ram_mem[TABLE_BASE+12] = L1_W_BASE[15:8];
        ram_mem[TABLE_BASE+13] = L1_W_BASE[7:0];
        ram_mem[TABLE_BASE+14] = L1_BIAS_ADDR[23:16];
        ram_mem[TABLE_BASE+15] = L1_BIAS_ADDR[15:8];
        ram_mem[TABLE_BASE+16] = L1_BIAS_ADDR[7:0];
        ram_mem[TABLE_BASE+17] = 8'h01; // ACT_RELU
        ram_mem[TABLE_BASE+18] = 8'h00; ram_mem[TABLE_BASE+19] = 8'd2; // n_inputs_real = 2
        ram_mem[TABLE_BASE+20] = 8'h00; ram_mem[TABLE_BASE+21] = 8'd4; // n_neurons_real = 4 (full)

        repeat (5) @(posedge clk);
        rst = 1'b0;
        repeat (5) @(posedge clk);

        $display("");
        $display("========================================");
        $display("LAYER_SEQUENCER TEST");
        $display("========================================");

        // --------------------------------------------------------
        // TEST A: 2-layer run, descriptor + ping-pong + copy-out
        // --------------------------------------------------------

        errors_before = errors;

        stage_layer_output({8'sd41, 8'sd31, 8'sd21, 8'sd11}); // layer 0 output (byte0=8'sd11 ... byte3=8'sd41)

        @(negedge clk);
        run_start      = 1'b1;
        run_num_layers = 8'd2;
        @(negedge clk);
        run_start = 1'b0;

        // seq_busy must assert promptly.
        clk_wait(2);
        if (seq_busy !== 1'b1) begin $display("  FAIL: seq_busy not asserted after run_start"); errors = errors + 1; end

        // Wait for nm_start (layer 0) and check the descriptor was applied.
        wait (nm_start === 1'b1);
        if (nm_w_base    !== L0_W_BASE)    begin $display("  FAIL: layer0 nm_w_base = 0x%06x", nm_w_base); errors = errors + 1; end
        if (nm_bias_addr !== L0_BIAS_ADDR) begin $display("  FAIL: layer0 nm_bias_addr = 0x%06x", nm_bias_addr); errors = errors + 1; end
        if (nm_x_base    !== X_BASE)       begin $display("  FAIL: layer0 nm_x_base = 0x%06x, expected external x_base", nm_x_base); errors = errors + 1; end
        if (nm_activation !== 2'd0)        begin $display("  FAIL: layer0 nm_activation = %0d, expected 0 (ACT_NONE)", nm_activation); errors = errors + 1; end
        if (nm_n_inputs   !== 16'd4)       begin $display("  FAIL: layer0 nm_n_inputs = %0d, expected 4", nm_n_inputs); errors = errors + 1; end
        if (nm_n_neurons  !== 16'd2)       begin $display("  FAIL: layer0 nm_n_neurons = %0d, expected 2", nm_n_neurons); errors = errors + 1; end

        // seq_busy must NOT drop between layer 0's nm_done and layer 1 starting.
        wait (nm_done === 1'b1);
        @(posedge clk);
        if (seq_busy !== 1'b1) begin $display("  FAIL: seq_busy dropped between layers"); errors = errors + 1; end
        if (seq_done === 1'b1) begin $display("  FAIL: seq_done pulsed after layer 0 (intermediate), should only fire after the last layer"); errors = errors + 1; end

        // Wait for nm_start (layer 1) and check the descriptor + ping-pong input.
        wait (nm_start === 1'b1);
        if (nm_w_base    !== L1_W_BASE)    begin $display("  FAIL: layer1 nm_w_base = 0x%06x", nm_w_base); errors = errors + 1; end
        if (nm_bias_addr !== L1_BIAS_ADDR) begin $display("  FAIL: layer1 nm_bias_addr = 0x%06x", nm_bias_addr); errors = errors + 1; end
        if (nm_x_base    !== BUF_A_BASE)   begin $display("  FAIL: layer1 nm_x_base = 0x%06x, expected buf_a_base (layer0's output buffer)", nm_x_base); errors = errors + 1; end
        if (nm_activation !== 2'd1)        begin $display("  FAIL: layer1 nm_activation = %0d, expected 1 (ACT_RELU)", nm_activation); errors = errors + 1; end
        if (nm_n_inputs   !== 16'd2)       begin $display("  FAIL: layer1 nm_n_inputs = %0d, expected 2", nm_n_inputs); errors = errors + 1; end
        if (nm_n_neurons  !== 16'd4)       begin $display("  FAIL: layer1 nm_n_neurons = %0d, expected 4", nm_n_neurons); errors = errors + 1; end

        // Stage layer 1's output now that its own nm_start has fired
        // (the mock samples staged_y a few cycles later, when ITS
        // nm_delay reaches 0 -- staging any earlier would race with
        // layer 0's own sampling, since the mock has a single
        // staged_y register shared across calls).
        stage_layer_output({8'sd44, 8'sd33, 8'sd22, 8'sd11}); // layer 1 output

        // Wait for the whole run to finish.
        wait (seq_done === 1'b1);
        @(posedge clk);
        if (seq_busy !== 1'b0) begin $display("  FAIL: seq_busy still set after seq_done"); errors = errors + 1; end

        clk_wait(4);

        if (seq_done_count !== 1) begin $display("  FAIL: seq_done pulsed %0d times, expected exactly 1", seq_done_count); errors = errors + 1; end

        // Verify layer 0's output landed in buf_a_base, byte for byte.
        if (ram_mem[BUF_A_BASE+0] !== 8'sd11) begin $display("  FAIL: buf_a[0] = 0x%02x, expected 0x0b", ram_mem[BUF_A_BASE+0]); errors = errors + 1; end
        if (ram_mem[BUF_A_BASE+1] !== 8'sd21) begin $display("  FAIL: buf_a[1] = 0x%02x, expected 0x15", ram_mem[BUF_A_BASE+1]); errors = errors + 1; end

        // layer 0's n_neurons_real=2: bytes 2/3 must NEVER be
        // written (must stay at their ram_mem init value of 0), not
        // just "happen to differ from the staged y" -- proves the
        // copy loop really stopped after 2 bytes, not 4.
        if (ram_mem[BUF_A_BASE+2] !== 8'sd0) begin $display("  FAIL: buf_a[2] = 0x%02x, expected untouched 0x00 (n_neurons_real=2 must skip this byte)", ram_mem[BUF_A_BASE+2]); errors = errors + 1; end
        if (ram_mem[BUF_A_BASE+3] !== 8'sd0) begin $display("  FAIL: buf_a[3] = 0x%02x, expected untouched 0x00 (n_neurons_real=2 must skip this byte)", ram_mem[BUF_A_BASE+3]); errors = errors + 1; end

        // Verify layer 1's (final) output landed in buf_b_base.
        if (ram_mem[BUF_B_BASE+0] !== 8'sd11) begin $display("  FAIL: buf_b[0] = 0x%02x, expected 0x0b", ram_mem[BUF_B_BASE+0]); errors = errors + 1; end
        if (ram_mem[BUF_B_BASE+1] !== 8'sd22) begin $display("  FAIL: buf_b[1] = 0x%02x, expected 0x16", ram_mem[BUF_B_BASE+1]); errors = errors + 1; end
        if (ram_mem[BUF_B_BASE+2] !== 8'sd33) begin $display("  FAIL: buf_b[2] = 0x%02x, expected 0x21", ram_mem[BUF_B_BASE+2]); errors = errors + 1; end
        if (ram_mem[BUF_B_BASE+3] !== 8'sd44) begin $display("  FAIL: buf_b[3] = 0x%02x, expected 0x2c", ram_mem[BUF_B_BASE+3]); errors = errors + 1; end

        report("TEST A: 2-layer run (descriptor / ping-pong / copy-out)");

        // --------------------------------------------------------
        // TEST B: run_start ignored while seq_busy
        // --------------------------------------------------------

        errors_before = errors;

        stage_layer_output({8'sd4, 8'sd3, 8'sd2, 8'sd1});

        @(negedge clk);
        run_start      = 1'b1;
        run_num_layers = 8'd1;
        @(negedge clk);
        run_start = 1'b0;

        clk_wait(2);
        if (seq_busy !== 1'b1) begin $display("  FAIL: seq_busy not asserted for single-layer run"); errors = errors + 1; end

        // A second run_start while busy must be ignored by whoever
        // gates it (spi_engine, per its own test) -- here we confirm
        // the sequencer itself has no re-entrancy hazard: pulsing
        // run_start again mid-run must not corrupt layer_idx/state.
        @(negedge clk);
        run_start      = 1'b1;
        run_num_layers = 8'd3;
        @(negedge clk);
        run_start = 1'b0;

        wait (seq_done === 1'b1);
        @(posedge clk);
        clk_wait(4);

        if (seq_done_count !== 2) begin $display("  FAIL: seq_done total count = %0d, expected 2 (1 from TEST A + 1 here)", seq_done_count); errors = errors + 1; end
        if (seq_busy !== 1'b0) begin $display("  FAIL: seq_busy stuck after single-layer run"); errors = errors + 1; end

        report("TEST B: run_start re-pulse mid-run does not corrupt state");

        // --------------------------------------------------------
        // SUMMARY
        // --------------------------------------------------------

        $display("");
        $display("========================================");
        if (errors == 0)
            $display("LAYER_SEQUENCER TEST PASSED");
        else
            $display("LAYER_SEQUENCER TEST FAILED: %0d errors", errors);
        $display("========================================");
        $display("");

        $finish;

    end

    // Safety timeout so a stuck FSM fails fast instead of hanging.
    initial begin
        #200000;
        $display("TIMEOUT: simulation did not finish in time");
        $finish;
    end

endmodule
