`timescale 1ns/1ps

// ================================================================
// ACT_BUFFER TESTBENCH (Phase G1)
//
// Verifies:
//   TEST 1 - write then read back (id 0, low end of range).
//   TEST 2 - write then read back (id N_TOTAL-1, high end of range).
//   TEST 3 - negative (signed) value round-trip.
//   TEST 4 - read is REGISTERED: rd_data must NOT show the new value
//            on the same cycle rd_addr changes, only one cycle later.
//   TEST 5 - independent ports: write to addr X while reading addr Y
//            in the same cycle does not disturb the read.
//   TEST 6 - a burst of writes to many ids, then read them all back
//            in a different order (models graph_engine's out-of-
//            order gather pattern).
// ================================================================

module tb;

    localparam N_TOTAL    = 4096;
    localparam DATA_WIDTH = 8;
    localparam ADDR_WIDTH = $clog2(N_TOTAL);
    localparam CLK_PERIOD = 10.0;

    reg clk;
    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD / 2.0) clk = ~clk;
    end

    reg                          wr_en;
    reg  [ADDR_WIDTH-1:0]        wr_addr;
    reg  signed [DATA_WIDTH-1:0] wr_data;

    reg  [ADDR_WIDTH-1:0]        rd_addr;
    wire signed [DATA_WIDTH-1:0] rd_data;

    act_buffer #(
        .N_TOTAL(N_TOTAL),
        .DATA_WIDTH(DATA_WIDTH)
    ) dut (
        .clk(clk),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .rd_addr(rd_addr), .rd_data(rd_data)
    );

    integer errors;

    task write_id(input [ADDR_WIDTH-1:0] addr, input signed [DATA_WIDTH-1:0] data);
        begin
            @(negedge clk);
            wr_en   = 1'b1;
            wr_addr = addr;
            wr_data = data;
            @(negedge clk);
            wr_en   = 1'b0;
        end
    endtask

    task check_read(input [ADDR_WIDTH-1:0] addr, input signed [DATA_WIDTH-1:0] expected, input [255:0] name);
        begin
            @(negedge clk);
            rd_addr = addr;
            @(negedge clk); // rd_data now reflects the address set above
            if (rd_data !== expected) begin
                $display("FAIL %0s: addr=%0d expected=%0d got=%0d", name, addr, expected, rd_data);
                errors = errors + 1;
            end else begin
                $display("PASS %0s: addr=%0d data=%0d", name, addr, rd_data);
            end
        end
    endtask

    integer i;

    initial begin
        errors  = 0;
        wr_en   = 1'b0;
        wr_addr = 0;
        wr_data = 0;
        rd_addr = 0;

        @(negedge clk);

        // TEST 1 - low end of range
        write_id(0, 8'sd42);
        check_read(0, 8'sd42, "TEST1 id0");

        // TEST 2 - high end of range
        write_id(N_TOTAL-1, 8'sd100);
        check_read(N_TOTAL-1, 8'sd100, "TEST2 id_max");

        // TEST 3 - negative value round-trip
        write_id(10, -8'sd77);
        check_read(10, -8'sd77, "TEST3 negative");

        // TEST 4 - read is registered (1-cycle latency), not
        // combinational: changing rd_addr must not show the new
        // value until the NEXT clock edge.
        @(negedge clk);
        rd_addr = 0; // id0 = 42
        @(negedge clk);
        if (rd_data !== 8'sd42) begin
            $display("FAIL TEST4 setup: expected 42 got %0d", rd_data);
            errors = errors + 1;
        end
        rd_addr = 10; // id10 = -77, but rd_data must still show id0's value THIS cycle
        if (rd_data !== 8'sd42) begin
            $display("FAIL TEST4 latency: rd_data changed same-cycle as rd_addr (got %0d, expected still 42)", rd_data);
            errors = errors + 1;
        end else begin
            $display("PASS TEST4 latency: rd_data still 42 same-cycle as rd_addr change");
        end
        @(negedge clk);
        if (rd_data !== -8'sd77) begin
            $display("FAIL TEST4 next-cycle: expected -77 got %0d", rd_data);
            errors = errors + 1;
        end else begin
            $display("PASS TEST4 next-cycle: rd_data=-77 one cycle after rd_addr=10");
        end

        // TEST 5 - independent ports: write addr 20 while reading addr 10
        @(negedge clk);
        rd_addr = 10;
        wr_en   = 1'b1;
        wr_addr = 20;
        wr_data = 8'sd55;
        @(negedge clk);
        wr_en = 1'b0;
        if (rd_data !== -8'sd77) begin
            $display("FAIL TEST5: concurrent write disturbed read (expected -77 got %0d)", rd_data);
            errors = errors + 1;
        end else begin
            $display("PASS TEST5: concurrent write to a different address did not disturb read");
        end
        check_read(20, 8'sd55, "TEST5 followup id20");

        // TEST 6 - burst write many ids, read back out of order
        for (i = 0; i < 16; i = i + 1) begin
            write_id(100 + i, i[7:0]);
        end
        for (i = 15; i >= 0; i = i - 1) begin
            check_read(100 + i, i[7:0], "TEST6 burst reverse-order");
        end

        if (errors == 0) begin
            $display("ALL TESTS PASSED");
        end else begin
            $display("%0d TEST(S) FAILED", errors);
        end

        $finish;
    end

endmodule
