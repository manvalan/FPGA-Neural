`timescale 1ns/1ps

module tb;

    localparam ADDR_WIDTH = 23;
    localparam CLK_PERIOD = 12.5;

    reg clk;
    reg rst;

    // ============================================================
    // INT8 interface
    // ============================================================

    reg               req;
    reg               wr;
    reg [ADDR_WIDTH-1:0] addr;
    reg signed [7:0]  wdata;

    wire signed [7:0] rdata;
    wire              ready;

    // ============================================================
    // Memory interface
    // ============================================================

    wire              mem_req;
    wire              mem_wr;
    wire [ADDR_WIDTH-1:0] mem_addr;
    wire [15:0]       mem_wdata;
    wire              mem_lb_n;
    wire              mem_ub_n;

    wire [15:0]       mem_rdata;
    wire              mem_ready;

    // ============================================================
    // DUT
    // ============================================================

    int8_memory_access #(
        .ADDR_WIDTH(ADDR_WIDTH)
    ) dut (
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
    // Simple memory model
    // ============================================================

    reg [15:0] memory [0:1023];

    reg [15:0] model_rdata;
    reg        model_ready;

    integer i;

    assign mem_rdata = model_rdata;
    assign mem_ready = model_ready;

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

        $dumpfile("sim/int8_memory_access.vcd");
        $dumpvars(0, tb);

    end

    // ============================================================
    // Memory model
    // ============================================================

    always @(posedge clk) begin

        model_ready <= 1'b0;

        if (mem_req) begin

            if (mem_wr) begin

                if (!mem_lb_n)
                    memory[mem_addr][7:0] <= mem_wdata[7:0];

                if (!mem_ub_n)
                    memory[mem_addr][15:8] <= mem_wdata[15:8];

            end else begin

                model_rdata <= memory[mem_addr];

            end

            model_ready <= 1'b1;

        end

    end

    // ============================================================
    // Write helper
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
    // Read helper
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

    initial begin

        req   = 1'b0;
        wr    = 1'b0;
        addr  = 0;
        wdata = 0;

        model_rdata = 16'h0000;
        model_ready = 1'b0;

        for (i = 0; i < 1024; i = i + 1)
            memory[i] = 16'h0000;

        rst = 1'b1;

        repeat (5)
            @(posedge clk);

        rst = 1'b0;

        $display("");
        $display("========================================");
        $display("INT8 MEMORY ACCESS TEST");
        $display("========================================");
        $display("");

        // ========================================================
        // Basic byte writes
        // ========================================================

        write_byte(22'h000000, 8'h12);
        write_byte(22'h000001, 8'h34);

        write_byte(22'h000002, 8'h56);
        write_byte(22'h000003, 8'h78);

        // ========================================================
        // Reads
        // ========================================================

        read_byte(22'h000000, 8'h12);
        read_byte(22'h000001, 8'h34);

        read_byte(22'h000002, 8'h56);
        read_byte(22'h000003, 8'h78);

        // ========================================================
        // Verify physical packing
        // ========================================================

        if (memory[0] !== 16'h3412) begin

            $display(
                "PACKING ERROR word[0]=0x%04x expected=0x3412",
                memory[0]
            );

            $fatal;

        end else begin

            $display(
                "PACKING word[0] = 0x%04x PASS",
                memory[0]
            );

        end

        if (memory[1] !== 16'h7856) begin

            $display(
                "PACKING ERROR word[1]=0x%04x expected=0x7856",
                memory[1]
            );

            $fatal;

        end else begin

            $display(
                "PACKING word[1] = 0x%04x PASS",
                memory[1]
            );

        end

        // ========================================================
        // Byte preservation test
        // ========================================================

        // Start with 0x1234
        write_byte(22'h000010, 8'h34);
        write_byte(22'h000011, 8'h12);

        if (memory[8] !== 16'h1234) begin

            $display(
                "INITIAL WORD ERROR = 0x%04x",
                memory[8]
            );

            $fatal;

        end

        // Change low byte only:
        // 0x1234 -> 0x12AA

        write_byte(22'h000010, 8'hAA);

        if (memory[8] !== 16'h12AA) begin

            $display(
                "LOW BYTE PRESERVE ERROR = 0x%04x expected=0x12AA",
                memory[8]
            );

            $fatal;

        end else begin

            $display(
                "LOW BYTE PRESERVE 0x1234 -> 0x12AA PASS"
            );

        end

        // Change high byte only:
        // 0x12AA -> 0xBBAA

        write_byte(22'h000011, 8'hBB);

        if (memory[8] !== 16'hBBAA) begin

            $display(
                "HIGH BYTE PRESERVE ERROR = 0x%04x expected=0xBBAA",
                memory[8]
            );

            $fatal;

        end else begin

            $display(
                "HIGH BYTE PRESERVE 0x12AA -> 0xBBAA PASS"
            );

        end

        // ========================================================
        // Signed INT8 values
        // ========================================================

        write_byte(22'h000020, -8'sd1);
        write_byte(22'h000021, -8'sd128);
        write_byte(22'h000022,  8'sd127);

        read_byte(22'h000020, -8'sd1);
        read_byte(22'h000021, -8'sd128);
        read_byte(22'h000022,  8'sd127);

        // ========================================================
        // Final result
        // ========================================================

        $display("");
        $display("========================================");
        $display("INT8 MEMORY ACCESS TEST PASSED");
        $display("BYTE ADDRESSING       : PASS");
        $display("LOW BYTE              : PASS");
        $display("HIGH BYTE             : PASS");
        $display("INT8 PACKING          : PASS");
        $display("BYTE PRESERVATION     : PASS");
        $display("SIGNED INT8           : PASS");
        $display("========================================");
        $display("");

        $finish;

    end

endmodule