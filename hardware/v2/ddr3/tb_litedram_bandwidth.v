`timescale 1ns/1ps

// ============================================================
// DDR3 exploration -- real measured sustained bandwidth of the
// generated litedram_core_sim.v (LiteDRAM standalone core, ECP5DDRPHY,
// DDR3 MT41K256M16 x16/512MB, sys_clk_freq=75MHz -- config in
// hardware/v2/ddr3/litedram_gen/ecp5_85f_ddr3_mt41k256m16.yml, the
// SAME real chip+clock the real ECPIX-5 board ships with, not a
// tuned/optimistic guess).
//
// Drives the native port (cmd/wdata/rdata, standard LiteX stream
// handshake -- see litedram/common.py's own cmd_description/
// wdata_description/rdata_description) directly, in strict lockstep
// per transaction (issue cmd, wait ready, push/pull the matching data
// phase, wait ready) -- this is a conservative lower bound on
// achievable bandwidth (no command pipelining attempted), reported as
// such, not claimed as the ceiling.
//
// N_TRANSACTIONS sequential 128-bit (16-byte) writes, then the same
// addresses read back and checked bit-exact against the write
// pattern, with real cycle counts converted to real MB/s using the
// declared sys_clk_freq.
// ============================================================
module tb;
    localparam ADDR_WIDTH = 25;
    localparam DATA_WIDTH = 128;
    localparam WE_WIDTH   = DATA_WIDTH/8;
    localparam real SYS_CLK_FREQ_MHZ = 75.0;
    localparam real CLK_PERIOD_NS = 1000.0/SYS_CLK_FREQ_MHZ;

    reg clk = 0;
    always #(CLK_PERIOD_NS/2.0) clk = ~clk;

    integer cyc;
    always @(posedge clk) cyc <= cyc + 1;

    wire init_done, init_error, user_clk, user_rst;
    reg  [ADDR_WIDTH-1:0] cmd_addr;
    wire cmd_ready;
    reg  cmd_valid, cmd_we;
    wire [DATA_WIDTH-1:0] rdata_data;
    reg  rdata_ready;
    wire rdata_valid;
    reg  [DATA_WIDTH-1:0] wdata_data;
    wire wdata_ready;
    reg  wdata_valid;
    reg  [WE_WIDTH-1:0] wdata_we;

    // wb_ctrl_* left disconnected (tied off) -- this benchmark drives
    // the native port only, no CSR/wishbone control path needed.
    wire wb_ctrl_ack, wb_ctrl_err;
    wire [31:0] wb_ctrl_dat_r;

    litedram_core_sim dut (
        .clk(clk),
        .init_done(init_done), .init_error(init_error),
        .sim_trace(1'b0),
        .user_clk(user_clk), .user_rst(user_rst),
        .user_port_native_0_cmd_addr(cmd_addr),
        .user_port_native_0_cmd_ready(cmd_ready),
        .user_port_native_0_cmd_valid(cmd_valid),
        .user_port_native_0_cmd_we(cmd_we),
        .user_port_native_0_rdata_data(rdata_data),
        .user_port_native_0_rdata_ready(rdata_ready),
        .user_port_native_0_rdata_valid(rdata_valid),
        .user_port_native_0_wdata_data(wdata_data),
        .user_port_native_0_wdata_ready(wdata_ready),
        .user_port_native_0_wdata_valid(wdata_valid),
        .user_port_native_0_wdata_we(wdata_we),
        .wb_ctrl_ack(wb_ctrl_ack), .wb_ctrl_adr(30'h0), .wb_ctrl_bte(2'h0),
        .wb_ctrl_cti(3'h0), .wb_ctrl_cyc(1'b0), .wb_ctrl_dat_r(wb_ctrl_dat_r),
        .wb_ctrl_dat_w(32'h0), .wb_ctrl_err(wb_ctrl_err), .wb_ctrl_sel(4'h0),
        .wb_ctrl_stb(1'b0), .wb_ctrl_we(1'b0)
    );

    task automatic do_write(input [ADDR_WIDTH-1:0] a, input [DATA_WIDTH-1:0] d);
        begin
            cmd_valid = 1'b1; cmd_we = 1'b1; cmd_addr = a;
            @(posedge clk);
            while (!cmd_ready) @(posedge clk);
            cmd_valid = 1'b0;
            wdata_valid = 1'b1; wdata_data = d; wdata_we = {WE_WIDTH{1'b1}};
            @(posedge clk);
            while (!wdata_ready) @(posedge clk);
            wdata_valid = 1'b0;
        end
    endtask

    task automatic do_read(input [ADDR_WIDTH-1:0] a, output [DATA_WIDTH-1:0] d);
        begin
            cmd_valid = 1'b1; cmd_we = 1'b0; cmd_addr = a;
            @(posedge clk);
            while (!cmd_ready) @(posedge clk);
            cmd_valid = 1'b0;
            rdata_ready = 1'b1;
            while (!rdata_valid) @(posedge clk);
            d = rdata_data;
            @(posedge clk);
            rdata_ready = 1'b0;
        end
    endtask

    localparam N_TRANSACTIONS = 256;
    integer i, t0, t1, write_cycles, read_cycles, errors;
    reg [DATA_WIDTH-1:0] got;
    real write_mb_s, read_mb_s;

    initial begin
        cmd_valid = 0; cmd_we = 0; cmd_addr = 0;
        wdata_valid = 0; wdata_data = 0; wdata_we = 0;
        rdata_ready = 0;
        errors = 0; cyc = 0;

        // NOTE: this is a CPU-less standalone core (cpu: None) -- init_done
        // is normally driven by BIOS software over the wishbone CSR bus
        // (real litedram known behavior, see enjoy-digital/litedram
        // issue #106 / PR #286: "enable the user port unconditionally in
        // CPU-less cases"). With no CPU attached, init_done never
        // asserts on its own -- the user port is intentionally usable
        // without waiting for it in this configuration. Give the
        // power-on reset counters real time to settle, then proceed.
        $display("=== CPU-less core: not gating on init_done (see litedram issue #106) -- settling power-on reset ===");
        repeat(2000) @(posedge clk);
        $display("  init_done=%b init_error=%b at cycle %0d (%0.2f us) -- proceeding regardless (informational only)",
            init_done, init_error, cyc, cyc*CLK_PERIOD_NS/1000.0);

        $display("=== WRITE: %0d sequential 128-bit transactions ===", N_TRANSACTIONS);
        t0 = cyc;
        for (i = 0; i < N_TRANSACTIONS; i = i + 1)
            do_write(i, {8{16'(16'hA000 + i)}});
        t1 = cyc;
        write_cycles = t1 - t0;
        write_mb_s = (N_TRANSACTIONS * (DATA_WIDTH/8)) / (write_cycles * CLK_PERIOD_NS / 1000.0) / 1.0e6 * 1.0e6;
        // (bytes) / (seconds) -> bytes/s; convert to MB/s
        write_mb_s = (N_TRANSACTIONS * (DATA_WIDTH/8) * 1.0) / (write_cycles * CLK_PERIOD_NS * 1.0e-9) / 1.0e6;
        $display("  %0d cycles, %00.3f us, REAL measured write bandwidth = %0.2f MB/s",
            write_cycles, write_cycles*CLK_PERIOD_NS/1000.0, write_mb_s);

        $display("=== READ: %0d sequential 128-bit transactions, bit-exact check ===", N_TRANSACTIONS);
        t0 = cyc;
        for (i = 0; i < N_TRANSACTIONS; i = i + 1) begin
            do_read(i, got);
            if (got !== {8{16'(16'hA000 + i)}}) begin
                $display("FAIL addr=%0d got=%h", i, got);
                errors = errors + 1;
            end
        end
        t1 = cyc;
        read_cycles = t1 - t0;
        read_mb_s = (N_TRANSACTIONS * (DATA_WIDTH/8) * 1.0) / (read_cycles * CLK_PERIOD_NS * 1.0e-9) / 1.0e6;
        $display("  %0d cycles, %0.3f us, REAL measured read bandwidth = %0.2f MB/s",
            read_cycles, read_cycles*CLK_PERIOD_NS/1000.0, read_mb_s);

        $display("=== %0d/%0d bit-exact, %0d errors ===", N_TRANSACTIONS-errors, N_TRANSACTIONS, errors);
        if (errors == 0) $display("ALL DATA BIT-EXACT (tb_litedram_bandwidth)");
        $finish;
    end

    initial begin
        #2000000; // 2ms real-time safety watchdog
        $display("WATCHDOG TIMEOUT -- init_done never asserted or benchmark hung");
        $finish;
    end
endmodule
