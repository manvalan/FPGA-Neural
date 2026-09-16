`timescale 1ns/1ps

// ============================================================
// EXP-0057 -- isolated correctness check for layer_weight_buffer.v:
// fill buffer A, swap, read A many times while filling B, swap again
// (order-independent: sometimes fill_done arrives first, sometimes
// consume_done does), verify data integrity and correct buffer
// selection throughout.
// ============================================================
module tb;
    localparam DATA_WIDTH  = 8;
    localparam LAYER_DEPTH = 128;
    localparam ADDRW = $clog2(LAYER_DEPTH);

    reg clk = 0;
    always #5 clk = ~clk;
    reg rst;

    reg                  fill_we;
    reg  [ADDRW-1:0]     fill_addr;
    reg  [DATA_WIDTH-1:0] fill_data;
    reg                  fill_done;
    reg  [ADDRW-1:0]     rd_addr;
    wire [DATA_WIDTH-1:0] rd_data;
    reg                  consume_done;
    wire                 active_sel;
    wire                 swapped;

    layer_weight_buffer #(
        .DATA_WIDTH(DATA_WIDTH), .LAYER_DEPTH(LAYER_DEPTH)
    ) dut (
        .clk(clk), .rst(rst),
        .fill_we(fill_we), .fill_addr(fill_addr), .fill_data(fill_data), .fill_done(fill_done),
        .rd_addr(rd_addr), .rd_data(rd_data), .consume_done(consume_done),
        .active_sel(active_sel), .swapped(swapped)
    );

    integer errors, tests, i;

    task automatic fill_layer(input [7:0] pattern_base);
        integer k;
        begin
            for (k = 0; k < LAYER_DEPTH; k = k + 1) begin
                @(posedge clk);
                fill_we = 1'b1; fill_addr = k[ADDRW-1:0]; fill_data = pattern_base + k[7:0];
            end
            @(posedge clk);
            fill_we = 1'b0;
            fill_done = 1'b1;
            @(posedge clk);
            fill_done = 1'b0;
        end
    endtask

    task automatic read_and_check_layer(input [7:0] pattern_base, input integer n_reuses);
        integer r, k;
        begin
            for (r = 0; r < n_reuses; r = r + 1) begin
                for (k = 0; k < LAYER_DEPTH; k = k + 1) begin
                    rd_addr = k[ADDRW-1:0];
                    #1;
                    tests = tests + 1;
                    if (rd_data !== (pattern_base + k[7:0])) begin
                        $display("FAIL reuse=%0d addr=%0d: expected %0d got %0d", r, k, pattern_base+k[7:0], rd_data);
                        errors = errors + 1;
                    end
                    @(posedge clk);
                end
            end
            consume_done = 1'b1;
            @(posedge clk);
            consume_done = 1'b0;
        end
    endtask

    initial begin
        errors = 0; tests = 0;
        rst = 1; fill_we = 0; fill_addr = 0; fill_data = 0; fill_done = 0;
        rd_addr = 0; consume_done = 0;
        repeat(3) @(posedge clk);
        rst = 0;

        $display("=== fill layer 0 (pattern 0x10), swap in ===");
        fill_layer(8'h10);
        if (active_sel !== 1'b0) begin
            $display("FAIL: expected active_sel=0 before any swap (fill alone must not swap)");
            errors = errors + 1;
        end
        // consume_done from reset state (never asserted yet) + fill_done just latched -> not swapped yet
        // now assert consume_done once (simulating "nothing to consume yet, first layer") to trigger the swap
        consume_done = 1'b1; @(posedge clk); consume_done = 1'b0;
        @(posedge clk); #1; // swap logic is 2-cycle latency from the triggering pulse; let it settle
        if (active_sel !== 1'b1) begin
            $display("FAIL: expected active_sel=1 after first swap, got %b", active_sel);
            errors = errors + 1;
        end
        tests = tests + 1;

        $display("=== read layer 0 (now active, 5 reuses), meanwhile fill layer 1 (pattern 0x40) ===");
        fork
            read_and_check_layer(8'h10, 5);
            fill_layer(8'h40);
        join
        @(posedge clk); #1;
        if (active_sel !== 1'b0) begin
            $display("FAIL: expected active_sel=0 after second swap (back to buffer 0, now holding layer1 data), got %b", active_sel);
            errors = errors + 1;
        end
        tests = tests + 1;

        $display("=== read layer 1 (pattern 0x40, 3 reuses), meanwhile fill layer 2 (pattern 0x80) -- fill finishes FIRST this time ===");
        fork
            begin
                fill_layer(8'h80);
            end
            begin
                #50; // let fill get a head start, so fill_done lands before consume_done
                read_and_check_layer(8'h40, 3);
            end
        join
        @(posedge clk); #1;
        if (active_sel !== 1'b1) begin
            $display("FAIL: expected active_sel=1 after third swap, got %b", active_sel);
            errors = errors + 1;
        end
        tests = tests + 1;

        $display("=== read layer 2 (pattern 0x80, 4 reuses), verify final data ===");
        read_and_check_layer(8'h80, 4);
        consume_done = 1'b1; @(posedge clk); consume_done = 1'b0; // extra pulse, no fill pending: must NOT swap without a fill_done
        if (active_sel !== 1'b1) begin
            $display("FAIL: consume_done alone (no matching fill_done) must not cause a swap, got active_sel=%b", active_sel);
            errors = errors + 1;
        end
        tests = tests + 1;

        $display("=== %0d/%0d passed, %0d errors ===", tests-errors, tests, errors);
        if (errors == 0) $display("ALL TESTS PASSED (tb_layer_weight_buffer)");
        $finish;
    end
endmodule
