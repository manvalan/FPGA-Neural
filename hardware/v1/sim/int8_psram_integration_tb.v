`timescale 1ns/1ps

module tb;

    localparam ADDR_WIDTH = 23;
    localparam DATA_WIDTH = 16;
    localparam CLK_PERIOD = 12.5; // 80 MHz

    // ============================================================
    // Clock / Reset
    // ============================================================

    reg clk;
    reg rst;

    // ============================================================
    // INT8 interface
    // ============================================================

    reg                    req;
    reg                    wr;
    reg  [ADDR_WIDTH-1:0]  addr;
    reg  signed [7:0]      wdata;

    wire signed [7:0]      rdata;
    wire                   ready;
    
    // ============================================================
    // memory_interface
    // ============================================================

    wire                   mem_req;
    wire                   mem_wr;
    wire [ADDR_WIDTH-1:0]  mem_addr;
    wire [DATA_WIDTH-1:0]  mem_wdata;
    wire                   mem_lb_n;
    wire                   mem_ub_n;

    wire [DATA_WIDTH-1:0]  mem_rdata;
    wire                   mem_ready;

    // ============================================================
    // Memory interface -> PSRAM controller
    // ============================================================

    wire                   psram_mem_req;
    wire                   psram_mem_wr;
    wire [ADDR_WIDTH-1:0]  psram_mem_addr;
    wire [DATA_WIDTH-1:0]  psram_mem_wdata;
    wire                   psram_mem_lb_n;
    wire                   psram_mem_ub_n;

    wire [DATA_WIDTH-1:0]  psram_mem_rdata;
    wire                   psram_mem_ready;

    // ============================================================
    // PSRAM physical interface
    // ============================================================

    wire [ADDR_WIDTH-1:0]  psram_a;
    wire [DATA_WIDTH-1:0]  psram_dq;

    wire                   psram_ce_n;
    wire                   psram_oe_n;
    wire                   psram_we_n;
    wire                   psram_lb_n;
    wire                   psram_ub_n;
    wire                   psram_zz_n;

    // ============================================================
    // INT8 MEMORY ACCESS
    // ============================================================

    int8_memory_access #(
        .ADDR_WIDTH(ADDR_WIDTH)
    ) int8_access (
        .clk       (clk),
        .rst       (rst),

        .req       (req),
        .wr        (wr),
        .addr      (addr),
        .wdata     (wdata),

        .rdata     (rdata),
        .ready     (ready),

        .mem_req   (mem_req),
        .mem_wr    (mem_wr),
        .mem_addr  (mem_addr),
        .mem_wdata (mem_wdata),
        .mem_lb_n  (mem_lb_n),
        .mem_ub_n  (mem_ub_n),

        .mem_rdata (mem_rdata),
        .mem_ready (mem_ready)
    );

    // ============================================================
    // MEMORY INTERFACE
    // ============================================================

    memory_interface #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH)
    ) memory_if (
        .clk       (clk),
        .rst       (rst),

        .req       (mem_req),
        .wr        (mem_wr),
        .addr      (mem_addr),
        .wdata     (mem_wdata),
        .lb_n      (mem_lb_n),
        .ub_n      (mem_ub_n),

        .rdata     (mem_rdata),
        .ready     (mem_ready),

        .mem_req   (psram_mem_req),
        .mem_wr    (psram_mem_wr),
        .mem_addr  (psram_mem_addr),
        .mem_wdata (psram_mem_wdata),
        .mem_lb_n  (psram_mem_lb_n),
        .mem_ub_n  (psram_mem_ub_n),

        .mem_rdata (psram_mem_rdata),
        .mem_ready (psram_mem_ready)
    );

    // ============================================================
    // PSRAM CONTROLLER
    // ============================================================

    psram_controller #(
        .ADDR_WIDTH   (ADDR_WIDTH),
        .DATA_WIDTH   (DATA_WIDTH),
        .CLK_FREQ_MHZ (80)
    ) psram_ctrl (
        .clk       (clk),
        .rst       (rst),

        .mem_req   (psram_mem_req),
        .mem_wr    (psram_mem_wr),
        .mem_addr  (psram_mem_addr),
        .mem_wdata (psram_mem_wdata),
        .mem_lb_n  (psram_mem_lb_n),
        .mem_ub_n  (psram_mem_ub_n),

        .mem_rdata (psram_mem_rdata),
        .mem_ready (psram_mem_ready),

        .psram_a   (psram_a),
        .psram_dq  (psram_dq),

        .psram_ce_n(psram_ce_n),
        .psram_oe_n(psram_oe_n),
        .psram_we_n(psram_we_n),
        .psram_lb_n(psram_lb_n),
        .psram_ub_n(psram_ub_n),
        .psram_zz_n(psram_zz_n)
    );

    // ============================================================
    // PSRAM MODEL
    // ============================================================

    psram_model #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .DEPTH(16384)
    ) psram (
        .clk   (clk),
        .a     (psram_a),
        .dq    (psram_dq),
        .ce_n  (psram_ce_n),
        .oe_n  (psram_oe_n),
        .we_n  (psram_we_n),
        .lb_n  (psram_lb_n),
        .ub_n  (psram_ub_n),
        .zz_n  (psram_zz_n)
    );

    // ============================================================
    // Clock
    // ============================================================

    initial begin

        clk = 1'b0;

        forever #(CLK_PERIOD / 2.0)
            clk = ~clk;

    end

    // ============================================================
    // VCD
    // ============================================================

    initial begin

        $dumpfile("sim/int8_psram_integration.vcd");
        $dumpvars(0, tb);

    end

    // ============================================================
    // Write INT8
    // ============================================================

    task write_byte;

        input [ADDR_WIDTH-1:0] byte_addr;
        input signed [7:0]     data;

        begin

            @(posedge clk);

            addr  <= byte_addr;
            wdata <= data;
            wr    <= 1'b1;
            req   <= 1'b1;

            @(posedge clk);

            req <= 1'b0;

            wait (ready);

            $display(
                "WRITE BYTE addr=0x%08x data=0x%02x PASS",
                byte_addr,
                data
            );

            @(posedge clk);

        end

    endtask

    // ============================================================
    // Read INT8
    // ============================================================

    task read_byte;

        input [ADDR_WIDTH-1:0] byte_addr;
        input signed [7:0]     expected;

        begin

            @(posedge clk);

            addr <= byte_addr;
            wr   <= 1'b0;
            req  <= 1'b1;

            @(posedge clk);

            req <= 1'b0;

            wait (ready);

            if (rdata !== expected) begin

                $display(
                    "READ BYTE addr=0x%08x FAIL got=0x%02x expected=0x%02x",
                    byte_addr,
                    rdata,
                    expected
                );

                $fatal;

            end else begin

                $display(
                    "READ BYTE addr=0x%08x data=0x%02x PASS",
                    byte_addr,
                    rdata
                );

            end

            @(posedge clk);

        end

    endtask

    // ============================================================
    // Test
    // ============================================================

    integer i;
    integer test_addr;
    reg signed [7:0] test_data;

    initial begin

        req   = 1'b0;
        wr    = 1'b0;
        addr  = 0;
        wdata = 0;

        rst = 1'b1;

        repeat (5)
            @(posedge clk);

        rst = 1'b0;

        $display("");
        $display("========================================");
        $display("INT8 + PSRAM FULL INTEGRATION TEST");
        $display("========================================");
        $display("");

        // --------------------------------------------------------
        // Wait for PSRAM initialization
        // --------------------------------------------------------

        wait (psram_ctrl.state == psram_ctrl.STATE_IDLE);

        $display("PSRAM initialization complete");
        $display("");

        // ========================================================
        // BASIC INT8 PACKING
        // ========================================================

        write_byte(22'h000000, 8'h12);
        write_byte(22'h000001, 8'h34);

        write_byte(22'h000002, 8'h56);
        write_byte(22'h000003, 8'h78);

        read_byte(22'h000000, 8'h12);
        read_byte(22'h000001, 8'h34);
        read_byte(22'h000002, 8'h56);
        read_byte(22'h000003, 8'h78);

        // ========================================================
        // BYTE PRESERVATION
        // ========================================================

        write_byte(22'h000010, 8'h34);
        write_byte(22'h000011, 8'h12);

        write_byte(22'h000010, 8'hAA);

        read_byte(22'h000010, 8'hAA);
        read_byte(22'h000011, 8'h12);

        write_byte(22'h000011, 8'hBB);

        read_byte(22'h000010, 8'hAA);
        read_byte(22'h000011, 8'hBB);

        // ========================================================
        // SIGNED INT8
        // ========================================================

        write_byte(22'h000020, -8'sd1);
        write_byte(22'h000021, -8'sd128);
        write_byte(22'h000022,  8'sd127);

        read_byte(22'h000020, -8'sd1);
        read_byte(22'h000021, -8'sd128);
        read_byte(22'h000022,  8'sd127);

        // ========================================================
        // SPARSE ADDRESSES
        // ========================================================

        write_byte(22'h000100, 8'h11);
        write_byte(22'h000101, 8'h22);

        write_byte(22'h001000, 8'h33);
        write_byte(22'h001001, 8'h44);

        write_byte(22'h003FFE, 8'h55);
        write_byte(22'h003FFF, 8'h66);

        read_byte(22'h000100, 8'h11);
        read_byte(22'h000101, 8'h22);

        read_byte(22'h001000, 8'h33);
        read_byte(22'h001001, 8'h44);

        read_byte(22'h003FFE, 8'h55);
        read_byte(22'h003FFF, 8'h66);

        // ========================================================
        // STRESS TEST
        // ========================================================

        $display("");
        $display("========================================");
        $display("INT8 PSRAM STRESS TEST");
        $display("2048 WRITE + READ BYTE TRANSACTIONS");
        $display("========================================");
        $display("");

        for (i = 0; i < 2048; i = i + 1) begin

            test_addr =
                ((i * 7919) ^ (i << 5)) & 16'h7FFF;

            test_data =
                ((i * 1237) ^ 8'hA5);

            write_byte(
                test_addr,
                test_data
            );

            read_byte(
                test_addr,
                test_data
            );

            if ((i % 128) == 0)
                $display(
                    "STRESS %0d / 2048 PASS",
                    i
                );

        end

        // ========================================================
        // Final result
        // ========================================================

        $display("");
        $display("========================================");
        $display("INT8 + PSRAM INTEGRATION TEST PASSED");
        $display("BYTE ADDRESSING       : PASS");
        $display("LB# / UB#             : PASS");
        $display("INT8 PACKING          : PASS");
        $display("BYTE PRESERVATION     : PASS");
        $display("SIGNED INT8           : PASS");
        $display("SPARSE ADDRESSES      : PASS");
        $display("2048 STRESS           : PASS");
        $display("========================================");
        $display("");

        $finish;

    end

endmodule