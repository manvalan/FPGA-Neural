`timescale 1ps/100fs

// ============================================================
// MILESTONE: the full N=2 multi-core system (EXP-0066/0067, real
// neural_director_packed.v + 2 real packed_slot.v instances + real
// sdram_arbiter_n.v) running against REAL DDR3 (mig_native_adapter.v,
// EXP-0068, verified against MIG's own ddr3_model.sv) instead of the
// SDR SDRAM placeholder used everywhere until now.
//
// Runs entirely in the ui_clk domain (MIG's own generated clock is
// now this whole system's clock, per mig_native_adapter.v's own
// documented convention). Everything downstream of the memory
// backend (Director, packed_slot, weight-reuse path, packed core) is
// UNCHANGED, byte-for-byte, from EXP-0066/0067 -- only the physical
// memory backend is swapped, isolating that as the one variable
// under test.
//
// Activation stand-in (see packed_slot.v's own header) is unchanged
// too -- still a disclosed, separate gap, not addressed here.
//
// Uses mig_7series_0_mig_sim (SIM_BYPASS_INIT_CAL="FAST" default,
// EXP-0068's own real vendor-shipped fast-calibration simulation
// variant), real ddr3_model.sv, real WireDelay pass-through -- same
// proven instantiation pattern as tb_mig_native_adapter.v.
// ============================================================
module tb;
    localparam CLKIN_PERIOD  = 3225;   // ps, this project's real MIG config
    localparam REFCLK_FREQ   = 200.0;  // MHz
    localparam real REFCLK_PERIOD = (1000000.0/(2*REFCLK_FREQ));
    localparam RESET_PERIOD = 200000;  // ps

    localparam DATA_WIDTH  = 8;
    localparam P_IN        = 8;
    localparam ACC_WIDTH   = 32;
    localparam ADDR_WIDTH  = 26;      // this project's byte-address convention (Director/packed_slot)
    localparam MIG_ADDR_WIDTH = 25;   // word-address convention (BURST_LEN=8) at the arbiter/adapter
    localparam BURST_LEN   = 8;
    localparam N_INPUTS    = 128;
    localparam N_TILES     = N_INPUTS/P_IN;
    localparam LAYER_BYTES = N_INPUTS;
    localparam WORDS_PER_LAYER = LAYER_BYTES/2;
    localparam N_SLOTS      = 2;
    localparam QUEUE_DEPTH  = 8;

    localparam L = 2;  // layers (kept small -- real DDR3 calibration + JEDEC timing already
    localparam M = 4;  // costs real simulated time; this is an integration check, not a
                        // repeat of EXP-0066's own fuller correctness sweep)

    // ---- clock/reset (mirrors tb_mig_native_adapter.v's own proven pattern) ----
    reg sys_rst_n;
    wire sys_rst = sys_rst_n;
    reg sys_clk_i = 1'b0;
    always #(CLKIN_PERIOD/2.0) sys_clk_i = ~sys_clk_i;
    reg clk_ref_i = 1'b0;
    always #REFCLK_PERIOD clk_ref_i = ~clk_ref_i;
    initial begin
        sys_rst_n = 1'b0;
        #RESET_PERIOD sys_rst_n = 1'b1;
    end

    // ---- real DDR3 pins + model (identical to tb_mig_native_adapter.v) ----
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

    ddr3_model u_ddr3 (
        .rst_n(ddr3_reset_n), .ck(ddr3_ck_p_sdram), .ck_n(ddr3_ck_n_sdram),
        .cke(ddr3_cke_sdram[0]), .cs_n(ddr3_cs_n_sdram[0]),
        .ras_n(ddr3_ras_n_sdram), .cas_n(ddr3_cas_n_sdram), .we_n(ddr3_we_n_sdram),
        .dm_tdqs(ddr3_dm_sdram), .ba(ddr3_ba_sdram), .addr(ddr3_addr_sdram),
        .dq(ddr3_dq_sdram), .dqs(ddr3_dqs_p_sdram), .dqs_n(ddr3_dqs_n_sdram),
        .tdqs_n(), .odt(ddr3_odt_sdram[0])
    );

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

    // ---- preload path: direct access to mig_native_adapter.v,
    // bypassing the arbiter, exactly like every prior testbench's own
    // "pre_active" mux (EXP-0057 onward) -- used only before job
    // submission begins. ----
    reg                        pre_active;
    reg                        pre_req, pre_wr;
    reg  [MIG_ADDR_WIDTH-1:0]  pre_addr;
    reg  [16*BURST_LEN-1:0]    pre_wdata;

    wire                     adp_req, adp_wr;
    wire [MIG_ADDR_WIDTH-1:0] adp_addr;
    wire [16*BURST_LEN-1:0]  adp_wdata;
    wire [2*BURST_LEN-1:0]   adp_wmask;
    wire [16*BURST_LEN-1:0]  adp_rdata;
    wire                     adp_ready, adp_busy;

    wire arb_ctrl_req_o, arb_ctrl_wr_o;
    wire [MIG_ADDR_WIDTH-1:0] arb_ctrl_addr_o;
    wire [16*BURST_LEN-1:0]  arb_ctrl_wdata_o;
    wire [2*BURST_LEN-1:0]   arb_ctrl_wmask_o;

    assign adp_req   = pre_active ? pre_req   : arb_ctrl_req_o;
    assign adp_wr    = pre_active ? pre_wr    : arb_ctrl_wr_o;
    assign adp_addr  = pre_active ? pre_addr  : arb_ctrl_addr_o;
    assign adp_wdata = pre_active ? pre_wdata : arb_ctrl_wdata_o;
    assign adp_wmask = pre_active ? {(2*BURST_LEN){1'b0}} : arb_ctrl_wmask_o;

    mig_native_adapter #(.BURST_LEN(BURST_LEN), .ADDR_WIDTH(MIG_ADDR_WIDTH)) u_adapter (
        .clk(ui_clk), .rst(ui_clk_sync_rst),
        .req(adp_req), .wr(adp_wr), .addr(adp_addr), .wdata(adp_wdata), .wmask(adp_wmask),
        .rdata(adp_rdata), .ready(adp_ready), .busy(adp_busy),
        .app_addr(app_addr), .app_cmd(app_cmd), .app_en(app_en), .app_rdy(app_rdy),
        .app_wdf_data(app_wdf_data), .app_wdf_end(app_wdf_end), .app_wdf_mask(app_wdf_mask),
        .app_wdf_wren(app_wdf_wren), .app_wdf_rdy(app_wdf_rdy),
        .app_rd_data(app_rd_data), .app_rd_data_end(app_rd_data_end), .app_rd_data_valid(app_rd_data_valid)
    );

    function automatic signed [7:0] weight_byte(input integer li, input integer t);
        weight_byte = $signed(8'((li*17 + t*29 + 13) & 8'hFF));
    endfunction
    function automatic signed [7:0] input_byte(input integer li, input integer pos, input integer t);
        input_byte = $signed(8'((li*11 + pos*41 + t*7 + 3) & 8'hFF));
    endfunction

    task automatic sdram_write_burst(input [MIG_ADDR_WIDTH-1:0] word_addr, input [16*BURST_LEN-1:0] data);
        begin
            @(posedge ui_clk); while (adp_busy) @(posedge ui_clk);
            pre_req = 1'b1; pre_wr = 1'b1; pre_addr = word_addr; pre_wdata = data;
            @(posedge ui_clk); pre_req = 1'b0;
            while (!adp_ready) @(posedge ui_clk);
        end
    endtask

    task automatic preload_sdram_layers;
        integer li, bi, wb, tt;
        reg [16*BURST_LEN-1:0] burst_data;
        begin
            for (li = 0; li < L; li = li + 1) begin
                for (bi = 0; bi < (LAYER_BYTES/(2*BURST_LEN)); bi = bi + 1) begin
                    for (wb = 0; wb < BURST_LEN; wb = wb + 1) begin
                        tt = bi*(2*BURST_LEN) + wb*2;
                        burst_data[wb*16 +: 16] = {weight_byte(li, tt+1), weight_byte(li, tt)};
                    end
                    sdram_write_burst((li*WORDS_PER_LAYER + bi*BURST_LEN), burst_data);
                end
            end
        end
    endtask

    function automatic signed [DATA_WIDTH*P_IN-1:0] act_lookup(input [ADDR_WIDTH-1:0] addr);
        integer li_d, pos_d, tidx_d, k;
        reg signed [DATA_WIDTH*P_IN-1:0] r;
        begin
            li_d   = addr / 100000;
            pos_d  = (addr / 1000) % 100;
            tidx_d = addr % 1000;
            for (k = 0; k < P_IN; k = k + 1)
                r[k*DATA_WIDTH +: DATA_WIDTH] = input_byte(li_d, pos_d, tidx_d*P_IN + k);
            act_lookup = r;
        end
    endfunction

    // ---- neural_director_packed.v ----
    reg                     job_in_valid;
    wire                    job_in_ready;
    reg  [ADDR_WIDTH-1:0]   job_in_x_base, job_in_w_base, job_in_result_addr;
    reg  [15:0]             job_in_n_tiles, job_in_node_id;

    wire [N_SLOTS-1:0]            slot_job_start;
    wire [ADDR_WIDTH*N_SLOTS-1:0] slot_x_base_a, slot_x_base_b, slot_w_base;
    wire [ADDR_WIDTH*N_SLOTS-1:0] slot_result_addr_a, slot_result_addr_b;
    wire [16*N_SLOTS-1:0]         slot_n_tiles, slot_node_id_a, slot_node_id_b;
    wire [N_SLOTS-1:0]            slot_job_done;
    wire                        job_out_done;
    wire [$clog2(N_SLOTS)-1:0]  job_out_slot;
    wire [3:0]                  dir_state;
    wire                        dir_error;

    neural_director_packed #(
        .ADDR_WIDTH(ADDR_WIDTH), .N_SLOTS(N_SLOTS), .QUEUE_DEPTH(QUEUE_DEPTH)
    ) u_dir (
        .clk(ui_clk), .rst(ui_clk_sync_rst),
        .job_in_valid(job_in_valid), .job_in_ready(job_in_ready),
        .job_in_x_base(job_in_x_base), .job_in_w_base(job_in_w_base),
        .job_in_n_tiles(job_in_n_tiles), .job_in_result_addr(job_in_result_addr),
        .job_in_node_id(job_in_node_id),
        .slot_job_start(slot_job_start),
        .slot_x_base_a(slot_x_base_a), .slot_x_base_b(slot_x_base_b),
        .slot_w_base(slot_w_base), .slot_n_tiles(slot_n_tiles),
        .slot_result_addr_a(slot_result_addr_a), .slot_result_addr_b(slot_result_addr_b),
        .slot_node_id_a(slot_node_id_a), .slot_node_id_b(slot_node_id_b),
        .slot_job_done(slot_job_done),
        .job_out_done(job_out_done), .job_out_slot(job_out_slot),
        .dir_state(dir_state), .dir_error(dir_error)
    );

    // ---- 2 real packed_slot.v instances + real N-way arbiter (NUM_REQ=2) ----
    wire [1:0] mem_active, mem_grant;
    wire [1:0] s_ctrl_req, s_ctrl_wr;
    wire [1:0] s_ctrl_ready, s_ctrl_busy;
    wire [MIG_ADDR_WIDTH*2-1:0]    s_ctrl_addr_flat;
    wire [16*BURST_LEN*2-1:0]      s_ctrl_wdata_flat, s_ctrl_rdata_flat;
    wire [2*BURST_LEN*2-1:0]       s_ctrl_wmask_flat;

    sdram_arbiter_n #(.NUM_REQ(2), .ADDR_WIDTH(MIG_ADDR_WIDTH), .BURST_LEN(BURST_LEN)) u_arb (
        .clk(ui_clk), .rst(ui_clk_sync_rst),
        .req_active(mem_active), .req_grant(mem_grant),
        .req_req(s_ctrl_req), .req_wr(s_ctrl_wr), .req_addr(s_ctrl_addr_flat),
        .req_wdata(s_ctrl_wdata_flat), .req_wmask(s_ctrl_wmask_flat),
        .req_rdata(s_ctrl_rdata_flat), .req_ready(s_ctrl_ready), .req_busy(s_ctrl_busy),
        .ctrl_req(arb_ctrl_req_o), .ctrl_wr(arb_ctrl_wr_o), .ctrl_addr(arb_ctrl_addr_o),
        .ctrl_wdata(arb_ctrl_wdata_o), .ctrl_wmask(arb_ctrl_wmask_o),
        .ctrl_rdata(adp_rdata), .ctrl_ready(adp_ready), .ctrl_busy(adp_busy)
    );

    genvar gi;
    generate
        for (gi = 0; gi < N_SLOTS; gi = gi + 1) begin : GEN_SLOT
            wire signed [DATA_WIDTH-1:0] res_a, res_b;
            wire [15:0] res_nid_a, res_nid_b;
            wire [ADDR_WIDTH-1:0] res_addr_a_out, res_addr_b_out;
            wire [ADDR_WIDTH-1:0] act_addr_a, act_addr_b;
            wire signed [DATA_WIDTH*P_IN-1:0] act_data_a, act_data_b;

            assign act_data_a = act_lookup(act_addr_a);
            assign act_data_b = act_lookup(act_addr_b);

            packed_slot #(
                .DATA_WIDTH(DATA_WIDTH), .P_IN(P_IN), .ACC_WIDTH(ACC_WIDTH),
                .BURST_LEN(BURST_LEN), .ADDR_WIDTH(ADDR_WIDTH), .LAYER_BYTES(LAYER_BYTES)
            ) u_slot (
                .clk(ui_clk), .rst(ui_clk_sync_rst),
                .job_start(slot_job_start[gi]),
                .x_base_a(slot_x_base_a[gi*ADDR_WIDTH +: ADDR_WIDTH]),
                .x_base_b(slot_x_base_b[gi*ADDR_WIDTH +: ADDR_WIDTH]),
                .w_base(slot_w_base[gi*ADDR_WIDTH +: ADDR_WIDTH]),
                .n_tiles(slot_n_tiles[gi*16 +: 16]),
                .result_addr_a(slot_result_addr_a[gi*ADDR_WIDTH +: ADDR_WIDTH]),
                .result_addr_b(slot_result_addr_b[gi*ADDR_WIDTH +: ADDR_WIDTH]),
                .node_id_a(slot_node_id_a[gi*16 +: 16]), .node_id_b(slot_node_id_b[gi*16 +: 16]),
                .job_done(slot_job_done[gi]),
                .result_data_a(res_a), .result_data_b(res_b),
                .result_node_id_a(res_nid_a), .result_node_id_b(res_nid_b),
                .result_addr_a_out(res_addr_a_out), .result_addr_b_out(res_addr_b_out),
                .mem_active(mem_active[gi]), .mem_grant(mem_grant[gi]),
                .act_tile_addr_a(act_addr_a), .act_tile_addr_b(act_addr_b),
                .act_tile_data_a(act_data_a), .act_tile_data_b(act_data_b),
                .ctrl_req(s_ctrl_req[gi]), .ctrl_wr(s_ctrl_wr[gi]),
                .ctrl_addr(s_ctrl_addr_flat[gi*MIG_ADDR_WIDTH +: MIG_ADDR_WIDTH]),
                .ctrl_wdata(s_ctrl_wdata_flat[gi*16*BURST_LEN +: 16*BURST_LEN]),
                .ctrl_wmask(s_ctrl_wmask_flat[gi*2*BURST_LEN +: 2*BURST_LEN]),
                .ctrl_rdata(s_ctrl_rdata_flat[gi*16*BURST_LEN +: 16*BURST_LEN]),
                .ctrl_ready(s_ctrl_ready[gi]), .ctrl_busy(s_ctrl_busy[gi])
            );
        end
    endgenerate

    integer errors, tests, completions, n_expected, si;
    reg [15:0] expect_node [0:31];
    reg signed [7:0] expect_val [0:31];

    function automatic signed [7:0] golden_result(input integer li, input integer pos);
        integer t, acc;
        reg signed [7:0] r;
        begin
            acc = 0;
            for (t = 0; t < N_INPUTS; t = t + 1)
                acc = acc + (input_byte(li, pos, t) * weight_byte(li, t));
            if (acc <= 0) r = 0; else if (acc > 127) r = 8'sd127; else r = acc[7:0];
            golden_result = r;
        end
    endfunction

    task automatic check_completion(input integer slot, input [15:0] nid, input signed [7:0] val);
        integer idx, found;
        begin
            found = 0;
            for (idx = 0; idx < n_expected; idx = idx + 1) begin
                if (expect_node[idx] === nid && !found) begin
                    found = 1;
                    tests = tests + 1;
                    if (expect_val[idx] !== val) begin
                        $display("FAIL slot=%0d node_id=%0d: got=%0d expected=%0d", slot, nid, $signed(val), $signed(expect_val[idx]));
                        errors = errors + 1;
                    end else begin
                        $display("PASS slot=%0d node_id=%0d: result=%0d", slot, nid, $signed(val));
                    end
                end
            end
        end
    endtask

    always @(posedge ui_clk) begin
        if (!ui_clk_sync_rst) begin
            for (si = 0; si < N_SLOTS; si = si + 1) begin
                if (slot_job_done[si]) begin
                    completions = completions + 2;
                    case (si)
                        0: begin
                            check_completion(0, GEN_SLOT[0].u_slot.result_node_id_a, GEN_SLOT[0].u_slot.result_data_a);
                            check_completion(0, GEN_SLOT[0].u_slot.result_node_id_b, GEN_SLOT[0].u_slot.result_data_b);
                        end
                        1: begin
                            check_completion(1, GEN_SLOT[1].u_slot.result_node_id_a, GEN_SLOT[1].u_slot.result_data_a);
                            check_completion(1, GEN_SLOT[1].u_slot.result_node_id_b, GEN_SLOT[1].u_slot.result_data_b);
                        end
                    endcase
                end
            end
        end
    end

    task automatic submit_job(
        input [ADDR_WIDTH-1:0] xb, input [ADDR_WIDTH-1:0] wb,
        input [15:0] nt, input [ADDR_WIDTH-1:0] resaddr, input [15:0] nid
    );
        begin
            @(posedge ui_clk);
            job_in_x_base = xb; job_in_w_base = wb; job_in_n_tiles = nt;
            job_in_result_addr = resaddr; job_in_node_id = nid;
            job_in_valid = 1'b1;
            while (!job_in_ready) @(posedge ui_clk);
            @(posedge ui_clk);
            job_in_valid = 1'b0;
        end
    endtask

    integer li_i, pp_i, wd;

    initial begin
        errors = 0; tests = 0; completions = 0; n_expected = 0;
        pre_active = 1'b1; pre_req = 0; pre_wr = 0; pre_addr = 0; pre_wdata = 0;
        job_in_valid = 0; job_in_x_base = 0; job_in_w_base = 0;
        job_in_n_tiles = 0; job_in_result_addr = 0; job_in_node_id = 0;

        $display("=== waiting for real DDR3 init_calib_complete ===");
        wait (init_calib_complete);
        $display("=== calibration done at time %0t ===", $time);
        repeat (10) @(posedge ui_clk);

        $display("=== preload SDRAM with %0d resident-filter weight sets ===", L);
        preload_sdram_layers;
        @(posedge ui_clk);
        pre_active = 1'b0;
        repeat (5) @(posedge ui_clk);

        $display("=== N=2 system on REAL DDR3: submitting %0d layers x %0d positions ===", L, M);
        for (li_i = 0; li_i < L; li_i = li_i + 1) begin
            for (pp_i = 0; pp_i < M; pp_i = pp_i + 1) begin
                submit_job(li_i*100000 + pp_i*1000, li_i*WORDS_PER_LAYER, N_TILES[15:0],
                           26'h9000 + li_i*10 + pp_i, (li_i*M + pp_i));
                expect_node[n_expected] = (li_i*M + pp_i);
                expect_val[n_expected]  = golden_result(li_i, pp_i);
                n_expected = n_expected + 1;
            end
        end

        wd = 0;
        while (completions < n_expected && wd < 200000) begin
            @(posedge ui_clk);
            wd = wd + 1;
        end

        if (completions < n_expected) begin
            $display("FAIL: only %0d/%0d position-results completed within watchdog", completions, n_expected);
            errors = errors + 1;
        end

        $display("=== %0d/%0d tests, %0d errors, %0d/%0d positions completed ===", tests-errors, tests, errors, completions, n_expected);
        if (errors == 0 && completions == n_expected) $display("ALL TESTS PASSED (tb_n2_system_ddr3, REAL DDR3)");
        $finish;
    end
endmodule
