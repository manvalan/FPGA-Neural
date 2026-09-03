`timescale 1ns/1ps

// ================================================================
// GRAPH FORMAT TESTBENCH (Phase G2)
//
// Validates the Type #2 (graph) on-disk data format from §4.2/§4.3
// of the spec, byte-exact, through the REAL memory stack
// (int8_memory_access + memory_interface + psram_controller +
// psram_model) -- same harness as sim/int8_psram_integration_tb.v.
// No new RTL: this phase is about the FORMAT, not new hardware.
//
// Graph under test is the worked example from §3:
//   4 inputs (id 0..3). n4 = f(x0*5 + x1*(-3) + bias=2), relu.
//   n5 = f(act[n4]*2 + x2*7 + bias=0), none. output = n5 (id 5).
//
// Graph descriptor table (11 bytes/entry, MSB-first, entries in
// out_id order) at table_base = 0x000000:
//   entry0 (n4, out_id=4): conn_ptr=0x000100 n_conn=2 out_id=4
//                          activation=ACT_RELU(1) bias=2 reserved=0
//   entry1 (n5, out_id=5): conn_ptr=0x000108 n_conn=2 out_id=5
//                          activation=ACT_NONE(0) bias=0 reserved=0
//
// Edge blocks (4 bytes/edge: src_id uint16 BE, weight int8,
// reserved=0):
//   n4 @ 0x000100: (src=0,w=5), (src=1,w=-3)
//   n5 @ 0x000108: (src=4,w=2), (src=2,w=7)
// ================================================================

module tb;

    localparam ADDR_WIDTH = 23;
    localparam DATA_WIDTH = 16;
    localparam CLK_PERIOD = 12.5; // 80 MHz

    localparam ACT_NONE = 8'd0;
    localparam ACT_RELU = 8'd1;

    reg clk;
    reg rst;

    reg                    req;
    reg                    wr;
    reg  [ADDR_WIDTH-1:0]  addr;
    reg  signed [7:0]      wdata;

    wire signed [7:0]      rdata;
    wire                   ready;

    wire                   mem_req;
    wire                   mem_wr;
    wire [ADDR_WIDTH-1:0]  mem_addr;
    wire [DATA_WIDTH-1:0]  mem_wdata;
    wire                   mem_lb_n;
    wire                   mem_ub_n;
    wire [DATA_WIDTH-1:0]  mem_rdata;
    wire                   mem_ready;

    wire                   psram_mem_req;
    wire                   psram_mem_wr;
    wire [ADDR_WIDTH-1:0]  psram_mem_addr;
    wire [DATA_WIDTH-1:0]  psram_mem_wdata;
    wire                   psram_mem_lb_n;
    wire                   psram_mem_ub_n;
    wire [DATA_WIDTH-1:0]  psram_mem_rdata;
    wire                   psram_mem_ready;

    wire [ADDR_WIDTH-1:0]  psram_a;
    wire [DATA_WIDTH-1:0]  psram_dq;
    wire                   psram_ce_n;
    wire                   psram_oe_n;
    wire                   psram_we_n;
    wire                   psram_lb_n;
    wire                   psram_ub_n;
    wire                   psram_zz_n;

    int8_memory_access #(
        .ADDR_WIDTH(ADDR_WIDTH)
    ) int8_access (
        .clk(clk), .rst(rst),
        .req(req), .wr(wr), .addr(addr), .wdata(wdata),
        .rdata(rdata), .ready(ready),
        .mem_req(mem_req), .mem_wr(mem_wr), .mem_addr(mem_addr),
        .mem_wdata(mem_wdata), .mem_lb_n(mem_lb_n), .mem_ub_n(mem_ub_n),
        .mem_rdata(mem_rdata), .mem_ready(mem_ready)
    );

    memory_interface #(
        .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH)
    ) memory_if (
        .clk(clk), .rst(rst),
        .req(mem_req), .wr(mem_wr), .addr(mem_addr), .wdata(mem_wdata),
        .lb_n(mem_lb_n), .ub_n(mem_ub_n),
        .rdata(mem_rdata), .ready(mem_ready),
        .mem_req(psram_mem_req), .mem_wr(psram_mem_wr), .mem_addr(psram_mem_addr),
        .mem_wdata(psram_mem_wdata), .mem_lb_n(psram_mem_lb_n), .mem_ub_n(psram_mem_ub_n),
        .mem_rdata(psram_mem_rdata), .mem_ready(psram_mem_ready)
    );

    psram_controller #(
        .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH), .CLK_FREQ_MHZ(80)
    ) psram_ctrl (
        .clk(clk), .rst(rst),
        .mem_req(psram_mem_req), .mem_wr(psram_mem_wr), .mem_addr(psram_mem_addr),
        .mem_wdata(psram_mem_wdata), .mem_lb_n(psram_mem_lb_n), .mem_ub_n(psram_mem_ub_n),
        .mem_rdata(psram_mem_rdata), .mem_ready(psram_mem_ready),
        .psram_a(psram_a), .psram_dq(psram_dq),
        .psram_ce_n(psram_ce_n), .psram_oe_n(psram_oe_n), .psram_we_n(psram_we_n),
        .psram_lb_n(psram_lb_n), .psram_ub_n(psram_ub_n), .psram_zz_n(psram_zz_n)
    );

    psram_model #(
        .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH), .DEPTH(16384)
    ) psram (
        .clk(clk), .a(psram_a), .dq(psram_dq),
        .ce_n(psram_ce_n), .oe_n(psram_oe_n), .we_n(psram_we_n),
        .lb_n(psram_lb_n), .ub_n(psram_ub_n), .zz_n(psram_zz_n)
    );

    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD / 2.0) clk = ~clk;
    end

    integer errors;

    task write_byte(input [ADDR_WIDTH-1:0] byte_addr, input [7:0] data);
        begin
            @(posedge clk);
            addr  <= byte_addr;
            wdata <= $signed(data);
            wr    <= 1'b1;
            req   <= 1'b1;
            @(posedge clk);
            req <= 1'b0;
            wait (ready);
            @(posedge clk);
        end
    endtask

    task read_byte(input [ADDR_WIDTH-1:0] byte_addr, input [7:0] expected, input [255:0] name);
        begin
            @(posedge clk);
            addr <= byte_addr;
            wr   <= 1'b0;
            req  <= 1'b1;
            @(posedge clk);
            req <= 1'b0;
            wait (ready);
            if (rdata !== $signed(expected)) begin
                $display("FAIL %0s addr=0x%06x expected=0x%02x got=0x%02x", name, byte_addr, expected, rdata);
                errors = errors + 1;
            end else begin
                $display("PASS %0s addr=0x%06x data=0x%02x", name, byte_addr, rdata);
            end
            @(posedge clk);
        end
    endtask

    // §4.2 graph descriptor entry: 11 bytes, MSB-first.
    task write_graph_desc(
        input [ADDR_WIDTH-1:0] base,
        input [23:0] conn_ptr,
        input [15:0] n_conn,
        input [15:0] out_id,
        input [7:0]  activation,
        input [7:0]  bias
    );
        begin
            write_byte(base + 0,  conn_ptr[23:16]);
            write_byte(base + 1,  conn_ptr[15:8]);
            write_byte(base + 2,  conn_ptr[7:0]);
            write_byte(base + 3,  n_conn[15:8]);
            write_byte(base + 4,  n_conn[7:0]);
            write_byte(base + 5,  out_id[15:8]);
            write_byte(base + 6,  out_id[7:0]);
            write_byte(base + 7,  activation);
            write_byte(base + 8,  bias);
            write_byte(base + 9,  8'h00); // reserved
            write_byte(base + 10, 8'h00); // reserved
        end
    endtask

    // §4.3 edge: 4 bytes, src_id uint16 BE, weight int8, reserved.
    task write_edge(
        input [ADDR_WIDTH-1:0] base,
        input [15:0] src_id,
        input [7:0]  weight
    );
        begin
            write_byte(base + 0, src_id[15:8]);
            write_byte(base + 1, src_id[7:0]);
            write_byte(base + 2, weight);
            write_byte(base + 3, 8'h00); // reserved
        end
    endtask

    localparam TABLE_BASE = 23'h000000;
    localparam N4_EDGES   = 23'h000100;
    localparam N5_EDGES   = 23'h000108;

    initial begin

        errors = 0;
        req = 1'b0; wr = 1'b0; addr = 0; wdata = 0;
        rst = 1'b1;
        repeat (5) @(posedge clk);
        rst = 1'b0;

        wait (psram_ctrl.state == psram_ctrl.STATE_IDLE);

        $display("");
        $display("========================================");
        $display("GRAPH FORMAT (Type #2) BYTE-EXACT TEST");
        $display("========================================");
        $display("");

        // ---- write the descriptor table (2 entries) ----
        write_graph_desc(TABLE_BASE + 0*11, N4_EDGES, 16'd2, 16'd4, ACT_RELU, 8'sd2);
        write_graph_desc(TABLE_BASE + 1*11, N5_EDGES, 16'd2, 16'd5, ACT_NONE, 8'sd0);

        // ---- write the edge blocks ----
        write_edge(N4_EDGES + 0*4, 16'd0, 8'sd5);
        write_edge(N4_EDGES + 1*4, 16'd1, -8'sd3);
        write_edge(N5_EDGES + 0*4, 16'd4, 8'sd2);
        write_edge(N5_EDGES + 1*4, 16'd2, 8'sd7);

        $display("-- write phase done, reading back byte-exact --");
        $display("");

        // ---- read back entry 0 (n4) byte-exact ----
        read_byte(TABLE_BASE+0,  8'h00, "n4.conn_ptr[23:16]");
        read_byte(TABLE_BASE+1,  8'h01, "n4.conn_ptr[15:8]");
        read_byte(TABLE_BASE+2,  8'h00, "n4.conn_ptr[7:0]");
        read_byte(TABLE_BASE+3,  8'h00, "n4.n_conn[15:8]");
        read_byte(TABLE_BASE+4,  8'h02, "n4.n_conn[7:0]");
        read_byte(TABLE_BASE+5,  8'h00, "n4.out_id[15:8]");
        read_byte(TABLE_BASE+6,  8'h04, "n4.out_id[7:0]");
        read_byte(TABLE_BASE+7,  ACT_RELU, "n4.activation");
        read_byte(TABLE_BASE+8,  8'h02, "n4.bias");
        read_byte(TABLE_BASE+9,  8'h00, "n4.reserved0");
        read_byte(TABLE_BASE+10, 8'h00, "n4.reserved1");

        // ---- read back entry 1 (n5) byte-exact ----
        read_byte(TABLE_BASE+11, 8'h00, "n5.conn_ptr[23:16]");
        read_byte(TABLE_BASE+12, 8'h01, "n5.conn_ptr[15:8]");
        read_byte(TABLE_BASE+13, 8'h08, "n5.conn_ptr[7:0]");
        read_byte(TABLE_BASE+14, 8'h00, "n5.n_conn[15:8]");
        read_byte(TABLE_BASE+15, 8'h02, "n5.n_conn[7:0]");
        read_byte(TABLE_BASE+16, 8'h00, "n5.out_id[15:8]");
        read_byte(TABLE_BASE+17, 8'h05, "n5.out_id[7:0]");
        read_byte(TABLE_BASE+18, ACT_NONE, "n5.activation");
        read_byte(TABLE_BASE+19, 8'h00, "n5.bias");
        read_byte(TABLE_BASE+20, 8'h00, "n5.reserved0");
        read_byte(TABLE_BASE+21, 8'h00, "n5.reserved1");

        // ---- read back n4's edges byte-exact ----
        read_byte(N4_EDGES+0, 8'h00, "n4.e0.src_id[15:8]");
        read_byte(N4_EDGES+1, 8'h00, "n4.e0.src_id[7:0]");
        read_byte(N4_EDGES+2, 8'h05, "n4.e0.weight");
        read_byte(N4_EDGES+3, 8'h00, "n4.e0.reserved");
        read_byte(N4_EDGES+4, 8'h00, "n4.e1.src_id[15:8]");
        read_byte(N4_EDGES+5, 8'h01, "n4.e1.src_id[7:0]");
        read_byte(N4_EDGES+6, 8'hFD, "n4.e1.weight(-3)");
        read_byte(N4_EDGES+7, 8'h00, "n4.e1.reserved");

        // ---- read back n5's edges byte-exact ----
        read_byte(N5_EDGES+0, 8'h00, "n5.e0.src_id[15:8]");
        read_byte(N5_EDGES+1, 8'h04, "n5.e0.src_id[7:0]");
        read_byte(N5_EDGES+2, 8'h02, "n5.e0.weight");
        read_byte(N5_EDGES+3, 8'h00, "n5.e0.reserved");
        read_byte(N5_EDGES+4, 8'h00, "n5.e1.src_id[15:8]");
        read_byte(N5_EDGES+5, 8'h02, "n5.e1.src_id[7:0]");
        read_byte(N5_EDGES+6, 8'h07, "n5.e1.weight");
        read_byte(N5_EDGES+7, 8'h00, "n5.e1.reserved");

        // ---- overlap/independence sanity check: rewriting n4's
        // bias must not disturb n5's descriptor or any edge byte ----
        write_byte(TABLE_BASE+8, 8'sd9);
        read_byte(TABLE_BASE+8, 8'h09, "n4.bias overwritten");
        read_byte(TABLE_BASE+19, 8'h00, "n5.bias unaffected by n4 rewrite");
        read_byte(N4_EDGES+2, 8'h05, "n4.e0.weight unaffected by n4 desc rewrite");

        $display("");
        if (errors == 0) begin
            $display("========================================");
            $display("GRAPH FORMAT TEST PASSED (0 errors)");
            $display("========================================");
        end else begin
            $display("========================================");
            $display("GRAPH FORMAT TEST FAILED (%0d errors)", errors);
            $display("========================================");
            $fatal;
        end

        $finish;
    end

endmodule
