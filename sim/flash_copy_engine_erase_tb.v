`timescale 1ns/1ps

// ================================================================
// FLASH_COPY_ENGINE TESTBENCH -- DIR_ERASE (F5's standalone
// FLASH_ERASE opcode primitive)
//
// Flash-side only (DIR_ERASE never touches PSRAM/Port D at all --
// d_req stays low throughout, checked explicitly below), so no
// PSRAM stack needed, mirroring F1's minimal testbench style.
//
//   TEST 1 (happy path): a sector pre-poisoned with 0x33 is erased
//     and read back (independent flash_model.mem[] peek) as all
//     0xFF -- §8.2.18 p.56.
//   TEST 2 (adversarial §A.3): non-sector-aligned flash_addr -> err,
//     no SE ever attempted (flash_model.v's own alignment guard,
//     which would $fatal, never fires).
//   TEST 3: an ADJACENT sector, deliberately left poisoned, must
//     survive untouched -- confirms DIR_ERASE erases EXACTLY one
//     sector, not a wider or narrower range.
// ================================================================

module tb;

    localparam CLK_PERIOD = 12.5; // 80 MHz

    reg clk;
    reg rst;

    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD / 2.0) clk = ~clk;
    end

    wire mosi, miso, cs_n, sclk_w;

    reg          op_start;
    reg  [1:0]   op_dir;
    reg  [23:0]  flash_addr;
    reg  [22:0]  psram_addr;
    reg  [23:0]  len;
    wire         busy, done, err;

    wire d_req, d_wr;
    wire [22:0] d_addr;
    wire signed [7:0] d_wdata;
    reg  signed [7:0] d_rdata;
    reg  d_ready;

    localparam DIR_ERASE = 2'd2;

    flash_copy_engine #(
        .PSRAM_ADDR_WIDTH(23), .CLK_FREQ_MHZ(80), .SCLK_DIV(2)
    ) dut (
        .clk(clk), .rst(rst),
        .mosi(mosi), .miso(miso), .cs_n(cs_n), .sclk(sclk_w),
        .op_start(op_start), .op_dir(op_dir),
        .flash_addr(flash_addr), .psram_addr(psram_addr), .len(len),
        .busy(busy), .done(done), .err(err),
        .d_req(d_req), .d_wr(d_wr), .d_addr(d_addr), .d_wdata(d_wdata),
        .d_rdata(d_rdata), .d_ready(d_ready)
    );

    flash_model #(.DEPTH(32'h0002_0000), .TIME_SCALE(100000)) dut_flash (
        .sclk(sclk_w), .mosi(mosi), .miso(miso), .cs_n(cs_n)
    );

    // Port D must NEVER be requested by DIR_ERASE.
    integer d_req_count;
    always @(posedge clk) if (d_req) d_req_count = d_req_count + 1;

    integer errors;
    integer i;

    task automatic do_op(input [23:0] p_addr);
        integer wd;
        begin
            @(posedge clk);
            op_start   <= 1'b1;
            op_dir     <= DIR_ERASE;
            flash_addr <= p_addr;
            psram_addr <= 23'h0;
            len        <= 24'h0;
            @(posedge clk);
            op_start <= 1'b0;
            wd = 0;
            while (!done) begin
                @(posedge clk);
                wd = wd + 1;
                if (wd > 2_000_000) begin
                    $display("FATAL: do_op watchdog timeout");
                    $finish;
                end
            end
        end
    endtask

    task automatic check_byte(input [7:0] got, input [7:0] exp, input [255:0] label);
        begin
            if (got !== exp) begin
                $display("FAIL: %0s got=%02h exp=%02h", label, got, exp);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        errors = 0;
        d_req_count = 0;
        rst = 1'b1;
        op_start = 1'b0; op_dir = DIR_ERASE; flash_addr = 24'h0;
        psram_addr = 23'h0; len = 24'h0;
        d_rdata = 8'sd0; d_ready = 1'b0;

        repeat (5) @(posedge clk);
        rst = 1'b0;
        repeat (5) @(posedge clk);

        // ========================================================
        // TEST 1: happy path
        // ========================================================
        $display("--- TEST 1 starting ---");
        for (i = 0; i < 4096; i = i + 1)
            dut_flash.mem[24'h00A000 + i] = 8'h33;

        do_op(24'h00A000);
        if (err) begin $display("FAIL: TEST1 unexpected err"); errors = errors + 1; end

        for (i = 0; i < 4096; i = i + 1) begin
            if (dut_flash.mem[24'h00A000 + i] !== 8'hFF) begin
                $display("FAIL: TEST1 not fully erased at offset %0d, got=%02h", i, dut_flash.mem[24'h00A000+i]);
                errors = errors + 1;
                i = 4096;
            end
        end

        // ========================================================
        // TEST 2 (adversarial §A.3): unaligned flash_addr
        // ========================================================
        $display("--- TEST 2 starting ---");
        do_op(24'h00A100); // not a multiple of 0x1000
        if (!err) begin $display("FAIL: TEST2 expected err for unaligned erase, got none"); errors = errors + 1; end

        // ========================================================
        // TEST 3: adjacent sector untouched
        // ========================================================
        $display("--- TEST 3 starting ---");
        for (i = 0; i < 4096; i = i + 1)
            dut_flash.mem[24'h00B000 + i] = 8'h44; // sector right after the one erased in TEST1

        do_op(24'h00A000); // re-erase the SAME sector as TEST1 (already 0xFF, harmless)
        if (err) begin $display("FAIL: TEST3 unexpected err"); errors = errors + 1; end

        for (i = 0; i < 4096; i = i + 1)
            check_byte(dut_flash.mem[24'h00B000 + i], 8'h44, "TEST3 adjacent sector untouched");

        if (d_req_count != 0) begin
            $display("FAIL: DIR_ERASE issued %0d Port D request(s), expected 0", d_req_count);
            errors = errors + 1;
        end

        // ========================================================
        if (errors == 0)
            $display("ALL TESTS PASSED");
        else
            $display("FAILED: %0d error(s)", errors);

        $finish;
    end

    initial begin
        #50_000_000;
        $display("FATAL: global simulation timeout");
        $finish;
    end

endmodule
