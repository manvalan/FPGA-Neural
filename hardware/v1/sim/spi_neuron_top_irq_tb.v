`timescale 1ns/1ps

// ================================================================
// SPI_NEURON_TOP IRQ_N / DATA_READY_N PIN TESTBENCH
//
// New physical attention pins (active-low): irq_n mirrors
// graph_engine's `err` (STATUS.bit2), data_ready_n mirrors
// spi_engine's status_done_sticky (STATUS.bit1). Verifies:
//
//   TEST 1 - idle: both pins HIGH (inactive) after reset.
//   TEST 2 - successful graph run: data_ready_n goes LOW exactly
//            when done latches, irq_n stays HIGH throughout, and
//            data_ready_n goes back HIGH the moment STATUS is read
//            (same flip-flop as STATUS.bit1, clear-on-read).
//   TEST 3 - guard-violation graph run: irq_n goes LOW, data_ready_n
//            stays HIGH (no result is actually ready), irq_n stays
//            LOW even across an unrelated STATUS read (it is NOT
//            clear-on-read like data_ready_n -- only RESET or a
//            fresh run_start clears it, matching graph_engine.err).
//   TEST 4 - RESET clears irq_n back to HIGH.
//
// Same SPI BFM style as sim/spi_neuron_top_graph_tb.v.
// ================================================================

module tb;

    localparam ADDR_WIDTH     = 23;
    localparam DATA_WIDTH     = 8;
    localparam N_INPUTS       = 4;
    localparam N_NEURONS      = 4;
    localparam PARALLEL       = 2;
    localparam ACC_WIDTH      = 32;
    localparam MEM_DATA_WIDTH = 16;
    localparam N_LAYERS       = 4;
    localparam GRAPH_MAX_CONN = 4;
    localparam GRAPH_N_TOTAL  = 4096;

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
    wire irq_n;
    wire data_ready_n;

    wire [ADDR_WIDTH-1:0]     psram_a;
    wire [MEM_DATA_WIDTH-1:0] psram_dq;
    wire psram_ce_n, psram_oe_n, psram_we_n, psram_lb_n, psram_ub_n, psram_zz_n;

    spi_neuron_top #(
        .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH),
        .N_INPUTS(N_INPUTS), .N_NEURONS(N_NEURONS), .PARALLEL(PARALLEL),
        .ACC_WIDTH(ACC_WIDTH), .MEM_DATA_WIDTH(MEM_DATA_WIDTH),
        .CLK_FREQ_MHZ(80), .N_LAYERS(N_LAYERS),
        .GRAPH_MAX_CONN(GRAPH_MAX_CONN), .GRAPH_N_TOTAL(GRAPH_N_TOTAL)
    ) dut (
        .clk(clk), .rst(rst),
        .sclk(sclk), .mosi(mosi), .miso(miso), .cs_n(cs_n),
        .irq_n(irq_n), .data_ready_n(data_ready_n),
        .psram_a(psram_a), .psram_dq(psram_dq),
        .psram_ce_n(psram_ce_n), .psram_oe_n(psram_oe_n), .psram_we_n(psram_we_n),
        .psram_lb_n(psram_lb_n), .psram_ub_n(psram_ub_n), .psram_zz_n(psram_zz_n)
    );

    psram_model #(
        .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(MEM_DATA_WIDTH), .DEPTH(16384)
    ) u_psram (
        .clk(clk), .a(psram_a), .dq(psram_dq),
        .ce_n(psram_ce_n), .oe_n(psram_oe_n), .we_n(psram_we_n),
        .lb_n(psram_lb_n), .ub_n(psram_ub_n), .zz_n(psram_zz_n)
    );

    // ============================================================
    // SPI MASTER BFM (identical to sim/spi_neuron_top_graph_tb.v)
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
            cs_n = 1'b1; sclk = 1'b0; mosi = 1'b0;
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

    reg signed [7:0] payload [0:31];

    task do_reset;
        begin
            spi_begin(HB_REG);
            spi_xfer_byte(8'h0F, HB_REG, rx_tmp);
            spi_end(HB_REG);
        end
    endtask

    task set_net_type;
        input [7:0] t;
        begin
            spi_begin(HB_REG);
            spi_xfer_byte(8'h11, HB_REG, rx_tmp);
            spi_xfer_byte(t, HB_REG, rx_tmp);
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

    task write_ram_bytes;
        input [ADDR_WIDTH-1:0] addr;
        input integer len;
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
                spi_xfer_byte(payload[k], HB_RAM, rx_tmp);
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

    task run_network;
        input [7:0] payload_byte;
        begin
            spi_begin(HB_REG);
            spi_xfer_byte(8'h23, HB_REG, rx_tmp);
            spi_xfer_byte(payload_byte, HB_REG, rx_tmp);
            spi_end(HB_REG);
        end
    endtask

    task write_graph_desc;
        input [ADDR_WIDTH-1:0] base;
        input [23:0] conn_ptr;
        input [15:0] n_conn;
        input [15:0] out_id;
        input [7:0]  activation;
        input [7:0]  bias;
        begin
            payload[0]  = conn_ptr[23:16]; payload[1] = conn_ptr[15:8]; payload[2] = conn_ptr[7:0];
            payload[3]  = n_conn[15:8];    payload[4] = n_conn[7:0];
            payload[5]  = out_id[15:8];    payload[6] = out_id[7:0];
            payload[7]  = activation;      payload[8] = bias;
            payload[9]  = 8'h00;           payload[10] = 8'h00;
            write_ram_bytes(base, 11);
        end
    endtask

    task write_edge;
        input [ADDR_WIDTH-1:0] base;
        input [15:0] src_id;
        input [7:0]  weight;
        begin
            payload[0] = src_id[15:8]; payload[1] = src_id[7:0];
            payload[2] = weight;       payload[3] = 8'h00;
            write_ram_bytes(base, 4);
        end
    endtask

    task wait_pin_low;
        input pin;
        integer cyc;
        begin
            cyc = 0;
            while (pin !== 1'b0 && cyc < 3000) begin
                @(posedge clk);
                cyc = cyc + 1;
            end
        end
    endtask

    localparam [ADDR_WIDTH-1:0] X_BASE     = 22'h000000;
    localparam [ADDR_WIDTH-1:0] TABLE_BASE = 22'h000100;
    localparam [ADDR_WIDTH-1:0] N4_EDGES   = 22'h000200;
    localparam [ADDR_WIDTH-1:0] N5_EDGES   = 22'h000210;
    localparam [ADDR_WIDTH-1:0] OUT_BASE   = 22'h000300;

    localparam ACT_NONE = 8'h00;
    localparam ACT_RELU = 8'h01;

    initial begin

        rst = 1'b1; cs_n = 1'b1; sclk = 1'b0; mosi = 1'b0;
        errors = 0;
        repeat (5) @(posedge clk);
        rst = 1'b0;
        wait (dut.u_psram_ctrl.state == dut.u_psram_ctrl.STATE_IDLE);

        $display("");
        $display("========================================");
        $display("SPI_NEURON_TOP IRQ_N / DATA_READY_N PIN TEST");
        $display("========================================");

        // ---- TEST 1: idle, both pins high after reset ----
        errors_before = errors;
        @(posedge clk);
        if (irq_n !== 1'b1) begin $display("  FAIL: irq_n not high after reset"); errors = errors + 1; end
        if (data_ready_n !== 1'b1) begin $display("  FAIL: data_ready_n not high after reset"); errors = errors + 1; end
        if (errors == errors_before) $display("TEST 1 (idle after reset, both pins high): PASS");
        else $display("TEST 1: FAIL");

        // ---- TEST 2: valid graph run -> data_ready_n pulses low, irq_n stays high ----
        errors_before = errors;

        do_reset;

        payload[0] = 8'sd10; payload[1] = 8'sd1; payload[2] = 8'sd4; payload[3] = 8'sd0;
        write_ram_bytes(X_BASE, 4);
        write_graph_desc(TABLE_BASE + 0*11, N4_EDGES, 16'd2, 16'd4, ACT_RELU, 8'sd2);
        write_graph_desc(TABLE_BASE + 1*11, N5_EDGES, 16'd2, 16'd5, ACT_NONE, 8'sd0);
        write_edge(N4_EDGES + 0*4, 16'd0, 8'sd5);
        write_edge(N4_EDGES + 1*4, 16'd1, -8'sd3);
        write_edge(N5_EDGES + 0*4, 16'd4, 8'sd2);
        write_edge(N5_EDGES + 1*4, 16'd2, 8'sd7);

        set_net_type(8'h02);
        set_base(8'h00, X_BASE);
        set_base(8'h03, TABLE_BASE);
        set_base(8'h04, OUT_BASE);
        set_base(8'h07, 24'h000004);
        set_base(8'h09, 24'h000002);
        set_base(8'h0A, 24'h000001);

        if (irq_n !== 1'b1) begin $display("  FAIL: irq_n dropped before run_start"); errors = errors + 1; end

        run_network(8'h00);

        wait_pin_low(data_ready_n);
        if (data_ready_n !== 1'b0) begin
            $display("  FAIL: data_ready_n never went low after a valid run");
            errors = errors + 1;
        end else begin
            $display("  data_ready_n went low as expected");
        end
        if (irq_n !== 1'b1) begin
            $display("  FAIL: irq_n dropped on a VALID graph run (should stay high)");
            errors = errors + 1;
        end

        // Reading STATUS clears the sticky bit -> data_ready_n back high
        read_status(rx_tmp);
        @(posedge clk);
        if (rx_tmp[1] !== 1'b1) begin
            $display("  FAIL: STATUS.done bit not set alongside data_ready_n");
            errors = errors + 1;
        end
        if (data_ready_n !== 1'b1) begin
            $display("  FAIL: data_ready_n did not return high after STATUS read");
            errors = errors + 1;
        end else begin
            $display("  data_ready_n returned high after STATUS read (clear-on-read, same flip-flop)");
        end

        if (errors == errors_before) $display("TEST 2 (valid run: data_ready_n low->high, irq_n stays high): PASS");
        else $display("TEST 2: FAIL");

        // ---- TEST 3: guard-violation graph run -> irq_n low, data_ready_n stays high ----
        errors_before = errors;

        do_reset;
        set_net_type(8'h02);

        payload[0] = 8'sd0;
        write_ram_bytes(X_BASE, 1);
        write_graph_desc(TABLE_BASE, N4_EDGES, 16'd1, 16'd4, ACT_RELU, 8'sd0);
        write_edge(N4_EDGES + 0*4, 16'd4, 8'sd1); // src_id == out_id: invalid
        write_edge(N4_EDGES + 1*4, 16'd0, 8'sd0);

        set_base(8'h00, X_BASE);
        set_base(8'h03, TABLE_BASE);
        set_base(8'h04, OUT_BASE);
        set_base(8'h07, 24'h000001);
        set_base(8'h09, 24'h000001);
        set_base(8'h0A, 24'h000001);

        run_network(8'h00);

        wait_pin_low(irq_n);
        if (irq_n !== 1'b0) begin
            $display("  FAIL: irq_n never went low on an invalid graph");
            errors = errors + 1;
        end else begin
            $display("  irq_n went low as expected");
        end
        if (data_ready_n !== 1'b1) begin
            $display("  FAIL: data_ready_n dropped on a run that errored (no result is ready)");
            errors = errors + 1;
        end

        // An unrelated STATUS read must NOT clear irq_n (only RESET / fresh run_start do)
        read_status(rx_tmp);
        @(posedge clk);
        if (rx_tmp[2] !== 1'b1) begin
            $display("  FAIL: STATUS.err bit not set alongside irq_n");
            errors = errors + 1;
        end
        if (irq_n !== 1'b0) begin
            $display("  FAIL: irq_n cleared by a plain STATUS read (should only clear on RESET/fresh run_start)");
            errors = errors + 1;
        end else begin
            $display("  irq_n correctly stayed low across a STATUS read (not clear-on-read)");
        end

        if (errors == errors_before) $display("TEST 3 (invalid run: irq_n low, data_ready_n stays high, not clear-on-read): PASS");
        else $display("TEST 3: FAIL");

        // ---- TEST 4: RESET clears irq_n back to high ----
        errors_before = errors;

        do_reset;
        @(posedge clk);
        if (irq_n !== 1'b1) begin
            $display("  FAIL: irq_n not cleared by RESET");
            errors = errors + 1;
        end else begin
            $display("  irq_n cleared by RESET as expected");
        end

        if (errors == errors_before) $display("TEST 4 (RESET clears irq_n): PASS");
        else $display("TEST 4: FAIL");

        $display("");
        $display("========================================");
        if (errors == 0)
            $display("SPI_NEURON_TOP IRQ/DATA_READY PIN TEST PASSED");
        else
            $display("SPI_NEURON_TOP IRQ/DATA_READY PIN TEST FAILED: %0d errors", errors);
        $display("========================================");
        $display("");

        $finish;
    end

    initial begin
        #50000000;
        $display("TIMEOUT: simulation did not finish in time");
        $finish;
    end

endmodule
