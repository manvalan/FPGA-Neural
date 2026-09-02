`timescale 1ns/1ps

module tb;

    localparam ADDR_WIDTH = 22;
    localparam DATA_WIDTH = 16;
    localparam CLK_PERIOD = 12.5; // 80 MHz

    reg clk;
    reg rst;

    // ============================================================
    // Memory Interface
    // ============================================================

    reg                   mem_req;
    reg                   mem_wr;
    reg  [ADDR_WIDTH-1:0] mem_addr;
    reg  [DATA_WIDTH-1:0] mem_wdata;
    reg                   mem_lb_n;
    reg                   mem_ub_n;

    wire [DATA_WIDTH-1:0] mem_rdata;
    wire                  mem_ready;

    // ============================================================
    // PSRAM
    // ============================================================

    wire [ADDR_WIDTH-1:0] psram_a;
    wire [DATA_WIDTH-1:0] psram_dq;

    wire psram_ce_n;
    wire psram_oe_n;
    wire psram_we_n;
    wire psram_lb_n;
    wire psram_ub_n;
    wire psram_zz_n;

    // ============================================================
    // Stress-test variables
    // ============================================================

    integer stress_i;
    integer stress_addr;
    reg [15:0] stress_data;

    // ============================================================
    // DUT
    // ============================================================

    psram_controller #(
        .ADDR_WIDTH   (ADDR_WIDTH),
        .DATA_WIDTH   (DATA_WIDTH),
        .CLK_FREQ_MHZ (80)
    ) dut (
        .clk       (clk),
        .rst       (rst),

        .mem_req   (mem_req),
        .mem_wr    (mem_wr),
        .mem_addr  (mem_addr),
        .mem_wdata (mem_wdata),
        .mem_lb_n  (mem_lb_n),
        .mem_ub_n  (mem_ub_n),

        .mem_rdata (mem_rdata),
        .mem_ready (mem_ready),

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
    // PSRAM model
    // ============================================================

    psram_model #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .DEPTH(16384)
    ) memory (
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
        $dumpfile("sim/psram_controller.vcd");
        $dumpvars(0, tb);
    end

    // ============================================================
    // Helper: write word with byte enables
    //
    // lb_n = 0 -> low byte enabled
    // ub_n = 0 -> high byte enabled
    // ============================================================

    task write_word;
        input [ADDR_WIDTH-1:0] addr;
        input [DATA_WIDTH-1:0] data;
        input                  lb;
        input                  ub;

        begin

            @(posedge clk);

            mem_addr  <= addr;
            mem_wdata <= data;
            mem_wr    <= 1'b1;
            mem_lb_n  <= lb;
            mem_ub_n  <= ub;
            mem_req   <= 1'b1;

            @(posedge clk);

            mem_req <= 1'b0;

            wait (mem_ready);

            $display(
                "WRITE addr=0x%08x data=0x%04x LB#=%b UB#=%b PASS",
                addr,
                data,
                lb,
                ub
            );

            @(posedge clk);

        end
    endtask

    // ============================================================
    // Helper: read full word
    //
    // For normal word reads both bytes are enabled.
    // ============================================================

    task read_word;
        input [ADDR_WIDTH-1:0] addr;
        input [DATA_WIDTH-1:0] expected;

        begin

            @(posedge clk);

            mem_addr <= addr;
            mem_wr   <= 1'b0;
            mem_lb_n <= 1'b0;
            mem_ub_n <= 1'b0;
            mem_req  <= 1'b1;

            @(posedge clk);

            mem_req <= 1'b0;

            wait (mem_ready);

            if (mem_rdata !== expected) begin

                $display(
                    "READ  addr=0x%08x FAIL got=0x%04x expected=0x%04x",
                    addr,
                    mem_rdata,
                    expected
                );

                $fatal;

            end else begin

                $display(
                    "READ  addr=0x%08x data=0x%04x PASS",
                    addr,
                    mem_rdata
                );

            end

            @(posedge clk);

        end
    endtask

    // ============================================================
    // Test
    // ============================================================

    initial begin

        mem_req   = 1'b0;
        mem_wr    = 1'b0;
        mem_addr  = 0;
        mem_wdata = 0;

        // Both bytes disabled while idle
        mem_lb_n  = 1'b1;
        mem_ub_n  = 1'b1;

        rst = 1'b1;

        repeat (5)
            @(posedge clk);

        rst = 1'b0;

        $display("");
        $display("========================================");
        $display("PSRAM CONTROLLER V1 TEST");
        $display("80 MHz");
        $display("4M x 16 PSRAM");
        $display("70 ns asynchronous timing");
        $display("========================================");
        $display("");

        wait (dut.state == dut.STATE_IDLE);

        $display("PSRAM initialization complete");
        $display("");

        // ========================================================
        // Basic writes / reads
        // ========================================================

        write_word(22'h000001, 16'h1234, 1'b0, 1'b0);
        read_word (22'h000001, 16'h1234);

        write_word(22'h000010, 16'hABCD, 1'b0, 1'b0);
        read_word (22'h000010, 16'hABCD);

        write_word(22'h000100, 16'h55AA, 1'b0, 1'b0);
        read_word (22'h000100, 16'h55AA);

        // ========================================================
        // Consecutive words
        // ========================================================

        write_word(22'h000200, 16'h0001, 1'b0, 1'b0);
        write_word(22'h000201, 16'h0002, 1'b0, 1'b0);
        write_word(22'h000202, 16'h0003, 1'b0, 1'b0);

        read_word(22'h000200, 16'h0001);
        read_word(22'h000201, 16'h0002);
        read_word(22'h000202, 16'h0003);

        // ========================================================
        // Edge values
        // ========================================================

        write_word(22'h000300, 16'h0000, 1'b0, 1'b0);
        read_word (22'h000300, 16'h0000);

        write_word(22'h000301, 16'hFFFF, 1'b0, 1'b0);
        read_word (22'h000301, 16'hFFFF);

        // ========================================================
        // High address
        // ========================================================

        write_word(22'h003FFF, 16'hCAFE, 1'b0, 1'b0);
        read_word (22'h003FFF, 16'hCAFE);

        // ========================================================
        // Basic test passed
        // ========================================================

        $display("");
        $display("========================================");
        $display("PSRAM CONTROLLER BASIC TEST PASSED");
        $display("========================================");
        $display("");

        // ========================================================
        // BYTE ENABLE TEST
        // ========================================================

        $display("");
        $display("========================================");
        $display("PSRAM BYTE ENABLE TEST");
        $display("LB# / UB#");
        $display("========================================");
        $display("");

        // --------------------------------------------------------
        // Start from known value
        // --------------------------------------------------------

        write_word(
            22'h000400,
            16'h1234,
            1'b0,
            1'b0
        );

        read_word(
            22'h000400,
            16'h1234
        );

        // --------------------------------------------------------
        // LOW BYTE ONLY
        //
        // Initial: 0x1234
        // Write:   0x00AA
        //
        // LB# = 0 -> low byte written
        // UB# = 1 -> high byte preserved
        //
        // Expected: 0x12AA
        // --------------------------------------------------------

        $display("");
        $display("LOW BYTE ONLY");
        $display("Initial = 0x1234");
        $display("Write   = 0x00AA");
        $display("LB#=0 UB#=1");
        $display("Expected= 0x12AA");
        $display("");

        write_word(
            22'h000400,
            16'h00AA,
            1'b0,
            1'b1
        );

        read_word(
            22'h000400,
            16'h12AA
        );

        // --------------------------------------------------------
        // HIGH BYTE ONLY
        //
        // Current: 0x12AA
        // Write:   0xBB00
        //
        // LB# = 1 -> low byte preserved
        // UB# = 0 -> high byte written
        //
        // Expected: 0xBBAA
        // --------------------------------------------------------

        $display("");
        $display("HIGH BYTE ONLY");
        $display("Initial = 0x12AA");
        $display("Write   = 0xBB00");
        $display("LB#=1 UB#=0");
        $display("Expected= 0xBBAA");
        $display("");

        write_word(
            22'h000400,
            16'hBB00,
            1'b1,
            1'b0
        );

        read_word(
            22'h000400,
            16'hBBAA
        );

        // --------------------------------------------------------
        // FULL WORD
        //
        // Current: 0xBBAA
        // Write:   0xCCDD
        //
        // LB# = 0 -> low byte written
        // UB# = 0 -> high byte written
        //
        // Expected: 0xCCDD
        // --------------------------------------------------------

        $display("");
        $display("FULL WORD");
        $display("Initial = 0xBBAA");
        $display("Write   = 0xCCDD");
        $display("LB#=0 UB#=0");
        $display("Expected= 0xCCDD");
        $display("");

        write_word(
            22'h000400,
            16'hCCDD,
            1'b0,
            1'b0
        );

        read_word(
            22'h000400,
            16'hCCDD
        );

        // ========================================================
        // BYTE ENABLE TEST PASSED
        // ========================================================

        $display("");
        $display("========================================");
        $display("PSRAM BYTE ENABLE TEST PASSED");
        $display("LOW BYTE  : PASS");
        $display("HIGH BYTE : PASS");
        $display("FULL WORD : PASS");
        $display("PRESERVE  : PASS");
        $display("========================================");
        $display("");

        // ========================================================
        // STRESS TEST
        // ========================================================

        $display("");
        $display("========================================");
        $display("PSRAM STRESS TEST");
        $display("2048 WRITE + READ transactions");
        $display("========================================");
        $display("");

        for (stress_i = 0;
             stress_i < 2048;
             stress_i = stress_i + 1) begin

            stress_addr =
                ((stress_i * 7919) ^ (stress_i << 5)) & 16'h3FFF;

            stress_data =
                ((stress_i * 1237) ^ 16'hA5A5);

            write_word(
                stress_addr,
                stress_data,
                1'b0,
                1'b0
            );

            read_word(
                stress_addr,
                stress_data
            );

            if ((stress_i % 128) == 0)
                $display(
                    "STRESS %0d / 2048 PASS",
                    stress_i
                );

        end

        // ========================================================
        // Final result
        // ========================================================

        $display("");
        $display("========================================");
        $display("PSRAM CONTROLLER V1 TEST PASSED");
        $display("2048 WRITE + READ stress transactions");
        $display("BYTE ENABLE TEST PASSED");
        $display("========================================");
        $display("");

        $finish;

    end

endmodule