`timescale 1ns/1ps

// ============================================================
// M3 testbench (docs/v2-description.md §14/§20): activation_buffer.v,
// weight_buffer.v, result_buffer.v. Verified with Verilator (see
// hardware/v2/logs/decisions.log DEC-0004).
//
// Coverage: write-then-read correctness (incl. the 1-cycle registered
// read latency all three share with hardware/v1/rtl/act_buffer.v),
// back-to-back writes to different addresses without corrupting
// earlier entries, and extreme INT8 values (-128, 127) round-tripping
// exactly.
// ============================================================

module tb;

    localparam DATA_WIDTH = 8;
    localparam P_IN       = 8;
    localparam AB_DEPTH   = 64;
    localparam WB_DEPTH   = 16;
    localparam RB_DEPTH   = 64;

    reg clk;
    initial begin clk = 0; forever #5 clk = ~clk; end

    integer errors, tests;

    // ---- activation_buffer ----
    reg                          ab_wr_en;
    reg  [$clog2(AB_DEPTH)-1:0]  ab_wr_addr, ab_rd_addr;
    reg  signed [DATA_WIDTH-1:0] ab_wr_data;
    wire signed [DATA_WIDTH-1:0] ab_rd_data;

    activation_buffer #(.DEPTH(AB_DEPTH), .DATA_WIDTH(DATA_WIDTH)) u_ab (
        .clk(clk), .wr_en(ab_wr_en), .wr_addr(ab_wr_addr), .wr_data(ab_wr_data),
        .rd_addr(ab_rd_addr), .rd_data(ab_rd_data)
    );

    // ---- weight_buffer ----
    reg                                  wb_wr_en;
    reg  [$clog2(WB_DEPTH)-1:0]          wb_wr_addr, wb_rd_addr;
    reg  signed [DATA_WIDTH*P_IN-1:0]    wb_wr_data;
    wire signed [DATA_WIDTH*P_IN-1:0]    wb_rd_data;

    weight_buffer #(.DEPTH(WB_DEPTH), .DATA_WIDTH(DATA_WIDTH), .P_IN(P_IN)) u_wb (
        .clk(clk), .wr_en(wb_wr_en), .wr_addr(wb_wr_addr), .wr_data(wb_wr_data),
        .rd_addr(wb_rd_addr), .rd_data(wb_rd_data)
    );

    // ---- result_buffer ----
    reg                          rb_wr_en;
    reg  [$clog2(RB_DEPTH)-1:0]  rb_wr_addr, rb_rd_addr;
    reg  signed [DATA_WIDTH-1:0] rb_wr_data;
    wire signed [DATA_WIDTH-1:0] rb_rd_data;

    result_buffer #(.DEPTH(RB_DEPTH), .DATA_WIDTH(DATA_WIDTH)) u_rb (
        .clk(clk), .wr_en(rb_wr_en), .wr_addr(rb_wr_addr), .wr_data(rb_wr_data),
        .rd_addr(rb_rd_addr), .rd_data(rb_rd_data)
    );

    task automatic check_ab(input [$clog2(AB_DEPTH)-1:0] addr, input signed [DATA_WIDTH-1:0] exp_val);
        begin
            tests = tests + 1;
            ab_rd_addr = addr;
            @(posedge clk);
            @(posedge clk); // registered read: value settles one cycle after rd_addr
            if (ab_rd_data !== exp_val) begin
                $display("FAIL activation_buffer[%0d]: got %0d expected %0d", addr, ab_rd_data, exp_val);
                errors = errors + 1;
            end else
                $display("PASS activation_buffer[%0d] = %0d", addr, ab_rd_data);
        end
    endtask

    task automatic check_wb(input [$clog2(WB_DEPTH)-1:0] addr, input signed [DATA_WIDTH*P_IN-1:0] exp_val);
        begin
            tests = tests + 1;
            wb_rd_addr = addr;
            @(posedge clk);
            @(posedge clk);
            if (wb_rd_data !== exp_val) begin
                $display("FAIL weight_buffer[%0d]: got %h expected %h", addr, wb_rd_data, exp_val);
                errors = errors + 1;
            end else
                $display("PASS weight_buffer[%0d] = %h", addr, wb_rd_data);
        end
    endtask

    task automatic check_rb(input [$clog2(RB_DEPTH)-1:0] addr, input signed [DATA_WIDTH-1:0] exp_val);
        begin
            tests = tests + 1;
            rb_rd_addr = addr;
            @(posedge clk);
            @(posedge clk);
            if (rb_rd_data !== exp_val) begin
                $display("FAIL result_buffer[%0d]: got %0d expected %0d", addr, rb_rd_data, exp_val);
                errors = errors + 1;
            end else
                $display("PASS result_buffer[%0d] = %0d", addr, rb_rd_data);
        end
    endtask

    integer i;

    initial begin
        errors = 0; tests = 0;
        ab_wr_en = 0; ab_wr_addr = 0; ab_wr_data = 0; ab_rd_addr = 0;
        wb_wr_en = 0; wb_wr_addr = 0; wb_wr_data = 0; wb_rd_addr = 0;
        rb_wr_en = 0; rb_wr_addr = 0; rb_wr_data = 0; rb_rd_addr = 0;
        @(posedge clk);

        // ---- activation_buffer: write extreme + regular values at
        // several addresses, confirm each reads back correctly and
        // earlier writes are not disturbed by later ones. ----
        @(posedge clk);
        ab_wr_en = 1; ab_wr_addr = 0;  ab_wr_data = -8'sd128; @(posedge clk);
        ab_wr_addr = 1;  ab_wr_data = 8'sd127;  @(posedge clk);
        ab_wr_addr = 5;  ab_wr_data = 8'sd42;   @(posedge clk);
        ab_wr_addr = 63; ab_wr_data = -8'sd1;   @(posedge clk);
        ab_wr_en = 0;
        check_ab(0, -8'sd128);
        check_ab(1, 8'sd127);
        check_ab(5, 8'sd42);
        check_ab(63, -8'sd1);
        check_ab(1, 8'sd127); // re-read: confirm earlier writes undisturbed

        // ---- weight_buffer: write two whole tiles, confirm full
        // TILE_WIDTH round-trips exactly (not just one lane). ----
        @(posedge clk);
        wb_wr_en = 1; wb_wr_addr = 0;
        wb_wr_data = 0;
        for (i = 0; i < P_IN; i = i + 1)
            wb_wr_data[i*DATA_WIDTH +: DATA_WIDTH] = i[DATA_WIDTH-1:0]; // 0,1,2,...,7
        @(posedge clk);
        wb_wr_addr = 3;
        wb_wr_data = 0;
        for (i = 0; i < P_IN; i = i + 1)
            wb_wr_data[i*DATA_WIDTH +: DATA_WIDTH] = -8'sd1; // all-lanes -1
        @(posedge clk);
        wb_wr_en = 0;

        begin
            reg signed [DATA_WIDTH*P_IN-1:0] expect0, expect3;
            expect0 = 0;
            for (i = 0; i < P_IN; i = i + 1) expect0[i*DATA_WIDTH +: DATA_WIDTH] = i[DATA_WIDTH-1:0];
            expect3 = {P_IN{8'hFF}};
            check_wb(0, expect0);
            check_wb(3, expect3);
            check_wb(0, expect0); // re-read: confirm undisturbed
        end

        // ---- result_buffer: same pattern as activation_buffer ----
        @(posedge clk);
        rb_wr_en = 1; rb_wr_addr = 7;  rb_wr_data = 8'sd100; @(posedge clk);
        rb_wr_addr = 8;  rb_wr_data = -8'sd100; @(posedge clk);
        rb_wr_en = 0;
        check_rb(7, 8'sd100);
        check_rb(8, -8'sd100);

        $display("========================================");
        if (errors == 0)
            $display("ALL %0d TESTS PASSED (activation/weight/result buffers)", tests);
        else
            $display("FAILED: %0d/%0d test(s) had errors -- see messages above", errors, tests);
        $display("========================================");
        $finish;
    end

endmodule
