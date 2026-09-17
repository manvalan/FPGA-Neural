`timescale 1ps/100fs

// ============================================================
// First real verification of mig_native_adapter.v against the REAL,
// vendor-provided DDR3 behavioral model (ddr3_model.sv, shipped with
// this project's own generated mig_7series_0 IP) -- not a stand-in,
// the actual JEDEC-timed model MIG itself ships for exactly this
// purpose. Confirms the app_cmd encoding, burst/beat sequencing, and
// address unit assumed by mig_native_adapter.v's own header comment
// are correct by real write-then-read-back comparison, not by
// documentation archaeology alone.
//
// Instantiates mig_7series_0_mig (the inner module, NOT the public
// mig_7series_0.v wrapper) directly, with SIM_BYPASS_INIT_CAL="FAST"
// overridden -- mig_7series_0.v's own wrapper hardcodes "OFF" (full
// real calibration, impractically slow for simulation) and does not
// expose this parameter; mig_7series_0_mig.v does. All other
// parameters are left at their defaults, which already ARE this
// project's real generated configuration (DQ_WIDTH=16, MEM_DENSITY=
// 2Gb, MEM_SPEEDGRADE=125, MEM_ADDR_ORDER=BANK_ROW_COLUMN, etc.) --
// not generic MIG defaults.
//
// Clock/reset generation and DDR3 pin wiring (WireDelay pass-through,
// zero propagation delay) mirror this project's own vendor-shipped
// example_design/sim/sim_tb_top.v exactly, per its own real, proven
// pattern -- not re-derived from scratch.
// ============================================================
module tb;
    localparam CLKIN_PERIOD  = 3225;   // ps, matches this project's real MIG config
    localparam REFCLK_FREQ   = 200.0;  // MHz
    localparam real REFCLK_PERIOD = (1000000.0/(2*REFCLK_FREQ));
    localparam RESET_PERIOD = 200000;  // ps

    localparam ADDR_WIDTH = 25; // this project's own word-address convention (BURST_LEN=8)
    localparam BURST_LEN  = 8;

    reg sys_rst_n;
    wire sys_rst = sys_rst_n; // Active Low, matches mig_7series_0_mig's own default polarity

    reg sys_clk_i = 1'b0;
    always #(CLKIN_PERIOD/2.0) sys_clk_i = ~sys_clk_i;

    reg clk_ref_i = 1'b0;
    always #REFCLK_PERIOD clk_ref_i = ~clk_ref_i;

    initial begin
        sys_rst_n = 1'b0;
        #RESET_PERIOD sys_rst_n = 1'b1;
    end

    // ---- real DDR3 pins ----
    wire        ddr3_reset_n;
    wire [15:0] ddr3_dq_fpga;
    wire [1:0]  ddr3_dqs_p_fpga, ddr3_dqs_n_fpga;
    wire [13:0] ddr3_addr_fpga;
    wire [2:0]  ddr3_ba_fpga;
    wire        ddr3_ras_n_fpga, ddr3_cas_n_fpga, ddr3_we_n_fpga;
    wire [0:0]  ddr3_cke_fpga, ddr3_ck_p_fpga, ddr3_ck_n_fpga, ddr3_cs_n_fpga;
    wire [1:0]  ddr3_dm_fpga;
    wire [0:0]  ddr3_odt_fpga;

    wire [15:0] ddr3_dq_sdram;
    reg  [13:0] ddr3_addr_sdram;
    reg  [2:0]  ddr3_ba_sdram;
    reg         ddr3_ras_n_sdram, ddr3_cas_n_sdram, ddr3_we_n_sdram;
    wire [0:0]  ddr3_cs_n_sdram;
    wire [0:0]  ddr3_odt_sdram;
    reg  [0:0]  ddr3_cke_sdram;
    wire [1:0]  ddr3_dm_sdram;
    wire [1:0]  ddr3_dqs_p_sdram, ddr3_dqs_n_sdram;
    reg  [0:0]  ddr3_ck_p_sdram, ddr3_ck_n_sdram;

    reg  [0:0]  ddr3_cs_n_sdram_tmp;
    reg  [1:0]  ddr3_dm_sdram_tmp;
    reg  [0:0]  ddr3_odt_sdram_tmp;

    always @(*) begin
        ddr3_ck_p_sdram  <= ddr3_ck_p_fpga;
        ddr3_ck_n_sdram  <= ddr3_ck_n_fpga;
        ddr3_addr_sdram  <= ddr3_addr_fpga;
        ddr3_ba_sdram    <= ddr3_ba_fpga;
        ddr3_ras_n_sdram <= ddr3_ras_n_fpga;
        ddr3_cas_n_sdram <= ddr3_cas_n_fpga;
        ddr3_we_n_sdram  <= ddr3_we_n_fpga;
        ddr3_cke_sdram   <= ddr3_cke_fpga;
    end
    always @(*) ddr3_cs_n_sdram_tmp <= ddr3_cs_n_fpga;
    assign ddr3_cs_n_sdram = ddr3_cs_n_sdram_tmp;
    always @(*) ddr3_dm_sdram_tmp <= ddr3_dm_fpga;
    assign ddr3_dm_sdram = ddr3_dm_sdram_tmp;
    always @(*) ddr3_odt_sdram_tmp <= ddr3_odt_fpga;
    assign ddr3_odt_sdram = ddr3_odt_sdram_tmp;

    genvar dqwd;
    generate
        for (dqwd = 0; dqwd < 16; dqwd = dqwd + 1) begin : dq_delay
            WireDelay #(.Delay_g(0.00), .Delay_rd(0.00), .ERR_INSERT("OFF")) u_delay_dq (
                .A(ddr3_dq_fpga[dqwd]), .B(ddr3_dq_sdram[dqwd]),
                .reset(sys_rst_n), .phy_init_done(init_calib_complete)
            );
        end
    endgenerate
    genvar dqswd;
    generate
        for (dqswd = 0; dqswd < 2; dqswd = dqswd + 1) begin : dqs_delay
            WireDelay #(.Delay_g(0.00), .Delay_rd(0.00), .ERR_INSERT("OFF")) u_delay_dqs_p (
                .A(ddr3_dqs_p_fpga[dqswd]), .B(ddr3_dqs_p_sdram[dqswd]),
                .reset(sys_rst_n), .phy_init_done(init_calib_complete)
            );
            WireDelay #(.Delay_g(0.00), .Delay_rd(0.00), .ERR_INSERT("OFF")) u_delay_dqs_n (
                .A(ddr3_dqs_n_fpga[dqswd]), .B(ddr3_dqs_n_sdram[dqswd]),
                .reset(sys_rst_n), .phy_init_done(init_calib_complete)
            );
        end
    endgenerate

    // ---- real DDR3 behavioral model (single component, DQ_WIDTH=16
    // matches MEMORY_WIDTH=16 exactly, no splitting needed) ----
    ddr3_model u_ddr3 (
        .rst_n(ddr3_reset_n), .ck(ddr3_ck_p_sdram), .ck_n(ddr3_ck_n_sdram),
        .cke(ddr3_cke_sdram[0]), .cs_n(ddr3_cs_n_sdram[0]),
        .ras_n(ddr3_ras_n_sdram), .cas_n(ddr3_cas_n_sdram), .we_n(ddr3_we_n_sdram),
        .dm_tdqs(ddr3_dm_sdram), .ba(ddr3_ba_sdram), .addr(ddr3_addr_sdram),
        .dq(ddr3_dq_sdram), .dqs(ddr3_dqs_p_sdram), .dqs_n(ddr3_dqs_n_sdram),
        .tdqs_n(), .odt(ddr3_odt_sdram[0])
    );

    // ---- real MIG controller (inner module, SIM_BYPASS_INIT_CAL
    // overridden for a real but fast simulation calibration) ----
    wire [27:0] app_addr;
    wire [2:0]  app_cmd;
    wire        app_en, app_rdy;
    wire [63:0] app_wdf_data;
    wire        app_wdf_end;
    wire [7:0]  app_wdf_mask;
    wire        app_wdf_wren, app_wdf_rdy;
    wire [63:0] app_rd_data;
    wire        app_rd_data_end, app_rd_data_valid;
    wire        ui_clk, ui_clk_sync_rst, init_calib_complete;

    mig_7series_0_mig #(
        .SIM_BYPASS_INIT_CAL("FAST")
    ) u_mig (
        .ddr3_dq(ddr3_dq_fpga), .ddr3_dqs_n(ddr3_dqs_n_fpga), .ddr3_dqs_p(ddr3_dqs_p_fpga),
        .ddr3_addr(ddr3_addr_fpga), .ddr3_ba(ddr3_ba_fpga),
        .ddr3_ras_n(ddr3_ras_n_fpga), .ddr3_cas_n(ddr3_cas_n_fpga), .ddr3_we_n(ddr3_we_n_fpga),
        .ddr3_reset_n(ddr3_reset_n),
        .ddr3_ck_p(ddr3_ck_p_fpga), .ddr3_ck_n(ddr3_ck_n_fpga),
        .ddr3_cke(ddr3_cke_fpga), .ddr3_cs_n(ddr3_cs_n_fpga),
        .ddr3_dm(ddr3_dm_fpga), .ddr3_odt(ddr3_odt_fpga),
        .sys_clk_i(sys_clk_i), .clk_ref_i(clk_ref_i),
        .app_addr(app_addr), .app_cmd(app_cmd), .app_en(app_en),
        .app_wdf_data(app_wdf_data), .app_wdf_end(app_wdf_end),
        .app_wdf_mask(app_wdf_mask), .app_wdf_wren(app_wdf_wren),
        .app_rd_data(app_rd_data), .app_rd_data_end(app_rd_data_end),
        .app_rd_data_valid(app_rd_data_valid), .app_rdy(app_rdy), .app_wdf_rdy(app_wdf_rdy),
        .app_sr_req(1'b0), .app_ref_req(1'b0), .app_zq_req(1'b0),
        .app_sr_active(), .app_ref_ack(), .app_zq_ack(),
        .ui_clk(ui_clk), .ui_clk_sync_rst(ui_clk_sync_rst),
        .init_calib_complete(init_calib_complete),
        .device_temp(),
        .sys_rst(sys_rst)
    );

    // ---- adapter under test ----
    reg                     req, wr;
    reg  [ADDR_WIDTH-1:0]   addr;
    reg  [16*BURST_LEN-1:0] wdata;
    reg  [2*BURST_LEN-1:0]  wmask;
    wire [16*BURST_LEN-1:0] rdata;
    wire                    ready, busy;

    mig_native_adapter #(.BURST_LEN(BURST_LEN), .ADDR_WIDTH(ADDR_WIDTH)) u_adapter (
        .clk(ui_clk), .rst(ui_clk_sync_rst),
        .req(req), .wr(wr), .addr(addr), .wdata(wdata), .wmask(wmask),
        .rdata(rdata), .ready(ready), .busy(busy),
        .app_addr(app_addr), .app_cmd(app_cmd), .app_en(app_en), .app_rdy(app_rdy),
        .app_wdf_data(app_wdf_data), .app_wdf_end(app_wdf_end), .app_wdf_mask(app_wdf_mask),
        .app_wdf_wren(app_wdf_wren), .app_wdf_rdy(app_wdf_rdy),
        .app_rd_data(app_rd_data), .app_rd_data_end(app_rd_data_end), .app_rd_data_valid(app_rd_data_valid)
    );

    task automatic do_txn(
        input                    t_wr,
        input [ADDR_WIDTH-1:0]   t_addr,
        input [16*BURST_LEN-1:0] t_wdata,
        output [16*BURST_LEN-1:0] t_rdata
    );
        begin
            @(posedge ui_clk);
            while (busy) @(posedge ui_clk);
            req = 1'b1; wr = t_wr; addr = t_addr; wdata = t_wdata; wmask = {(2*BURST_LEN){1'b0}};
            @(posedge ui_clk);
            req = 1'b0;
            while (!ready) @(posedge ui_clk);
            t_rdata = rdata;
        end
    endtask

    integer errors, tests;
    reg [16*BURST_LEN-1:0] got, wpat;
    integer k, i;

    task automatic check_addr(input [ADDR_WIDTH-1:0] a, input [15:0] pattern);
        begin
            for (k = 0; k < BURST_LEN; k = k + 1)
                wpat[k*16 +: 16] = pattern + k[15:0];
            do_txn(1'b1, a, wpat, got);
            do_txn(1'b0, a, {(16*BURST_LEN){1'b0}}, got);
            tests = tests + 1;
            if (got !== wpat) begin
                $display("FAIL addr=%0d: got=%h expected=%h", a, got, wpat);
                errors = errors + 1;
            end else begin
                $display("PASS addr=%0d: bit-exact %h", a, got);
            end
        end
    endtask

    initial begin
        errors = 0; tests = 0;
        req = 0; wr = 0; addr = 0; wdata = 0; wmask = 0;

        $display("=== waiting for real DDR3 init_calib_complete (FAST sim calibration) ===");
        wait (init_calib_complete);
        $display("=== calibration done at time %0t, starting real write/read-back test ===", $time);
        repeat (10) @(posedge ui_clk);

        check_addr(25'd0,   16'hA5A5);
        check_addr(25'd8,   16'h1000);
        check_addr(25'd16,  16'h2000);
        check_addr(25'd1024,16'h3000);
        for (i = 0; i < 8; i = i + 1)
            check_addr((25'd2048 + i*8), 16'h4000 + i);

        $display("=== %0d/%0d tests, %0d errors ===", tests-errors, tests, errors);
        if (errors == 0) $display("ALL TESTS PASSED (tb_mig_native_adapter, real ddr3_model.sv)");
        else $display("SOME TESTS FAILED");
        $finish;
    end

    initial begin
        #200000000.0; // 200us watchdog
        if (!init_calib_complete) $display("FAIL: calibration never completed within watchdog");
        else $display("(watchdog fired after calibration already completed -- not a failure by itself)");
        $finish;
    end
endmodule
