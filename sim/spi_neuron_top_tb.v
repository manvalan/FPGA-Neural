`timescale 1ns/1ps

// ================================================================
// SPI_NEURON_TOP END-TO-END TESTBENCH
//
// Drives the FULL real stack (spi_slave + spi_engine + mem_arbiter
// + int8_memory_access + memory_interface + psram_controller +
// psram_model) purely over simulated SPI -- no direct injection
// into neuron_memory's ports. This is the "verified with the real
// RAM" test: everything WRITE_RAM/READ_RAM/neuron_memory touches
// goes through the actual PSRAM timing model, not a synthetic mock.
//
// Session (matches docs §8.1 example + neuron_memory_tb.v scenarios,
// this time reached only through the SPI opcode set):
//   RESET -> READ_CONFIG -> WRITE_RAM(X) -> WRITE_RAM(W) ->
//   WRITE_RAM(bias) -> READ_RAM verify -> SET_BASE x3 -> START ->
//   poll STATUS -> READ_OUTPUT
//
// TEST 1: X=1 (32x), W=1, bias=0   -> y = 32
// TEST 2: reload W=4               -> y saturates to 127
// TEST 3: reload W=-1              -> ReLU -> y = 0
// ================================================================

module tb;

    localparam ADDR_WIDTH     = 22;
    localparam DATA_WIDTH     = 8;
    localparam N_INPUTS       = 32;
    localparam N_NEURONS      = 1;
    localparam PARALLEL       = 8;
    localparam ACC_WIDTH      = 32;
    localparam MEM_DATA_WIDTH = 16;

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
        .CLK_FREQ_MHZ(80)
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
    // SPI MASTER BFM
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

    // RAM-touching bytes need enough margin for the real PSRAM
    // chain's latency (psram_controller ACCESS_CYCLES ~= ceil(70ns
    // * 80MHz) = 6 cycles, plus memory_interface/int8_memory_access/
    // arbiter overhead -- comfortably covered by 40 cycles/half-bit).
    localparam HB_RAM = 40;
    // Pure register opcodes (SET_BASE/START/STATUS/READ_OUTPUT/
    // READ_CONFIG/RESET) only need CDC margin (~4 cycles).
    localparam HB_REG = 8;

    reg [7:0] rx_tmp;
    integer   errors;
    integer   i;
    integer   poll_count;

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
            spi_xfer_byte(8'h10, HB_REG, rx_tmp);
            spi_xfer_byte(sel, HB_REG, rx_tmp);
            spi_xfer_byte(addr[23:16], HB_REG, rx_tmp);
            spi_xfer_byte(addr[15:8],  HB_REG, rx_tmp);
            spi_xfer_byte(addr[7:0],   HB_REG, rx_tmp);
            spi_end(HB_REG);
        end
    endtask

    task write_ram_const;
        input [ADDR_WIDTH-1:0] addr;
        input integer len;
        input signed [7:0] value;
        integer k;
        begin
            spi_begin(HB_RAM);
            spi_xfer_byte(8'h01, HB_RAM, rx_tmp);
            spi_xfer_byte(addr[23:16], HB_RAM, rx_tmp);
            spi_xfer_byte(addr[15:8],  HB_RAM, rx_tmp);
            spi_xfer_byte(addr[7:0],   HB_RAM, rx_tmp);
            spi_xfer_byte(len[15:8],   HB_RAM, rx_tmp);
            spi_xfer_byte(len[7:0],    HB_RAM, rx_tmp);
            for (k = 0; k < len; k = k + 1)
                spi_xfer_byte(value, HB_RAM, rx_tmp);
            spi_end(HB_RAM);
        end
    endtask

    task read_ram_byte;
        input [ADDR_WIDTH-1:0] addr;
        output [7:0] data;
        begin
            spi_begin(HB_RAM);
            spi_xfer_byte(8'h02, HB_RAM, rx_tmp);
            spi_xfer_byte(addr[23:16], HB_RAM, rx_tmp);
            spi_xfer_byte(addr[15:8],  HB_RAM, rx_tmp);
            spi_xfer_byte(addr[7:0],   HB_RAM, rx_tmp);
            spi_xfer_byte(8'h00, HB_RAM, rx_tmp);
            spi_xfer_byte(8'h01, HB_RAM, rx_tmp);
            spi_xfer_byte(8'h00, HB_RAM, data);
            spi_end(HB_RAM);
        end
    endtask

    task read_status;
        output [7:0] status;
        begin
            spi_begin(HB_REG);
            spi_xfer_byte(8'h21, HB_REG, rx_tmp);
            spi_xfer_byte(8'h00, HB_REG, status);
            spi_end(HB_REG);
        end
    endtask

    task do_start;
        begin
            spi_begin(HB_REG);
            spi_xfer_byte(8'h20, HB_REG, rx_tmp);
            spi_end(HB_REG);
        end
    endtask

    task wait_done;
        reg [7:0] status;
        begin
            poll_count = 0;
            status = 8'h00;
            while (!status[1] && poll_count < 1000) begin
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

    task read_output_byte0;
        output signed [7:0] y0;
        begin
            spi_begin(HB_REG);
            spi_xfer_byte(8'h22, HB_REG, rx_tmp);
            spi_xfer_byte(8'h00, HB_REG, y0);
            spi_end(HB_REG);
        end
    endtask

    // ============================================================
    // MAIN
    // ============================================================

    reg signed [7:0] y_result;
    reg [7:0] cfg_byte;
    reg [7:0] verify_byte;

    initial begin

        $dumpfile("sim/spi_neuron_top.vcd");
        $dumpvars(0, tb);

        rst   = 1'b1;
        cs_n  = 1'b1;
        sclk  = 1'b0;
        mosi  = 1'b0;
        errors = 0;

        repeat (5) @(posedge clk);
        rst = 1'b0;

        // Wait for PSRAM controller initialization (same as
        // sim/neuron_memory_tb.v).
        wait (dut.u_psram_ctrl.state == dut.u_psram_ctrl.STATE_IDLE);

        $display("");
        $display("========================================");
        $display("SPI_NEURON_TOP END-TO-END TEST (real PSRAM)");
        $display("========================================");

        // --------------------------------------------------------
        // RESET (opcode) + READ_CONFIG
        // --------------------------------------------------------

        do_reset;

        spi_begin(HB_REG);
        spi_xfer_byte(8'h30, HB_REG, rx_tmp);
        spi_xfer_byte(8'h00, HB_REG, cfg_byte);
        if (cfg_byte !== ADDR_WIDTH[7:0]) begin $display("  FAIL: READ_CONFIG ADDR_WIDTH"); errors = errors + 1; end
        spi_xfer_byte(8'h00, HB_REG, cfg_byte);
        if (cfg_byte !== N_INPUTS[15:8]) begin $display("  FAIL: READ_CONFIG N_INPUTS hi"); errors = errors + 1; end
        spi_xfer_byte(8'h00, HB_REG, cfg_byte);
        if (cfg_byte !== N_INPUTS[7:0]) begin $display("  FAIL: READ_CONFIG N_INPUTS lo"); errors = errors + 1; end
        spi_xfer_byte(8'h00, HB_REG, cfg_byte);
        if (cfg_byte !== N_NEURONS[7:0]) begin $display("  FAIL: READ_CONFIG N_NEURONS"); errors = errors + 1; end
        spi_xfer_byte(8'h00, HB_REG, cfg_byte);
        if (cfg_byte !== PARALLEL[7:0]) begin $display("  FAIL: READ_CONFIG PARALLEL"); errors = errors + 1; end
        spi_xfer_byte(8'h00, HB_REG, cfg_byte);
        if (cfg_byte !== DATA_WIDTH[7:0]) begin $display("  FAIL: READ_CONFIG DATA_WIDTH"); errors = errors + 1; end
        spi_end(HB_REG);

        $display("READ_CONFIG: %0s", (errors == 0) ? "PASS" : "FAIL");

        // --------------------------------------------------------
        // Load X=1 (32x), W=1 (32x), bias=0 into real PSRAM over SPI
        // --------------------------------------------------------

        write_ram_const(22'h000000, N_INPUTS, 8'sd1); // X
        write_ram_const(22'h000100, N_INPUTS, 8'sd1); // W
        write_ram_const(22'h000200, 1,        8'sd0); // bias

        // Verify one written byte reads back correctly through the
        // real PSRAM (READ_RAM), confirming the write actually
        // landed and isn't just accepted-but-dropped.
        read_ram_byte(22'h000000, verify_byte);
        if (verify_byte !== 8'sd1) begin
            $display("  FAIL: READ_RAM verify X[0] = 0x%02x expected 0x01", verify_byte);
            errors = errors + 1;
        end else begin
            $display("READ_RAM verify: PASS (X[0]=0x%02x)", verify_byte);
        end

        set_base(8'h00, 22'h000000); // X_BASE
        set_base(8'h01, 22'h000100); // W_BASE
        set_base(8'h02, 22'h000200); // BIAS_ADDR

        // --------------------------------------------------------
        // TEST 1: 32 * 1 * 1 + 0 = 32
        // --------------------------------------------------------

        do_start;
        wait_done;
        read_output_byte0(y_result);

        $display("");
        $display("TEST 1 (SUM=32): y = %0d (expected 32)", y_result);
        if (y_result !== 8'sd32) begin
            $display("  FAIL");
            errors = errors + 1;
        end else begin
            $display("  PASS");
        end

        // --------------------------------------------------------
        // TEST 2: reload W=4 -> 32*1*4 = 128 -> saturate to 127
        // --------------------------------------------------------

        write_ram_const(22'h000100, N_INPUTS, 8'sd4);

        do_start;
        wait_done;
        read_output_byte0(y_result);

        $display("");
        $display("TEST 2 (SATURATION): y = %0d (expected 127)", y_result);
        if (y_result !== 8'sd127) begin
            $display("  FAIL");
            errors = errors + 1;
        end else begin
            $display("  PASS");
        end

        // --------------------------------------------------------
        // TEST 3: reload W=-1 -> 32*1*(-1) = -32 -> ReLU -> 0
        // --------------------------------------------------------

        write_ram_const(22'h000100, N_INPUTS, -8'sd1);

        do_start;
        wait_done;
        read_output_byte0(y_result);

        $display("");
        $display("TEST 3 (RELU): y = %0d (expected 0)", y_result);
        if (y_result !== 8'sd0) begin
            $display("  FAIL");
            errors = errors + 1;
        end else begin
            $display("  PASS");
        end

        // --------------------------------------------------------
        // SUMMARY
        // --------------------------------------------------------

        $display("");
        $display("========================================");
        if (errors == 0)
            $display("SPI_NEURON_TOP END-TO-END TEST PASSED");
        else
            $display("SPI_NEURON_TOP END-TO-END TEST FAILED: %0d errors", errors);
        $display("========================================");
        $display("");

        $finish;

    end

endmodule
