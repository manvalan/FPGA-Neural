`timescale 1ns/1ps

// ================================================================
// SPI_NEURON_TOP RUN_NETWORK END-TO-END TESTBENCH (Phase 5)
//
// Same rigor as sim/spi_neuron_top_tb.v (real spi_slave + spi_engine
// + mem_arbiter + int8_memory_access + memory_interface +
// psram_controller + psram_model, driven purely over simulated SPI),
// but this time exercising the Phase 5 path: RUN_NETWORK (opcode
// 0x23) chaining a REAL, non-mocked neuron_memory through TWO
// layers via layer_sequencer.v, with hand-computed expected outputs.
//
// N_INPUTS = N_NEURONS = 4 (required for RUN_NETWORK, see
// rtl/layer_sequencer.v), PARALLEL = 2, N_LAYERS = 2.
//
// Session:
//   RESET -> WRITE_RAM(X, table, W0, bias0, W1, bias1) ->
//   SET_BASE(X/TABLE/BUF_A/BUF_B) -> RUN_NETWORK(2) ->
//   poll STATUS -> READ_OUTPUT (layer 1's y_bus) ->
//   READ_RAM(buf_b) (layer 1's output, copied by the sequencer) ->
//   READ_RAM(buf_a) (layer 0's intermediate output) ->
//   legacy single-layer START still works afterward (mux sanity)
//
// Hand-computed layer 0 (X=[1,2,3,4]):
//   n0: w=[1,1,1,1] b=0    -> 1+2+3+4+0    = 10
//   n1: w=[1,0,0,0] b=5    -> 1+5          = 6
//   n2: w=[0,0,0,0] b=-3   -> 0-3          = -3  -> ReLU -> 0
//   n3: w=[2,2,2,2] b=120  -> 2*10+120=140 -> saturate -> 127
//   Y0 = [10, 6, 0, 127]  (also layer 1's input, via buf_a)
//
// Hand-computed layer 1 (X=Y0=[10,6,0,127]):
//   n0: w=[1,1,1,1] b=-20  -> 10+6+0+127-20 = 123
//   n1: w=[1,0,0,0] b=0    -> 10
//   n2: w=[0,1,0,0] b=0    -> 6
//   n3: w=[0,0,0,1] b=0    -> 127
//   Y1 = [123, 10, 6, 127]  (final output: y_bus AND buf_b)
// ================================================================

module tb;

    localparam ADDR_WIDTH     = 22;
    localparam DATA_WIDTH     = 8;
    localparam N_INPUTS       = 4;
    localparam N_NEURONS      = 4;
    localparam PARALLEL       = 2;
    localparam ACC_WIDTH      = 32;
    localparam MEM_DATA_WIDTH = 16;
    localparam N_LAYERS       = 4;

    localparam CLK_PERIOD = 12.5; // 80 MHz

    reg clk;
    reg rst;

    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD / 2.0) clk = ~clk;
    end

    reg  sclk;
    reg  mosi;
    wire miso;
    reg  cs_n;

    wire [ADDR_WIDTH-1:0]     psram_a;
    wire [MEM_DATA_WIDTH-1:0] psram_dq;
    wire psram_ce_n, psram_oe_n, psram_we_n, psram_lb_n, psram_ub_n, psram_zz_n;

    spi_neuron_top #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .N_INPUTS(N_INPUTS),
        .N_NEURONS(N_NEURONS),
        .PARALLEL(PARALLEL),
        .ACC_WIDTH(ACC_WIDTH),
        .MEM_DATA_WIDTH(MEM_DATA_WIDTH),
        .CLK_FREQ_MHZ(80),
        .N_LAYERS(N_LAYERS)
    ) dut (
        .clk(clk), .rst(rst),

        .sclk(sclk), .mosi(mosi), .miso(miso), .cs_n(cs_n),

        .psram_a(psram_a), .psram_dq(psram_dq),
        .psram_ce_n(psram_ce_n), .psram_oe_n(psram_oe_n), .psram_we_n(psram_we_n),
        .psram_lb_n(psram_lb_n), .psram_ub_n(psram_ub_n), .psram_zz_n(psram_zz_n)
    );

    psram_model #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(MEM_DATA_WIDTH),
        .DEPTH(16384)
    ) u_psram (
        .clk(clk),
        .a(psram_a), .dq(psram_dq),
        .ce_n(psram_ce_n), .oe_n(psram_oe_n), .we_n(psram_we_n),
        .lb_n(psram_lb_n), .ub_n(psram_ub_n), .zz_n(psram_zz_n)
    );

    // ============================================================
    // SPI MASTER BFM (same pattern as sim/spi_neuron_top_tb.v)
    // ============================================================

    task clk_wait;
        input integer n;
        integer k;
        begin
            for (k = 0; k < n; k = k + 1)
                @(posedge clk);
        end
    endtask

    task spi_begin;
        input integer half_bit_cycles;
        begin
            cs_n = 1'b1;
            sclk = 1'b0;
            mosi = 1'b0;
            clk_wait(half_bit_cycles * 2);
            cs_n = 1'b0;
            clk_wait(half_bit_cycles * 2);
        end
    endtask

    task spi_end;
        input integer half_bit_cycles;
        begin
            clk_wait(half_bit_cycles * 2);
            cs_n = 1'b1;
            clk_wait(half_bit_cycles * 2);
        end
    endtask

    task spi_xfer_byte;
        input  [7:0] tx;
        input integer half_bit_cycles;
        output [7:0] rx;
        integer i;
        reg [7:0] rx_acc;
        begin
            rx_acc = 8'h00;
            for (i = 7; i >= 0; i = i - 1) begin
                mosi = tx[i];
                clk_wait(half_bit_cycles);
                sclk = 1'b1;
                rx_acc[i] = miso;
                clk_wait(half_bit_cycles);
                sclk = 1'b0;
                clk_wait(half_bit_cycles);
            end
            rx = rx_acc;
        end
    endtask

    localparam HB_RAM = 40;
    localparam HB_REG = 8;

    reg [7:0] rx_tmp;
    integer   errors;
    integer   errors_before;
    integer   poll_count;

    // Shared scratch buffers for the byte-array helper tasks below
    // (max 16 bytes covers every payload used in this test: the
    // 12-byte descriptor table and the 16-byte weight matrices).
    reg signed [7:0] payload  [0:15];
    reg signed [7:0] readback [0:15];

    // ============================================================
    // HELPER TASKS
    // ============================================================

    task do_reset;
        begin
            spi_begin(HB_REG);
            spi_xfer_byte(8'h0F, HB_REG, rx_tmp); // RESET
            spi_end(HB_REG);
        end
    endtask

    task set_base;
        input [7:0] sel;
        input [ADDR_WIDTH-1:0] addr;
        begin
            spi_begin(HB_REG);
            spi_xfer_byte(8'h10, HB_REG, rx_tmp); // SET_BASE
            spi_xfer_byte(sel, HB_REG, rx_tmp);
            spi_xfer_byte(addr[23:16], HB_REG, rx_tmp);
            spi_xfer_byte(addr[15:8],  HB_REG, rx_tmp);
            spi_xfer_byte(addr[7:0],   HB_REG, rx_tmp);
            spi_end(HB_REG);
        end
    endtask

    // Writes `len` bytes from the shared `payload` array (caller
    // fills payload[0..len-1] beforehand).
    task write_ram_bytes;
        input [ADDR_WIDTH-1:0] addr;
        input integer len;
        integer k;
        begin
            spi_begin(HB_RAM);
            spi_xfer_byte(8'h01, HB_RAM, rx_tmp); // WRITE_RAM
            spi_xfer_byte(addr[23:16], HB_RAM, rx_tmp);
            spi_xfer_byte(addr[15:8],  HB_RAM, rx_tmp);
            spi_xfer_byte(addr[7:0],   HB_RAM, rx_tmp);
            spi_xfer_byte(len[15:8],   HB_RAM, rx_tmp);
            spi_xfer_byte(len[7:0],    HB_RAM, rx_tmp);
            for (k = 0; k < len; k = k + 1)
                spi_xfer_byte(payload[k], HB_RAM, rx_tmp);
            spi_end(HB_RAM);
        end
    endtask

    // Reads `len` bytes into the shared `readback` array.
    task read_ram_bytes;
        input [ADDR_WIDTH-1:0] addr;
        input integer len;
        integer k;
        begin
            spi_begin(HB_RAM);
            spi_xfer_byte(8'h02, HB_RAM, rx_tmp); // READ_RAM
            spi_xfer_byte(addr[23:16], HB_RAM, rx_tmp);
            spi_xfer_byte(addr[15:8],  HB_RAM, rx_tmp);
            spi_xfer_byte(addr[7:0],   HB_RAM, rx_tmp);
            spi_xfer_byte(len[15:8],   HB_RAM, rx_tmp);
            spi_xfer_byte(len[7:0],    HB_RAM, rx_tmp);
            for (k = 0; k < len; k = k + 1)
                spi_xfer_byte(8'h00, HB_RAM, readback[k]);
            spi_end(HB_RAM);
        end
    endtask

    task read_status;
        output [7:0] status;
        begin
            spi_begin(HB_REG);
            spi_xfer_byte(8'h21, HB_REG, rx_tmp); // STATUS
            spi_xfer_byte(8'h00, HB_REG, status);
            spi_end(HB_REG);
        end
    endtask

    task do_start;
        begin
            spi_begin(HB_REG);
            spi_xfer_byte(8'h20, HB_REG, rx_tmp); // START
            spi_end(HB_REG);
        end
    endtask

    task run_network;
        input [7:0] num_layers;
        begin
            spi_begin(HB_REG);
            spi_xfer_byte(8'h23, HB_REG, rx_tmp); // RUN_NETWORK
            spi_xfer_byte(num_layers, HB_REG, rx_tmp);
            spi_end(HB_REG);
        end
    endtask

    task wait_done;
        reg [7:0] status;
        begin
            poll_count = 0;
            status = 8'h00;
            while (!status[1] && poll_count < 2000) begin
                clk_wait(20);
                read_status(status);
                poll_count = poll_count + 1;
            end
            if (!status[1]) begin
                $display("  FAIL: done never asserted (poll_count=%0d)", poll_count);
                errors = errors + 1;
            end
        end
    endtask

    task read_output_bytes;
        input integer n;
        integer k;
        begin
            spi_begin(HB_REG);
            spi_xfer_byte(8'h22, HB_REG, rx_tmp); // READ_OUTPUT
            for (k = 0; k < n; k = k + 1)
                spi_xfer_byte(8'h00, HB_REG, readback[k]);
            spi_end(HB_REG);
        end
    endtask

    task check_bytes4;
        input [8*4*8-1:0] label; // 4 chars, wide enough for a short tag
        input signed [7:0] e0, e1, e2, e3;
        begin
            if (readback[0] !== e0) begin $display("  FAIL: %0s[0] = %0d, expected %0d", label, readback[0], e0); errors = errors + 1; end
            if (readback[1] !== e1) begin $display("  FAIL: %0s[1] = %0d, expected %0d", label, readback[1], e1); errors = errors + 1; end
            if (readback[2] !== e2) begin $display("  FAIL: %0s[2] = %0d, expected %0d", label, readback[2], e2); errors = errors + 1; end
            if (readback[3] !== e3) begin $display("  FAIL: %0s[3] = %0d, expected %0d", label, readback[3], e3); errors = errors + 1; end
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

    // ============================================================
    // ADDRESS MAP (all well-separated, no overlap)
    // ============================================================

    localparam [ADDR_WIDTH-1:0] X_BASE     = 22'h000000;
    localparam [ADDR_WIDTH-1:0] TABLE_BASE = 22'h000010;
    localparam [ADDR_WIDTH-1:0] W0_BASE    = 22'h000100;
    localparam [ADDR_WIDTH-1:0] BIAS0_ADDR = 22'h000120;
    localparam [ADDR_WIDTH-1:0] W1_BASE    = 22'h000200;
    localparam [ADDR_WIDTH-1:0] BIAS1_ADDR = 22'h000220;
    localparam [ADDR_WIDTH-1:0] BUF_A_BASE = 22'h000300;
    localparam [ADDR_WIDTH-1:0] BUF_B_BASE = 22'h000310;

    // ============================================================
    // MAIN
    // ============================================================

    initial begin

        $dumpfile("sim/spi_neuron_top_runnetwork.vcd");
        $dumpvars(0, tb);

        rst   = 1'b1;
        cs_n  = 1'b1;
        sclk  = 1'b0;
        mosi  = 1'b0;
        errors = 0;

        repeat (5) @(posedge clk);
        rst = 1'b0;

        wait (dut.u_psram_ctrl.state == dut.u_psram_ctrl.STATE_IDLE);

        $display("");
        $display("========================================");
        $display("SPI_NEURON_TOP RUN_NETWORK END-TO-END TEST (real PSRAM)");
        $display("========================================");

        do_reset;

        // --------------------------------------------------------
        // Load X, descriptor table, W0/bias0, W1/bias1
        // --------------------------------------------------------

        errors_before = errors;

        payload[0] = 8'sd1; payload[1] = 8'sd2; payload[2] = 8'sd3; payload[3] = 8'sd4;
        write_ram_bytes(X_BASE, 4);

        // Descriptor table: 2 x (w_base(3B) + bias_addr(3B)), MSB-first.
        payload[0]  = W0_BASE[23:16];    payload[1]  = W0_BASE[15:8];    payload[2]  = W0_BASE[7:0];
        payload[3]  = BIAS0_ADDR[23:16]; payload[4]  = BIAS0_ADDR[15:8]; payload[5]  = BIAS0_ADDR[7:0];
        payload[6]  = W1_BASE[23:16];    payload[7]  = W1_BASE[15:8];    payload[8]  = W1_BASE[7:0];
        payload[9]  = BIAS1_ADDR[23:16]; payload[10] = BIAS1_ADDR[15:8]; payload[11] = BIAS1_ADDR[7:0];
        write_ram_bytes(TABLE_BASE, 12);

        // W0 (neuron-major, N_INPUTS bytes each):
        //   n0=[1,1,1,1] n1=[1,0,0,0] n2=[0,0,0,0] n3=[2,2,2,2]
        payload[0]=8'sd1; payload[1]=8'sd1; payload[2]=8'sd1; payload[3]=8'sd1;
        payload[4]=8'sd1; payload[5]=8'sd0; payload[6]=8'sd0; payload[7]=8'sd0;
        payload[8]=8'sd0; payload[9]=8'sd0; payload[10]=8'sd0; payload[11]=8'sd0;
        payload[12]=8'sd2; payload[13]=8'sd2; payload[14]=8'sd2; payload[15]=8'sd2;
        write_ram_bytes(W0_BASE, 16);

        // bias0 = [0, 5, -3, 120]
        payload[0]=8'sd0; payload[1]=8'sd5; payload[2]=-8'sd3; payload[3]=8'sd120;
        write_ram_bytes(BIAS0_ADDR, 4);

        // W1: n0=[1,1,1,1] n1=[1,0,0,0] n2=[0,1,0,0] n3=[0,0,0,1]
        payload[0]=8'sd1; payload[1]=8'sd1; payload[2]=8'sd1; payload[3]=8'sd1;
        payload[4]=8'sd1; payload[5]=8'sd0; payload[6]=8'sd0; payload[7]=8'sd0;
        payload[8]=8'sd0; payload[9]=8'sd1; payload[10]=8'sd0; payload[11]=8'sd0;
        payload[12]=8'sd0; payload[13]=8'sd0; payload[14]=8'sd0; payload[15]=8'sd1;
        write_ram_bytes(W1_BASE, 16);

        // bias1 = [-20, 0, 0, 0]
        payload[0]=-8'sd20; payload[1]=8'sd0; payload[2]=8'sd0; payload[3]=8'sd0;
        write_ram_bytes(BIAS1_ADDR, 4);

        report("LOAD (X / table / W0 / bias0 / W1 / bias1)");

        // --------------------------------------------------------
        // SET_BASE + RUN_NETWORK(2)
        // --------------------------------------------------------

        errors_before = errors;

        set_base(8'h00, X_BASE);     // X_BASE
        set_base(8'h03, TABLE_BASE); // TABLE_BASE
        set_base(8'h04, BUF_A_BASE); // BUF_A_BASE
        set_base(8'h05, BUF_B_BASE); // BUF_B_BASE

        run_network(8'd2);

        // busy must be observable shortly after RUN_NETWORK is accepted.
        clk_wait(4);
        read_status(rx_tmp);
        if (rx_tmp[0] !== 1'b1) begin $display("  FAIL: busy bit not set right after RUN_NETWORK"); errors = errors + 1; end

        wait_done;

        report("RUN_NETWORK(2) accepted, busy observed, done reached");

        // --------------------------------------------------------
        // READ_OUTPUT: final layer's y_bus, neuron-major
        // Expected Y1 = [123, 10, 6, 127]
        // --------------------------------------------------------

        errors_before = errors;

        read_output_bytes(4);
        check_bytes4("Y1(READ_OUTPUT)", 8'sd123, 8'sd10, 8'sd6, 8'sd127);

        report("READ_OUTPUT matches hand-computed layer 1 output");

        // --------------------------------------------------------
        // READ_RAM at buf_b_base: the sequencer must have copied the
        // SAME final output there (per layer_sequencer.v's contract).
        // --------------------------------------------------------

        errors_before = errors;

        read_ram_bytes(BUF_B_BASE, 4);
        check_bytes4("Y1(buf_b)", 8'sd123, 8'sd10, 8'sd6, 8'sd127);

        report("buf_b_base holds the same final output");

        // --------------------------------------------------------
        // READ_RAM at buf_a_base: layer 0's intermediate output,
        // which became layer 1's input via the ping-pong scheme.
        // Expected Y0 = [10, 6, 0, 127]
        // --------------------------------------------------------

        errors_before = errors;

        read_ram_bytes(BUF_A_BASE, 4);
        check_bytes4("Y0(buf_a)", 8'sd10, 8'sd6, 8'sd0, 8'sd127);

        report("buf_a_base holds layer 0's intermediate output");

        // --------------------------------------------------------
        // Legacy single-layer START must still work after a
        // RUN_NETWORK job (mux correctly releases neuron_memory back
        // to spi_engine's direct-drive path once seq_busy drops).
        // Re-run layer 0 alone via SET_BASE(X/W/BIAS) + START.
        // --------------------------------------------------------

        errors_before = errors;

        set_base(8'h00, X_BASE);     // X_BASE (unchanged, still [1,2,3,4])
        set_base(8'h01, W0_BASE);    // W_BASE = layer 0's weights
        set_base(8'h02, BIAS0_ADDR); // BIAS_ADDR = layer 0's bias

        do_start;
        wait_done;

        read_output_bytes(4);
        check_bytes4("Y0(legacy START)", 8'sd10, 8'sd6, 8'sd0, 8'sd127);

        report("legacy single-layer START still works after RUN_NETWORK (mux sanity)");

        // --------------------------------------------------------
        // SUMMARY
        // --------------------------------------------------------

        $display("");
        $display("========================================");
        if (errors == 0)
            $display("SPI_NEURON_TOP RUN_NETWORK END-TO-END TEST PASSED");
        else
            $display("SPI_NEURON_TOP RUN_NETWORK END-TO-END TEST FAILED: %0d errors", errors);
        $display("========================================");
        $display("");

        $finish;

    end

    // Safety timeout.
    initial begin
        #50000000;
        $display("TIMEOUT: simulation did not finish in time");
        $finish;
    end

endmodule
