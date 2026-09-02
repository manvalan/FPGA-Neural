`timescale 1ns/1ps

module memory_interface_tb;

    parameter ADDR_WIDTH = 22;
    parameter DATA_WIDTH = 16;

    reg clk;
    reg rst;

    // Host side
    reg                    req;
    reg                    wr;
    reg  [ADDR_WIDTH-1:0]  addr;
    reg  [DATA_WIDTH-1:0]  wdata;

    wire [DATA_WIDTH-1:0]  rdata;
    wire                   ready;

    // Memory side
    wire                   mem_req;
    wire                   mem_wr;
    wire [ADDR_WIDTH-1:0]  mem_addr;
    wire [DATA_WIDTH-1:0]  mem_wdata;

    wire [DATA_WIDTH-1:0]  mem_rdata;
    wire                   mem_ready;

    // ------------------------------------------------------------
    // Clock
    // ------------------------------------------------------------

    initial begin
        clk = 1'b0;

        forever #5 clk = ~clk;
    end

    // ------------------------------------------------------------
    // DUT: Memory Interface
    // ------------------------------------------------------------

    memory_interface #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH)
    ) dut (
        .clk(clk),
        .rst(rst),

        .req(req),
        .wr(wr),
        .addr(addr),
        .wdata(wdata),

        .rdata(rdata),
        .ready(ready),

        .mem_req(mem_req),
        .mem_wr(mem_wr),
        .mem_addr(mem_addr),
        .mem_wdata(mem_wdata),

        .mem_rdata(mem_rdata),
        .mem_ready(mem_ready)
    );

    // ------------------------------------------------------------
    // Memory model
    // ------------------------------------------------------------

    memory_model #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .DEPTH(4096),
        .READ_LATENCY(2)
    ) memory (
        .clk(clk),
        .rst(rst),

        .req(mem_req),
        .wr(mem_wr),
        .addr(mem_addr),
        .wdata(mem_wdata),

        .rdata(mem_rdata),
        .ready(mem_ready)
    );

    // ------------------------------------------------------------
    // Test utilities
    // ------------------------------------------------------------

    task write_mem;
        input [ADDR_WIDTH-1:0] address;
        input [DATA_WIDTH-1:0] data;
        begin
            @(posedge clk);

            addr  <= address;
            wdata <= data;
            wr    <= 1'b1;
            req   <= 1'b1;

            @(posedge clk);

            req <= 1'b0;

            wait (ready);

            @(posedge clk);

            $display(
                "WRITE addr=0x%08h data=0x%04h PASS",
                address,
                data
            );
        end
    endtask

    task read_mem;
        input [ADDR_WIDTH-1:0] address;
        input [DATA_WIDTH-1:0] expected;

        reg [DATA_WIDTH-1:0] received;

        begin
            @(posedge clk);

            addr <= address;
            wr   <= 1'b0;
            req  <= 1'b1;

            @(posedge clk);

            req <= 1'b0;

            wait (ready);

            received = rdata;

            @(posedge clk);

            if (received === expected) begin
                $display(
                    "READ  addr=0x%08h data=0x%04h PASS",
                    address,
                    received
                );
            end else begin
                $display(
                    "READ  addr=0x%08h got=0x%04h expected=0x%04h FAIL",
                    address,
                    received,
                    expected
                );

                $fatal;
            end
        end
    endtask

    // ------------------------------------------------------------
    // Test sequence
    // ------------------------------------------------------------

    initial begin

        // Defaults
        rst   = 1'b1;

        req   = 1'b0;
        wr    = 1'b0;
        addr  = {ADDR_WIDTH{1'b0}};
        wdata = {DATA_WIDTH{1'b0}};

        // Reset
        repeat (3)
            @(posedge clk);

        rst = 1'b0;

        $display("");
        $display("========================================");
        $display("MEMORY INTERFACE V1 TEST");
        $display("ADDR_WIDTH = %0d", ADDR_WIDTH);
        $display("DATA_WIDTH = %0d", DATA_WIDTH);
        $display("========================================");
        $display("");

        // --------------------------------------------------------
        // Test 1
        // --------------------------------------------------------

        write_mem(
            22'h000001,
            16'h1234
        );

        read_mem(
            22'h000001,
            16'h1234
        );

        // --------------------------------------------------------
        // Test 2
        // --------------------------------------------------------

        write_mem(
            22'h000010,
            16'hABCD
        );

        read_mem(
            22'h000010,
            16'hABCD
        );

        // --------------------------------------------------------
        // Test 3
        // --------------------------------------------------------

        write_mem(
            22'h000100,
            16'h55AA
        );

        read_mem(
            22'h000100,
            16'h55AA
        );

        // --------------------------------------------------------
        // Test 4
        // --------------------------------------------------------
        // Consecutive different addresses

        write_mem(
            22'h000200,
            16'h0001
        );

        write_mem(
            22'h000201,
            16'h0002
        );

        write_mem(
            22'h000202,
            16'h0003
        );

        read_mem(
            22'h000200,
            16'h0001
        );

        read_mem(
            22'h000201,
            16'h0002
        );

        read_mem(
            22'h000202,
            16'h0003
        );

        // --------------------------------------------------------
        // Test 5
        // --------------------------------------------------------
        // Zero value

        write_mem(
            22'h000300,
            16'h0000
        );

        read_mem(
            22'h000300,
            16'h0000
        );

        // --------------------------------------------------------
        // Test 6
        // --------------------------------------------------------
        // Full 16-bit value

        write_mem(
            22'h000301,
            16'hFFFF
        );

        read_mem(
            22'h000301,
            16'hFFFF
        );

        // --------------------------------------------------------
        // Finished
        // --------------------------------------------------------

        $display("");
        $display("========================================");
        $display("MEMORY INTERFACE V1 TEST PASSED");
        $display("========================================");
        $display("");

        $finish;
    end

    // ------------------------------------------------------------
    // VCD
    // ------------------------------------------------------------

    initial begin
        $dumpfile("sim/memory_interface.vcd");
        $dumpvars(0, memory_interface_tb);
    end

endmodule