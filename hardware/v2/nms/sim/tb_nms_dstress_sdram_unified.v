`timescale 1ns/1ps

// ================================================================
// FPGA-Neural V2 -- Final Benchmark Campaign (post-M10, real
// end-to-end characterization, docs/v2-description.md §22/§30/§32)
//
// One testbench, compiled once per N_SLOTS configuration (N_SLOTS_CFG
// parameter, overridden at Verilator invocation via -GN_SLOTS_CFG=N),
// running SIX representative workloads back-to-back through the REAL
// neural_multiprocessor.v (M8: dataflow_core + slot_mem_arbiter + the
// real, unmodified V1 PSRAM chain), with:
//   - a software "golden" model replicating neural_processor.v's exact
//     integer math (sum(x*w) over all tiles, ReLU + INT8 saturate --
//     dataflow_core.v hardcodes bias=0/ACT_RELU for every job, so the
//     golden model only needs to replicate that one path)
//   - bit-exact verification of EVERY neuron's real result against
//     that golden model (peek_byte from the real psram_model backing
//     array -- an oracle independent of the RTL under test)
//   - real cycle-accounting instrumentation (testbench-only, no RTL
//     touched): per-slot busy/idle cycles, shared PSRAM port busy/idle
//     cycles, REAL tiles delivered per slot (operand_valid&&
//     operand_ready pulses -- one pulse = one whole P_IN-wide tile
//     consumed by neural_processor, NOT one byte), director/dependency
//     bookkeeping (jobs allocated/completed, ready-queue occupancy,
//     WAITING/READY/DISPATCHED node counts, producer-done wakeups)
//
// Workloads (node_id ranges are disjoint across all six so the WHOLE
// campaign runs in ONE continuous simulation -- only ONE real PSRAM
// power-up wait, no reset between phases, closer to real sustained
// operation than resetting between every workload):
//   A) Small      -- 16 independent neurons, 8 inputs each
//   B) Medium     -- 64 independent neurons, 32 inputs each
//   C) Large      -- 128 independent neurons, 128 inputs each
//   D) Stress     -- 256 independent neurons, 128 inputs each
//   E) Multilayer -- 8 layer-1 neurons (RANDOM data, logged seed) feed
//                    a shared 8-byte hidden vector; 2 layer-2 neurons
//                    consume that vector (real cross-node data
//                    forwarding through real PSRAM, real dependency
//                    wake-up, "shared producer/multiple consumers")
//   F) DAG        -- 6-node diamond+fan-in graph (A,B independent; C
//                    dep on A; D dep on B; E dep on BOTH C and D
//                    [2-hop transitive wake-up]; F dep on A,B,C [mixed
//                    direct+1-hop, 3 producers])
//
// All workloads A-D use a REALISTIC dense-layer shape: one shared
// input activation vector, N independent weight vectors (one per
// neuron) -- exactly how a real fully-connected layer's neurons share
// their layer's input. This is not an isolated synthetic microbench.
//
// Verified with Verilator (decisions.log DEC-0004).
// ================================================================

// ================================================================
// STEP11 variant: identical D-Stress workload/golden-model/correctness
// criteria as tb_nms_dstress.v (STEP9's own official benchmark), but
// instantiating nms_neural_multiprocessor_pf (REAL weight prefetch
// engine, weight_prefetch_engine.v) instead of the baseline
// nms_neural_multiprocessor.v, with an added PFD_CFG (PREFETCH_DISTANCE)
// parameter, plus NEW instrumentation (testbench-only, no RTL touched)
// for the two STEP11-mandated metrics that cannot be derived from the
// STEP9 instrumentation alone:
//   weight_stall_cycles       = cycles a slot is otherwise ready to
//                                present a tile (activation resident,
//                                in bounds) but blocked purely because
//                                tile_idx >= wgt_ready_count
//   prefetch_effectiveness    = tiles consumed with ZERO such
//                                weight-blocking cycles beforehand
//                                (i.e. the weight was ALREADY resident
//                                the moment the tile became eligible)
//                                / total tiles consumed
// per STEP11's own explicit metric definitions.
// ================================================================
module tb #(
    parameter N_SLOTS_CFG = 2,
    parameter PFD_CFG     = 8
);

    localparam ADDR_WIDTH  = 23;
    localparam DATA_WIDTH  = 8;
    localparam P_IN        = 8;
    localparam ACC_WIDTH   = 32;
    // N_NODES must exceed the HIGHEST node_id used by ANY workload
    // (node_base + count - 1) -- workload D's own range alone
    // (node_base=400, 256 neurons) reaches id 655. An earlier draft
    // used N_NODES=512: D's ids silently wrapped (9-bit truncation)
    // past id 511, colliding with workload A's already-DISPATCHED
    // node 0 (dependency_manager never reclaims dispatched node slots,
    // DEC-0008) and deadlocking register_node's reg_ready wait
    // forever. A real consequence of DEC-0008's design choice, not an
    // RTL bug -- fixed here by sizing N_NODES generously above the
    // real id range used below (see decisions.log DEC-0008 and the
    // final benchmark report's Limitations section).
    localparam N_NODES     = 1024;
    localparam MAX_DEPS    = 8;
    localparam QUEUE_DEPTH = 8;
    localparam NODE_IDW    = $clog2(N_NODES);
    localparam CLK_PERIOD  = 12.5; // 80 MHz, matches psram_controller's CLK_FREQ_MHZ

    reg clk, rst;
    initial begin clk = 1'b0; forever #(CLK_PERIOD/2.0) clk = ~clk; end

    reg                                reg_valid;
    wire                               reg_ready;
    reg  [NODE_IDW-1:0]                reg_node_id;
    reg  [$clog2(MAX_DEPS+1)-1:0]      reg_required;
    reg  [MAX_DEPS*NODE_IDW-1:0]       reg_producer_ids;
    reg  [ADDR_WIDTH-1:0]              reg_x_base, reg_w_base, reg_result_addr;
    reg  [15:0]                        reg_n_tiles;

    // STEP19: ONE physical SDRAM interface. weights, activations, and
    // results ALL share this single bus/chip now -- no PSRAM anywhere.
    wire        sdram_cke, sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n;
    wire [1:0]  sdram_ba;
    wire [11:0] sdram_a;
    wire [15:0] sdram_dq;
    wire [1:0]  sdram_dqm;

    nms_neural_multiprocessor_sdram_unified #(
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

    // ============================================================
    // STEP19: byte-level backdoor access (test setup/verification
    // only) -- weights, activations, AND results now ALL live on the
    // single real SDRAM physical interface (u_sdram); there is no
    // PSRAM anywhere in this system anymore. poke_byte/peek_byte (used
    // by activation+result call sites) and poke_byte_weight/peek_byte
    // _weight (used by weight call sites) are now identical in
    // implementation -- kept as two names rather than merged, to avoid
    // touching every one of their many existing call sites for a
    // cosmetic rename; both correctly target the same u_sdram.mem
    // backing array via the same byte_addr>>1 / byte_addr[0] pattern.
    // ============================================================
    task automatic poke_byte(input [ADDR_WIDTH-1:0] byte_addr, input signed [7:0] val);
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

    // sdram_model.v's own `mem` array is flat-indexed by the 22-bit
    // word address directly (bank*ROWS*COLS + row*COLS + col, which,
    // given ROWS=4096/COLS=256 are both powers of 2, is numerically
    // IDENTICAL to treating the address as one flat 22-bit integer --
    // confirmed against sdram_model.v's own BANKS/ROWS/COLS localparams
    // before writing this, not assumed) -- so this is the exact same
    // byte_addr>>1 / byte_addr[0] pattern as the original single-chip
    // poke_byte/peek_byte above, just against u_sdram.mem instead of
    // u_psram.mem.
    task automatic poke_byte_weight(input [ADDR_WIDTH-1:0] byte_addr, input signed [7:0] val);
        reg [21:0] word_addr;
        begin
            word_addr = byte_addr[ADDR_WIDTH-1:1];
            if (byte_addr[0] == 1'b0) u_sdram.mem[word_addr][7:0]  = val;
            else                      u_sdram.mem[word_addr][15:8] = val;
        end
    endtask

    function automatic signed [7:0] peek_byte_weight(input [ADDR_WIDTH-1:0] byte_addr);
        reg [21:0] word_addr;
        begin
            word_addr = byte_addr[ADDR_WIDTH-1:1];
            peek_byte_weight = (byte_addr[0] == 1'b0) ? u_sdram.mem[word_addr][7:0] : u_sdram.mem[word_addr][15:8];
        end
    endfunction

    // Golden model: exactly replicates neural_processor.v's real path
    // through dataflow_core (bias=0, ACT_RELU always -- see
    // dataflow_core.v's own hardcoded job_bias/job_activation).
    function automatic signed [7:0] relu_sat(input integer acc);
        begin
            if (acc <= 0)        relu_sat = 8'sd0;
            else if (acc > 127)  relu_sat = 8'sd127;
            else                 relu_sat = acc[7:0];
        end
    endfunction

    // ============================================================
    // Node registration (generalized to MAX_DEPS=8 producers, passed
    // as a packed array; n_producers of them are meaningful, the rest
    // ignored since reg_required gates how many entries the RTL
    // actually reads).
    // ============================================================
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

    // ============================================================
    // M10+ real cycle-accounting instrumentation (testbench-only, no
    // RTL touched -- same idiom as EXP-0013).
    // ============================================================
    reg measure_en;
    integer total_cycles;
    integer psram_busy_cycles;
    genvar gi;

    reg [N_SLOTS_CFG-1:0] slot_busy_bit;   // memory_manager.state != MM_IDLE, this cycle
    reg [N_SLOTS_CFG-1:0] slot_tile_bit;   // operand_valid && operand_ready, this cycle
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

    // ============================================================
    // STEP17 Part B/C: cycle-decomposition + SDRAM effectiveness
    // instrumentation (testbench-only, no RTL touched).
    // ============================================================
    integer active_count;               // popcount(slot_busy_bit) this cycle
    integer active_hist [0:4];          // cycles with exactly k active slots, k=0..4
    integer useful_mac_cycles;          // sum over cycles of (#slots with slot_tile_bit this cycle)
    integer first_tile_cyc;             // total_cycles value at the first tile ever delivered (startup boundary)
    integer last_tile_cyc;              // total_cycles value at the most recent tile delivered (drain boundary)
    integer any_tile_bit;

    // SDRAM controller-port instrumentation (real signals on the
    // actual sdram_controller.v instance servicing all weight fetch)
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

            // ---- real SDRAM controller port (single physical chip,
            // all weight-fetch traffic funnels through this one
            // instance) ----
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
            $display("  ---- STEP17 Part B: cycle decomposition ----");
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
            $display("  ---- STEP17 Part C: SDRAM effectiveness ----");
            sdram_avg_lat = (sdram_lat_n > 0) ? (1.0*sdram_lat_sum/sdram_lat_n) : 0.0;
            sdram_busy_pct = (total_cycles > 0) ? (100.0*sdram_busy_cycles/total_cycles) : 0.0;
            sdram_bytes_per_cycle = (total_cycles > 0) ? (8.0*sdram_ready_count/total_cycles) : 0.0;
            $display("    sdram_req_count=%0d  sdram_ready_count=%0d  sdram_wr_count=%0d (real reads vs writes)",
                sdram_req_count, sdram_ready_count, sdram_wr_count);
            $display("    sdram_busy_cycles=%0d/%0d (%0.2f%%)", sdram_busy_cycles, total_cycles, sdram_busy_pct);
            $display("    sdram_refresh_count=%0d (real AUTO REFRESH commands issued)", sdram_refresh_count);
            $display("    sdram_request_latency: min=%0d max=%0d avg=%0.2f cycles (req-to-ready, single controller port)",
                sdram_lat_min, sdram_lat_max, sdram_avg_lat);
            $display("    sdram_avg_bytes_per_cycle (8 bytes/transaction * ready_count / total_cycles)=%0.4f", sdram_bytes_per_cycle);
        end
    endtask

    // ---- STEP11: weight-stall / prefetch-effectiveness instrumentation ----
    // slot_could_present_act: this slot's tile_idx is in-bounds and the
    // activation operand for it is already resident -- i.e. everything
    // EXCEPT the weight is ready. slot_weight_blocking: on top of that,
    // the weight specifically is NOT yet ready (tile_idx>=wgt_ready_count)
    // and the FSM is genuinely stalled on it (not mid-read-pipeline, not
    // already holding a valid operand).
    wire [N_SLOTS_CFG-1:0] slot_could_present_act;
    wire [N_SLOTS_CFG-1:0] slot_weight_blocking;
    reg  [N_SLOTS_CFG-1:0] slot_stalled_this_tile; // sticky per current tile_idx
    reg  [31:0] prev_tile_idx [0:N_SLOTS_CFG-1];
    integer weight_stall_cycles [0:N_SLOTS_CFG-1];
    integer tiles_prefetched_clean [0:N_SLOTS_CFG-1]; // consumed w/ zero weight-blocking cycles
    integer tiles_consumed_total [0:N_SLOTS_CFG-1];
    // plain (non-hierarchical) mirrors of each slot's tile_idx, populated
    // combinationally inside the genvar-indexed generate block below --
    // a generate-block instance array (GEN_SLOT[.]) can only be indexed
    // by a constant genvar, not a runtime `for` variable, so the
    // sequential accumulation loop reads these plain arrays instead of
    // reaching back into the hierarchy with a runtime index.
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
                // nms_memory_manager_stream.v has no read_issued/
                // read_ready states (replaced by the rd_ptr/rd_pending
                // read-ahead pipeline) -- the equivalent "blocked
                // purely on weight readiness, nothing buffered yet"
                // condition is simply: consumption pointer in bounds,
                // activation ready, weight NOT ready, and no operand
                // currently held in the skid buffer awaiting NP.
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
                    // moved on to a new tile: clear the sticky flag for it
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

    // Director/dependency bookkeeping
    integer jobs_allocated, jobs_completed, wakeups;
    integer waiting_sum, ready_sum, dispatched_sum, sample_count;
    integer ni;

    // Occupancy sampling is EXPENSIVE (a full N_NODES=512 scan) and is
    // only needed for the small/structural workloads (A/B/E/F), not
    // for the large neuron counts (C/D) where it would dominate
    // simulation wall-time for no real benefit (per-slot/PSRAM/tile
    // counters below are cheap and always collected). Gated by
    // sample_occupancy, set per-workload.
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
                $display("  dependency_manager avg occupancy (sampled every measured cycle): waiting=%0.2f ready=%0.2f dispatched=%0.2f", avg_waiting, avg_ready, avg_dispatched);
            else
                $display("  dependency_manager occupancy: NOT SAMPLED for this workload (N_NODES scan skipped for large neuron counts to keep simulation time reasonable)");
            $display("  DERIVED: sustained end-to-end MAC/cycle = %0.4f (real tiles*%0d / real total_cycles)", sustained_mac_per_cycle, P_IN);
            if (n_neurons_completed > 0)
                $display("  DERIVED: cycles/neuron = %0.2f", 1.0*total_cycles/n_neurons_completed);
            if (total_tiles > 0)
                $display("  DERIVED: cycles/tile = %0.2f", 1.0*total_cycles/total_tiles);

            // ---- STEP11 metrics ----
            total_weight_stall_cycles = 0; total_tiles_consumed_all = 0; total_tiles_prefetched_clean = 0;
            for (k = 0; k < N_SLOTS_CFG; k = k + 1) begin
                total_weight_stall_cycles   = total_weight_stall_cycles + weight_stall_cycles[k];
                total_tiles_consumed_all    = total_tiles_consumed_all + tiles_consumed_total[k];
                total_tiles_prefetched_clean = total_tiles_prefetched_clean + tiles_prefetched_clean[k];
            end
            processor_utilization = (total_cycles > 0) ? (100.0*total_tiles/(total_cycles*1.0)) : 0.0;
            weight_stall_pct = (total_cycles > 0) ? (100.0*total_weight_stall_cycles/(total_cycles*N_SLOTS_CFG*1.0)) : 0.0;
            prefetch_effectiveness_pct = (total_tiles_consumed_all > 0) ?
                (100.0*total_tiles_prefetched_clean/(total_tiles_consumed_all*1.0)) : 0.0;
            $display("  [STEP11] PFD=%0d weight_stall_cycles(sum,all slots)=%0d (%0.2f%% of total_cycles*N_SLOTS)",
                PFD_CFG, total_weight_stall_cycles, weight_stall_pct);
            $display("  [STEP11] tiles_consumed=%0d  tiles_prefetched_clean(zero weight-block before consumption)=%0d",
                total_tiles_consumed_all, total_tiles_prefetched_clean);
            $display("  [STEP11] DERIVED: prefetch_effectiveness = %0.2f%%", prefetch_effectiveness_pct);
            $display("  [STEP11] DERIVED: processor_utilization (tiles*P_IN-equivalent proxy, see sustained MAC/cycle) reference sustained_mac_per_cycle=%0.4f", sustained_mac_per_cycle);
        end
    endtask

    // ============================================================
    // Workload generators
    // ============================================================
    integer errors, tests;
    integer wd;

    // A/B/C/D: shared-input dense layer. Generates the shared X
    // vector, then N independent (neuron, weight-vector) jobs, each
    // verified bit-exact against the golden model.
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

            // shared input vector
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
                poke_byte(res_base + n, 8'sd0); // poison, must NOT still be 0 after completion (unless golden IS 0 -- checked separately)
                register_node(node_base + n[NODE_IDW-1:0], 0, no_deps,
                              x_base, w_base + n*len, n_tiles_count[15:0], res_base + n);
                if ((n % 32) == 0) begin
                    $display("  [%0s] registered %0d/%0d", label, n+1, n_neurons);
                    $fflush;
                end
            end
            $display("  [%0s] all %0d neurons registered, waiting for completion...", label, n_neurons);
            $fflush;

            // wait for all n_neurons completions
            completed = 0; wd2 = 0;
            while (completed < n_neurons && wd2 < 2000000) begin
                @(posedge clk);
                wd2 = wd2 + 1;
                completed = jobs_completed;
                if ((wd2 % 20000) == 0) begin
                    $display("  [%0s] watchdog %0d: completed=%0d/%0d total_cycles=%0d", label, wd2, completed, n_neurons, total_cycles);
`ifdef STEP16_DEBUG_TRACE
                    $display("    slot0: mm.state=%0d tile_idx=%0d n_tiles_reg=%0d wgt_ready_count=%0d usable_act=%0d op_valid=%0d op_ready=%0d",
                        u_nmp.u_dataflow_core.GEN_SLOT[0].u_mm.state,
                        u_nmp.u_dataflow_core.GEN_SLOT[0].u_mm.tile_idx,
                        u_nmp.u_dataflow_core.GEN_SLOT[0].u_mm.n_tiles_reg,
                        u_nmp.u_dataflow_core.GEN_SLOT[0].u_mm.wgt_ready_count,
                        u_nmp.u_dataflow_core.GEN_SLOT[0].u_mm.usable_act,
                        u_nmp.u_dataflow_core.GEN_SLOT[0].mm_operand_valid,
                        u_nmp.u_dataflow_core.GEN_SLOT[0].mm_operand_ready);
                    $display("    slot1: mm.state=%0d tile_idx=%0d n_tiles_reg=%0d wgt_ready_count=%0d usable_act=%0d op_valid=%0d op_ready=%0d",
                        u_nmp.u_dataflow_core.GEN_SLOT[1].u_mm.state,
                        u_nmp.u_dataflow_core.GEN_SLOT[1].u_mm.tile_idx,
                        u_nmp.u_dataflow_core.GEN_SLOT[1].u_mm.n_tiles_reg,
                        u_nmp.u_dataflow_core.GEN_SLOT[1].u_mm.wgt_ready_count,
                        u_nmp.u_dataflow_core.GEN_SLOT[1].u_mm.usable_act,
                        u_nmp.u_dataflow_core.GEN_SLOT[1].mm_operand_valid,
                        u_nmp.u_dataflow_core.GEN_SLOT[1].mm_operand_ready);
                    $display("    sdram: req=%0d busy=%0d ready=%0d req_pending=%0d state=%0d | arb: owner=%0d pending=%0b wide_req=%0b wide_ready=%0b",
                        u_nmp.u_sdram_backend.u_sdram_ctrl.req,
                        u_nmp.u_sdram_backend.u_sdram_ctrl.busy,
                        u_nmp.u_sdram_backend.u_sdram_ctrl.ready,
                        u_nmp.u_sdram_backend.u_sdram_ctrl.req_pending,
                        u_nmp.u_sdram_backend.u_sdram_ctrl.state,
                        u_nmp.u_arbiter_wide.owner,
                        u_nmp.u_arbiter_wide.pending,
                        u_nmp.wide_slot_mem_req,
                        u_nmp.wide_slot_mem_ready);
`endif
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

    // E: Multilayer (8 layer-1 random neurons -> shared hidden vector
    // -> 2 layer-2 neurons consuming it, real dependency wake-up +
    // real cross-node data forwarding through real PSRAM).
    localparam L1_N = 8;
    localparam L2_N = 2;
    integer rand_seed;

    task automatic run_multilayer(
        input [NODE_IDW-1:0] node_base,
        input [ADDR_WIDTH-1:0] l1x_base, input [ADDR_WIDTH-1:0] l1w_base,
        input [ADDR_WIDTH-1:0] hidden_base,
        input [ADDR_WIDTH-1:0] l2w_base, input [ADDR_WIDTH-1:0] l2res_base
    );
        integer n, k, acc, completed, wd2;
        reg signed [7:0] xv, wv, golden_l1 [0:L1_N-1], golden_l2, real_y;
        reg [MAX_DEPS*NODE_IDW-1:0] no_deps, l2_deps;
        integer local_errors;
        begin
            no_deps = {(MAX_DEPS*NODE_IDW){1'b0}};
            l2_deps = {(MAX_DEPS*NODE_IDW){1'b0}};
            for (n = 0; n < L1_N; n = n + 1)
                l2_deps[n*NODE_IDW +: NODE_IDW] = node_base + n[NODE_IDW-1:0];

            rand_seed = 32'hC0FFEE01;
            $display("RANDOM SEED (workload E, layer-1 data) = 32'h%08h", rand_seed);

            reset_instrumentation(1'b1);
            measure_en = 1'b1;

            for (n = 0; n < L1_N; n = n + 1) begin
                acc = 0;
                for (k = 0; k < P_IN; k = k + 1) begin
                    xv = $random(rand_seed) % 9; // deterministic PRNG stream, range roughly [-8,8]
                    wv = $random(rand_seed) % 9;
                    poke_byte(l1x_base + n*P_IN + k, xv);
                    poke_byte(l1w_base + n*P_IN + k, wv);
                    acc = acc + xv*wv;
                end
                golden_l1[n] = relu_sat(acc);
                poke_byte(hidden_base + n, 8'sd0); // poison hidden slot
                register_node(node_base + n[NODE_IDW-1:0], 0, no_deps,
                              l1x_base + n*P_IN, l1w_base + n*P_IN, 16'd1, hidden_base + n);
            end

            for (n = 0; n < L2_N; n = n + 1) begin
                for (k = 0; k < P_IN; k = k + 1)
                    poke_byte(l2w_base + n*P_IN + k, ((n + k) % 6) + 1);
                register_node(node_base + L1_N[NODE_IDW-1:0] + n[NODE_IDW-1:0], L1_N[$clog2(MAX_DEPS+1)-1:0], l2_deps,
                              hidden_base, l2w_base + n*P_IN, 16'd1, l2res_base + n);
            end

            completed = 0; wd2 = 0;
            while (completed < (L1_N+L2_N) && wd2 < 2000000) begin
                @(posedge clk); wd2 = wd2 + 1; completed = jobs_completed;
            end
            repeat(5) @(posedge clk);
            measure_en = 1'b0;

            tests = tests + 1;
            local_errors = 0;
            if (completed < (L1_N+L2_N)) begin
                $display("FAIL Multilayer: only %0d/%0d nodes completed", completed, L1_N+L2_N);
                local_errors = local_errors + 1;
            end else begin
                for (n = 0; n < L1_N; n = n + 1) begin
                    real_y = peek_byte(hidden_base + n);
                    if (real_y !== golden_l1[n]) begin
                        $display("FAIL Multilayer L1 neuron %0d: real=%0d golden=%0d", n, real_y, golden_l1[n]);
                        local_errors = local_errors + 1;
                    end
                end
                for (n = 0; n < L2_N; n = n + 1) begin
                    acc = 0;
                    for (k = 0; k < P_IN; k = k + 1)
                        acc = acc + golden_l1[k] * peek_byte(l2w_base + n*P_IN + k);
                    golden_l2 = relu_sat(acc);
                    real_y = peek_byte(l2res_base + n);
                    if (real_y !== golden_l2) begin
                        $display("FAIL Multilayer L2 neuron %0d: real=%0d golden=%0d (using REAL L1 hidden values)", n, real_y, golden_l2);
                        local_errors = local_errors + 1;
                    end
                end
            end
            if (local_errors == 0) $display("PASS Multilayer: 8 L1 (random) -> 2 L2 neurons, all bit-exact, real cross-node forwarding via real PSRAM");
            else errors = errors + 1;
            report_instrumentation("E-Multilayer", L1_N+L2_N);
        end
    endtask

    // F: DAG diamond+fan-in (A,B indep; C dep-A; D dep-B; E dep-C&D
    // [2-hop]; F dep-A,B,C [mixed, 3 producers])
    task automatic run_dag(
        input [NODE_IDW-1:0] node_base,
        input [ADDR_WIDTH-1:0] x_base, input [ADDR_WIDTH-1:0] w_base, input [ADDR_WIDTH-1:0] res_base
    );
        integer n, k, acc, completed, wd2, local_errors;
        reg signed [7:0] golden [0:5];
        reg signed [7:0] real_y;
        reg [MAX_DEPS*NODE_IDW-1:0] deps;
        reg [NODE_IDW-1:0] idA, idB, idC, idD, idE, idF;
        begin
            idA = node_base+0; idB = node_base+1; idC = node_base+2;
            idD = node_base+3; idE = node_base+4; idF = node_base+5;

            // Each of the 6 nodes: its own small independent 8-input
            // job (deterministic, distinct per node) -- dependencies
            // here are purely about SCHEDULING/wake-up order, not
            // data forwarding (workload E already covers that).
            for (n = 0; n < 6; n = n + 1) begin
                acc = 0;
                for (k = 0; k < P_IN; k = k + 1) begin
                    poke_byte(x_base + n*P_IN + k, ((n+k)%4)+1);
                    poke_byte(w_base + n*P_IN + k, ((n+k)%5)+1);
                    acc = acc + peek_byte(x_base+n*P_IN+k)*peek_byte(w_base+n*P_IN+k);
                end
                golden[n] = relu_sat(acc);
                poke_byte(res_base + n, 8'sd0);
            end

            reset_instrumentation(1'b1);
            measure_en = 1'b1;

            deps = {(MAX_DEPS*NODE_IDW){1'b0}};
            register_node(idA, 0, deps, x_base+0*P_IN, w_base+0*P_IN, 16'd1, res_base+0);
            register_node(idB, 0, deps, x_base+1*P_IN, w_base+1*P_IN, 16'd1, res_base+1);

            deps = {(MAX_DEPS*NODE_IDW){1'b0}}; deps[0*NODE_IDW+:NODE_IDW] = idA;
            register_node(idC, 1, deps, x_base+2*P_IN, w_base+2*P_IN, 16'd1, res_base+2);

            deps = {(MAX_DEPS*NODE_IDW){1'b0}}; deps[0*NODE_IDW+:NODE_IDW] = idB;
            register_node(idD, 1, deps, x_base+3*P_IN, w_base+3*P_IN, 16'd1, res_base+3);

            deps = {(MAX_DEPS*NODE_IDW){1'b0}}; deps[0*NODE_IDW+:NODE_IDW] = idC; deps[1*NODE_IDW+:NODE_IDW] = idD;
            register_node(idE, 2, deps, x_base+4*P_IN, w_base+4*P_IN, 16'd1, res_base+4);

            deps = {(MAX_DEPS*NODE_IDW){1'b0}}; deps[0*NODE_IDW+:NODE_IDW] = idA; deps[1*NODE_IDW+:NODE_IDW] = idB; deps[2*NODE_IDW+:NODE_IDW] = idC;
            register_node(idF, 3, deps, x_base+5*P_IN, w_base+5*P_IN, 16'd1, res_base+5);

            completed = 0; wd2 = 0;
            while (completed < 6 && wd2 < 2000000) begin @(posedge clk); wd2=wd2+1; completed = jobs_completed; end
            repeat(5) @(posedge clk);
            measure_en = 1'b0;

            tests = tests + 1;
            local_errors = 0;
            if (completed < 6) begin
                $display("FAIL DAG: only %0d/6 nodes completed", completed);
                local_errors = local_errors + 1;
            end else begin
                for (n = 0; n < 6; n = n + 1) begin
                    real_y = peek_byte(res_base+n);
                    if (real_y !== golden[n]) begin
                        $display("FAIL DAG node %0d: real=%0d golden=%0d", n, real_y, golden[n]);
                        local_errors = local_errors + 1;
                    end
                end
            end
            if (local_errors == 0) $display("PASS DAG: 6-node diamond+fan-in (2-hop transitive wake-up, 3-producer mixed-depth dependency), all bit-exact");
            else errors = errors + 1;
            report_instrumentation("F-DAG", 6);
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
        $display("NMS D-Stress benchmark (STEP19, SINGLE SDRAM (AS4C4M16SA-6TIN) for weights+activations+results, no PSRAM anywhere) -- N_SLOTS_CFG=%0d PFD_CFG=%0d", N_SLOTS_CFG, PFD_CFG);
        $display("========================================");

        wait (u_nmp.u_sdram_backend.u_sdram_ctrl.state == u_nmp.u_sdram_backend.u_sdram_ctrl.S_IDLE);
        @(posedge clk);

        // STEP19 official memory map (hardware/v2/docs/MEMORY_ARCHITECTURE.md):
        // weights @ 0x010000, activations @ 0x200000, results @ 0x300000 --
        // non-overlapping 1MB-aligned regions in the single 8MB SDRAM.
        run_dense_layer("D-Stress", 256, 16, 16'd400, 23'h200000, 23'h010000, 23'h300000, 1'b0);

        $display("========================================");
        if (errors == 0)
            $display("ALL %0d WORKLOAD SUITES PASSED (N_SLOTS_CFG=%0d, PFD_CFG=%0d, SINGLE SDRAM for weights+activations+results, no PSRAM)", tests, N_SLOTS_CFG, PFD_CFG);
        else
            $display("FAILED: %0d/%0d workload suite(s) had errors -- see messages above", errors, tests);
        $display("========================================");
        $finish;
    end

endmodule
