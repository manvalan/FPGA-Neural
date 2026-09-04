`timescale 1ns/1ps

// ================================================================
// FLASH_SLOT_MANAGER TESTBENCH -- F5 raw block ops (op_code 4-6:
// OP_FLASH_READ_BLOCK / OP_FLASH_WRITE_BLOCK / OP_FLASH_ERASE),
// straight pass-through to the internal flash_copy_engine, no
// catalog/CRC involvement. Same real stack as flash_slot_manager_tb.v.
//
//   TEST 1: FLASH_READ_BLOCK, byte-exact, independent oracle (data
//     planted directly in flash_model.mem[]).
//   TEST 2: FLASH_WRITE_BLOCK, byte-exact, independent oracle
//     (direct flash_model.mem[] peek after the write).
//   TEST 3: FLASH_ERASE, independent oracle (direct peek, all 0xFF).
//   TEST 4 (adversarial §A.3): FLASH_ERASE on a non-sector-aligned
//     address -> err (forwarded from flash_copy_engine's own DIR_ERASE
//     bounds check, verified reaching this module's own `err` output).
// ================================================================

module tb;

    localparam CLK_PERIOD = 12.5;
    localparam ADDR_WIDTH = 23;

    reg clk, rst;
    initial begin clk = 1'b0; forever #(CLK_PERIOD/2.0) clk = ~clk; end

    wire mosi, miso, cs_n, sclk_w;

    reg          op_start;
    reg  [2:0]   op_code;
    reg  [3:0]   slot_id;
    reg  [23:0]  new_offset, new_length;
    reg  [7:0]   new_type;
    reg  [ADDR_WIDTH-1:0] ext_psram_addr;
    reg  [23:0]  ext_length;
    reg  [23:0]  raw_flash_addr;
    wire         busy, done, err;

    reg  [3:0]   cat_read_sel;
    wire [23:0]  cat_out_offset, cat_out_length;
    wire [7:0]   cat_out_type;
    wire         cat_out_valid;
    wire [31:0]  cat_out_crc;

    localparam OP_FLASH_READ_BLOCK  = 3'd4;
    localparam OP_FLASH_WRITE_BLOCK = 3'd5;
    localparam OP_FLASH_ERASE       = 3'd6;

    wire                   d_req, d_wr;
    wire [ADDR_WIDTH-1:0]  d_addr;
    wire signed [7:0]      d_wdata;
    wire signed [7:0]      d_rdata;
    wire                   d_ready;

    reg                    a_req, a_wr;
    reg  [ADDR_WIDTH-1:0]  a_addr;
    reg  signed [7:0]      a_wdata;
    wire signed [7:0]      a_rdata;
    wire                   a_ready;

    flash_slot_manager #(
        .PSRAM_ADDR_WIDTH(ADDR_WIDTH), .CLK_FREQ_MHZ(80), .SCLK_DIV(2),
        .CATALOG_PSRAM_ADDR(23'h000000)
    ) dut (
        .clk(clk), .rst(rst),
        .mosi(mosi), .miso(miso), .cs_n(cs_n), .sclk(sclk_w),
        .op_start(op_start), .op_code(op_code), .slot_id(slot_id),
        .new_offset(new_offset), .new_length(new_length), .new_type(new_type),
        .ext_psram_addr(ext_psram_addr), .ext_length(ext_length),
        .raw_flash_addr(raw_flash_addr),
        .busy(busy), .done(done), .err(err),
        .cat_read_sel(cat_read_sel),
        .cat_out_offset(cat_out_offset), .cat_out_length(cat_out_length),
        .cat_out_type(cat_out_type), .cat_out_valid(cat_out_valid), .cat_out_crc(cat_out_crc),
        .d_req(d_req), .d_wr(d_wr), .d_addr(d_addr), .d_wdata(d_wdata),
        .d_rdata(d_rdata), .d_ready(d_ready)
    );

    flash_model #(.DEPTH(32'h0002_0000), .TIME_SCALE(100000)) dut_flash (
        .sclk(sclk_w), .mosi(mosi), .miso(miso), .cs_n(cs_n)
    );

    wire                   arb_req, arb_wr;
    wire [ADDR_WIDTH-1:0]  arb_addr;
    wire signed [7:0]      arb_wdata, arb_rdata;
    wire                   arb_ready;

    mem_arbiter #(.ADDR_WIDTH(ADDR_WIDTH)) u_arbiter (
        .clk(clk), .rst(rst),
        .a_req(a_req), .a_wr(a_wr), .a_addr(a_addr), .a_wdata(a_wdata),
        .a_rdata(a_rdata), .a_ready(a_ready),
        .b_req(1'b0), .b_wr(1'b0), .b_addr({ADDR_WIDTH{1'b0}}), .b_wdata(8'sd0), .b_rdata(), .b_ready(),
        .c_req(1'b0), .c_wr(1'b0), .c_addr({ADDR_WIDTH{1'b0}}), .c_wdata(8'sd0), .c_rdata(), .c_ready(),
        .d_req(d_req), .d_wr(d_wr), .d_addr(d_addr), .d_wdata(d_wdata),
        .d_rdata(d_rdata), .d_ready(d_ready),
        .m_req(arb_req), .m_wr(arb_wr), .m_addr(arb_addr), .m_wdata(arb_wdata),
        .m_rdata(arb_rdata), .m_ready(arb_ready)
    );

    wire                    i8_req, i8_wr;
    wire [ADDR_WIDTH-1:0]   i8_addr;
    wire [15:0]             i8_wdata;
    wire                    i8_lb_n, i8_ub_n;
    wire [15:0]             i8_rdata;
    wire                    i8_ready;

    int8_memory_access #(.ADDR_WIDTH(ADDR_WIDTH)) u_i8 (
        .clk(clk), .rst(rst),
        .req(arb_req), .wr(arb_wr), .addr(arb_addr), .wdata(arb_wdata),
        .rdata(arb_rdata), .ready(arb_ready),
        .mem_req(i8_req), .mem_wr(i8_wr), .mem_addr(i8_addr), .mem_wdata(i8_wdata),
        .mem_lb_n(i8_lb_n), .mem_ub_n(i8_ub_n),
        .mem_rdata(i8_rdata), .mem_ready(i8_ready)
    );

    wire                    mi_req, mi_wr;
    wire [ADDR_WIDTH-1:0]   mi_addr;
    wire [15:0]             mi_wdata;
    wire                    mi_lb_n, mi_ub_n;
    wire [15:0]             mi_rdata;
    wire                    mi_ready;

    memory_interface #(.ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(16)) u_mi (
        .clk(clk), .rst(rst),
        .req(i8_req), .wr(i8_wr), .addr(i8_addr), .wdata(i8_wdata),
        .lb_n(i8_lb_n), .ub_n(i8_ub_n),
        .rdata(i8_rdata), .ready(i8_ready),
        .mem_req(mi_req), .mem_wr(mi_wr), .mem_addr(mi_addr), .mem_wdata(mi_wdata),
        .mem_lb_n(mi_lb_n), .mem_ub_n(mi_ub_n),
        .mem_rdata(mi_rdata), .mem_ready(mi_ready)
    );

    wire [ADDR_WIDTH-1:0] psram_a;
    wire [15:0]           psram_dq;
    wire                  psram_ce_n, psram_oe_n, psram_we_n, psram_lb_n, psram_ub_n, psram_zz_n;

    psram_controller #(.ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(16), .CLK_FREQ_MHZ(80)) u_psram_ctrl (
        .clk(clk), .rst(rst),
        .mem_req(mi_req), .mem_wr(mi_wr), .mem_addr(mi_addr), .mem_wdata(mi_wdata),
        .mem_lb_n(mi_lb_n), .mem_ub_n(mi_ub_n),
        .mem_rdata(mi_rdata), .mem_ready(mi_ready),
        .psram_a(psram_a), .psram_dq(psram_dq),
        .psram_ce_n(psram_ce_n), .psram_oe_n(psram_oe_n), .psram_we_n(psram_we_n),
        .psram_lb_n(psram_lb_n), .psram_ub_n(psram_ub_n), .psram_zz_n(psram_zz_n)
    );

    psram_model #(.ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(16), .DEPTH(16384)) u_psram (
        .clk(clk), .a(psram_a), .dq(psram_dq),
        .ce_n(psram_ce_n), .oe_n(psram_oe_n), .we_n(psram_we_n),
        .lb_n(psram_lb_n), .ub_n(psram_ub_n), .zz_n(psram_zz_n)
    );

    integer errors;
    integer i;
    reg [7:0] rb;

    task automatic do_op(
        input [2:0]  p_code,
        input [23:0] p_raw_flash_addr,
        input [ADDR_WIDTH-1:0] p_ext_psram_addr,
        input [23:0] p_ext_length
    );
        integer wd;
        begin
            @(posedge clk);
            op_start       <= 1'b1;
            op_code        <= p_code;
            raw_flash_addr <= p_raw_flash_addr;
            ext_psram_addr <= p_ext_psram_addr;
            ext_length     <= p_ext_length;
            @(posedge clk);
            op_start <= 1'b0;
            wd = 0;
            while (!done) begin
                @(posedge clk);
                wd = wd + 1;
                if (wd > 5_000_000) begin
                    $display("FATAL: do_op watchdog timeout");
                    $finish;
                end
            end
        end
    endtask

    task automatic psram_read_byte(input [ADDR_WIDTH-1:0] a, output [7:0] v);
        begin
            @(posedge clk);
            a_req <= 1'b1; a_wr <= 1'b0; a_addr <= a;
            @(posedge clk);
            a_req <= 1'b0;
            while (!a_ready) @(posedge clk);
            v = a_rdata; @(posedge clk);
        end
    endtask

    task automatic psram_write_byte(input [ADDR_WIDTH-1:0] a, input [7:0] v);
        begin
            @(posedge clk);
            a_req <= 1'b1; a_wr <= 1'b1; a_addr <= a; a_wdata <= $signed(v);
            @(posedge clk);
            a_req <= 1'b0;
            while (!a_ready) @(posedge clk);
            @(posedge clk);
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
        rst = 1'b1;
        op_start = 1'b0; op_code = 3'h0; slot_id = 4'h0;
        new_offset = 24'h0; new_length = 24'h0; new_type = 8'h0;
        ext_psram_addr = {ADDR_WIDTH{1'b0}}; ext_length = 24'h0; raw_flash_addr = 24'h0;
        cat_read_sel = 4'h0;
        a_req = 1'b0; a_wr = 1'b0; a_addr = {ADDR_WIDTH{1'b0}}; a_wdata = 8'sd0;

        repeat (5) @(posedge clk);
        rst = 1'b0;
        repeat (5) @(posedge clk);

        // ========================================================
        $display("--- TEST 1 starting ---");
        for (i = 0; i < 20; i = i + 1)
            dut_flash.mem[24'h00C000 + i] = 8'h90 + i[7:0];

        do_op(OP_FLASH_READ_BLOCK, 24'h00C000, 23'h001500, 24'd20);
        if (err) begin $display("FAIL: TEST1 unexpected err"); errors = errors + 1; end
        for (i = 0; i < 20; i = i + 1) begin
            psram_read_byte(23'h001500 + i, rb);
            check_byte(rb, 8'h90 + i[7:0], "TEST1 FLASH_READ_BLOCK byte-exact");
        end

        // ========================================================
        $display("--- TEST 2 starting ---");
        for (i = 0; i < 20; i = i + 1)
            psram_write_byte(23'h001600 + i, 8'hB0 + i[7:0]);

        do_op(OP_FLASH_WRITE_BLOCK, 24'h00D000, 23'h001600, 24'd20);
        if (err) begin $display("FAIL: TEST2 unexpected err"); errors = errors + 1; end
        for (i = 0; i < 20; i = i + 1)
            check_byte(dut_flash.mem[24'h00D000 + i], 8'hB0 + i[7:0], "TEST2 FLASH_WRITE_BLOCK vs independent flash peek");

        // ========================================================
        $display("--- TEST 3 starting ---");
        for (i = 0; i < 4096; i = i + 1)
            dut_flash.mem[24'h00E000 + i] = 8'h22;

        do_op(OP_FLASH_ERASE, 24'h00E000, {ADDR_WIDTH{1'b0}}, 24'h0);
        if (err) begin $display("FAIL: TEST3 unexpected err"); errors = errors + 1; end
        for (i = 0; i < 4096; i = i + 1) begin
            if (dut_flash.mem[24'h00E000 + i] !== 8'hFF) begin
                $display("FAIL: TEST3 not erased at offset %0d", i);
                errors = errors + 1;
                i = 4096;
            end
        end

        // ========================================================
        $display("--- TEST 4 starting ---");
        do_op(OP_FLASH_ERASE, 24'h00E100, {ADDR_WIDTH{1'b0}}, 24'h0); // not sector-aligned
        if (!err) begin $display("FAIL: TEST4 expected err for unaligned erase, got none"); errors = errors + 1; end

        // ========================================================
        if (errors == 0)
            $display("ALL TESTS PASSED");
        else
            $display("FAILED: %0d error(s)", errors);

        $finish;
    end

    initial begin
        #200_000_000;
        $display("FATAL: global simulation timeout");
        $finish;
    end

endmodule
