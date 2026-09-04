`timescale 1ns/1ps

// ================================================================
// FLASH_LATENCY_BENCH -- Phase F6 real-timing measurement
//
// NOT a pass/fail testbench -- a benchmark, matching the style of
// sim/graph_engine_bandwidth_tb.v (numbers reported, checked only
// against the datasheet's own cited values, not a design oracle).
//
// METHODOLOGY (declared per §A.5 -- "ogni numero misurato: con come
// e' stato misurato e contro cosa"):
//
//   Simulating the FULL real-time WIP wait (tSE=400ms / tPP=3ms MAX,
//   §9.6 p.90) with flash_copy_engine's actual RDSR poll loop running
//   at real SPI clock rates was ATTEMPTED FIRST and abandoned: at
//   real timing, one RDSR poll transaction takes on the order of a
//   microsecond, so covering a 400ms wait means on the order of
//   100,000+ discrete poll transactions, each many simulated clock
//   edges -- tens of millions of Icarus events, which did not finish
//   in reasonable wall-clock time (killed after >60s with no result).
//   This is a SIMULATOR PERFORMANCE limit, not a hardware one (real
//   silicon polling costs no wall-clock time at all) -- worth stating
//   explicitly rather than silently switching approach.
//
//   Approach actually used: measure the SPI-clock-bound "issue"
//   phase directly in simulation (accurate regardless of
//   flash_model.v's TIME_SCALE, since that parameter only scales the
//   POST-issue WIP-wait delay, not the bit-shift timing itself) --
//   stopping the clock the instant the flash model latches
//   pending_pp/pending_se (i.e. the command has been fully clocked in
//   and the flash has started its own internal write/erase) -- then
//   ADD the datasheet's own cited MAX duration for the wait itself.
//   This is the same total latency a real polling host would see,
//   decomposed into a directly-measured part (SPI overhead) and a
//   directly-cited part (flash-internal timing), rather than forcing
//   a single simulated number that costs more than it's worth to
//   obtain honestly.
//
//   One representative RDSR poll transaction's own SPI time (needed
//   once, to detect the eventual WIP=0) is computed the same way as
//   every other transaction below: opcode(8b)+data(8b) = 16 bits.
//
//   Representative operations (matching what the catalog design
//   actually produces, phase-plan §4/§9):
//     ERASE: one 4KB sector.
//     SAVE:  256 bytes (one Page Program, sector-aligned -- includes
//            its own internal erase, per F3's design).
//     LOAD:  4096 bytes (one sector's worth -- READ has NO WIP wait
//            at all, §8 intro p.24, so this number is purely SPI-
//            clock-rate-bound and needs no analytical addition).
// ================================================================

module tb;

    parameter CLK_FREQ_MHZ = 80; // overridden via -P from the command line

    localparam CLK_PERIOD_NS = 1000.0 / CLK_FREQ_MHZ;

    reg clk;
    reg rst;

    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD_NS / 2.0) clk = ~clk;
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

    localparam DIR_LOAD  = 2'd0;
    localparam DIR_SAVE  = 2'd1;
    localparam DIR_ERASE = 2'd2;

    flash_copy_engine #(
        .PSRAM_ADDR_WIDTH(23), .CLK_FREQ_MHZ(CLK_FREQ_MHZ), .SCLK_DIV(2)
    ) dut (
        .clk(clk), .rst(rst),
        .mosi(mosi), .miso(miso), .cs_n(cs_n), .sclk(sclk_w),
        .op_start(op_start), .op_dir(op_dir),
        .flash_addr(flash_addr), .psram_addr(psram_addr), .len(len),
        .busy(busy), .done(done), .err(err),
        .d_req(d_req), .d_wr(d_wr), .d_addr(d_addr), .d_wdata(d_wdata),
        .d_rdata(d_rdata), .d_ready(d_ready)
    );

    // Compressed TIME_SCALE (same 100000x as every other testbench in
    // this project) -- safe here because we stop measuring BEFORE the
    // scaled WIP-wait delay even starts (see do_op_until_issued below);
    // the datasheet's real MAX duration is added back analytically.
    flash_model #(.DEPTH(32'h0002_0000), .TIME_SCALE(100000)) dut_flash (
        .sclk(sclk_w), .mosi(mosi), .miso(miso), .cs_n(cs_n)
    );

    reg [7:0] fake_ram [0:8191];
    always @(posedge clk) begin
        d_ready <= d_req;
        if (d_req && d_wr) fake_ram[d_addr[12:0]] <= d_wdata;
        d_rdata <= fake_ram[d_addr[12:0]];
    end

    // Measures from op_start to the moment the flash model's own
    // pending_pp/pending_se latches (command fully issued, WIP just
    // started) -- NOT to `done` (which would include the compressed,
    // not-representative-of-real-hardware TIME_SCALE'd wait).
    task automatic do_op_until_issued(
        input [1:0] p_dir, input [23:0] p_flash_addr, input [23:0] p_len, output real ns_elapsed
    );
        real t0;
        begin
            t0 = $realtime;
            @(posedge clk);
            op_start   <= 1'b1;
            op_dir     <= p_dir;
            flash_addr <= p_flash_addr;
            psram_addr <= 23'h0;
            len        <= p_len;
            @(posedge clk);
            op_start <= 1'b0;
            @(posedge dut_flash.pending_se or posedge dut_flash.pending_pp);
            ns_elapsed = $realtime - t0;
            // Let this op actually finish (compressed timing, fast)
            // before starting the next one.
            while (!done) @(posedge clk);
        end
    endtask

    // LOAD has no WIP wait at all -- measure straight to `done`.
    task automatic do_op_full(
        input [1:0] p_dir, input [23:0] p_flash_addr, input [23:0] p_len, output real ns_elapsed
    );
        real t0;
        begin
            t0 = $realtime;
            @(posedge clk);
            op_start   <= 1'b1;
            op_dir     <= p_dir;
            flash_addr <= p_flash_addr;
            psram_addr <= 23'h0;
            len        <= p_len;
            @(posedge clk);
            op_start <= 1'b0;
            while (!done) @(posedge clk);
            ns_elapsed = $realtime - t0;
        end
    endtask

    real t_erase_issue, t_save_issue, t_load_full;
    real rdsr_poll_ns;
    real erase_total, save_total;

    // One representative RDSR poll transaction: opcode(8b)+data(8b)
    // = 16 bits, same bit-clock rate as every other transaction here
    // -- computed from the SAME CLK_PERIOD_NS/SCLK_DIV=2 this bench
    // itself uses (2*SCLK_DIV=4 clk cycles/bit, spi_flash_master.v's
    // own divider), not a separate assumption.
    initial rdsr_poll_ns = 16.0 * 4.0 * CLK_PERIOD_NS;

    initial begin
        rst = 1'b1;
        op_start = 1'b0; op_dir = DIR_LOAD; flash_addr = 24'h0; psram_addr = 23'h0; len = 24'h0;
        d_ready = 1'b0; d_rdata = 8'sd0;

        repeat (5) @(posedge clk);
        rst = 1'b0;
        repeat (5) @(posedge clk);

        do_op_until_issued(DIR_ERASE, 24'h010000, 24'd0, t_erase_issue);
        do_op_until_issued(DIR_SAVE,  24'h011000, 24'd256, t_save_issue);
        do_op_full(DIR_LOAD, 24'h010000, 24'd4096, t_load_full);

        // Datasheet MAX (worst-case) values, §9.6 p.90, already cited
        // in sim/flash_model.v: tSE_MAX=400ms, tPP_MAX=3ms.
        erase_total = t_erase_issue + 400_000_000.0 + rdsr_poll_ns;
        save_total  = t_save_issue  + 400_000_000.0 + rdsr_poll_ns  // SAVE's own internal erase
                                     + 3_000_000.0   + rdsr_poll_ns; // then its Page Program

        $display("CLK_FREQ_MHZ=%0d SCLK_DIV=2:", CLK_FREQ_MHZ);
        $display("  RDSR poll transaction        = %0.3f us (measured bit-clock rate)", rdsr_poll_ns/1000.0);
        $display("  ERASE issue (WREN+SE, measured) = %0.3f us", t_erase_issue/1000.0);
        $display("  ERASE total (issue + tSE_MAX + 1 poll, tSE_MAX cited \302\247A.5) = %0.3f ms", erase_total/1_000_000.0);
        $display("  SAVE issue (WREN+SE, measured, save's own erase phase) = %0.3f us", t_save_issue/1000.0);
        $display("  SAVE total (256B page, incl. its own erase; issue + tSE_MAX + tPP_MAX + 2 polls) = %0.3f ms", save_total/1_000_000.0);
        $display("  LOAD total (4096B, measured directly -- READ has no WIP wait) = %0.3f ms, effective bandwidth = %0.3f MB/s",
            t_load_full/1_000_000.0, 4096.0 / (t_load_full/1000.0));

        $finish;
    end

    initial begin
        #100_000_000; // compressed-scale ops finish in well under this
        $display("FATAL: unexpected timeout");
        $finish;
    end

endmodule
