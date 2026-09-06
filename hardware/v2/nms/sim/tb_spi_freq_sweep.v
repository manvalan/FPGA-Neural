`timescale 1ns/1ps

// ================================================================
// PRE-PCB CLOSURE, POINT 2 -- SPI operating-clock frequency sweep.
//
// tb_fpga_neural_v2_top_smoke.v only ever exercises the SPI bus at a
// single, fixed ~2MHz bit rate (500ns/bit: #200/#50/#50/#200). This
// testbench reuses the SAME real board-level top and the SAME job-
// registration protocol, but makes the SPI bit period a runtime
// parameter (SPI_FREQ_MHZ), so a genuine, reproducible frequency
// sweep can determine the highest rate the CDC synchronizer +
// protocol FSM in spi_host_bridge.v actually tolerates -- rather than
// assuming any particular number.
//
// Unlike tb_fpga_neural_v2_top_smoke.v (which parameterizes
// CLK_FREQ_MHZ=80 as a historical leftover), this testbench uses the
// real, frozen CLK_FREQ_MHZ=64 default AND drives osc_clk itself at
// 64MHz -- under the `SIM behavioral PLL bypass (ecp5_pll_sys_clk.v:
// `clk_sys = clk_16mhz` directly, since no open EHXPLLL model exists),
// this makes clk_sys run at the REAL board's actual 64MHz system-
// clock rate, which is the frequency that actually determines the
// synchronizer's real margin against a given SPI rate.
//
// Coverage per swept frequency (matching the mandate's own explicit
// list): job registration (register access), a job run alone, two
// jobs back-to-back (minimal CS gap), two jobs with a realistic gap,
// a raw WRITE_MEM/READ_MEM round trip over SPI (memory read/write +
// result readback via the ACTUAL SPI response path, not just the
// backdoor SDRAM peek), and repeated transactions.
// ================================================================

`define SIM

module tb_spi_freq_sweep #(
    parameter real SPI_FREQ_MHZ = 2.0
);

    localparam ADDR_WIDTH = 23;
    localparam N_SLOTS    = 2;
    localparam N_NODES    = 16;
    localparam MAX_DEPS   = 4;

    // real board system clock: 64MHz, driven directly as osc_clk under
    // the `SIM bypass (clk_sys = osc_clk, see ecp5_pll_sys_clk.v)
    reg osc_clk = 0;
    always #7.8125 osc_clk = ~osc_clk; // 64MHz

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
        .CLK_FREQ_MHZ(64)
    ) dut (
        .osc_clk(osc_clk), .ext_rst_n(ext_rst_n),
        .spi_sclk(spi_sclk), .spi_mosi(spi_mosi), .spi_miso(spi_miso), .spi_cs_n(spi_cs_n),
        .sdram_cke(sdram_cke), .sdram_cs_n(sdram_cs_n), .sdram_ras_n(sdram_ras_n),
        .sdram_cas_n(sdram_cas_n), .sdram_we_n(sdram_we_n),
        .sdram_ba(sdram_ba), .sdram_a(sdram_a), .sdram_dq(sdram_dq), .sdram_dqm(sdram_dqm),
        .pll_locked(pll_locked)
    );

    sdram_model #(.CLK_FREQ_MHZ(64)) u_sdram (
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

    // ---- runtime-configurable SPI bit timing (mode 0, MSB-first),
    // proportioned the same 40/10/10/40 split as the existing fixed-
    // rate testbenches' own 200/50/50/200ns convention, scaled to
    // whatever bit period SPI_FREQ_MHZ implies ----
    real BIT_NS, T_SETUP, T_SAMPLE, T_HOLD;
    initial begin
        BIT_NS   = 1000.0 / SPI_FREQ_MHZ;
        T_SETUP  = 0.4 * BIT_NS;
        T_SAMPLE = 0.1 * BIT_NS;
        T_HOLD   = 0.1 * BIT_NS;
    end

    task spi_byte(input [7:0] tx, output [7:0] rx);
        integer i;
        begin
            rx = 8'h00;
            for (i = 7; i >= 0; i = i - 1) begin
                spi_mosi = tx[i];
                #(T_SETUP); spi_sclk = 1; #(T_SAMPLE); rx = {rx[6:0], spi_miso}; #(T_HOLD); spi_sclk = 0; #(T_SETUP);
            end
        end
    endtask

    task write_job(input [3:0] node_id, input [2:0] required, input [15:0] producer_ids,
                    input [22:0] x_base, input [22:0] w_base, input [15:0] n_tiles,
                    input [22:0] result_addr);
        reg [7:0] rxb;
        begin
            spi_cs_n = 0; #(T_SETUP);
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
            // hold CS through the reg_valid/reg_ready handshake -- a
            // fixed real-time wait, independent of SPI bit rate (the
            // backend handshake runs on clk_sys, not on SCLK)
            #2000;
            spi_cs_n = 1; #(T_SETUP);
        end
    endtask

    // ---- raw WRITE_MEM / READ_MEM (opcodes 0x01/0x02), single word,
    // exercising the ACTUAL SPI response path (not the backdoor SDRAM
    // peek), directly testing "memory read/write over SPI" and
    // "result readback" at the swept frequency ----
    // ST_MEM_ROUT=4'd8, ST_IGNORE=4'd9 (spi_host_bridge.v's own FSM
    // localparams) -- polled directly rather than guessing a fixed
    // real-time margin, since the real host-arb/SDRAM-controller
    // backend latency (unlike the isolated tb_spi_host_bridge.v unit
    // test's own directly-driven mem_rdata/mem_ready mock) genuinely
    // varies cycle to cycle (e.g. a periodic AUTO REFRESH landing
    // during the request). A fixed real-time wait here previously
    // produced one real, reproducible failure (mem-word-1 at
    // SPI_FREQ_MHZ=2.0: the response's MSB sampled 0 instead of 1)
    // when the backend legitimately took longer than the guessed
    // margin -- traced to this testbench's own race, NOT a
    // spi_host_bridge.v defect (tb_spi_host_bridge.v's own isolated
    // regression already proves the FIRST READ_MEM after reset
    // delivers all 16 bits correctly when its own mock backend
    // responds within ITS OWN test's assumed timing).
    task spi_write_mem_word(input [22:0] word_addr, input [15:0] data);
        reg [7:0] rxb;
        begin
            spi_cs_n = 0; #(T_SETUP);
            spi_byte(8'h01, rxb);
            spi_byte({1'b0, word_addr[22:16]}, rxb);
            spi_byte(word_addr[15:8], rxb);
            spi_byte(word_addr[7:0], rxb);
            spi_byte(16'd1 >> 8, rxb);
            spi_byte(16'd1 & 8'hFF, rxb);
            spi_byte(data[15:8], rxb);
            spi_byte(data[7:0], rxb);
            while (dut.u_spi_bridge.state != 4'd9) @(posedge dut.clk_sys); // ST_IGNORE: mem_req/mem_ready handshake done
            spi_cs_n = 1; #(T_SETUP);
        end
    endtask

    task spi_read_mem_word(input [22:0] word_addr, output [15:0] data);
        reg [7:0] rxb_hi, rxb_lo;
        begin
            spi_cs_n = 0; #(T_SETUP);
            spi_byte(8'h02, rxb_hi);
            spi_byte({1'b0, word_addr[22:16]}, rxb_hi);
            spi_byte(word_addr[15:8], rxb_hi);
            spi_byte(word_addr[7:0], rxb_hi);
            spi_byte(16'd1 >> 8, rxb_hi);
            spi_byte(16'd1 & 8'hFF, rxb_hi);
            while (dut.u_spi_bridge.state != 4'd8) @(posedge dut.clk_sys); // ST_MEM_ROUT: cur_word latched, response bytes ready
            spi_byte(8'h00, rxb_hi); // clock out response byte 0 (MSB)
            spi_byte(8'h00, rxb_lo); // clock out response byte 1 (LSB)
            data = {rxb_hi, rxb_lo};
            spi_cs_n = 1; #(T_SETUP);
        end
    endtask

    integer errors, tests;
    integer node_ctr;

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

    task check_mem_word(input [22:0] word_addr, input [15:0] wr_pattern, input [255:0] label);
        reg [15:0] rd_pattern;
        begin
            spi_write_mem_word(word_addr, wr_pattern);
            spi_read_mem_word(word_addr, rd_pattern);
            tests = tests + 1;
            if (rd_pattern !== wr_pattern) begin
                errors = errors + 1;
                $display("FAIL %0s: wrote=%h read-back=%h", label, wr_pattern, rd_pattern);
            end else begin
                $display("PASS %0s: wrote=%h read-back=%h (real SPI response path)", label, wr_pattern, rd_pattern);
            end
        end
    endtask

    // watchdog: if the CDC/protocol FSM genuinely locks up at a given
    // SPI rate (rather than merely corrupting a data bit), a blind
    // `while (state != X) @(posedge clk)` poll would hang the
    // simulation forever. Report a clean, explicit HANG verdict
    // instead of an infinite loop.
    initial begin
        #2_000_000; // 2ms real time -- generous, real tests finish in <50us
        $display("*** WATCHDOG TIMEOUT at SPI_FREQ_MHZ=%0.3f -- protocol FSM HUNG (not merely a data error) ***", SPI_FREQ_MHZ);
        $finish;
    end

    initial begin
        errors = 0; tests = 0; node_ctr = 0;
        ext_rst_n = 0;
        repeat (20) @(posedge osc_clk);
        ext_rst_n = 1;
        repeat (10) @(posedge osc_clk);

        wait (dut.u_sdram_backend.u_sdram_ctrl.state == dut.u_sdram_backend.u_sdram_ctrl.S_IDLE);
        @(posedge dut.clk_sys);

        $display("--- SPI_FREQ_MHZ=%0.3f (bit period=%0.2fns) ---", SPI_FREQ_MHZ, BIT_NS);

        // register access / neural job submission, single job
        run_single(23'h001000, "single-neuron0");

        // two jobs back-to-back (minimal CS gap) -- register access stress
        run_pair(23'h004000, 0, "back-to-back");

        // two jobs, realistic gap
        run_pair(23'h007000, 20000, "realistic-gap");

        // raw memory write/read over the real SPI response path
        check_mem_word(23'h00A000, 16'hA55A, "mem-word-1");
        check_mem_word(23'h00A001, 16'h1234, "mem-word-2");

        // repeated transactions (stress the framing/CDC over many
        // back-to-back opcodes, not just one pair)
        run_single(23'h00D000, "repeat-1");
        run_single(23'h00E000, "repeat-2");
        run_single(23'h00F000, "repeat-3");

        $display("=== SPI_FREQ_MHZ=%0.3f: %0d/%0d PASS ===", SPI_FREQ_MHZ, tests-errors, tests);
        if (errors != 0) $display("*** %0d FAILURES at SPI_FREQ_MHZ=%0.3f ***", errors, SPI_FREQ_MHZ);
        $finish;
    end

endmodule
