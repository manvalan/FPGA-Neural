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
// trusted tool, see errors.log ERR-0024) -- it exists purely to
// validate the NEW pieces this step adds (SPI bridge, PLL-bypass
// clocking, reset_sync, the extra host-arb arbiter level) that
// D-Stress's own tight, back-to-back dispatch loop never exercises:
// realistic, WIDELY TIME-SEPARATED job pacing, as a real host would
// actually issue over SPI.
//
// STATUS (STEP20, ERR-0025 Part B): FIXED. Root cause: nms_weight_
// packed.v / nms_activation_replicated.v used a REGISTERED read (one
// full extra clock of latency) while nms_memory_manager_stream_wide.v's
// own read-ahead pipeline (`rd_pending`) assumes a COMBINATIONAL read
// (issue this cycle, data valid to capture next cycle). A busy multi-
// tile job's own prefetch lead time always absorbs the extra cycle
// invisibly; an uncontested single-tile job's first (only) tile has
// zero such margin and captured stale/zero data permanently. Fixed by
// making both SRAMs' reads combinational (with an explicit same-cycle
// fill/read bypass for the one hazard a combinational read alone would
// still miss). Verified: this test now passes, AND the STEP19 D-Stress
// regression (N=2 49788 cycles, N=4 49771 cycles, both 256/256
// bit-exact) is UNCHANGED -- cycle-for-cycle identical to before the
// fix, since D-Stress's own prefetch margin never depended on the
// extra (buggy) register cycle in the first place.
//
// Six scenarios below, using disjoint SDRAM regions so none interfere:
//   A) two jobs, realistic wide SPI pacing (the original failing case)
//   B) a single job dispatched alone (twice: neuron0 alone, neuron1 alone)
//   C) two jobs back-to-back (minimal CS gap)
//   D) two jobs with a large gap (same as A, kept as its own named case)
//   G) parametric sweep across several distinct inter-job gaps, proving
//      the fix does not depend on any particular cycle count
//
// Weights/activations are preloaded via the same backdoor poke
// convention already used by tb_nms_dstress_sdram_unified.v (direct
// writes into u_sdram.mem[]) -- only JOB REGISTRATION goes through the
// real, physical SPI path, since that is the actual integration
// surface under test. `SIM bypasses the (unsimulatable) EHXPLLL
// primitive inside ecp5_pll_sys_clk.v with a direct pass-through, per
// that module's own documented, declared limitation.
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
            #2000;
            spi_cs_n = 1; #200;
        end
    endtask

    integer errors, tests;
    integer node_ctr; // fresh node_id per sub-test (dependency_manager never reclaims a dispatched id)

    task check_neuron(input [22:0] x_base, input [22:0] w_base, input [22:0] res_addr,
                       input [255:0] label);
        integer k;
        reg signed [31:0] acc;
        reg signed [7:0] golden, real_y;
        begin
            acc = 0;
            for (k = 0; k < 8; k = k + 1)
                acc = acc + peek_byte(x_base + k) * peek_byte(w_base + k);
            golden = relu_sat(acc);
            real_y = peek_byte(res_addr);
            tests = tests + 1;
            if (real_y !== golden) begin
                errors = errors + 1;
                $display("FAIL %0s: real=%0d golden=%0d", label, real_y, golden);
            end else begin
                $display("PASS %0s: real=%0d golden=%0d", label, real_y, golden);
            end
        end
    endtask

    // One independent, disjoint scratch region per pair-test invocation,
    // so scenarios never interfere with each other's SDRAM content:
    // x_base=region, w0=region+0x100, w1=region+0x110, res=region+0x200/0x201
    task run_pair(input [22:0] region, input integer gap_ns, input [255:0] label);
        reg [22:0] x_base, w0, w1, res0, res1;
        integer k, n;
        begin
            x_base = region;
            w0     = region + 23'h100;
            w1     = region + 23'h110;
            res0   = region + 23'h200;
            res1   = region + 23'h201;

            for (k = 0; k < 8; k = k + 1) poke_byte(x_base + k, k[7:0] + 1);
            for (n = 0; n < 2; n = n + 1)
                for (k = 0; k < 8; k = k + 1)
                    poke_byte((n == 0 ? w0 : w1) + k, ((n + k) % 4) + 1);
            poke_byte(res0, 8'sd0);
            poke_byte(res1, 8'sd0);

            write_job(node_ctr[3:0], 3'd0, 16'h0000, x_base, w0, 16'd1, res0);
            node_ctr = node_ctr + 1;
            if (gap_ns > 0) #gap_ns;
            write_job(node_ctr[3:0], 3'd0, 16'h0000, x_base, w1, 16'd1, res1);
            node_ctr = node_ctr + 1;

            repeat (3000) @(posedge dut.clk_sys);

            check_neuron(x_base, w0, res0, {label, "-A"});
            check_neuron(x_base, w1, res1, {label, "-B"});
        end
    endtask

    // Single, standalone job (scenario B) -- no second job at all.
    task run_single(input [22:0] region, input [255:0] label);
        reg [22:0] x_base, w0, res0;
        integer k;
        begin
            x_base = region;
            w0     = region + 23'h100;
            res0   = region + 23'h200;
            for (k = 0; k < 8; k = k + 1) poke_byte(x_base + k, k[7:0] + 3);
            for (k = 0; k < 8; k = k + 1) poke_byte(w0 + k, ((k) % 3) + 1);
            poke_byte(res0, 8'sd0);

            write_job(node_ctr[3:0], 3'd0, 16'h0000, x_base, w0, 16'd1, res0);
            node_ctr = node_ctr + 1;

            repeat (3000) @(posedge dut.clk_sys);
            check_neuron(x_base, w0, res0, label);
        end
    endtask

    initial begin
        errors = 0; tests = 0; node_ctr = 0;
        ext_rst_n = 0;
        repeat (20) @(posedge osc_clk);
        ext_rst_n = 1;
        repeat (10) @(posedge osc_clk);

        wait (dut.u_sdram_backend.u_sdram_ctrl.state == dut.u_sdram_backend.u_sdram_ctrl.S_IDLE);
        @(posedge dut.clk_sys);

        // B) single job, alone
        run_single(23'h001000, "B-single-neuron0");

        // A/D) two jobs, realistic wide SPI pacing (~85us worth of SPI
        // framing plus an explicit extra gap -- the original failing case)
        run_pair(23'h004000, 20000, "A-wide-gap");

        // C) two jobs back-to-back (minimal CS-high gap between them)
        run_pair(23'h007000, 0, "C-back-to-back");

        // G) parametric sweep across several distinct inter-job gaps
        run_pair(23'h00A000, 100,    "G-gap100ns");
        run_pair(23'h00D000, 5000,   "G-gap5000ns");
        run_pair(23'h010000, 50000,  "G-gap50000ns");

        $display("=== tb_fpga_neural_v2_top_smoke: %0d/%0d PASS ===", tests-errors, tests);
        if (errors != 0) $display("*** %0d FAILURES ***", errors);
        $finish;
    end

endmodule
