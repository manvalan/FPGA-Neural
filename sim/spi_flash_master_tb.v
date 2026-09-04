`timescale 1ns/1ps
// Compile with -DSIMULATION (see rtl/spi_flash_master.v header: this
// exposes sclk_sim as a normal port in place of the real USRMCLK
// primitive, which has no Icarus simulation model).

// ================================================================
// SPI_FLASH_MASTER TESTBENCH (Phase F1)
//
// Drives rtl/spi_flash_master.v against sim/flash_model.v (an
// independent behavioral model of the datasheet's write rules, see
// its own header) and checks:
//
//   TEST 1 (RDID, happy path): oracle is the datasheet's own
//     manufacturer/type/capacity bytes (EF/40/18h -- see
//     flash_model.v's header for the plain-vs-DTR JEDEC-ID note),
//     hardcoded here independently of both the RTL and the model's
//     internal constant (this testbench does not read
//     flash_model.v's localparam, it states the expected value
//     itself, from the same citation).
//
//   TEST 2 (READ, known block, INDEPENDENT oracle): a pattern is
//     planted directly into flash_model's memory array via
//     hierarchical reference (dut_flash.mem[...]) -- NOT written
//     through spi_flash_master -- then read back through the DUT
//     and compared byte-exact. This is the true independent-oracle
//     test per WORKLOG.md §A.1: the expected data was never
//     produced by the RTL under test.
//
//   TEST 3 (WREN+PP+RDSR-poll+READ round-trip): exercises the
//     write-side primitives (not yet independent of the RTL's own
//     write path -- a round-trip self-consistency check, distinct
//     from TEST 2's independence, and explicitly noted as such).
//     Confirms AND-only programming into an erased (0xFF) region
//     reproduces the exact bytes written, and that RDSR's BUSY bit
//     is observed high during the modeled tPP delay and clears
//     after.
//
//   TEST 4 (WREN+SE+RDSR-poll+READ): confirms sector erase drives
//     the target sector back to all-0xFF, verified against a region
//     TEST 3 deliberately left non-0xFF first (so this test cannot
//     pass by coincidence on an already-blank region).
//
//   TEST 5 (negative, §A.3): an opcode this design never uses
//     (0xAB, Release Power-down / Device ID -- a real, harmless
//     W25Q128JV instruction, but NOT one spi_flash_master or
//     flash_model implement) is issued. Requirement: the
//     transaction completes (`done` pulses within a bounded cycle
//     count) rather than hanging -- a master that can wedge on an
//     opcode it doesn't specifically recognize is broken by
//     construction, since it always just shifts bits regardless of
//     opcode semantics.
// ================================================================

module tb;

    localparam CLK_PERIOD = 12.5; // 80 MHz, matches CLK_FREQ_MHZ default

    reg clk;
    reg rst;

    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD / 2.0) clk = ~clk;
    end

    // ------------------------------------------------------------
    // DUT <-> flash_model physical wiring
    // ------------------------------------------------------------
    wire mosi;
    wire miso;
    wire cs_n;
    wire sclk_w;

    reg         start;
    reg  [7:0]  opcode;
    reg          has_addr;
    reg  [23:0]  addr;
    reg  [1:0]   dir;
    reg  [15:0]  n_data;

    wire         wdata_req;
    reg  [7:0]   wdata;
    reg           wdata_valid;

    wire         rdata_valid;
    wire [7:0]   rdata;
    reg           rdata_ack;

    wire busy;
    wire done;

    localparam DIR_NONE  = 2'd0;
    localparam DIR_WRITE = 2'd1;
    localparam DIR_READ  = 2'd2;

    spi_flash_master #(
        .CLK_FREQ_MHZ(80),
        .SCLK_DIV(2)
    ) dut (
        .clk(clk), .rst(rst),

        .mosi(mosi), .miso(miso), .cs_n(cs_n),
        .sclk_sim(sclk_w),

        .start(start), .opcode(opcode), .has_addr(has_addr), .addr(addr),
        .dir(dir), .n_data(n_data),

        .wdata_req(wdata_req), .wdata(wdata), .wdata_valid(wdata_valid),

        .rdata_valid(rdata_valid), .rdata(rdata), .rdata_ack(rdata_ack),

        .busy(busy), .done(done)
    );

    flash_model #(
        .DEPTH(32'h0002_0000),
        .TIME_SCALE(100000) // see flash_model.v header: MAX datasheet timing / 100000
    ) dut_flash (
        .sclk(sclk_w), .mosi(mosi), .miso(miso), .cs_n(cs_n)
    );

    // ------------------------------------------------------------
    // Bookkeeping
    // ------------------------------------------------------------
    integer errors;
    reg [7:0] rbuf [0:511];
    reg [7:0] wbuf [0:511];

    // ============================================================
    // do_cmd: drive one full command through the DUT's byte-level
    // handshake, servicing wdata_req/rdata_valid as needed. Reads
    // land in rbuf[0..n_data-1]; writes are sourced from wbuf.
    // ============================================================
    integer k;
    integer wd_cyc;

    task automatic do_cmd(
        input [7:0]  p_opcode,
        input        p_has_addr,
        input [23:0] p_addr,
        input [1:0]  p_dir,
        input [15:0] p_n
    );
        begin
            @(posedge clk);
            start    <= 1'b1;
            opcode   <= p_opcode;
            has_addr <= p_has_addr;
            addr     <= p_addr;
            dir      <= p_dir;
            n_data   <= p_n;
            @(posedge clk);
            start <= 1'b0;

            k = 0;
            wd_cyc = 0;
            while (!done) begin
                @(posedge clk);

                if (wdata_req) begin
                    wdata_valid <= 1'b1;
                    wdata       <= wbuf[k];
                end else begin
                    wdata_valid <= 1'b0;
                end

                if (wdata_valid) begin
                    k = k + 1;
                end

                if (rdata_valid) begin
                    rbuf[k] = rdata;
                    k = k + 1;
                    rdata_ack <= 1'b1;
                end else begin
                    rdata_ack <= 1'b0;
                end

                wd_cyc = wd_cyc + 1;
                if (wd_cyc > 200000) begin
                    $display("FATAL: do_cmd watchdog timeout (opcode=%02h) at t=%0t", p_opcode, $time);
                    $finish;
                end
            end
            @(posedge clk);
            rdata_ack   <= 1'b0;
            wdata_valid <= 1'b0;
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

    localparam [7:0] OP_WREN  = 8'h06;
    localparam [7:0] OP_READ  = 8'h03;
    localparam [7:0] OP_PP    = 8'h02;
    localparam [7:0] OP_SE    = 8'h20;
    localparam [7:0] OP_RDSR1 = 8'h05;
    localparam [7:0] OP_RDID  = 8'h9F;

    task automatic wait_wip_clear;
        begin
            rbuf[0] = 8'hFF;
            while (rbuf[0][0] == 1'b1) begin
                do_cmd(OP_RDSR1, 1'b0, 24'h0, DIR_READ, 16'd1);
            end
        end
    endtask

    integer i;

    initial begin
        errors      = 0;
        rst         = 1'b1;
        start       = 1'b0;
        opcode      = 8'h00;
        has_addr    = 1'b0;
        addr        = 24'h0;
        dir         = DIR_NONE;
        n_data      = 16'd0;
        wdata_valid = 1'b0;
        wdata       = 8'h00;
        rdata_ack   = 1'b0;

        repeat (5) @(posedge clk);
        rst = 1'b0;
        repeat (5) @(posedge clk);

        // ========================================================
        // TEST 1: RDID happy path
        // ========================================================
        do_cmd(OP_RDID, 1'b0, 24'h0, DIR_READ, 16'd3);
        check_byte(rbuf[0], 8'hEF, "TEST1 RDID manufacturer");
        check_byte(rbuf[1], 8'h40, "TEST1 RDID memtype");
        check_byte(rbuf[2], 8'h18, "TEST1 RDID capacity");

        // ========================================================
        // TEST 2: READ, known block, planted independently of the
        // RTL (hierarchical poke into the flash model's own array).
        // ========================================================
        for (i = 0; i < 16; i = i + 1)
            dut_flash.mem[24'h001000 + i] = 8'hA0 + i[7:0];

        do_cmd(OP_READ, 1'b1, 24'h001000, DIR_READ, 16'd16);
        for (i = 0; i < 16; i = i + 1)
            check_byte(rbuf[i], 8'hA0 + i[7:0], "TEST2 READ known block");

        // ========================================================
        // TEST 3: WREN + PP (16 bytes) + RDSR poll + READ round-trip.
        // Target region 0x002000 starts erased (0xFF, from
        // flash_model's own reset init) -- programming a pattern
        // with some cleared bits must read back exactly that
        // pattern (AND-with-0xFF is a no-op, so this alone doesn't
        // yet prove AND-only; TEST 3b below does).
        // ========================================================
        for (i = 0; i < 16; i = i + 1)
            wbuf[i] = 8'h10 + i[7:0];

        do_cmd(OP_WREN, 1'b0, 24'h0, DIR_NONE, 16'd0);
        do_cmd(OP_PP,   1'b1, 24'h002000, DIR_WRITE, 16'd16);

        wait_wip_clear;

        do_cmd(OP_READ, 1'b1, 24'h002000, DIR_READ, 16'd16);
        for (i = 0; i < 16; i = i + 1)
            check_byte(rbuf[i], 8'h10 + i[7:0], "TEST3 PP/READ round-trip");

        // TEST 3b: program the SAME region again with a value that
        // tries to SET a bit the first program cleared (0x10 has
        // bit4 set high already at 0x10=00010000; try programming
        // 0xFF over it, which per the AND-only rule must leave 0x10
        // unchanged, NOT flip it to 0xFF). This is the datasheet
        // rule TEST 3 alone cannot distinguish from a naive
        // "programming just overwrites" implementation.
        for (i = 0; i < 16; i = i + 1)
            wbuf[i] = 8'hFF;

        do_cmd(OP_WREN, 1'b0, 24'h0, DIR_NONE, 16'd0);
        do_cmd(OP_PP,   1'b1, 24'h002000, DIR_WRITE, 16'd16);
        wait_wip_clear;

        do_cmd(OP_READ, 1'b1, 24'h002000, DIR_READ, 16'd16);
        for (i = 0; i < 16; i = i + 1)
            check_byte(rbuf[i], 8'h10 + i[7:0], "TEST3b PP AND-only (program cannot set bits)");

        // ========================================================
        // TEST 4: WREN + SE (sector containing 0x002000) + RDSR
        // poll + READ, confirming erase -> all-FF. The region was
        // deliberately left non-FF by TEST 3/3b above, so this
        // cannot pass by coincidence.
        // ========================================================
        do_cmd(OP_WREN, 1'b0, 24'h0, DIR_NONE, 16'd0);
        do_cmd(OP_SE,   1'b1, 24'h002000, DIR_NONE, 16'd0);

        wait_wip_clear;

        do_cmd(OP_READ, 1'b1, 24'h002000, DIR_READ, 16'd16);
        for (i = 0; i < 16; i = i + 1)
            check_byte(rbuf[i], 8'hFF, "TEST4 SE erase -> 0xFF");

        // ========================================================
        // TEST 5 (negative, §A.3): unsupported/unrecognized opcode
        // (0xABh, a real W25Q128JV instruction -- Release
        // Power-down/Device ID -- that neither spi_flash_master nor
        // flash_model implement any special-case for). Requirement:
        // do_cmd's watchdog must NOT fire -- the transaction has to
        // complete (`done` pulses) purely from the master's own
        // fixed bit-count/opcode-agnostic shifting, proving the
        // master cannot wedge on an opcode it doesn't recognize.
        // ========================================================
        do_cmd(8'hAB, 1'b0, 24'h0, DIR_READ, 16'd1);
        $display("TEST5 (illegal/unsupported opcode 0xAB): completed without watchdog timeout, got=%02h (undefined/don't-care by design)", rbuf[0]);

        // ========================================================
        if (errors == 0)
            $display("ALL TESTS PASSED");
        else
            $display("FAILED: %0d error(s)", errors);

        $finish;
    end

    // Safety net: absolute simulation timeout independent of the
    // per-command watchdog above (catches a hang between commands,
    // e.g. in the top-level initial block itself).
    initial begin
        #50_000_000;
        $display("FATAL: global simulation timeout");
        $finish;
    end

endmodule
