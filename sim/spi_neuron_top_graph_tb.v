`timescale 1ns/1ps

// ================================================================
// SPI_NEURON_TOP GRAPH (Type #2) END-TO-END TESTBENCH (Phase G5)
//
// Same rigor/BFM style as sim/spi_neuron_top_runnetwork_tb.v (real
// spi_slave + spi_engine + graph_engine + mem_arbiter +
// int8_memory_access + memory_interface + psram_controller +
// psram_model, driven purely over simulated SPI), but exercising the
// NEW Type #2 dispatch path: SET_NET_TYPE(graph) -> SET_BASE sel 9/
// 10 -> RUN_NETWORK -> STATUS (incl. bit2=err) -> READ_RAM at
// out_base for the result (graph mode has no y_bus, unlike dense).
//
// Graph under test: the same §3 worked example used in
// sim/graph_engine_tb.v (hand-computed there): 4 inputs
// x=[10,1,4,0], n4=out_id4 (ACT_RELU,bias=2,edges (0,5)(1,-3)) -> 49,
// n5=out_id5 (ACT_NONE,bias=0,edges (4,2)(2,7)) -> 126, n_out=1 (n5
// only). PARALLEL=2 here (top's build parameter) and n_conn=2 for
// both neurons, so n_conn_padded=2 already -- no padding edges
// needed for this particular test (padding itself is already
// covered end-to-end in sim/graph_engine_tb.v).
//
// TEST SEQUENCE:
//   1. RESET -> load inputs/table/edges -> SET_NET_TYPE(graph) ->
//      SET_BASE(x/table/out_base/n_inputs/num_neurons_graph/n_out)
//      -> RUN_NETWORK -> poll STATUS -> READ_RAM(out_base) matches
//      the hand-computed 126.
//   2. READ_CONFIG exposes N_TOTAL and the graph-capability bit.
//   3. A deliberately invalid graph (src_id >= out_id) makes
//      STATUS.bit2 (err) go high over real SPI, busy drops, done
//      never sets -- the RTL-level guard (sim/graph_engine_guard_tb.v)
//      already covers the FSM itself; this proves the bit actually
//      reaches the host over the wire.
//   4. RESET, then a legacy dense single-layer START still works --
//      proves net_type truly defaults back to dense after RESET and
//      the Type #1 path is unaffected by having run graph mode.
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
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .N_INPUTS(N_INPUTS),
        .N_NEURONS(N_NEURONS),
        .PARALLEL(PARALLEL),
        .ACC_WIDTH(ACC_WIDTH),
        .MEM_DATA_WIDTH(MEM_DATA_WIDTH),
        .CLK_FREQ_MHZ(80),
        .N_LAYERS(N_LAYERS),
        .GRAPH_MAX_CONN(GRAPH_MAX_CONN),
        .GRAPH_N_TOTAL(GRAPH_N_TOTAL)
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
    // SPI MASTER BFM (identical to sim/spi_neuron_top_runnetwork_tb.v)
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

    reg signed [7:0] payload  [0:31];
    reg signed [7:0] readback [0:31];

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

    task set_net_type;
        input [7:0] t;
        begin
            spi_begin(HB_REG);
            spi_xfer_byte(8'h11, HB_REG, rx_tmp); // SET_NET_TYPE
            spi_xfer_byte(t, HB_REG, rx_tmp);
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
        input [7:0] payload_byte;
        begin
            spi_begin(HB_REG);
            spi_xfer_byte(8'h23, HB_REG, rx_tmp); // RUN_NETWORK
            spi_xfer_byte(payload_byte, HB_REG, rx_tmp);
            spi_end(HB_REG);
        end
    endtask

    // Polls STATUS until either done(bit1) or err(bit2) latches, or
    // timeout. Leaves the final status byte in `last_status`.
    reg [7:0] last_status;

    task wait_done_or_err;
        begin
            poll_count = 0;
            last_status = 8'h00;
            while (!last_status[1] && !last_status[2] && poll_count < 2000) begin
                clk_wait(20);
                read_status(last_status);
                poll_count = poll_count + 1;
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

    task read_config_bytes;
        input integer n;
        integer k;
        begin
            spi_begin(HB_REG);
            spi_xfer_byte(8'h30, HB_REG, rx_tmp); // READ_CONFIG
            for (k = 0; k < n; k = k + 1)
                spi_xfer_byte(8'h00, HB_REG, readback[k]);
            spi_end(HB_REG);
        end
    endtask

    task check_bytes4;
        input [8*4*8-1:0] label;
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

    task write_graph_desc;
        input [ADDR_WIDTH-1:0] base;
        input [23:0] conn_ptr;
        input [15:0] n_conn;
        input [15:0] out_id;
        input [7:0]  activation;
        input [7:0]  bias;
        begin
            payload[0]  = conn_ptr[23:16];
            payload[1]  = conn_ptr[15:8];
            payload[2]  = conn_ptr[7:0];
            payload[3]  = n_conn[15:8];
            payload[4]  = n_conn[7:0];
            payload[5]  = out_id[15:8];
            payload[6]  = out_id[7:0];
            payload[7]  = activation;
            payload[8]  = bias;
            payload[9]  = 8'h00;
            payload[10] = 8'h00;
            write_ram_bytes(base, 11);
        end
    endtask

    task write_edge;
        input [ADDR_WIDTH-1:0] base;
        input [15:0] src_id;
        input [7:0]  weight;
        begin
            payload[0] = src_id[15:8];
            payload[1] = src_id[7:0];
            payload[2] = weight;
            payload[3] = 8'h00;
            write_ram_bytes(base, 4);
        end
    endtask

    // ============================================================
    // ADDRESS MAP
    // ============================================================

    localparam [ADDR_WIDTH-1:0] X_BASE     = 22'h000000;
    localparam [ADDR_WIDTH-1:0] TABLE_BASE = 22'h000100;
    localparam [ADDR_WIDTH-1:0] N4_EDGES   = 22'h000200;
    localparam [ADDR_WIDTH-1:0] N5_EDGES   = 22'h000210;
    localparam [ADDR_WIDTH-1:0] OUT_BASE   = 22'h000300;

    // legacy dense single-layer regions for the final sanity check
    localparam [ADDR_WIDTH-1:0] W_BASE     = 22'h000400;
    localparam [ADDR_WIDTH-1:0] BIAS_ADDR  = 22'h000420;

    localparam ACT_NONE = 8'h00;
    localparam ACT_RELU = 8'h01;

    // ============================================================
    // MAIN
    // ============================================================

    initial begin

        $dumpfile("sim/spi_neuron_top_graph.vcd");
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
        $display("SPI_NEURON_TOP GRAPH (Type #2) END-TO-END TEST");
        $display("========================================");

        do_reset;

        // --------------------------------------------------------
        // TEST 1: valid graph end to end over SPI
        // --------------------------------------------------------

        errors_before = errors;

        payload[0] = 8'sd10; payload[1] = 8'sd1; payload[2] = 8'sd4; payload[3] = 8'sd0;
        write_ram_bytes(X_BASE, 4);

        write_graph_desc(TABLE_BASE + 0*11, N4_EDGES, 16'd2, 16'd4, ACT_RELU, 8'sd2);
        write_graph_desc(TABLE_BASE + 1*11, N5_EDGES, 16'd2, 16'd5, ACT_NONE, 8'sd0);

        write_edge(N4_EDGES + 0*4, 16'd0, 8'sd5);
        write_edge(N4_EDGES + 1*4, 16'd1, -8'sd3);
        write_edge(N5_EDGES + 0*4, 16'd4, 8'sd2);
        write_edge(N5_EDGES + 1*4, 16'd2, 8'sd7);

        set_net_type(8'h02); // NET_TYPE_GRAPH

        set_base(8'h00, X_BASE);       // x_base
        set_base(8'h03, TABLE_BASE);   // table_base
        set_base(8'h04, OUT_BASE);     // buf_a_base (reused as out_base)
        set_base(8'h07, 24'h000004);   // n_inputs_real (reused as N_in) = 4
        set_base(8'h09, 24'h000002);   // num_neurons_graph = 2
        set_base(8'h0A, 24'h000001);   // n_out = 1

        run_network(8'h00); // payload byte unused for graph mode

        wait_done_or_err;

        if (last_status[2]) begin
            $display("  FAIL: err unexpectedly asserted on a valid graph");
            errors = errors + 1;
        end
        if (!last_status[1]) begin
            $display("  FAIL: done never asserted (poll_count=%0d, status=0x%02x)", poll_count, last_status);
            errors = errors + 1;
        end

        report("valid graph RUN_NETWORK: done reached, err clear");

        // --------------------------------------------------------
        // TEST 2: out_base holds the sole output (n5 = 126)
        // --------------------------------------------------------

        errors_before = errors;

        read_ram_bytes(OUT_BASE, 1);
        if (readback[0] !== 8'sd126) begin
            $display("  FAIL: out_base[0] = %0d, expected 126", readback[0]);
            errors = errors + 1;
        end

        report("out_base holds the hand-computed graph output (126)");

        // --------------------------------------------------------
        // TEST 3: READ_CONFIG exposes N_TOTAL + graph capability
        // --------------------------------------------------------

        errors_before = errors;

        read_config_bytes(11);
        if ({readback[8][7:0], readback[9][7:0]} !== GRAPH_N_TOTAL[15:0]) begin
            $display("  FAIL: READ_CONFIG N_TOTAL = %0d, expected %0d", {readback[8][7:0], readback[9][7:0]}, GRAPH_N_TOTAL);
            errors = errors + 1;
        end
        if (readback[10][0] !== 1'b1) begin
            $display("  FAIL: READ_CONFIG graph-capability bit not set");
            errors = errors + 1;
        end

        report("READ_CONFIG exposes N_TOTAL and graph-supported flag");

        // --------------------------------------------------------
        // TEST 4: guard violation surfaces as STATUS.bit2 over SPI
        // (src_id >= out_id: n4 references itself)
        // --------------------------------------------------------

        errors_before = errors;

        do_reset;
        set_net_type(8'h02);

        payload[0] = 8'sd0;
        write_ram_bytes(X_BASE, 1);

        write_graph_desc(TABLE_BASE, N4_EDGES, 16'd1, 16'd4, ACT_RELU, 8'sd0);
        write_edge(N4_EDGES + 0*4, 16'd4, 8'sd1); // src_id == out_id: invalid
        write_edge(N4_EDGES + 1*4, 16'd0, 8'sd0); // padding (n_conn_padded=2 @ PARALLEL=2)

        set_base(8'h00, X_BASE);
        set_base(8'h03, TABLE_BASE);
        set_base(8'h04, OUT_BASE);
        set_base(8'h07, 24'h000001); // n_inputs_real = 1
        set_base(8'h09, 24'h000001); // num_neurons_graph = 1
        set_base(8'h0A, 24'h000001); // n_out = 1

        run_network(8'h00);
        wait_done_or_err;

        if (!last_status[2]) begin
            $display("  FAIL: STATUS.err never asserted on an invalid graph (status=0x%02x)", last_status);
            errors = errors + 1;
        end
        if (last_status[1]) begin
            $display("  FAIL: STATUS.done asserted on an invalid graph (guard did not stop execution)");
            errors = errors + 1;
        end
        if (last_status[0]) begin
            $display("  FAIL: STATUS.busy still set after the guard stopped execution");
            errors = errors + 1;
        end

        report("guard violation reaches the host as STATUS.bit2 (err)");

        // --------------------------------------------------------
        // TEST 5: RESET clears net_type back to dense; legacy
        // single-layer START still works over SPI afterward.
        // --------------------------------------------------------

        errors_before = errors;

        do_reset; // net_type -> dense (default), err/busy cleared

        // RESET does NOT roll back spi_engine's own config registers
        // (only the compute engines' internal state) -- TEST 4 left
        // n_inputs_real (reused as N_in for graph mode) at 1, so it
        // must be restored to N_INPUTS=4 explicitly before this
        // dense run, exactly as the host would.
        set_base(8'h07, 24'h000004); // n_inputs_real = 4

        payload[0] = 8'sd1; payload[1] = 8'sd2; payload[2] = 8'sd3; payload[3] = 8'sd4;
        write_ram_bytes(X_BASE, 4);

        // W: n0=[1,1,1,1] n1=[1,0,0,0] n2=[0,0,0,0] n3=[2,2,2,2], bias=[0,5,-3,120]
        payload[0]=8'sd1; payload[1]=8'sd1; payload[2]=8'sd1; payload[3]=8'sd1;
        payload[4]=8'sd1; payload[5]=8'sd0; payload[6]=8'sd0; payload[7]=8'sd0;
        payload[8]=8'sd0; payload[9]=8'sd0; payload[10]=8'sd0; payload[11]=8'sd0;
        payload[12]=8'sd2; payload[13]=8'sd2; payload[14]=8'sd2; payload[15]=8'sd2;
        write_ram_bytes(W_BASE, 16);

        payload[0]=8'sd0; payload[1]=8'sd5; payload[2]=-8'sd3; payload[3]=8'sd120;
        write_ram_bytes(BIAS_ADDR, 4);

        set_base(8'h00, X_BASE);
        set_base(8'h01, W_BASE);
        set_base(8'h02, BIAS_ADDR);

        do_start;

        poll_count = 0;
        last_status = 8'h00;
        while (!last_status[1] && poll_count < 2000) begin
            clk_wait(20);
            read_status(last_status);
            poll_count = poll_count + 1;
        end
        if (!last_status[1]) begin
            $display("  FAIL: legacy dense START never completed after graph tests (status=0x%02x)", last_status);
            errors = errors + 1;
        end

        read_output_bytes(4);
        check_bytes4("Y(legacy dense after graph)", 8'sd10, 8'sd6, 8'sd0, 8'sd127);

        report("RESET restores dense default; legacy START unaffected by prior graph runs");

        // --------------------------------------------------------
        // SUMMARY
        // --------------------------------------------------------

        $display("");
        $display("========================================");
        if (errors == 0)
            $display("SPI_NEURON_TOP GRAPH END-TO-END TEST PASSED");
        else
            $display("SPI_NEURON_TOP GRAPH END-TO-END TEST FAILED: %0d errors", errors);
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
