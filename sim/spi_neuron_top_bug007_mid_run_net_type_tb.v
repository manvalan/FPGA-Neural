`timescale 1ns/1ps

// ================================================================
// C.8 / BUG-007 REGRESSION TEST: does SET_NET_TYPE mid-run corrupt an
// in-flight RUN_NETWORK?
//
// BUG-007 (docs/validation/bugs.md), now FIXED: rtl/spi_engine.v's
// ST_SET_NET_TYPE used to accept `net_type <= rx_byte`
// unconditionally, with no check against graph_busy/seq_busy --
// confirmed via this exact test before the fix to permanently hang
// graph_engine (STATUS.busy stuck for 400+ consecutive polls) by
// re-routing the arbiter Port C mux (spi_neuron_top.v) away from its
// in-flight memory transaction mid-flight. RESET was shown to recover
// the system, but plain STATUS polling alone never would have.
//
// Fix (rtl/spi_engine.v, ST_SET_NET_TYPE): the net_type write is now
// silently ignored while `graph_busy || seq_busy` -- same
// "accept the command, safe no-op" convention as WRITE_RAM/READ_RAM's
// len==0 guard. This test now ASSERTS the graph run completes
// normally with the correct output (126) despite the adversarial
// mid-run switch, instead of only observing whether it hung.
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
        run_network(8'h00);

        // Do NOT wait for done/err -- immediately issue the adversarial
        // net_type switch while graph_engine should still be busy. The
        // fix makes spi_engine.v silently ignore this write while
        // graph_busy/seq_busy is set, so the in-flight run should be
        // completely unaffected.
        set_net_type(8'h01); // NET_TYPE_DENSE, mid-flight -- must be rejected

        // 30 polls (~150 cycles' worth of clk_wait plus SPI overhead)
        // is comfortably more than this exact graph normally takes to
        // complete (~12-25us, per the certified
        // sim/spi_neuron_top_graph_tb.v) -- enough margin to call a
        // FAIL if done hasn't landed by then.
        poll_count = 0; last_status = 8'h00;
        while (!last_status[1] && !last_status[2] && poll_count < 30) begin
            clk_wait(20); read_status(last_status); poll_count = poll_count + 1;
        end

        if (!last_status[1] && !last_status[2]) begin
            $display("FAIL: STATUS.busy stuck, no done/err after 30 polls (status=0x%02x) -- BUG-007 fix regressed, the mid-run net_type switch hung the engine again", last_status);
            errors = errors + 1;
        end else if (last_status[2]) begin
            $display("FAIL: STATUS.err latched (status=0x%02x) on a graph that is valid and was already certified to complete cleanly -- unexpected side effect of the fix", last_status);
            errors = errors + 1;
        end else begin
            read_ram_bytes(OUT_BASE, 1);
            if (readback[0] !== 8'sd126) begin
                $display("FAIL: done latched but out_base[0]=%0d, expected 126 -- the mid-run switch still corrupted the result even though it didn't hang", readback[0]);
                errors = errors + 1;
            end else begin
                $display("PASS: graph run completed normally (out_base[0]=126) after %0d polls despite the adversarial mid-run SET_NET_TYPE -- BUG-007 fix confirmed, the switch was correctly rejected while graph_busy", poll_count);
            end
        end

        // --------------------------------------------------------
        // Confirm the rejected write really left net_type alone: a
        // second graph RUN_NETWORK (net_type must still read as
        // GRAPH internally) should work exactly like the first, not
        // require SET_NET_TYPE(graph) to be re-sent.
        // --------------------------------------------------------
        errors_before = errors;
        run_network(8'h00);
        poll_count = 0; last_status = 8'h00;
        while (!last_status[1] && !last_status[2] && poll_count < 30) begin
            clk_wait(20); read_status(last_status); poll_count = poll_count + 1;
        end
        if (!last_status[1]) begin
            $display("FAIL: second graph RUN_NETWORK (net_type never re-set) did not complete (status=0x%02x) -- the rejected SET_NET_TYPE may have partially applied", last_status);
            errors = errors + 1;
        end else begin
            read_ram_bytes(OUT_BASE, 1);
            if (readback[0] !== 8'sd126) begin
                $display("FAIL: second graph run out_base[0]=%0d, expected 126", readback[0]);
                errors = errors + 1;
            end else begin
                $display("PASS: net_type correctly still reads as GRAPH internally -- the rejected mid-run write left it untouched, not partially applied");
            end
        end

        if (errors == 0)
            $display("ALL TESTS PASSED -- BUG-007 fix confirmed end-to-end over real SPI");
        else
            $display("FAILED: %0d error(s) -- see messages above", errors);

        $finish;
    end

    initial begin
        #4000000;
        $display("SAFETY TIMEOUT after 4ms -- something past the confirm-hang/recovery-check sequence did not complete in time");
        $finish;
    end

endmodule
