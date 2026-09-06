// ============================================================
// Neural Memory System (NMS) -- STEP 11: WEIGHT-ONLY ideal-memory
// prefetch-distance sweep.
//
// Same harness/methodology as EXP-0017 (tb_bandwidth_study.v), but
// scoped specifically to the weight path per STEP11's own explicit
// instruction ("Do NOT unnecessarily modify the activation path...
// EXP-0022 already showed activation hit rate ~99.6%"). TILE_BYTES is
// P_IN (8, weight only) here, not 2*P_IN (X+W combined) as in
// EXP-0017 -- a real, different per-tile transfer size, hence a
// separate sweep rather than reusing EXP-0017's own numbers directly.
//
// Purpose: determine, using the REAL, unmodified, bit-exact
// hardware/v2/rtl/neural_processor.v compute pipeline, the minimum
// PREFETCH_DISTANCE (max outstanding weight tiles) needed to hide a
// given round-trip latency, for N_SLOTS in {1,2} (this step's own
// explicit scope), before any RTL is implemented -- IDEAL-MEMORY
// SIMULATION classification, not a real hardware measurement.
// ============================================================
`timescale 1ns/1ps

module tb_bandwidth_study;

    parameter N_SLOTS  = 2;
    parameter P_IN     = 8;
    parameter DATA_WIDTH = 8;
    parameter ACC_WIDTH  = 32;
    parameter TILE_BYTES = P_IN; // WEIGHT ONLY (activation out of scope, EXP-0022: 99.6% hit rate)
    parameter NTILES     = 2048;     // tiles per synthetic job (steady-state dominated)

    localparam TAGW = (N_SLOTS <= 1) ? 1 : $clog2(N_SLOTS);

    reg clk = 0;
    always #5 clk = ~clk;

    reg rst;

    // ---- shared ideal memory model, runtime-configurable ----
    reg  [15:0] cfg_latency;
    reg  [15:0] cfg_bw_bytes;
    wire [N_SLOTS-1:0] mem_req_valid;
    wire [N_SLOTS-1:0] mem_req_ready;
    wire [N_SLOTS-1:0] mem_resp_valid;

    ideal_memory_model #(
        .NREQ(N_SLOTS), .TILE_BYTES(TILE_BYTES), .QDEPTH(128)
    ) u_mem (
        .clk(clk), .rst(rst),
        .cfg_latency(cfg_latency), .cfg_bw_bytes(cfg_bw_bytes),
        .req_valid(mem_req_valid), .req_ready(mem_req_ready),
        .resp_valid(mem_resp_valid)
    );

    reg [31:0] prefetch_depth;

    // ---- per-slot compute + feeder ----
    wire [N_SLOTS-1:0] job_valid_s, job_ready_s;
    wire [N_SLOTS-1:0] operand_valid_s, operand_ready_s;
    wire [N_SLOTS-1:0] tile_last_s;
    wire [N_SLOTS-1:0] result_valid_s;
    wire [3:0] np_state_s [0:N_SLOTS-1];

    reg [31:0] issued_count   [0:N_SLOTS-1];
    reg [31:0] consumed_count [0:N_SLOTS-1];
    reg [31:0] buffered_count [0:N_SLOTS-1];
    reg        job_started    [0:N_SLOTS-1];
    reg        done_flag      [0:N_SLOTS-1];
    reg [31:0] done_cycle     [0:N_SLOTS-1];
    reg [31:0] stall_count    [0:N_SLOTS-1];
    reg [31:0] combo_cycle;

    genvar s;
    generate
        for (s = 0; s < N_SLOTS; s = s + 1) begin : GEN_SLOT
            wire want_fetch = (issued_count[s] < NTILES) &&
                              ((issued_count[s] - consumed_count[s]) < prefetch_depth);
            wire tile_consumed = operand_valid_s[s] && operand_ready_s[s];

            // req_valid driven COMBINATIONALLY from want_fetch (not a
            // latched pending-flag that only re-evaluates want_fetch once
            // per grant round trip) -- ideal_memory_model's own admission
            // is unconstrained (req_ready mirrors req_valid every cycle),
            // so a registered fetch_pending flag would only ever issue one
            // request every ~2 cycles regardless of PREFETCH_DEPTH/
            // bandwidth, an artificial testbench-side throughput cap
            // unrelated to the memory model being studied (found via
            // EXP-0017: utilization plateaued at ~50% even at BW=64,
            // latency=0, PREFETCH_DEPTH=8 -- a suspiciously round,
            // PFD-and-BW-independent ceiling, traced to this feeder
            // issuing at most one admitted request per two cycles).
            assign mem_req_valid[s]  = want_fetch;
            assign operand_valid_s[s] = (buffered_count[s] > 0);
            assign tile_last_s[s]     = (consumed_count[s] == (NTILES - 1));

            always @(posedge clk) begin
                if (rst) begin
                    issued_count[s]   <= 32'd0;
                end else begin
                    if (mem_req_valid[s] && mem_req_ready[s])
                        issued_count[s] <= issued_count[s] + 32'd1;
                end
            end

            always @(posedge clk) begin
                if (rst) begin
                    buffered_count[s] <= 32'd0;
                    consumed_count[s] <= 32'd0;
                    stall_count[s]    <= 32'd0;
                end else begin
                    case ({mem_resp_valid[s], tile_consumed})
                        2'b10:   buffered_count[s] <= buffered_count[s] + 32'd1;
                        2'b01:   buffered_count[s] <= buffered_count[s] - 32'd1;
                        default: buffered_count[s] <= buffered_count[s];
                    endcase
                    if (tile_consumed)
                        consumed_count[s] <= consumed_count[s] + 32'd1;
                    if ((np_state_s[s] == 4'd2) && !operand_valid_s[s]) // NP_WAIT_OPERANDS
                        stall_count[s] <= stall_count[s] + 32'd1;
                end
            end

            always @(posedge clk) begin
                if (rst) begin
                    job_started[s] <= 1'b0;
                    done_flag[s]   <= 1'b0;
                    done_cycle[s]  <= 32'd0;
                end else begin
                    if (!job_started[s] && job_ready_s[s])
                        job_started[s] <= 1'b1;
                    if (result_valid_s[s] && !done_flag[s]) begin
                        done_flag[s]  <= 1'b1;
                        done_cycle[s] <= combo_cycle;
                    end
                end
            end

            neural_processor #(
                .DATA_WIDTH(DATA_WIDTH), .P_IN(P_IN), .ACC_WIDTH(ACC_WIDTH)
            ) u_np (
                .clk(clk), .rst(rst),
                .job_valid(!job_started[s]), .job_ready(job_ready_s[s]),
                .job_node_id(s[15:0]), .job_bias({DATA_WIDTH{1'b0}}), .job_activation(2'd1),
                .operand_valid(operand_valid_s[s]), .operand_ready(operand_ready_s[s]),
                .input_data({(DATA_WIDTH*P_IN){1'b0}}), .weight_data({(DATA_WIDTH*P_IN){1'b0}}),
                .tile_last(tile_last_s[s]),
                .result_valid(result_valid_s[s]), .result_ready(1'b1),
                .result_data(), .result_node_id(),
                .np_state(np_state_s[s]), .np_error()
            );
        end
    endgenerate

    always @(posedge clk) begin
        if (rst) combo_cycle <= 32'd0;
        else     combo_cycle <= combo_cycle + 32'd1;
    end

    // ---- sweep driver ----
    integer li, bi, pi, s2;
    integer lat_list [0:5];
    integer bw_list  [0:7];
    integer pfd_list [0:5];
    integer fh;
    integer all_done;
    integer max_cycle;
    integer min_util_ppm, max_util_ppm, sum_util_ppm;
    real    util_r, mac_per_cycle_sys;

    initial begin
        lat_list[0]=0;  lat_list[1]=1;  lat_list[2]=2;  lat_list[3]=4; lat_list[4]=8; lat_list[5]=16;
        bw_list[0]=1;   bw_list[1]=2;   bw_list[2]=4;   bw_list[3]=8;  bw_list[4]=16; bw_list[5]=32; bw_list[6]=64; bw_list[7]=128;
        pfd_list[0]=1;  pfd_list[1]=2;  pfd_list[2]=4;  pfd_list[3]=8; pfd_list[4]=16; pfd_list[5]=32;

        fh = $fopen("/tmp/nms_weight_prefetch_sweep.csv", "a");

        for (pi = 0; pi < 6; pi = pi + 1) begin
            for (li = 0; li < 6; li = li + 1) begin
                for (bi = 0; bi < 8; bi = bi + 1) begin
                    // ---- configure and reset for this combo ----
                    rst = 1'b1;
                    cfg_latency  = lat_list[li];
                    cfg_bw_bytes = bw_list[bi];
                    prefetch_depth = pfd_list[pi];
                    repeat (3) @(posedge clk);
                    rst = 1'b0;

                    // ---- run until every slot has finished NTILES tiles ----
                    all_done = 0;
                    while (all_done == 0) begin
                        @(posedge clk);
                        all_done = 1;
                        for (s2 = 0; s2 < N_SLOTS; s2 = s2 + 1)
                            if (!done_flag[s2]) all_done = 0;
                    end

                    // ---- gather metrics ----
                    max_cycle = 0;
                    min_util_ppm = 1000000;
                    max_util_ppm = 0;
                    sum_util_ppm = 0;
                    for (s2 = 0; s2 < N_SLOTS; s2 = s2 + 1) begin
                        if (done_cycle[s2] > max_cycle) max_cycle = done_cycle[s2];
                    end
                    for (s2 = 0; s2 < N_SLOTS; s2 = s2 + 1) begin
                        util_r = (done_cycle[s2] > 0) ? (1000000.0 * NTILES / done_cycle[s2]) : 0.0;
                        if (util_r > 1000000.0) util_r = 1000000.0;
                        if (util_r < min_util_ppm) min_util_ppm = util_r;
                        if (util_r > max_util_ppm) max_util_ppm = util_r;
                        sum_util_ppm = sum_util_ppm + util_r;
                    end
                    mac_per_cycle_sys = (1.0 * N_SLOTS * P_IN * NTILES) / max_cycle;

                    $fdisplay(fh, "%0d,%0d,%0d,%0d,%0d,%0d,%0.4f,%0.4f,%0.4f,%0.4f",
                        N_SLOTS, prefetch_depth, cfg_latency, cfg_bw_bytes, max_cycle, NTILES,
                        min_util_ppm/1000000.0, max_util_ppm/1000000.0,
                        (sum_util_ppm/N_SLOTS)/1000000.0, mac_per_cycle_sys);
                end
            end
        end

        $fclose(fh);
        $display("BANDWIDTH_STUDY_DONE N_SLOTS=%0d", N_SLOTS);
        $finish;
    end

endmodule
