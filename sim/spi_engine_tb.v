`timescale 1ns/1ps

// ================================================================
// SPI_ENGINE TESTBENCH
//
// Drives spi_slave.v + spi_engine.v together through a simulated
// SPI master (same clk-cycle-counted BFM proven in spi_slave_tb.v),
// against a synthetic byte-RAM model (small fixed latency, isolates
// the opcode FSM from the full PSRAM stack) and a manually-driven
// neuron_memory mock (nm_busy/nm_done/y_bus driven by the test,
// x_base/w_base/bias_addr/nm_start/nm_soft_rst observed).
//
// Covers every opcode plus a few protocol edge cases:
//   A: WRITE_RAM then READ_RAM back
//   B: SET_BASE for X/W/BIAS
//   C: START (accepted when idle, ignored when busy)
//   D: STATUS (live busy bit, sticky done bit, clear-on-read)
//   E: RESET (pulses nm_soft_rst, clears sticky done)
//   F: READ_OUTPUT (N_NEURONS=3 bytes, neuron-major)
//   G: READ_CONFIG (8-byte hardware record)
//   H: NOP (no side effects)
//   I: WRITE_RAM with more MOSI bytes than len (extra bytes ignored)
//   J: back-to-back transactions (state resets cleanly via cs_end)
//   K: SET_BASE for TABLE/BUF_A/BUF_B (Phase 5)
//   L: RUN_NETWORK (Phase 5: accepted/ignored gating, STATUS.busy
//      following seq_busy, STATUS.done latching on seq_done only)
// ================================================================

module tb;

    localparam ADDR_WIDTH = 22;
    localparam DATA_WIDTH = 8;
    localparam N_INPUTS   = 32;
    localparam N_NEURONS  = 3;
    localparam PARALLEL   = 8;

    localparam CLK_PERIOD = 12.5; // 80 MHz

    reg clk;
    reg rst;

    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD / 2.0) clk = ~clk;
    end

    // ============================================================
    // SPI PINS
    // ============================================================

    reg  sclk;
    reg  mosi;
    wire miso;
    reg  cs_n;

    // ============================================================
    // spi_slave <-> spi_engine byte-level bus
    // ============================================================

    wire [7:0] rx_byte;
    wire       rx_valid;
    wire       cs_start;
    wire       cs_end_w;
    wire [7:0] tx_byte;
    wire       tx_byte_req;

    spi_slave u_slave (
        .clk(clk), .rst(rst),
        .sclk(sclk), .mosi(mosi), .miso(miso), .cs_n(cs_n),
        .rx_byte(rx_byte), .rx_valid(rx_valid),
        .tx_byte(tx_byte), .tx_byte_req(tx_byte_req),
        .cs_active(), .cs_start(cs_start), .cs_end(cs_end_w)
    );

    // ============================================================
    // spi_engine <-> synthetic RAM
    // ============================================================

    wire                   ram_req;
    wire                   ram_wr;
    wire [ADDR_WIDTH-1:0]  ram_addr;
    wire signed [7:0]      ram_wdata;

    reg  signed [7:0]      ram_rdata;
    reg                    ram_ready;

    wire [ADDR_WIDTH-1:0] x_base;
    wire [ADDR_WIDTH-1:0] w_base;
    wire [ADDR_WIDTH-1:0] bias_addr;

    wire nm_start;
    reg  nm_busy;
    reg  nm_done;

    reg signed [DATA_WIDTH*N_NEURONS-1:0] y_bus;

    wire nm_soft_rst;

    // Phase 5 layer_sequencer ports: this testbench only exercises
    // spi_engine's legacy single-layer path, so seq_busy/seq_done
    // are tied off (must be driven, not left floating -- a floating
    // input here would make busy_all/done_event unknown ('x') and
    // silently break the existing OP_START/STATUS tests below).
    // table_base/buf_a_base/buf_b_base/run_start/run_num_layers are
    // outputs and are left unconnected on purpose.
    reg seq_busy = 1'b0;
    reg seq_done = 1'b0;

    wire [ADDR_WIDTH-1:0] table_base;
    wire [ADDR_WIDTH-1:0] buf_a_base;
    wire [ADDR_WIDTH-1:0] buf_b_base;
    wire                  run_start;
    wire [7:0]             run_num_layers;

    spi_engine #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .N_INPUTS(N_INPUTS),
        .N_NEURONS(N_NEURONS),
        .PARALLEL(PARALLEL)
    ) u_engine (
        .clk(clk), .rst(rst),

        .rx_byte(rx_byte), .rx_valid(rx_valid),
        .cs_start(cs_start), .cs_end(cs_end_w),
        .tx_byte(tx_byte), .tx_byte_req(tx_byte_req),

        .ram_req(ram_req), .ram_wr(ram_wr), .ram_addr(ram_addr), .ram_wdata(ram_wdata),
        .ram_rdata(ram_rdata), .ram_ready(ram_ready),

        .x_base(x_base), .w_base(w_base), .bias_addr(bias_addr),

        .nm_start(nm_start), .nm_busy(nm_busy), .nm_done(nm_done),
        .y_bus(y_bus),

        .nm_soft_rst(nm_soft_rst),

        .table_base(table_base), .buf_a_base(buf_a_base), .buf_b_base(buf_b_base),
        .run_start(run_start), .run_num_layers(run_num_layers),
        .seq_busy(seq_busy), .seq_done(seq_done)
    );

    // ============================================================
    // SYNTHETIC BYTE-RAM MODEL
    //
    // Fixed 2-cycle latency (req seen -> 1 extra cycle -> ready
    // pulse), independent of the real PSRAM stack, to isolate
    // spi_engine's own request/ready handshake correctness.
    // ============================================================

    reg [7:0] ram_mem [0:1023];

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
    // SPI MASTER BFM (same pattern as sim/spi_slave_tb.v)
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

    localparam HB = 6; // half-bit cycles for all transfers in this bench

    // ============================================================
    // nm_start / nm_soft_rst pulse latches (declared here, ahead of
    // the main initial block below, since Icarus in -g2012 mode
    // still requires declaration-before-use for plain Verilog regs)
    // ============================================================

    reg nm_start_seen;
    reg nm_soft_rst_seen;
    reg run_start_seen;

    always @(posedge clk) begin
        if (nm_start)    nm_start_seen    <= 1'b1;
        if (nm_soft_rst) nm_soft_rst_seen <= 1'b1;
        if (run_start)   run_start_seen   <= 1'b1;
    end

    reg [7:0] rx_tmp;
    integer   errors;
    integer   errors_before;
    integer   i;

    // ============================================================
    // MAIN
    // ============================================================

    initial begin

        $dumpfile("sim/spi_engine.vcd");
        $dumpvars(0, tb);

        rst   = 1'b1;
        cs_n  = 1'b1;
        sclk  = 1'b0;
        mosi  = 1'b0;
        nm_busy = 1'b0;
        nm_done = 1'b0;
        y_bus   = 0;
        errors  = 0;

        for (i = 0; i < 1024; i = i + 1)
            ram_mem[i] = 8'h00;

        repeat (5) @(posedge clk);
        rst = 1'b0;
        repeat (5) @(posedge clk);

        $display("");
        $display("========================================");
        $display("SPI_ENGINE TEST");
        $display("========================================");

        // --------------------------------------------------------
        // TEST A: WRITE_RAM then READ_RAM back
        // WRITE_RAM opcode=0x01, addr=0x000010 (3B), len=0x0004 (2B),
        // data = 11 22 33 44.
        // READ_RAM opcode=0x02, addr=0x000010 (3B), len=0x0004 (2B).
        // --------------------------------------------------------

        errors_before = errors;

        spi_begin(HB);
        spi_xfer_byte(8'h01, HB, rx_tmp);       // WRITE_RAM
        spi_xfer_byte(8'h00, HB, rx_tmp);       // addr[23:16]
        spi_xfer_byte(8'h00, HB, rx_tmp);       // addr[15:8]
        spi_xfer_byte(8'h10, HB, rx_tmp);       // addr[7:0]
        spi_xfer_byte(8'h00, HB, rx_tmp);       // len[15:8]
        spi_xfer_byte(8'h04, HB, rx_tmp);       // len[7:0]
        spi_xfer_byte(8'h11, HB, rx_tmp);
        spi_xfer_byte(8'h22, HB, rx_tmp);
        spi_xfer_byte(8'h33, HB, rx_tmp);
        spi_xfer_byte(8'h44, HB, rx_tmp);
        spi_end(HB);

        clk_wait(4);

        spi_begin(HB);
        spi_xfer_byte(8'h02, HB, rx_tmp);       // READ_RAM
        spi_xfer_byte(8'h00, HB, rx_tmp);       // addr[23:16]
        spi_xfer_byte(8'h00, HB, rx_tmp);       // addr[15:8]
        spi_xfer_byte(8'h10, HB, rx_tmp);       // addr[7:0]
        spi_xfer_byte(8'h00, HB, rx_tmp);       // len[15:8]
        spi_xfer_byte(8'h04, HB, rx_tmp);       // len[7:0]
        spi_xfer_byte(8'h00, HB, rx_tmp); miso_check(rx_tmp, 8'h11, "A: byte0");
        spi_xfer_byte(8'h00, HB, rx_tmp); miso_check(rx_tmp, 8'h22, "A: byte1");
        spi_xfer_byte(8'h00, HB, rx_tmp); miso_check(rx_tmp, 8'h33, "A: byte2");
        spi_xfer_byte(8'h00, HB, rx_tmp); miso_check(rx_tmp, 8'h44, "A: byte3");
        spi_end(HB);

        report("TEST A: WRITE_RAM / READ_RAM");

        // --------------------------------------------------------
        // TEST B: SET_BASE for X, W, BIAS
        // --------------------------------------------------------

        errors_before = errors;

        set_base(8'h00, 22'h000001); // X_BASE
        set_base(8'h01, 22'h000101); // W_BASE
        set_base(8'h02, 22'h000201); // BIAS_ADDR

        clk_wait(2);

        if (x_base    !== 22'h000001) begin $display("  FAIL: x_base = 0x%06x", x_base); errors = errors + 1; end
        if (w_base    !== 22'h000101) begin $display("  FAIL: w_base = 0x%06x", w_base); errors = errors + 1; end
        if (bias_addr !== 22'h000201) begin $display("  FAIL: bias_addr = 0x%06x", bias_addr); errors = errors + 1; end

        report("TEST B: SET_BASE (X/W/BIAS)");

        // --------------------------------------------------------
        // TEST C: START -- accepted when idle, ignored when busy
        // --------------------------------------------------------

        errors_before = errors;

        nm_busy = 1'b0;
        nm_start_seen = 1'b0;
        spi_begin(HB);
        spi_xfer_byte(8'h20, HB, rx_tmp); // START
        spi_end(HB);
        clk_wait(4);

        if (!nm_start_seen) begin
            $display("  FAIL: nm_start not pulsed while idle");
            errors = errors + 1;
        end

        // now busy: START must be ignored
        nm_busy = 1'b1;
        nm_start_seen = 1'b0;
        spi_begin(HB);
        spi_xfer_byte(8'h20, HB, rx_tmp); // START
        spi_end(HB);
        clk_wait(4);

        if (nm_start_seen) begin
            $display("  FAIL: nm_start pulsed while busy (should be ignored)");
            errors = errors + 1;
        end
        nm_busy = 1'b0;

        report("TEST C: START (idle vs busy)");

        // --------------------------------------------------------
        // TEST D: STATUS -- live busy, sticky/clear-on-read done
        // --------------------------------------------------------

        errors_before = errors;

        nm_busy = 1'b1;
        read_status(rx_tmp);
        if (rx_tmp[0] !== 1'b1) begin $display("  FAIL: busy bit not set while nm_busy=1"); errors = errors + 1; end
        if (rx_tmp[1] !== 1'b0) begin $display("  FAIL: done bit set before any nm_done pulse"); errors = errors + 1; end
        nm_busy = 1'b0;

        // pulse nm_done, then read STATUS well after the pulse: must still be set (sticky)
        @(negedge clk); nm_done = 1'b1; @(negedge clk); nm_done = 1'b0;
        clk_wait(10);
        read_status(rx_tmp);
        if (rx_tmp[1] !== 1'b1) begin $display("  FAIL: done bit not sticky after nm_done pulse"); errors = errors + 1; end

        // reading STATUS must clear done
        read_status(rx_tmp);
        if (rx_tmp[1] !== 1'b0) begin $display("  FAIL: done bit not cleared after STATUS read"); errors = errors + 1; end

        report("TEST D: STATUS (busy live, done sticky/clear-on-read)");

        // --------------------------------------------------------
        // TEST E: RESET -- pulses nm_soft_rst, clears sticky done
        // --------------------------------------------------------

        errors_before = errors;

        @(negedge clk); nm_done = 1'b1; @(negedge clk); nm_done = 1'b0;
        clk_wait(4);

        nm_soft_rst_seen = 1'b0;
        spi_begin(HB);
        spi_xfer_byte(8'h0F, HB, rx_tmp); // RESET
        spi_end(HB);
        clk_wait(4);

        if (!nm_soft_rst_seen) begin
            $display("  FAIL: nm_soft_rst not pulsed by RESET opcode");
            errors = errors + 1;
        end

        clk_wait(4);
        read_status(rx_tmp);
        if (rx_tmp[1] !== 1'b0) begin $display("  FAIL: done bit still set after RESET"); errors = errors + 1; end

        report("TEST E: RESET");

        // --------------------------------------------------------
        // TEST F: READ_OUTPUT (N_NEURONS=3, neuron-major)
        // --------------------------------------------------------

        errors_before = errors;

        y_bus[0*DATA_WIDTH +: DATA_WIDTH] = 8'sd10;
        y_bus[1*DATA_WIDTH +: DATA_WIDTH] = -8'sd20;
        y_bus[2*DATA_WIDTH +: DATA_WIDTH] = 8'sd127;

        spi_begin(HB);
        spi_xfer_byte(8'h22, HB, rx_tmp);       // READ_OUTPUT
        spi_xfer_byte(8'h00, HB, rx_tmp); miso_check(rx_tmp, 8'sd10,   "F: neuron0");
        spi_xfer_byte(8'h00, HB, rx_tmp); miso_check(rx_tmp, -8'sd20,  "F: neuron1");
        spi_xfer_byte(8'h00, HB, rx_tmp); miso_check(rx_tmp, 8'sd127,  "F: neuron2");
        spi_end(HB);

        report("TEST F: READ_OUTPUT");

        // --------------------------------------------------------
        // TEST G: READ_CONFIG
        // --------------------------------------------------------

        errors_before = errors;

        spi_begin(HB);
        spi_xfer_byte(8'h30, HB, rx_tmp);       // READ_CONFIG
        spi_xfer_byte(8'h00, HB, rx_tmp); miso_check(rx_tmp, ADDR_WIDTH[7:0],  "G: ADDR_WIDTH");
        spi_xfer_byte(8'h00, HB, rx_tmp); miso_check(rx_tmp, N_INPUTS[15:8],   "G: N_INPUTS hi");
        spi_xfer_byte(8'h00, HB, rx_tmp); miso_check(rx_tmp, N_INPUTS[7:0],    "G: N_INPUTS lo");
        spi_xfer_byte(8'h00, HB, rx_tmp); miso_check(rx_tmp, N_NEURONS[7:0],   "G: N_NEURONS");
        spi_xfer_byte(8'h00, HB, rx_tmp); miso_check(rx_tmp, PARALLEL[7:0],    "G: PARALLEL");
        spi_xfer_byte(8'h00, HB, rx_tmp); miso_check(rx_tmp, DATA_WIDTH[7:0],  "G: DATA_WIDTH");
        spi_xfer_byte(8'h00, HB, rx_tmp); miso_check(rx_tmp, 8'h00,            "G: version hi");
        spi_xfer_byte(8'h00, HB, rx_tmp); miso_check(rx_tmp, 8'h01,            "G: version lo");
        spi_end(HB);

        report("TEST G: READ_CONFIG");

        // --------------------------------------------------------
        // TEST H: NOP -- no side effects
        // --------------------------------------------------------

        errors_before = errors;

        spi_begin(HB);
        spi_xfer_byte(8'h00, HB, rx_tmp);       // NOP
        spi_end(HB);
        clk_wait(4);

        if (x_base !== 22'h000001 || w_base !== 22'h000101 || bias_addr !== 22'h000201) begin
            $display("  FAIL: NOP changed base registers");
            errors = errors + 1;
        end

        report("TEST H: NOP");

        // --------------------------------------------------------
        // TEST I: WRITE_RAM with more MOSI bytes than len
        // len=2 but 4 data bytes sent; only the first 2 must land.
        // --------------------------------------------------------

        errors_before = errors;

        ram_mem[16'h0300] = 8'hFF; // sentinel: must NOT be overwritten
        ram_mem[16'h0301] = 8'hFF;
        ram_mem[16'h0302] = 8'hFF; // sentinel: extra byte must not land here

        spi_begin(HB);
        spi_xfer_byte(8'h01, HB, rx_tmp);       // WRITE_RAM
        spi_xfer_byte(8'h00, HB, rx_tmp);
        spi_xfer_byte(8'h03, HB, rx_tmp);
        spi_xfer_byte(8'h00, HB, rx_tmp);       // addr = 0x000300
        spi_xfer_byte(8'h00, HB, rx_tmp);
        spi_xfer_byte(8'h02, HB, rx_tmp);       // len = 2
        spi_xfer_byte(8'hAA, HB, rx_tmp);       // byte 0 (written)
        spi_xfer_byte(8'hBB, HB, rx_tmp);       // byte 1 (written)
        spi_xfer_byte(8'hCC, HB, rx_tmp);       // byte 2 (must be ignored)
        spi_xfer_byte(8'hDD, HB, rx_tmp);       // byte 3 (must be ignored)
        spi_end(HB);

        clk_wait(4);

        if (ram_mem[16'h0300] !== 8'hAA) begin $display("  FAIL: ram[0x300]=0x%02x expected 0xAA", ram_mem[16'h0300]); errors = errors + 1; end
        if (ram_mem[16'h0301] !== 8'hBB) begin $display("  FAIL: ram[0x301]=0x%02x expected 0xBB", ram_mem[16'h0301]); errors = errors + 1; end
        if (ram_mem[16'h0302] !== 8'hFF) begin $display("  FAIL: ram[0x302] was overwritten (extra byte not ignored)"); errors = errors + 1; end

        report("TEST I: WRITE_RAM extra MOSI bytes ignored");

        // --------------------------------------------------------
        // TEST J: back-to-back transactions
        // --------------------------------------------------------

        errors_before = errors;

        set_base(8'h00, 22'h000005);
        set_base(8'h01, 22'h000006);

        if (x_base !== 22'h000005) begin $display("  FAIL: x_base after back-to-back = 0x%06x", x_base); errors = errors + 1; end
        if (w_base !== 22'h000006) begin $display("  FAIL: w_base after back-to-back = 0x%06x", w_base); errors = errors + 1; end

        report("TEST J: back-to-back transactions");

        // --------------------------------------------------------
        // TEST K: SET_BASE for TABLE / BUF_A / BUF_B (Phase 5)
        // --------------------------------------------------------

        errors_before = errors;

        set_base(8'h03, 22'h000301); // TABLE_BASE
        set_base(8'h04, 22'h000401); // BUF_A_BASE
        set_base(8'h05, 22'h000501); // BUF_B_BASE

        clk_wait(2);

        if (table_base !== 22'h000301) begin $display("  FAIL: table_base = 0x%06x", table_base); errors = errors + 1; end
        if (buf_a_base !== 22'h000401) begin $display("  FAIL: buf_a_base = 0x%06x", buf_a_base); errors = errors + 1; end
        if (buf_b_base !== 22'h000501) begin $display("  FAIL: buf_b_base = 0x%06x", buf_b_base); errors = errors + 1; end

        report("TEST K: SET_BASE (TABLE/BUF_A/BUF_B)");

        // --------------------------------------------------------
        // TEST L: RUN_NETWORK (Phase 5)
        //   - accepted when idle: pulses run_start, captures
        //     run_num_layers, and STATUS.busy tracks seq_busy
        //     (independent of nm_busy) until seq_done.
        //   - ignored (no run_start) if the engine is already busy
        //     in any form (nm_busy or seq_busy).
        //   - STATUS.done latches only on seq_done while a
        //     RUN_NETWORK job is in flight, not on an intermediate
        //     nm_done pulse (the sequencer's own per-layer nm_done).
        // --------------------------------------------------------

        errors_before = errors;

        // -- accepted when idle --
        run_start_seen = 1'b0;
        spi_begin(HB);
        spi_xfer_byte(8'h23, HB, rx_tmp); // RUN_NETWORK
        spi_xfer_byte(8'h02, HB, rx_tmp); // num_layers = 2
        spi_end(HB);
        clk_wait(4);

        if (!run_start_seen) begin $display("  FAIL: run_start not pulsed while idle"); errors = errors + 1; end
        if (run_num_layers !== 8'h02) begin $display("  FAIL: run_num_layers = %0d, expected 2", run_num_layers); errors = errors + 1; end

        // -- STATUS.busy follows seq_busy even while nm_busy=0 (the
        //    gaps between layers, e.g. descriptor read/output copy) --
        seq_busy = 1'b1;
        read_status(rx_tmp);
        if (rx_tmp[0] !== 1'b1) begin $display("  FAIL: busy bit not set from seq_busy alone"); errors = errors + 1; end

        // -- ignored while seq_busy (a RUN_NETWORK job in flight) --
        run_start_seen = 1'b0;
        spi_begin(HB);
        spi_xfer_byte(8'h23, HB, rx_tmp); // RUN_NETWORK
        spi_xfer_byte(8'h03, HB, rx_tmp); // num_layers = 3 (must be ignored)
        spi_end(HB);
        clk_wait(4);

        if (run_start_seen) begin $display("  FAIL: run_start pulsed while seq_busy (should be ignored)"); errors = errors + 1; end
        if (run_num_layers !== 8'h02) begin $display("  FAIL: run_num_layers changed to %0d while busy (should stay 2)", run_num_layers); errors = errors + 1; end

        // -- an intermediate nm_done pulse (sequencer's per-layer
        //    completion) must NOT set STATUS.done while net_mode
        //    (i.e. seq_busy) is active --
        @(negedge clk); nm_done = 1'b1; @(negedge clk); nm_done = 1'b0;
        clk_wait(4);
        read_status(rx_tmp);
        if (rx_tmp[1] !== 1'b0) begin $display("  FAIL: done bit set by an intermediate nm_done during RUN_NETWORK"); errors = errors + 1; end

        // -- the sequencer's own seq_done (final layer) DOES latch
        //    STATUS.done, and busy drops once seq_busy deasserts --
        @(negedge clk); seq_busy = 1'b0; seq_done = 1'b1;
        @(negedge clk); seq_done = 1'b0;
        clk_wait(4);

        read_status(rx_tmp);
        if (rx_tmp[0] !== 1'b0) begin $display("  FAIL: busy bit still set after seq_busy/seq_done"); errors = errors + 1; end
        if (rx_tmp[1] !== 1'b1) begin $display("  FAIL: done bit not set by seq_done"); errors = errors + 1; end

        report("TEST L: RUN_NETWORK");

        // --------------------------------------------------------
        // SUMMARY
        // --------------------------------------------------------

        $display("");
        $display("========================================");
        if (errors == 0)
            $display("SPI_ENGINE TEST PASSED");
        else
            $display("SPI_ENGINE TEST FAILED: %0d errors", errors);
        $display("========================================");
        $display("");

        $finish;

    end

    // ============================================================
    // HELPER TASKS
    // ============================================================

    task set_base;
        input [7:0] sel;
        input [ADDR_WIDTH-1:0] addr;
        begin
            spi_begin(HB);
            spi_xfer_byte(8'h10, HB, rx_tmp);            // SET_BASE
            spi_xfer_byte(sel, HB, rx_tmp);               // selector
            spi_xfer_byte(addr[23:16], HB, rx_tmp);
            spi_xfer_byte(addr[15:8],  HB, rx_tmp);
            spi_xfer_byte(addr[7:0],   HB, rx_tmp);
            spi_end(HB);
        end
    endtask

    task read_status;
        output [7:0] status;
        begin
            spi_begin(HB);
            spi_xfer_byte(8'h21, HB, rx_tmp);            // STATUS
            spi_xfer_byte(8'h00, HB, status);
            spi_end(HB);
        end
    endtask

    task miso_check;
        input [7:0] got;
        input [7:0] expected;
        input [511:0] label;
        begin
            if (got !== expected) begin
                $display("  FAIL %0s: got 0x%02x expected 0x%02x", label, got, expected);
                errors = errors + 1;
            end
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

    initial begin
        nm_start_seen    = 1'b0;
        nm_soft_rst_seen = 1'b0;
    end

endmodule
