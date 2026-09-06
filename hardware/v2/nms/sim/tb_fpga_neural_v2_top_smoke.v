`timescale 1ns/1ps

// ================================================================
// FPGA-Neural V2 -- board-level top INTEGRATION SMOKE TEST (STEP20)
//
// Proves the NEW STEP20 wiring end-to-end: real SPI transactions (bit-
// banged, mode 0) drive job registration THROUGH spi_host_bridge.v,
// through the real compute+memory pipeline (byte-for-byte identical
// to the already-verified STEP19 nms_neural_multiprocessor_sdram_
// unified.v internals) via the NEW 2-level host-arb AR arbitration,
// down to the SAME single sdram_unified_backend/sdram_controller/
// AS4C4M16SA-6TIN chain -- checked against a real, backdoor-peeked
// SDRAM result. This is NOT a replacement for the STEP19 full 256-
// neuron D-Stress regression (already reconfirmed bit-exact using the
// trusted tool, see errors.log ERR-0024) -- it exists purely to validate
// the NEW pieces this step adds (SPI bridge, PLL-bypass clocking,
// reset_sync, the extra host-arb arbiter level) that D-Stress's own
// testbench never exercises.
//
// Weights/activations are preloaded via the same backdoor poke
// convention already used by tb_nms_dstress_sdram_unified.v (direct
// writes into u_sdram.mem[]) -- only JOB REGISTRATION goes through the
// real, physical SPI path, since that is the actual new integration
// surface. `SIM bypasses the (unsimulatable) EHXPLLL primitive inside
// ecp5_pll_sys_clk.v with a direct pass-through, per that module's own
// documented, declared limitation.
//
// CURRENT STATUS (STEP20): FAILING, real, disclosed -- see errors.log
// ERR-0025 Part B. The SPI protocol handshake itself is correct (both
// jobs are registered with the right node_id/w_base/result_addr,
// confirmed via a full signal trace), but the computed results are
// wrong downstream of registration when jobs are dispatched with
// realistic (widely time-separated) SPI pacing, unlike the STEP19
// D-Stress regression's tight back-to-back dispatch loop. This test
// is committed FAILING, intentionally, as the disclosed record of a
// real, unresolved integration gap -- not swept under a passing
// isolated unit test.
// ================================================================

`define SIM

module tb_fpga_neural_v2_top_smoke;

    localparam ADDR_WIDTH = 23;
    localparam N_SLOTS    = 2;
    localparam N_NODES    = 16;
    localparam MAX_DEPS   = 4;

    reg osc_clk = 0;
    always #31.25 osc_clk = ~osc_clk; // 16MHz (bypassed 1:1 to clk_sys under `SIM)

    reg ext_rst_n = 0;

    reg  spi_sclk = 0, spi_mosi = 0, spi_cs_n = 1;
    wire spi_miso;

    wire sdram_cke, sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n;
    wire [1:0]  sdram_ba;
    wire [11:0] sdram_a;
    wire [15:0] sdram_dq;
    wire [1:0]  sdram_dqm;
    wire pll_locked;

    fpga_neural_v2_top #(
        .ADDR_WIDTH(ADDR_WIDTH), .N_SLOTS(N_SLOTS), .N_NODES(N_NODES), .MAX_DEPS(MAX_DEPS),
        .CLK_FREQ_MHZ(80)
    ) dut (
        .osc_clk(osc_clk), .ext_rst_n(ext_rst_n),
        .spi_sclk(spi_sclk), .spi_mosi(spi_mosi), .spi_miso(spi_miso), .spi_cs_n(spi_cs_n),
        .sdram_cke(sdram_cke), .sdram_cs_n(sdram_cs_n), .sdram_ras_n(sdram_ras_n),
        .sdram_cas_n(sdram_cas_n), .sdram_we_n(sdram_we_n),
        .sdram_ba(sdram_ba), .sdram_a(sdram_a), .sdram_dq(sdram_dq), .sdram_dqm(sdram_dqm),
        .pll_locked(pll_locked)
    );

    sdram_model #(.CLK_FREQ_MHZ(80)) u_sdram (
        .clk(dut.clk_sys), .cke(sdram_cke), .cs_n(sdram_cs_n), .ras_n(sdram_ras_n),
        .cas_n(sdram_cas_n), .we_n(sdram_we_n), .ba(sdram_ba), .a(sdram_a),
        .dq(sdram_dq), .dqm(sdram_dqm)
    );

    function automatic signed [7:0] relu_sat(input signed [31:0] acc);
        begin
            if (acc < 0) relu_sat = 8'sd0;
            else if (acc > 127) relu_sat = 8'sd127;
            else relu_sat = acc[7:0];
        end
    endfunction

    task poke_byte(input [ADDR_WIDTH-1:0] byte_addr, input signed [7:0] val);
        reg [21:0] word_addr;
        begin
            word_addr = byte_addr[ADDR_WIDTH-1:1];
            if (byte_addr[0] == 1'b0) u_sdram.mem[word_addr][7:0]  = val;
            else                      u_sdram.mem[word_addr][15:8] = val;
        end
    endtask

    function automatic signed [7:0] peek_byte(input [ADDR_WIDTH-1:0] byte_addr);
        reg [21:0] word_addr;
        begin
            word_addr = byte_addr[ADDR_WIDTH-1:1];
            peek_byte = (byte_addr[0] == 1'b0) ? u_sdram.mem[word_addr][7:0] : u_sdram.mem[word_addr][15:8];
        end
    endfunction

    // ---- SPI master BFM (matches spi_host_bridge.v's own protocol,
    // same realistic 500ns-bit-period convention as tb_spi_host_
    // bridge.v -- see that module's header on the CDC margin reason) ----
    task spi_byte(input [7:0] tx, output [7:0] rx);
        integer i;
        begin
            rx = 8'h00;
            for (i = 7; i >= 0; i = i - 1) begin
                spi_mosi = tx[i];
                #200; spi_sclk = 1; #50; rx = {rx[6:0], spi_miso}; #50; spi_sclk = 0; #200;
            end
        end
    endtask

    task write_job(input [3:0] node_id, input [2:0] required, input [15:0] producer_ids,
                    input [22:0] x_base, input [22:0] w_base, input [15:0] n_tiles,
                    input [22:0] result_addr);
        reg [7:0] rxb;
        begin
            spi_cs_n = 0; #20;
            spi_byte(8'h10, rxb);
            spi_byte({4'b0, node_id}, rxb);
            spi_byte({5'b0, required}, rxb);
            spi_byte(producer_ids[15:8], rxb);
            spi_byte(producer_ids[7:0], rxb);
            spi_byte({1'b0, x_base[22:16]}, rxb);
            spi_byte(x_base[15:8], rxb);
            spi_byte(x_base[7:0], rxb);
            spi_byte({1'b0, w_base[22:16]}, rxb);
            spi_byte(w_base[15:8], rxb);
            spi_byte(w_base[7:0], rxb);
            spi_byte(n_tiles[15:8], rxb);
            spi_byte(n_tiles[7:0], rxb);
            spi_byte({1'b0, result_addr[22:16]}, rxb);
            spi_byte(result_addr[15:8], rxb);
            spi_byte(result_addr[7:0], rxb);
            // hold CS through the reg_valid/reg_ready handshake (may
            // need a few extra idle clocks if the target slot is busy)
            #20000;
            spi_cs_n = 1; #200;
        end
    endtask

    integer n, k, t, errors, tests;
    reg signed [31:0] acc;
    reg signed [7:0]  golden, real_y;
    localparam N_TILES = 2;

    initial begin
        errors = 0; tests = 0;
        ext_rst_n = 0;
        repeat (20) @(posedge osc_clk);
        ext_rst_n = 1;
        repeat (10) @(posedge osc_clk);

        // preload: 2 independent single-tile (P_IN=8) neurons sharing
        // one activation vector, at x_base=0x001000, weights at
        // 0x002000 (neuron0) / 0x002010 (neuron1), results at 0x003000
        for (k = 0; k < 8; k = k + 1) poke_byte(23'h001000 + k, k[7:0] + 1);
        for (n = 0; n < 2; n = n + 1)
            for (k = 0; k < 8; k = k + 1)
                poke_byte(23'h002000 + n*16 + k, ((n+k) % 4) + 1);
        poke_byte(23'h003000, 8'sd0);
        poke_byte(23'h003001, 8'sd0);

        wait (dut.u_sdram_backend.u_sdram_ctrl.state == dut.u_sdram_backend.u_sdram_ctrl.S_IDLE);
        @(posedge dut.clk_sys);

        write_job(4'd0, 3'd0, 16'h0000, 23'h001000, 23'h002000, 16'd1, 23'h003000);
        write_job(4'd1, 3'd0, 16'h0000, 23'h001000, 23'h002010, 16'd1, 23'h003001);

        // wait for both results to land (generous margin)
        repeat (3000) @(posedge dut.clk_sys);

        for (n = 0; n < 2; n = n + 1) begin
            acc = 0;
            for (t = 0; t < N_TILES/N_TILES; t = t + 1) ; // no-op, single tile
            for (k = 0; k < 8; k = k + 1)
                acc = acc + peek_byte(23'h001000 + k) * peek_byte(23'h002000 + n*16 + k);
            golden = relu_sat(acc);
            real_y = peek_byte(23'h003000 + n);
            tests = tests + 1;
            if (real_y !== golden) begin
                errors = errors + 1;
                $display("FAIL smoke neuron %0d: real=%0d golden=%0d", n, real_y, golden);
            end else begin
                $display("PASS smoke neuron %0d: real=%0d golden=%0d", n, real_y, golden);
            end
        end

        $display("=== tb_fpga_neural_v2_top_smoke: %0d/%0d PASS ===", tests-errors, tests);
        if (errors != 0) $display("*** %0d FAILURES ***", errors);
        $finish;
    end

endmodule
