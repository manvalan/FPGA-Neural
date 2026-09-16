`timescale 1ns/1ps

// ================================================================
// EXPERIMENTAL fork of tb_nms_dstress_sdram_unified.v -- instantiates
// nms_neural_multiprocessor_sdram_pipelined.v (single physical SDRAM
// chip, but with sdram_controller_pipelined.v's bank-interleaved
// command pipelining inside) instead of nms_neural_multiprocessor_
// sdram_unified.v. Identical D-Stress workload/golden-model/bit-exact
// verification.
//
// ONLY functional difference vs the original testbench: poke_byte/
// peek_byte/poke_byte_weight/peek_byte_weight no longer compute a
// flat `u_sdram.mem[word_addr]` index by hand (that shortcut relied
// on the ORIGINAL controller's bank-from-TOP-bits decomposition,
// where ROWS/COLS being powers of 2 makes the flat word address
// numerically identical to bank*ROWS*COLS+row*COLS+col). The
// pipelined controller re-slices which address bits mean bank/row/
// col (see sdram_controller_pipelined.v's own header, note (1)), so
// these backdoor helpers instead: (a) decompose the flat word address
// using the EXACT SAME bit ranges as sdram_controller_pipelined.v's
// own addr_bank/addr_row/addr_col wires, then (b) call sdram_model.v's
// own explicit, decomposition-agnostic backdoor_read/backdoor_write
// tasks (bank/row/col-addressed) instead of indexing `mem[]` directly
// -- this guarantees the testbench and the RTL agree on where a given
// byte physically lives, by construction, rather than by two
// independently-maintained flat-index formulas that could silently
// drift apart.
// ================================================================
module tb #(
    parameter N_SLOTS_CFG = 2,
    parameter PFD_CFG     = 8
);

    localparam ADDR_WIDTH  = 26;
    localparam DATA_WIDTH  = 8;
    localparam P_IN        = 8;
    localparam ACC_WIDTH   = 32;
    localparam N_NODES     = 1024;
    localparam MAX_DEPS    = 8;
    localparam QUEUE_DEPTH = 8;
    localparam NODE_IDW    = $clog2(N_NODES);
    localparam CLK_PERIOD  = 12.5; // 80 MHz

    // must match sdram_controller_pipelined.v's own instantiation
    // parameters exactly (BURST_LEN=8 hardcoded by sdram_unified_
    // backend_pipelined.v, ROW_BITS/COL_BITS/BANK_BITS defaults)
    localparam ROW_BITS  = 13;
    localparam COL_BITS  = 10;
    localparam BANK_BITS = 2;
    localparam ALIGN_BITS = 3; // clog2(BURST_LEN=8)

    reg clk, rst;
    initial begin clk = 1'b0; forever #(CLK_PERIOD/2.0) clk = ~clk; end

    reg                                reg_valid;
    wire                               reg_ready;
    reg  [NODE_IDW-1:0]                reg_node_id;
    reg  [$clog2(MAX_DEPS+1)-1:0]      reg_required;
    reg  [MAX_DEPS*NODE_IDW-1:0]       reg_producer_ids;
    reg  [ADDR_WIDTH-1:0]              reg_x_base, reg_w_base, reg_result_addr;
    reg  [15:0]                        reg_n_tiles;

    wire        sdram_cke, sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n;
    wire [1:0]  sdram_ba;
    wire [12:0] sdram_a;
    wire [15:0] sdram_dq;
    wire [1:0]  sdram_dqm;

    nms_neural_multiprocessor_sdram_pipelined #(
        .DATA_WIDTH(DATA_WIDTH), .P_IN(P_IN), .ACC_WIDTH(ACC_WIDTH), .ADDR_WIDTH(ADDR_WIDTH),
        .N_SLOTS(N_SLOTS_CFG), .N_NODES(N_NODES), .MAX_DEPS(MAX_DEPS), .QUEUE_DEPTH(QUEUE_DEPTH),
        .MAX_TILES(16), .PREFETCH_DISTANCE(PFD_CFG), .CLK_FREQ_MHZ(80)
    ) u_nmp (
        .clk(clk), .rst(rst),
        .reg_valid(reg_valid), .reg_ready(reg_ready), .reg_node_id(reg_node_id),
        .reg_required(reg_required), .reg_producer_ids(reg_producer_ids),
        .reg_x_base(reg_x_base), .reg_w_base(reg_w_base), .reg_n_tiles(reg_n_tiles),
        .reg_result_addr(reg_result_addr),
        .sdram_cke(sdram_cke), .sdram_cs_n(sdram_cs_n), .sdram_ras_n(sdram_ras_n),
        .sdram_cas_n(sdram_cas_n), .sdram_we_n(sdram_we_n),
        .sdram_ba(sdram_ba), .sdram_a(sdram_a), .sdram_dq(sdram_dq), .sdram_dqm(sdram_dqm)
    );

    sdram_model #(.CLK_FREQ_MHZ(80)) u_sdram (
        .clk(clk), .cke(sdram_cke), .cs_n(sdram_cs_n), .ras_n(sdram_ras_n),
        .cas_n(sdram_cas_n), .we_n(sdram_we_n), .ba(sdram_ba), .a(sdram_a),
        .dq(sdram_dq), .dqm(sdram_dqm)
    );

    // ---- backdoor helpers: decompose a flat 25-bit word address into
    // (bank,row,col) using sdram_controller_pipelined.v's own bit
    // ranges, then use sdram_model.v's own bank/row/col-addressed
    // backdoor tasks -- see header note above ----
    function automatic [BANK_BITS-1:0] wa_bank(input [24:0] wa);
        wa_bank = wa[ALIGN_BITS +: BANK_BITS];
    endfunction
    function automatic [COL_BITS-1:0] wa_col(input [24:0] wa);
        wa_col = {wa[ALIGN_BITS+BANK_BITS +: (COL_BITS-ALIGN_BITS)], wa[ALIGN_BITS-1:0]};
    endfunction
    function automatic [ROW_BITS-1:0] wa_row(input [24:0] wa);
        wa_row = wa[24 -: ROW_BITS];
    endfunction

    task automatic poke_byte(input [ADDR_WIDTH-1:0] byte_addr, input signed [7:0] val);
        reg [24:0] wa;
        reg [15:0] cur;
        begin
            wa = byte_addr[ADDR_WIDTH-1:1];
            cur = u_sdram.backdoor_read(wa_bank(wa), wa_row(wa), wa_col(wa));
            if (byte_addr[0] == 1'b0) cur[7:0] = val; else cur[15:8] = val;
            u_sdram.backdoor_write(wa_bank(wa), wa_row(wa), wa_col(wa), cur);
        end
    endtask

    function automatic signed [7:0] peek_byte(input [ADDR_WIDTH-1:0] byte_addr);
        reg [24:0] wa;
        reg [15:0] cur;
        begin
            wa = byte_addr[ADDR_WIDTH-1:1];
            cur = u_sdram.backdoor_read(wa_bank(wa), wa_row(wa), wa_col(wa));
            peek_byte = (byte_addr[0] == 1'b0) ? cur[7:0] : cur[15:8];
        end
    endfunction

    task automatic poke_byte_weight(input [ADDR_WIDTH-1:0] byte_addr, input signed [7:0] val);
        reg [24:0] wa;
        reg [15:0] cur;
        begin
            wa = byte_addr[ADDR_WIDTH-1:1];
            cur = u_sdram.backdoor_read(wa_bank(wa), wa_row(wa), wa_col(wa));
            if (byte_addr[0] == 1'b0) cur[7:0] = val; else cur[15:8] = val;
            u_sdram.backdoor_write(wa_bank(wa), wa_row(wa), wa_col(wa), cur);
        end
    endtask

    function automatic signed [7:0] peek_byte_weight(input [ADDR_WIDTH-1:0] byte_addr);
        reg [24:0] wa;
        reg [15:0] cur;
        begin
            wa = byte_addr[ADDR_WIDTH-1:1];
            cur = u_sdram.backdoor_read(wa_bank(wa), wa_row(wa), wa_col(wa));
            peek_byte_weight = (byte_addr[0] == 1'b0) ? cur[7:0] : cur[15:8];
        end
    endfunction

    function automatic signed [7:0] relu_sat(input integer acc);
        begin
            if (acc <= 0)        relu_sat = 8'sd0;
            else if (acc > 127)  relu_sat = 8'sd127;
            else                 relu_sat = acc[7:0];
        end
    endfunction

    task automatic register_node(
        input [NODE_IDW-1:0] nid,
        input [$clog2(MAX_DEPS+1)-1:0] required,
        input [MAX_DEPS*NODE_IDW-1:0] producer_ids_packed,
        input [ADDR_WIDTH-1:0] xb, input [ADDR_WIDTH-1:0] wb,
        input [15:0] nt, input [ADDR_WIDTH-1:0] resaddr
    );
        begin
            @(posedge clk);
            reg_node_id      = nid;
            reg_required     = required;
            reg_producer_ids = producer_ids_packed;
            reg_x_base = xb; reg_w_base = wb; reg_n_tiles = nt; reg_result_addr = resaddr;
            reg_valid = 1'b1;
            while (!reg_ready) @(posedge clk);
            @(posedge clk);
            reg_valid = 1'b0;
        end
    endtask

    reg measure_en;
    integer total_cycles;
    integer psram_busy_cycles;
    integer ni;
    genvar gi;

    reg [N_SLOTS_CFG-1:0] slot_busy_bit;
    reg [N_SLOTS_CFG-1:0] slot_tile_bit;
    integer slot_busy_cycles [0:N_SLOTS_CFG-1];
    integer slot_tiles_delivered [0:N_SLOTS_CFG-1];

    generate
        for (gi = 0; gi < N_SLOTS_CFG; gi = gi + 1) begin : GEN_SLOT_MON
            always @(*) begin
                slot_busy_bit[gi] = (u_nmp.u_dataflow_core.GEN_SLOT[gi].u_mm.state != 3'd0);
                slot_tile_bit[gi] = u_nmp.u_dataflow_core.GEN_SLOT[gi].mm_operand_valid &&
                                    u_nmp.u_dataflow_core.GEN_SLOT[gi].mm_operand_ready;
            end
        end
    endgenerate

    integer active_count;
    integer active_hist [0:4];
    integer useful_mac_cycles;
    integer first_tile_cyc;
    integer last_tile_cyc;
    integer any_tile_bit;

    integer sdram_req_count, sdram_ready_count, sdram_wr_count;
    integer sdram_busy_cycles, sdram_refresh_count;
    integer sdram_req_start_cyc, sdram_lat_sum, sdram_lat_min, sdram_lat_max, sdram_lat_n;
    reg     sdram_prev_state_is_refwait;

    initial begin
        active_hist[0]=0; active_hist[1]=0; active_hist[2]=0; active_hist[3]=0; active_hist[4]=0;
        useful_mac_cycles = 0; first_tile_cyc = -1; last_tile_cyc = -1;
        sdram_req_count=0; sdram_ready_count=0; sdram_wr_count=0;
        sdram_busy_cycles=0; sdram_refresh_count=0;
        sdram_req_start_cyc=0; sdram_lat_sum=0; sdram_lat_min=999999; sdram_lat_max=0; sdram_lat_n=0;
        sdram_prev_state_is_refwait=1'b0;
    end

    always @(posedge clk) begin
        if (measure_en) begin
            active_count = slot_busy_bit[0];
            for (ni = 1; ni < N_SLOTS_CFG; ni = ni + 1) active_count = active_count + slot_busy_bit[ni];
            active_hist[active_count] <= active_hist[active_count] + 1;

            any_tile_bit = slot_tile_bit[0];
            for (ni = 1; ni < N_SLOTS_CFG; ni = ni + 1) any_tile_bit = any_tile_bit | slot_tile_bit[ni];
            for (ni = 0; ni < N_SLOTS_CFG; ni = ni + 1)
                if (slot_tile_bit[ni]) useful_mac_cycles <= useful_mac_cycles + 1;
            if (any_tile_bit) begin
                if (first_tile_cyc < 0) first_tile_cyc <= total_cycles;
                last_tile_cyc <= total_cycles;
            end

            if (u_nmp.u_sdram_backend.u_sdram_ctrl.req) begin
                sdram_req_count <= sdram_req_count + 1;
                sdram_req_start_cyc <= total_cycles;
                if (u_nmp.u_sdram_backend.u_sdram_ctrl.wr) sdram_wr_count <= sdram_wr_count + 1;
            end
            if (u_nmp.u_sdram_backend.u_sdram_ctrl.ready) begin
                sdram_ready_count <= sdram_ready_count + 1;
                sdram_lat_sum <= sdram_lat_sum + (total_cycles - sdram_req_start_cyc);
                sdram_lat_n   <= sdram_lat_n + 1;
                if ((total_cycles - sdram_req_start_cyc) < sdram_lat_min) sdram_lat_min <= (total_cycles - sdram_req_start_cyc);
                if ((total_cycles - sdram_req_start_cyc) > sdram_lat_max) sdram_lat_max <= (total_cycles - sdram_req_start_cyc);
            end
            if (u_nmp.u_sdram_backend.u_sdram_ctrl.busy) sdram_busy_cycles <= sdram_busy_cycles + 1;
            sdram_prev_state_is_refwait <= (u_nmp.u_sdram_backend.u_sdram_ctrl.state == 5'd9);
            if (u_nmp.u_sdram_backend.u_sdram_ctrl.state == 5'd9 && !sdram_prev_state_is_refwait)
                sdram_refresh_count <= sdram_refresh_count + 1;
        end
    end

    task automatic report_step17_instrumentation;
        real active_pct [0:4];
        real util_pct, startup_cycles, drain_cycles;
        real sdram_avg_lat, sdram_busy_pct, sdram_bytes_per_cycle;
        integer kk, total_tiles_all;
        begin
            total_tiles_all = 0;
            for (kk = 0; kk < N_SLOTS_CFG; kk = kk + 1) total_tiles_all = total_tiles_all + slot_tiles_delivered[kk];
            $display("  ---- cycle decomposition ----");
            for (kk = 0; kk <= N_SLOTS_CFG; kk = kk + 1) begin
                active_pct[kk] = (total_cycles > 0) ? (100.0*active_hist[kk]/total_cycles) : 0.0;
                $display("    active_slots=%0d: %0d cycles (%0.2f%%)", kk, active_hist[kk], active_pct[kk]);
            end
            util_pct = (total_cycles > 0) ? (100.0*useful_mac_cycles/(total_cycles*1.0*N_SLOTS_CFG)) : 0.0;
            $display("    useful_mac_cycles (slot-tile-delivery events, summed)=%0d  (%0.2f%% of total_cycles*N_SLOTS)", useful_mac_cycles, util_pct);
            startup_cycles = (first_tile_cyc >= 0) ? (1.0*first_tile_cyc) : 0.0;
            drain_cycles   = (last_tile_cyc >= 0) ? (1.0*(total_cycles - last_tile_cyc)) : 0.0;
            $display("    startup (cycles before first tile delivered anywhere)=%0.0f", startup_cycles);
            $display("    drain (cycles after last tile delivered, until job completion)=%0.0f", drain_cycles);
            $display("  ---- SDRAM (pipelined controller) effectiveness ----");
            sdram_avg_lat = (sdram_lat_n > 0) ? (1.0*sdram_lat_sum/sdram_lat_n) : 0.0;
            sdram_busy_pct = (total_cycles > 0) ? (100.0*sdram_busy_cycles/total_cycles) : 0.0;
            sdram_bytes_per_cycle = (total_cycles > 0) ? (8.0*sdram_ready_count/total_cycles) : 0.0;
            $display("    sdram_req_count=%0d  sdram_ready_count=%0d  sdram_wr_count=%0d",
                sdram_req_count, sdram_ready_count, sdram_wr_count);
            $display("    sdram_busy_cycles=%0d/%0d (%0.2f%%)", sdram_busy_cycles, total_cycles, sdram_busy_pct);
            $display("    sdram_refresh_count=%0d", sdram_refresh_count);
            $display("    sdram_request_latency: min=%0d max=%0d avg=%0.2f cycles",
                sdram_lat_min, sdram_lat_max, sdram_avg_lat);
            $display("    sdram_avg_bytes_per_cycle=%0.4f", sdram_bytes_per_cycle);
        end
    endtask

    reg  [N_SLOTS_CFG-1:0] slot_could_present_act;
    reg  [N_SLOTS_CFG-1:0] slot_weight_blocking;
    reg  [N_SLOTS_CFG-1:0] slot_stalled_this_tile;
    reg  [31:0] prev_tile_idx [0:N_SLOTS_CFG-1];
    integer weight_stall_cycles [0:N_SLOTS_CFG-1];
    integer tiles_prefetched_clean [0:N_SLOTS_CFG-1];
    integer tiles_consumed_total [0:N_SLOTS_CFG-1];
    wire [31:0] slot_tile_idx_w [0:N_SLOTS_CFG-1];

    generate
        for (gi = 0; gi < N_SLOTS_CFG; gi = gi + 1) begin : GEN_SLOT_PF_MON
            assign slot_tile_idx_w[gi] = {16'b0, u_nmp.u_dataflow_core.GEN_SLOT[gi].u_mm.tile_idx};
            always @(*) begin
                slot_could_present_act[gi] =
                    ({{16{1'b0}}, u_nmp.u_dataflow_core.GEN_SLOT[gi].u_mm.tile_idx} <
                     {16'b0, u_nmp.u_dataflow_core.GEN_SLOT[gi].u_mm.n_tiles_reg}) &&
                    ({{16{1'b0}}, u_nmp.u_dataflow_core.GEN_SLOT[gi].u_mm.tile_idx} <
                     {16'b0, u_nmp.u_dataflow_core.GEN_SLOT[gi].u_mm.usable_act});
                slot_weight_blocking[gi] =
                    slot_could_present_act[gi] &&
                    !(u_nmp.u_dataflow_core.GEN_SLOT[gi].u_mm.tile_idx <
                      u_nmp.u_dataflow_core.GEN_SLOT[gi].u_mm.wgt_ready_count) &&
                    !u_nmp.u_dataflow_core.GEN_SLOT[gi].u_mm.operand_valid;
            end
        end
    endgenerate

    always @(posedge clk) begin
        if (measure_en) begin
            for (ni = 0; ni < N_SLOTS_CFG; ni = ni + 1) begin
                if (prev_tile_idx[ni] != slot_tile_idx_w[ni]) begin
                    slot_stalled_this_tile[ni] <= 1'b0;
                    prev_tile_idx[ni] <= slot_tile_idx_w[ni];
                end else if (slot_weight_blocking[ni]) begin
                    slot_stalled_this_tile[ni] <= 1'b1;
                    weight_stall_cycles[ni] <= weight_stall_cycles[ni] + 1;
                end
                if (slot_tile_bit[ni]) begin
                    tiles_consumed_total[ni] <= tiles_consumed_total[ni] + 1;
                    if (!slot_stalled_this_tile[ni])
                        tiles_prefetched_clean[ni] <= tiles_prefetched_clean[ni] + 1;
                end
            end
        end
    end

    integer jobs_allocated, jobs_completed, wakeups;
    integer waiting_sum, ready_sum, dispatched_sum, sample_count;
    reg sample_occupancy;
    integer scan_i;
    integer waiting_now, ready_now, dispatched_now;

    always @(posedge clk) begin
        if (measure_en) begin
            total_cycles <= total_cycles + 1;
            if (u_nmp.u_arbiter.owner != 0) psram_busy_cycles <= psram_busy_cycles + 1;
            for (ni = 0; ni < N_SLOTS_CFG; ni = ni + 1) begin
                if (slot_busy_bit[ni]) slot_busy_cycles[ni] <= slot_busy_cycles[ni] + 1;
                if (slot_tile_bit[ni]) slot_tiles_delivered[ni] <= slot_tiles_delivered[ni] + 1;
            end
            if (u_nmp.u_dataflow_core.dm_ready_valid && u_nmp.u_dataflow_core.dm_ready_ready)
                jobs_allocated <= jobs_allocated + 1;
            if (u_nmp.u_dataflow_core.dir_job_out_done)
                jobs_completed <= jobs_completed + 1;
            if (u_nmp.u_dataflow_core.dm_producer_done_valid)
                wakeups <= wakeups + 1;

            if (sample_occupancy) begin
                waiting_now = 0; ready_now = 0; dispatched_now = 0;
                for (scan_i = 0; scan_i < N_NODES; scan_i = scan_i + 1) begin
                    case (u_nmp.u_dataflow_core.u_dep_mgr.node_state[scan_i])
                        2'd1: waiting_now    = waiting_now + 1;
                        2'd2: ready_now      = ready_now + 1;
                        2'd3: dispatched_now = dispatched_now + 1;
                        default: ;
                    endcase
                end
                waiting_sum    <= waiting_sum    + waiting_now;
                ready_sum      <= ready_sum      + ready_now;
                dispatched_sum <= dispatched_sum + dispatched_now;
                sample_count   <= sample_count + 1;
            end
        end
    end

    task automatic reset_instrumentation(input do_sample_occupancy);
        integer k;
        begin
            active_hist[0]=0; active_hist[1]=0; active_hist[2]=0; active_hist[3]=0; active_hist[4]=0;
            useful_mac_cycles = 0; first_tile_cyc = -1; last_tile_cyc = -1;
            sdram_req_count=0; sdram_ready_count=0; sdram_wr_count=0;
            sdram_busy_cycles=0; sdram_refresh_count=0;
            sdram_req_start_cyc=0; sdram_lat_sum=0; sdram_lat_min=999999; sdram_lat_max=0; sdram_lat_n=0;
            total_cycles = 0; psram_busy_cycles = 0;
            jobs_allocated = 0; jobs_completed = 0; wakeups = 0;
            waiting_sum = 0; ready_sum = 0; dispatched_sum = 0; sample_count = 0;
            sample_occupancy = do_sample_occupancy;
            for (k = 0; k < N_SLOTS_CFG; k = k + 1) begin
                slot_busy_cycles[k] = 0;
                slot_tiles_delivered[k] = 0;
                weight_stall_cycles[k] = 0;
                tiles_prefetched_clean[k] = 0;
                tiles_consumed_total[k] = 0;
                slot_stalled_this_tile[k] = 1'b0;
                prev_tile_idx[k] = 32'hFFFFFFFF;
            end
        end
    endtask

    task automatic report_instrumentation(input [255:0] label, input integer n_neurons_completed);
        integer k, total_tiles;
        integer total_weight_stall_cycles, total_tiles_consumed_all, total_tiles_prefetched_clean;
        real avg_waiting, avg_ready, avg_dispatched;
        real psram_util, sustained_mac_per_cycle, wallclock_us;
        real processor_utilization, weight_stall_pct, prefetch_effectiveness_pct;
        begin
            total_tiles = 0;
            for (k = 0; k < N_SLOTS_CFG; k = k + 1) total_tiles = total_tiles + slot_tiles_delivered[k];
            avg_waiting    = (sample_count > 0) ? (1.0*waiting_sum/sample_count) : 0.0;
            avg_ready      = (sample_count > 0) ? (1.0*ready_sum/sample_count) : 0.0;
            avg_dispatched = (sample_count > 0) ? (1.0*dispatched_sum/sample_count) : 0.0;
            psram_util     = (total_cycles > 0) ? (100.0*psram_busy_cycles/total_cycles) : 0.0;
            sustained_mac_per_cycle = (total_cycles > 0) ? (1.0*total_tiles*P_IN/total_cycles) : 0.0;
            wallclock_us = total_cycles * CLK_PERIOD / 1000.0;
            $display("---- BENCHMARK REPORT: %0s ----", label);
            $display("  total_cycles=%0d  wallclock_us=%0.3f", total_cycles, wallclock_us);
            $display("  neurons_completed=%0d  tiles_delivered(real)=%0d", n_neurons_completed, total_tiles);
            $display("  jobs_allocated=%0d  jobs_completed=%0d  dependency_wakeups=%0d", jobs_allocated, jobs_completed, wakeups);
            $display("  shared AR (activation+result) arbiter-side utilization: %0.1f%% (%0d/%0d busy cycles)", psram_util, psram_busy_cycles, total_cycles);
            for (k = 0; k < N_SLOTS_CFG; k = k + 1)
                $display("  slot %0d: busy=%0d/%0d (%0.1f%%) tiles=%0d", k, slot_busy_cycles[k], total_cycles,
                          (total_cycles>0)?(100.0*slot_busy_cycles[k]/total_cycles):0.0, slot_tiles_delivered[k]);
            if (sample_count > 0)
                $display("  dependency_manager avg occupancy: waiting=%0.2f ready=%0.2f dispatched=%0.2f", avg_waiting, avg_ready, avg_dispatched);
            $display("  DERIVED: sustained end-to-end MAC/cycle = %0.4f", sustained_mac_per_cycle);
            if (n_neurons_completed > 0)
                $display("  DERIVED: cycles/neuron = %0.2f", 1.0*total_cycles/n_neurons_completed);
            if (total_tiles > 0)
                $display("  DERIVED: cycles/tile = %0.2f", 1.0*total_cycles/total_tiles);

            total_weight_stall_cycles = 0; total_tiles_consumed_all = 0; total_tiles_prefetched_clean = 0;
            for (k = 0; k < N_SLOTS_CFG; k = k + 1) begin
                total_weight_stall_cycles   = total_weight_stall_cycles + weight_stall_cycles[k];
                total_tiles_consumed_all    = total_tiles_consumed_all + tiles_consumed_total[k];
                total_tiles_prefetched_clean = total_tiles_prefetched_clean + tiles_prefetched_clean[k];
            end
            weight_stall_pct = (total_cycles > 0) ? (100.0*total_weight_stall_cycles/(total_cycles*N_SLOTS_CFG*1.0)) : 0.0;
            prefetch_effectiveness_pct = (total_tiles_consumed_all > 0) ?
                (100.0*total_tiles_prefetched_clean/(total_tiles_consumed_all*1.0)) : 0.0;
            $display("  [STEP11] PFD=%0d weight_stall_cycles(sum,all slots)=%0d (%0.2f%%)",
                PFD_CFG, total_weight_stall_cycles, weight_stall_pct);
            $display("  [STEP11] DERIVED: prefetch_effectiveness = %0.2f%%", prefetch_effectiveness_pct);
        end
    endtask

    integer errors, tests;

    task automatic run_dense_layer(
        input [255:0] label,
        input integer n_neurons,
        input integer n_tiles_count,
        input [NODE_IDW-1:0] node_base,
        input [ADDR_WIDTH-1:0] x_base,
        input [ADDR_WIDTH-1:0] w_base,
        input [ADDR_WIDTH-1:0] res_base,
        input sample_occ
    );
        integer n, t, k, len, acc;
        reg signed [7:0] xv, wv, golden, real_y;
        reg [MAX_DEPS*NODE_IDW-1:0] no_deps;
        integer completed, wd2;
        begin
            len = n_tiles_count * P_IN;
            no_deps = {(MAX_DEPS*NODE_IDW){1'b0}};

            for (k = 0; k < len; k = k + 1)
                poke_byte(x_base + k, ((k % 8) + 1));

            reset_instrumentation(sample_occ);
            measure_en = 1'b1;

            for (n = 0; n < n_neurons; n = n + 1) begin
                acc = 0;
                for (t = 0; t < n_tiles_count; t = t + 1) begin
                    for (k = 0; k < P_IN; k = k + 1) begin
                        xv = peek_byte(x_base + t*P_IN + k);
                        wv = (((n + t*P_IN + k) % 8) + 1);
                        poke_byte_weight(w_base + n*len + t*P_IN + k, wv);
                        acc = acc + xv*wv;
                    end
                end
                golden = relu_sat(acc);
                poke_byte(res_base + n, 8'sd0);
                register_node(node_base + n[NODE_IDW-1:0], 0, no_deps,
                              x_base, w_base + n*len, n_tiles_count[15:0], res_base + n);
                if ((n % 32) == 0) begin
                    $display("  [%0s] registered %0d/%0d", label, n+1, n_neurons);
                    $fflush;
                end
            end
            $display("  [%0s] all %0d neurons registered, waiting for completion...", label, n_neurons);
            $fflush;

            completed = 0; wd2 = 0;
            while (completed < n_neurons && wd2 < 2000000) begin
                @(posedge clk);
                wd2 = wd2 + 1;
                completed = jobs_completed;
                if ((wd2 % 20000) == 0) begin
                    $display("  [%0s] watchdog %0d: completed=%0d/%0d total_cycles=%0d", label, wd2, completed, n_neurons, total_cycles);
                    $fflush;
                end
            end
            repeat(5) @(posedge clk);
            measure_en = 1'b0;

            tests = tests + 1;
            if (completed < n_neurons) begin
                $display("FAIL %0s: only %0d/%0d neurons completed within watchdog", label, completed, n_neurons);
                errors = errors + 1;
            end else begin : check_block
                integer local_errors;
                local_errors = 0;
                for (n = 0; n < n_neurons; n = n + 1) begin
                    acc = 0;
                    for (t = 0; t < n_tiles_count; t = t + 1)
                        for (k = 0; k < P_IN; k = k + 1)
                            acc = acc + peek_byte(x_base + t*P_IN + k) * peek_byte_weight(w_base + n*len + t*P_IN + k);
                    golden = relu_sat(acc);
                    real_y = peek_byte(res_base + n);
                    if (real_y !== golden) begin
                        $display("FAIL %0s neuron %0d: real=%0d golden=%0d", label, n, real_y, golden);
                        local_errors = local_errors + 1;
                    end
                end
                if (local_errors == 0)
                    $display("PASS %0s: all %0d neurons bit-exact vs golden", label, n_neurons);
                else
                    errors = errors + 1;
            end
            report_instrumentation(label, n_neurons);
            report_step17_instrumentation;
        end
    endtask

    initial begin
        errors = 0; tests = 0;
        rst = 1; reg_valid = 0; reg_node_id = 0; reg_required = 0; reg_producer_ids = 0;
        reg_x_base = 0; reg_w_base = 0; reg_n_tiles = 0; reg_result_addr = 0;
        measure_en = 0;
        repeat(5) @(posedge clk);
        rst = 0;

        $display("========================================");
        $display("NMS D-Stress benchmark (EXPERIMENTAL PIPELINED SDRAM controller) -- N_SLOTS_CFG=%0d PFD_CFG=%0d", N_SLOTS_CFG, PFD_CFG);
        $display("========================================");

        wait (u_nmp.u_sdram_backend.u_sdram_ctrl.state == u_nmp.u_sdram_backend.u_sdram_ctrl.S_IDLE);
        @(posedge clk);

        run_dense_layer("D-Stress", 256, 16, 16'd400, 26'h200000, 26'h010000, 26'h300000, 1'b0);

        repeat (4) @(posedge clk);
        if (u_nmp.data_ready !== 1'b1) begin
            $display("FAIL data_ready: expected 1 after graph completion, got %b", u_nmp.data_ready);
            errors = errors + 1;
        end else begin
            $display("PASS data_ready: correctly asserted after graph completion");
        end

        $display("========================================");
        if (errors == 0)
            $display("ALL %0d WORKLOAD SUITES PASSED (N_SLOTS_CFG=%0d, PFD_CFG=%0d, PIPELINED SDRAM)", tests, N_SLOTS_CFG, PFD_CFG);
        else
            $display("FAILED: %0d/%0d workload suite(s) had errors -- see messages above", errors, tests);
        $display("========================================");
        $finish;
    end

endmodule
