`timescale 1ns/1ps

// ================================================================
// SPI_SLAVE PHYSICAL LAYER TESTBENCH
//
// Bit-bangs a simulated SPI master (Mode 0, MSB-first) against
// rtl/spi_slave.v and checks:
//   TEST 1: single-byte transaction (rx_byte/rx_valid, MISO readback)
//   TEST 2: multi-byte transaction within one CS-low period
//   TEST 3: back-to-back separate transactions (state resets cleanly)
//   TEST 4: a slower SPI clock (stresses nothing new, but confirms
//           the module isn't implicitly tied to one SCLK/clk ratio)
// ================================================================

module tb;

    localparam CLK_PERIOD = 12.5; // 80 MHz system clock

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

    wire [7:0] rx_byte;
    wire       rx_valid;
    reg  [7:0] tx_byte;
    wire       tx_byte_req;
    wire       cs_active;
    wire       cs_start;
    wire       cs_end;

    spi_slave dut (
        .clk(clk),
        .rst(rst),

        .sclk(sclk),
        .mosi(mosi),
        .miso(miso),
        .cs_n(cs_n),

        .rx_byte(rx_byte),
        .rx_valid(rx_valid),

        .tx_byte(tx_byte),
        .tx_byte_req(tx_byte_req),

        .cs_active(cs_active),
        .cs_start(cs_start),
        .cs_end(cs_end)
    );

    // ============================================================
    // tx_byte queue: serves tx_queue[tx_queue_idx] combinationally
    // at all times (spi_slave.v prefetches it via tx_byte_req).
    //
    // The index advances on `rx_valid`, NOT on `tx_byte_req`:
    // tx_byte_req fires one extra ("phantom") time after the last
    // byte of every transaction (see the contract note in
    // rtl/spi_slave.v), while rx_valid fires exactly once per REAL
    // byte transferred, in both directions (SPI is full-duplex) --
    // the correct signal to retire one queue entry.
    // ============================================================

    reg [7:0] tx_queue [0:7];
    integer   tx_queue_len;
    integer   tx_queue_idx;

    always @(posedge clk) begin
        if (rst) begin
            tx_queue_idx <= 0;
        end else if (rx_valid) begin
            if (tx_queue_idx < tx_queue_len)
                tx_queue_idx <= tx_queue_idx + 1;
        end
    end

    always @(*) begin
        tx_byte = (tx_queue_idx < tx_queue_len) ? tx_queue[tx_queue_idx] : 8'h00;
    end

    // ============================================================
    // rx capture: record every received byte in order
    // ============================================================

    reg [7:0] rx_log [0:7];
    integer   rx_log_len;

    always @(posedge clk) begin
        if (rst) begin
            rx_log_len <= 0;
        end else if (rx_valid) begin
            rx_log[rx_log_len] <= rx_byte;
            rx_log_len <= rx_log_len + 1;
        end
    end

    // ============================================================
    // cs_start / cs_end pulse counters
    // ============================================================

    integer cs_start_count;
    integer cs_end_count;

    always @(posedge clk) begin
        if (rst) begin
            cs_start_count <= 0;
            cs_end_count   <= 0;
        end else begin
            if (cs_start) cs_start_count <= cs_start_count + 1;
            if (cs_end)   cs_end_count   <= cs_end_count + 1;
        end
    end

    // ============================================================
    // SPI MASTER BFM (Mode 0, MSB-first, bit-banged)
    //
    // half_period is in ns; must stay large enough relative to
    // CLK_PERIOD for the 2-flop CDC synchronizer in spi_slave.v to
    // reliably catch every edge (>= ~3 system clocks per SCLK
    // half-period is a safe margin).
    // ============================================================

    reg [7:0] miso_capture [0:7];
    integer   miso_capture_len;

    // clk-cycle-counted wait: every SPI edge in this BFM is placed a
    // fixed number of `clk` cycles apart, instead of a raw `#ns`
    // delay. This keeps the master deterministically phase-aligned
    // to the system clock, so the fixed CDC latency of spi_slave.v
    // (3-stage synchronizer + 1 cycle for edge detect, ~4 clk
    // cycles) always falls comfortably inside the margin instead of
    // drifting against it run to run.
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
                sclk = 1'b1;              // rising edge: slave samples MOSI
                rx_acc[i] = miso;         // master samples MISO (stable since the prior falling edge)
                clk_wait(half_bit_cycles);
                sclk = 1'b0;              // falling edge: slave updates MISO
                clk_wait(half_bit_cycles);
            end
            rx = rx_acc;
        end
    endtask

    reg [7:0] rx_tmp;
    integer errors;
    integer errors_before;

    // ============================================================
    // MAIN
    // ============================================================

    initial begin

        $dumpfile("sim/spi_slave.vcd");
        $dumpvars(0, tb);

        rst   = 1'b1;
        cs_n  = 1'b1;
        sclk  = 1'b0;
        mosi  = 1'b0;
        errors = 0;
        tx_queue_len = 0;
        rx_log_len   = 0;

        repeat (5) @(posedge clk);
        rst = 1'b0;
        repeat (5) @(posedge clk);

        $display("");
        $display("========================================");
        $display("SPI_SLAVE PHYSICAL LAYER TEST");
        $display("========================================");

        // --------------------------------------------------------
        // TEST 1: single-byte transaction
        // Master sends 0xA5, slave echoes back queued 0x3C.
        // --------------------------------------------------------

        errors_before = errors;

        tx_queue[0] = 8'h3C;
        tx_queue_len = 1;

        spi_begin(8);
        spi_xfer_byte(8'hA5, 8, rx_tmp);
        spi_end(8);

        @(posedge clk); @(posedge clk);

        $display("");
        $display("TEST 1: single byte");
        $display("  MOSI sent = 0xA5, slave rx_byte  = 0x%02x (expect 0xA5)", rx_log[0]);
        $display("  MISO sent = 0x3C, master received = 0x%02x (expect 0x3C)", rx_tmp);
        $display("  cs_start pulses = %0d (expect 1), cs_end pulses = %0d (expect 1)",
                  cs_start_count, cs_end_count);

        if (rx_log[0] !== 8'hA5) begin $display("  FAIL: rx_byte mismatch"); errors = errors + 1; end
        if (rx_tmp    !== 8'h3C) begin $display("  FAIL: MISO readback mismatch"); errors = errors + 1; end
        if (cs_start_count !== 1) begin $display("  FAIL: cs_start count"); errors = errors + 1; end
        if (cs_end_count   !== 1) begin $display("  FAIL: cs_end count"); errors = errors + 1; end
        if (errors == errors_before) $display("  PASS");

        // --------------------------------------------------------
        // TEST 2: multi-byte transaction, single CS-low period
        // Master sends 0x11, 0x22, 0x33, 0x44.
        // Slave echoes back 0xDE, 0xAD, 0xBE, 0xEF.
        // --------------------------------------------------------

        @(negedge clk); rst = 1'b1; @(negedge clk); rst = 1'b0; @(posedge clk);
        rx_log_len = 0; cs_start_count = 0; cs_end_count = 0;
        errors_before = errors;

        tx_queue[0] = 8'hDE;
        tx_queue[1] = 8'hAD;
        tx_queue[2] = 8'hBE;
        tx_queue[3] = 8'hEF;
        tx_queue_len = 4;

        spi_begin(8);
        spi_xfer_byte(8'h11, 8, rx_tmp); miso_capture[0] = rx_tmp;
        spi_xfer_byte(8'h22, 8, rx_tmp); miso_capture[1] = rx_tmp;
        spi_xfer_byte(8'h33, 8, rx_tmp); miso_capture[2] = rx_tmp;
        spi_xfer_byte(8'h44, 8, rx_tmp); miso_capture[3] = rx_tmp;
        spi_end(8);

        @(posedge clk); @(posedge clk);

        $display("");
        $display("TEST 2: multi-byte, one CS period");
        $display("  rx_log = %02x %02x %02x %02x (expect 11 22 33 44)",
                  rx_log[0], rx_log[1], rx_log[2], rx_log[3]);
        $display("  miso   = %02x %02x %02x %02x (expect de ad be ef)",
                  miso_capture[0], miso_capture[1], miso_capture[2], miso_capture[3]);
        $display("  cs_start pulses = %0d (expect 1), cs_end pulses = %0d (expect 1)",
                  cs_start_count, cs_end_count);

        if (rx_log[0] !== 8'h11 || rx_log[1] !== 8'h22 ||
            rx_log[2] !== 8'h33 || rx_log[3] !== 8'h44) begin
            $display("  FAIL: rx sequence mismatch");
            errors = errors + 1;
        end
        if (miso_capture[0] !== 8'hDE || miso_capture[1] !== 8'hAD ||
            miso_capture[2] !== 8'hBE || miso_capture[3] !== 8'hEF) begin
            $display("  FAIL: MISO sequence mismatch");
            errors = errors + 1;
        end
        if (cs_start_count !== 1) begin $display("  FAIL: cs_start count"); errors = errors + 1; end
        if (cs_end_count   !== 1) begin $display("  FAIL: cs_end count"); errors = errors + 1; end
        if (errors == errors_before) $display("  PASS");

        // --------------------------------------------------------
        // TEST 3: back-to-back separate transactions
        // Two independent single-byte transactions; state must
        // reset cleanly between them (no leftover bit_count/shift).
        // --------------------------------------------------------

        @(negedge clk); rst = 1'b1; @(negedge clk); rst = 1'b0; @(posedge clk);
        rx_log_len = 0; cs_start_count = 0; cs_end_count = 0;
        errors_before = errors;

        tx_queue[0] = 8'h01;
        tx_queue_len = 1;
        spi_begin(8);
        spi_xfer_byte(8'h7E, 8, rx_tmp);
        spi_end(8);

        repeat (10) @(posedge clk);

        tx_queue[0] = 8'h02;
        tx_queue_len = 1;
        spi_begin(8);
        spi_xfer_byte(8'h81, 8, rx_tmp);
        spi_end(8);

        @(posedge clk); @(posedge clk);

        $display("");
        $display("TEST 3: back-to-back transactions");
        $display("  rx_log = %02x %02x (expect 7e 81)", rx_log[0], rx_log[1]);
        $display("  cs_start pulses = %0d (expect 2), cs_end pulses = %0d (expect 2)",
                  cs_start_count, cs_end_count);

        if (rx_log[0] !== 8'h7E || rx_log[1] !== 8'h81) begin
            $display("  FAIL: rx sequence mismatch");
            errors = errors + 1;
        end
        if (cs_start_count !== 2) begin $display("  FAIL: cs_start count"); errors = errors + 1; end
        if (cs_end_count   !== 2) begin $display("  FAIL: cs_end count"); errors = errors + 1; end
        if (errors == errors_before) $display("  PASS");

        // --------------------------------------------------------
        // TEST 4: slower SPI clock (larger half_period), same
        // single-byte check, confirms no hidden dependency on a
        // specific SCLK/clk ratio (as long as the CDC margin holds).
        // --------------------------------------------------------

        @(negedge clk); rst = 1'b1; @(negedge clk); rst = 1'b0; @(posedge clk);
        rx_log_len = 0; cs_start_count = 0; cs_end_count = 0;
        errors_before = errors;

        tx_queue[0] = 8'h5A;
        tx_queue_len = 1;

        spi_begin(20);
        spi_xfer_byte(8'h96, 20, rx_tmp);
        spi_end(20);

        @(posedge clk); @(posedge clk);

        $display("");
        $display("TEST 4: slower SCLK (200ns half-period)");
        $display("  rx_byte = 0x%02x (expect 0x96), MISO = 0x%02x (expect 0x5a)",
                  rx_log[0], rx_tmp);

        if (rx_log[0] !== 8'h96) begin $display("  FAIL: rx_byte mismatch"); errors = errors + 1; end
        if (rx_tmp    !== 8'h5A) begin $display("  FAIL: MISO readback mismatch"); errors = errors + 1; end
        if (errors == errors_before) $display("  PASS");

        $display("");
        $display("========================================");
        if (errors == 0)
            $display("SPI_SLAVE TEST PASSED");
        else
            $display("SPI_SLAVE TEST FAILED: %0d errors", errors);
        $display("========================================");
        $display("");

        $finish;

    end

endmodule
