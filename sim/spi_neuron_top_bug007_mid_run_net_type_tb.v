`timescale 1ns/1ps

// ================================================================
// C.8 certification: does SET_NET_TYPE mid-run corrupt an in-flight
// RUN_NETWORK?
//
// Code-inspection finding: rtl/spi_engine.v's ST_SET_NET_TYPE state
// (around line 961) accepts `net_type <= rx_byte` unconditionally on
// any rx_valid -- no check against graph_busy or seq_busy anywhere.
// rtl/spi_neuron_top.v's arbiter Port C mux (lines 394-397) selects
// between graph_engine's and layer_sequencer's ram_req/rdata/ready
// signals PURELY combinationally on the CURRENT value of `net_type`
// -- not latched to "whichever engine started this run". The
// header comment at line 390 calls the two engines "mutually
// exclusive by construction", but that construction only prevents
// both engines from being STARTED at once -- it says nothing about a
// net_type write arriving mid-run.
//
// Hypothesis: starting a graph RUN_NETWORK, then sending
// SET_NET_TYPE(dense) before it completes, re-routes Port C away from
// graph_engine's in-flight memory transaction mid-flight -- graph_engine
// would be left waiting for a ram_ready that can never arrive via its
// now-disconnected mux path (permanent hang, STATUS.busy stuck,
// STATUS.done never sets), while the freshly-selected dense path sees
// spurious traffic not meant for it.
//
// Full end-to-end setup identical to the proven, passing
// sim/spi_neuron_top_graph_tb.v (same graph, same addresses, same SPI
// BFM tasks) -- only the test sequence differs, so any failure here is
// attributable to the net_type switch, not to a setup difference from
// the already-certified happy path.
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

    wire [ADDR_WIDTH-1:0]     psram_a;
    wire [MEM_DATA_WIDTH-1:0] psram_dq;
    wire psram_ce_n, psram_oe_n, psram_we_n, psram_lb_n, psram_ub_n, psram_zz_n;

    spi_neuron_top #(
        .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH),
        .N_INPUTS(N_INPUTS), .N_NEURONS(N_NEURONS), .PARALLEL(PARALLEL), .ACC_WIDTH(ACC_WIDTH),
        .MEM_DATA_WIDTH(MEM_DATA_WIDTH), .CLK_FREQ_MHZ(80), .N_LAYERS(N_LAYERS),
        .GRAPH_MAX_CONN(GRAPH_MAX_CONN), .GRAPH_N_TOTAL(GRAPH_N_TOTAL)
    ) dut (
        .clk(clk), .rst(rst),
        .sclk(sclk), .mosi(mosi), .miso(miso), .cs_n(cs_n),
        .psram_a(psram_a), .psram_dq(psram_dq),
        .psram_ce_n(psram_ce_n), .psram_oe_n(psram_oe_n), .psram_we_n(psram_we_n),
        .psram_lb_n(psram_lb_n), .psram_ub_n(psram_ub_n), .psram_zz_n(psram_zz_n)
    );

    psram_model #(.ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(MEM_DATA_WIDTH), .DEPTH(16384)) u_psram (
        .clk(clk), .a(psram_a), .dq(psram_dq),
        .ce_n(psram_ce_n), .oe_n(psram_oe_n), .we_n(psram_we_n),
        .lb_n(psram_lb_n), .ub_n(psram_ub_n), .zz_n(psram_zz_n)
    );

    task clk_wait; input integer n; integer k; begin for (k=0;k<n;k=k+1) @(posedge clk); end endtask

    task spi_begin;
        input integer half_bit_cycles;
        begin cs_n=1'b1; sclk=1'b0; mosi=1'b0; clk_wait(half_bit_cycles*2); cs_n=1'b0; clk_wait(half_bit_cycles*2); end
    endtask

    task spi_end;
        input integer half_bit_cycles;
        begin clk_wait(half_bit_cycles*2); cs_n=1'b1; clk_wait(half_bit_cycles*2); end
    endtask

    task spi_xfer_byte;
        input [7:0] tx; input integer half_bit_cycles; output [7:0] rx;
        integer i; reg [7:0] rx_acc;
        begin
            rx_acc = 8'h00;
            for (i=7;i>=0;i=i-1) begin
                mosi=tx[i]; clk_wait(half_bit_cycles);
                sclk=1'b1; rx_acc[i]=miso; clk_wait(half_bit_cycles);
                sclk=1'b0; clk_wait(half_bit_cycles);
            end
            rx = rx_acc;
        end
    endtask

    localparam HB_RAM = 40;
    localparam HB_REG = 8;

    reg [7:0] rx_tmp;
    integer errors, errors_before, poll_count;
    reg signed [7:0] payload [0:31];
    reg signed [7:0] readback [0:31];

    task do_reset; begin spi_begin(HB_REG); spi_xfer_byte(8'h0F, HB_REG, rx_tmp); spi_end(HB_REG); end endtask

    task set_net_type;
        input [7:0] t;
        begin spi_begin(HB_REG); spi_xfer_byte(8'h11, HB_REG, rx_tmp); spi_xfer_byte(t, HB_REG, rx_tmp); spi_end(HB_REG); end
    endtask

    task set_base;
        input [7:0] sel; input [ADDR_WIDTH-1:0] addr;
        begin
            spi_begin(HB_REG); spi_xfer_byte(8'h10, HB_REG, rx_tmp); spi_xfer_byte(sel, HB_REG, rx_tmp);
            spi_xfer_byte(addr[23:16], HB_REG, rx_tmp); spi_xfer_byte(addr[15:8], HB_REG, rx_tmp); spi_xfer_byte(addr[7:0], HB_REG, rx_tmp);
            spi_end(HB_REG);
        end
    endtask

    task write_ram_bytes;
        input [ADDR_WIDTH-1:0] addr; input integer len; integer k;
        begin
            spi_begin(HB_RAM); spi_xfer_byte(8'h01, HB_RAM, rx_tmp);
            spi_xfer_byte(addr[23:16], HB_RAM, rx_tmp); spi_xfer_byte(addr[15:8], HB_RAM, rx_tmp); spi_xfer_byte(addr[7:0], HB_RAM, rx_tmp);
            spi_xfer_byte(len[15:8], HB_RAM, rx_tmp); spi_xfer_byte(len[7:0], HB_RAM, rx_tmp);
            for (k=0;k<len;k=k+1) spi_xfer_byte(payload[k], HB_RAM, rx_tmp);
            spi_end(HB_RAM);
        end
    endtask

    task read_ram_bytes;
        input [ADDR_WIDTH-1:0] addr; input integer len; integer k;
        begin
            spi_begin(HB_RAM); spi_xfer_byte(8'h02, HB_RAM, rx_tmp);
            spi_xfer_byte(addr[23:16], HB_RAM, rx_tmp); spi_xfer_byte(addr[15:8], HB_RAM, rx_tmp); spi_xfer_byte(addr[7:0], HB_RAM, rx_tmp);
            spi_xfer_byte(len[15:8], HB_RAM, rx_tmp); spi_xfer_byte(len[7:0], HB_RAM, rx_tmp);
            for (k=0;k<len;k=k+1) spi_xfer_byte(8'h00, HB_RAM, readback[k]);
            spi_end(HB_RAM);
        end
    endtask

    task read_status;
        output [7:0] status;
        begin spi_begin(HB_REG); spi_xfer_byte(8'h21, HB_REG, rx_tmp); spi_xfer_byte(8'h00, HB_REG, status); spi_end(HB_REG); end
    endtask

    task run_network;
        input [7:0] payload_byte;
        begin spi_begin(HB_REG); spi_xfer_byte(8'h23, HB_REG, rx_tmp); spi_xfer_byte(payload_byte, HB_REG, rx_tmp); spi_end(HB_REG); end
    endtask

    reg [7:0] last_status;

    task wait_done_or_err;
        begin
            poll_count = 0; last_status = 8'h00;
            while (!last_status[1] && !last_status[2] && poll_count < 2000) begin
                clk_wait(20); read_status(last_status); poll_count = poll_count + 1;
                if (poll_count <= 5 || poll_count % 200 == 0)
                    $display("  poll_count=%0d t=%0t last_status=0x%02x", poll_count, $time, last_status);
            end
        end
    endtask

    task write_graph_desc;
        input [ADDR_WIDTH-1:0] base; input [23:0] conn_ptr; input [15:0] n_conn;
        input [15:0] out_id; input [7:0] activation; input [7:0] bias;
        begin
            payload[0]=conn_ptr[23:16]; payload[1]=conn_ptr[15:8]; payload[2]=conn_ptr[7:0];
            payload[3]=n_conn[15:8]; payload[4]=n_conn[7:0];
            payload[5]=out_id[15:8]; payload[6]=out_id[7:0];
            payload[7]=activation; payload[8]=bias; payload[9]=8'h00; payload[10]=8'h00;
            write_ram_bytes(base, 11);
        end
    endtask

    task write_edge;
        input [ADDR_WIDTH-1:0] base; input [15:0] src_id; input [7:0] weight;
        begin payload[0]=src_id[15:8]; payload[1]=src_id[7:0]; payload[2]=weight; payload[3]=8'h00; write_ram_bytes(base,4); end
    endtask

    localparam [ADDR_WIDTH-1:0] X_BASE     = 22'h000000;
    localparam [ADDR_WIDTH-1:0] TABLE_BASE = 22'h000100;
    localparam [ADDR_WIDTH-1:0] N4_EDGES   = 22'h000200;
    localparam [ADDR_WIDTH-1:0] N5_EDGES   = 22'h000210;
    localparam [ADDR_WIDTH-1:0] OUT_BASE   = 22'h000300;
    localparam ACT_NONE = 8'h00;
    localparam ACT_RELU = 8'h01;

    initial begin
        $dumpfile("sim/spi_neuron_top_bug007.vcd");
        $dumpvars(0, tb);

        rst = 1'b1; cs_n = 1'b1; sclk = 1'b0; mosi = 1'b0; errors = 0;
        repeat(5) @(posedge clk);
        rst = 1'b0;
        wait (dut.u_psram_ctrl.state == dut.u_psram_ctrl.STATE_IDLE);

        $display("");
        $display("========================================");
        $display("BUG-007 PROBE: SET_NET_TYPE mid-RUN_NETWORK");
        $display("========================================");

        do_reset;

        // Same valid graph as the certified sim/spi_neuron_top_graph_tb.v TEST 1.
        payload[0]=8'sd10; payload[1]=8'sd1; payload[2]=8'sd4; payload[3]=8'sd0;
        write_ram_bytes(X_BASE, 4);

        write_graph_desc(TABLE_BASE + 0*11, N4_EDGES, 16'd2, 16'd4, ACT_RELU, 8'sd2);
        write_graph_desc(TABLE_BASE + 1*11, N5_EDGES, 16'd2, 16'd5, ACT_NONE, 8'sd0);
        write_edge(N4_EDGES + 0*4, 16'd0, 8'sd5);
        write_edge(N4_EDGES + 1*4, 16'd1, -8'sd3);
        write_edge(N5_EDGES + 0*4, 16'd4, 8'sd2);
        write_edge(N5_EDGES + 1*4, 16'd2, 8'sd7);

        set_net_type(8'h02); // NET_TYPE_GRAPH
        set_base(8'h00, X_BASE);
        set_base(8'h03, TABLE_BASE);
        set_base(8'h04, OUT_BASE);
        set_base(8'h07, 24'h000004);
        set_base(8'h09, 24'h000002);
        set_base(8'h0A, 24'h000001);

        $display("--- starting graph RUN_NETWORK, then immediately SET_NET_TYPE(dense) before it completes ---");
        $display("t=%0t before run_network", $time);
        run_network(8'h00);
        $display("t=%0t after run_network, before set_net_type", $time);

        // Do NOT wait for done/err -- immediately issue the adversarial
        // net_type switch while graph_engine should still be busy.
        set_net_type(8'h01); // NET_TYPE_DENSE, mid-flight
        $display("t=%0t after mid-flight set_net_type, before short confirm-hang poll ---", $time);

        // 30 polls (~150 cycles' worth of clk_wait plus SPI overhead,
        // roughly 20-30us of simulated time) is already several times
        // longer than this exact graph normally takes to complete
        // (~12-25us, per the certified sim/spi_neuron_top_graph_tb.v) --
        // enough to confirm the hang without waiting for the full
        // 2000-poll budget.
        poll_count = 0; last_status = 8'h00;
        while (!last_status[1] && !last_status[2] && poll_count < 30) begin
            clk_wait(20); read_status(last_status); poll_count = poll_count + 1;
        end
        $display("after 30 polls: last_status=0x%02x (bit0=busy) -- expected 0x01 stuck if the hang reproduces", last_status);

        if (!last_status[1] && !last_status[2]) begin
            $display("RESULT: HANG CONFIRMED -- STATUS.busy stuck, no done/err after 30 polls (vs. ~12-25us normal completion time for this graph)");

            // --------------------------------------------------------
            // Recovery check: does RESET bring the system back to a
            // usable state, or is this a permanent lockup requiring a
            // power cycle? Not assumed either way -- checked directly
            // with a subsequent legitimate legacy dense operation.
            // --------------------------------------------------------
            $display("--- recovery check: RESET, then a legitimate legacy dense START ---");
            do_reset;

            payload[0]=8'sd1; payload[1]=8'sd2; payload[2]=8'sd3; payload[3]=8'sd4;
            write_ram_bytes(X_BASE, 4);
            payload[0]=8'sd1; payload[1]=8'sd1; payload[2]=8'sd1; payload[3]=8'sd1;
            write_ram_bytes(22'h000400, 4); // W_BASE, single neuron n0=[1,1,1,1]
            payload[0]=8'sd0;
            write_ram_bytes(22'h000420, 1); // BIAS_ADDR

            set_base(8'h00, X_BASE);
            set_base(8'h01, 22'h000400);
            set_base(8'h02, 22'h000420);

            spi_begin(HB_REG); spi_xfer_byte(8'h20, HB_REG, rx_tmp); spi_end(HB_REG); // START

            poll_count = 0; last_status = 8'h00;
            while (!last_status[1] && poll_count < 200) begin
                clk_wait(20); read_status(last_status); poll_count = poll_count + 1;
            end

            if (!last_status[1]) begin
                $display("RECOVERY RESULT: FAILED -- legitimate dense START never completed after RESET (status=0x%02x, poll_count=%0d) -- the hang from BUG-007 is NOT cleanly recoverable via RESET alone", last_status, poll_count);
            end else begin
                read_ram_bytes(22'h000000, 1); // harmless if this doesn't match READ_OUTPUT semantics -- just probing responsiveness
                $display("RECOVERY RESULT: RESET DOES recover the system -- a subsequent legitimate dense op completed normally (status=0x%02x after %0d polls)", last_status, poll_count);
            end
        end else begin
            $display("RESULT: UNEXPECTED -- done or err latched within 30 polls (status=0x%02x) -- the hang did NOT reproduce this run. Re-examine before assuming BUG-007 is fixed or was a fluke.", last_status);
        end

        $finish;
    end

    initial begin
        #4000000;
        $display("SAFETY TIMEOUT after 4ms -- something past the confirm-hang/recovery-check sequence did not complete in time");
        $finish;
    end

endmodule
