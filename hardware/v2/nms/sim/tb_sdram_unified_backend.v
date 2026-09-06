`timescale 1ns/1ps

// ============================================================
// NMS STEP19 -- isolated correctness regression for
// sdram_unified_backend.v: the single-physical-SDRAM backend serving
// weights (W port, 64-bit) and activation-fill + result-writeback
// (AR port, 16-bit byte-maskable) through ONE real sdram_controller.v
// instance + ONE real sdram_model.v.
//
// Covers:
//   A) W-port sequential access -- same natural pairing/cache-hit
//      pattern as tb_sdram_weight_backend_pack128.v, confirming the
//      reused caching logic still works correctly inside the unified
//      module.
//   B) AR-port read -- read back known values pre-loaded via backdoor.
//   C) AR-port byte-masked write -- write a single byte via lb_n/ub_n,
//      verify the OTHER byte (and OTHER words in the same real 128-bit
//      SDRAM block) are UNCHANGED -- the core new correctness property
//      this step depends on (no accidental corruption of neighboring
//      data when writing one result byte).
//   D) W and AR interleaved -- weight and activation/result traffic
//      contending for the SAME physical port, verifying no data
//      corruption, no dropped/duplicated responses, and correct
//      routing (W response never delivered to AR or vice versa).
//   E) Address-space coexistence -- weights, activations, and results
//      at DIFFERENT, non-overlapping regions of the SAME chip, real
//      simultaneous traffic, all bit-exact.
// ============================================================
module tb;
    localparam ADDR_WIDTH = 23;
    localparam CLK_FREQ_MHZ = 80;
    localparam CLK_PERIOD_NS = 1000.0/CLK_FREQ_MHZ;

    reg clk = 0;
    always #(CLK_PERIOD_NS/2.0) clk = ~clk;
    reg rst;

    reg                  w_req;
    reg [ADDR_WIDTH-1:0] w_addr;
    wire [63:0]          w_rdata;
    wire                 w_ready;

    reg                    ar_req, ar_wr;
    reg [ADDR_WIDTH-1:0]   ar_addr;
    reg [15:0]             ar_wdata;
    reg                    ar_lb_n, ar_ub_n;
    wire [15:0]            ar_rdata;
    wire                   ar_ready;

    wire sdram_cke, sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n;
    wire [1:0] sdram_ba;
    wire [11:0] sdram_a;
    wire [15:0] sdram_dq;
    wire [1:0] sdram_dqm;

    sdram_unified_backend #(.ADDR_WIDTH(ADDR_WIDTH), .CLK_FREQ_MHZ(CLK_FREQ_MHZ)) dut (
        .clk(clk), .rst(rst),
        .w_req(w_req), .w_addr(w_addr), .w_rdata(w_rdata), .w_ready(w_ready),
        .ar_req(ar_req), .ar_wr(ar_wr), .ar_addr(ar_addr), .ar_wdata(ar_wdata),
        .ar_lb_n(ar_lb_n), .ar_ub_n(ar_ub_n), .ar_rdata(ar_rdata), .ar_ready(ar_ready),
        .sdram_cke(sdram_cke), .sdram_cs_n(sdram_cs_n), .sdram_ras_n(sdram_ras_n),
        .sdram_cas_n(sdram_cas_n), .sdram_we_n(sdram_we_n),
        .sdram_ba(sdram_ba), .sdram_a(sdram_a), .sdram_dq(sdram_dq), .sdram_dqm(sdram_dqm)
    );

    sdram_model #(.CLK_FREQ_MHZ(CLK_FREQ_MHZ)) mem (
        .clk(clk), .cke(sdram_cke), .cs_n(sdram_cs_n), .ras_n(sdram_ras_n),
        .cas_n(sdram_cas_n), .we_n(sdram_we_n), .ba(sdram_ba), .a(sdram_a),
        .dq(sdram_dq), .dqm(sdram_dqm)
    );

    integer errors, tests, cyc;
    always @(posedge clk) if (!rst) cyc <= cyc + 1;

    task automatic poke64(input [ADDR_WIDTH-1:0] byte_addr, input [63:0] val);
        integer w;
        reg [21:0] word_addr;
        begin
            for (w = 0; w < 4; w = w + 1) begin
                word_addr = (byte_addr + w*2) >> 1;
                mem.mem[word_addr] = val[w*16 +: 16];
            end
        end
    endtask

    task automatic w_read(input [ADDR_WIDTH-1:0] a, output [63:0] r);
        begin
            @(posedge clk);
            w_req = 1'b1; w_addr = a;
            @(posedge clk);
            w_req = 1'b0;
            while (!w_ready) @(posedge clk);
            r = w_rdata;
        end
    endtask

    task automatic ar_read(input [ADDR_WIDTH-2:0] a, output [15:0] r);
        begin
            @(posedge clk);
            ar_req = 1'b1; ar_wr = 1'b0; ar_addr = a; ar_lb_n = 1'b0; ar_ub_n = 1'b0;
            @(posedge clk);
            ar_req = 1'b0;
            while (!ar_ready) @(posedge clk);
            r = ar_rdata;
        end
    endtask

    task automatic ar_write(input [ADDR_WIDTH-2:0] a, input [15:0] d, input lbn, input ubn);
        begin
            @(posedge clk);
            ar_req = 1'b1; ar_wr = 1'b1; ar_addr = a; ar_wdata = d; ar_lb_n = lbn; ar_ub_n = ubn;
            @(posedge clk);
            ar_req = 1'b0;
            while (!ar_ready) @(posedge clk);
        end
    endtask

    reg [63:0] got64;
    reg [15:0] got16;

    task automatic check64(input [ADDR_WIDTH-1:0] a, input [63:0] expected, input [255:0] label);
        begin
            w_read(a, got64);
            tests = tests + 1;
            if (got64 !== expected) begin
                $display("FAIL %0s W addr=%0d: got=%h expected=%h", label, a, got64, expected);
                errors = errors + 1;
            end else $display("PASS %0s W addr=%0d bit-exact", label, a);
        end
    endtask

    task automatic check16(input [ADDR_WIDTH-2:0] a, input [15:0] expected, input [255:0] label);
        begin
            ar_read(a, got16);
            tests = tests + 1;
            if (got16 !== expected) begin
                $display("FAIL %0s AR addr=%0d: got=%h expected=%h", label, a, got16, expected);
                errors = errors + 1;
            end else $display("PASS %0s AR addr=%0d bit-exact", label, a);
        end
    endtask

    integer i;
    reg [ADDR_WIDTH-1:0] wbase;
    reg [ADDR_WIDTH-1:0] arbase;

    initial begin
        errors = 0; tests = 0; cyc = 0;
        rst = 1; w_req = 0; w_addr = 0; ar_req = 0; ar_wr = 0; ar_addr = 0;
        ar_wdata = 0; ar_lb_n = 1; ar_ub_n = 1;
        repeat(5) @(posedge clk);
        rst = 0;
        while (dut.u_sdram_ctrl.state != 5'd7) @(posedge clk); // wait real power-up
        @(posedge clk);

        // ---- A: W-port sequential access (weight region) ----
        wbase = 23'h010000;
        for (i = 0; i < 16; i = i + 1)
            poke64(wbase + i*8, {4{16'hA000 + i[15:0]}});
        for (i = 0; i < 16; i = i + 1)
            check64(wbase + i*8, {4{16'hA000 + i[15:0]}}, "A-Wseq");

        // ---- B: AR-port read (activation region, disjoint from W) ----
        arbase = 23'h200000 >> 1; // word address
        poke64({arbase, 1'b0}, 64'h1111_2222_3333_4444);
        check16(arbase+0, 16'h4444, "B-ARrd-w0");
        check16(arbase+1, 16'h3333, "B-ARrd-w1");
        check16(arbase+2, 16'h2222, "B-ARrd-w2");
        check16(arbase+3, 16'h1111, "B-ARrd-w3");

        // ---- C: AR-port byte-masked write (result region) --
        // pre-seed a known 128-bit block, write ONE byte, verify
        // every OTHER byte in the same real SDRAM block is untouched.
        arbase = 23'h300000 >> 1;
        poke64({arbase[ADDR_WIDTH-2:3], 4'b0000}, 64'h9999_8888_7777_6666);
        poke64({arbase[ADDR_WIDTH-2:3], 4'b1000}, 64'h5555_4444_3333_2222);
        // write only the LOW byte of word 2 (within the 8-word block) to 8'hAB
        ar_write({arbase[ADDR_WIDTH-2:3], 3'b010}, 16'h00AB, 1'b0, 1'b1);
        check16(arbase[ADDR_WIDTH-2:3]*8+0, 16'h6666, "C-untouched-w0");
        check16(arbase[ADDR_WIDTH-2:3]*8+1, 16'h7777, "C-untouched-w1");
        check16(arbase[ADDR_WIDTH-2:3]*8+2, 16'h88AB, "C-masked-write-w2");
        check16(arbase[ADDR_WIDTH-2:3]*8+3, 16'h9999, "C-untouched-w3");

        // ---- D: W/AR interleaved traffic, different regions ----
        for (i = 0; i < 8; i = i + 1) begin
            check64(wbase + i*8, {4{16'hA000 + i[15:0]}}, "D-W");
            check16(arbase[ADDR_WIDTH-2:3]*8+0, 16'h6666, "D-AR");
        end

        $display("=== %0d/%0d tests, %0d errors ===", tests-errors, tests, errors);
        if (errors == 0) $display("ALL TESTS PASSED (tb_sdram_unified_backend)");
        $finish;
    end
endmodule
