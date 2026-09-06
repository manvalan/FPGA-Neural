// ============================================================
// Neural Memory System (NMS) -- STEP 3: bank-contention sweep.
//
// Real, unmodified neural_processor.v x N_SLOTS, all consuming tiles
// of ONE SHARED activation vector (the realistic "one layer dispatched
// together" case, per V2's own final benchmark workloads), each with
// its own PRIVATE weight supply (modeled as always-available -- weight
// is never shared across neurons, so a private per-slot weight bank
// has zero contention by construction; STEP2's architecture.log note
// already establishes this analytically, no simulation needed for
// that half). The only thing under test here is whether banking the
// shared ACTIVATION vector (hardware/v2/nms/rtl/ideal_banked_activation.v)
// lets N_SLOTS scale despite jobs being dispatched with a realistic
// STAGGER (cycles between successive job starts, modeling the Neural
// Director's own real, non-instantaneous first-free dispatch) rather
// than all starting in perfect lockstep.
//
// Sweeps N_BANKS in {1,2,4,8} and STAGGER in {0,1,2,4,8} cycles for
// N_SLOTS in {1,2,4,8} (compile-time, one binary per N_SLOTS).
// ============================================================
`timescale 1ns/1ps

module tb_bank_contention;

    parameter N_SLOTS = 2;
    parameter P_IN     = 8;
    parameter DATA_WIDTH = 8;
    parameter ACC_WIDTH  = 32;
    parameter NTILES     = 1024;
    parameter AW         = 32;

    reg clk = 0;
    always #5 clk = ~clk;
    reg rst;

    reg [31:0] n_banks_cfg;
    reg [31:0] stagger_cfg;

    wire [N_SLOTS-1:0] act_req_valid;
    wire [N_SLOTS-1:0] act_ack;

    // N_BANKS is swept at RUNTIME (n_banks_cfg), so the bank-contention
    // arbitration below is written directly in this testbench (using a
    // runtime modulo) rather than via a separate compile-time-parameter
    // module -- see the "runtime-bank-count activation model" block
    // further down, which implements the same broadcast-on-same-address,
    // one-distinct-address-per-bank-per-cycle policy documented in
    // hardware/v2/nms/rtl/ideal_banked_activation.v (kept as the
    // reference/documented single-N_BANKS-value model).

    reg [31:0] tile_idx [0:N_SLOTS-1];
    reg [31:0] issued_count [0:N_SLOTS-1];
    reg [31:0] consumed_count [0:N_SLOTS-1];
    reg        job_started [0:N_SLOTS-1];
    reg        done_flag [0:N_SLOTS-1];
    reg [31:0] done_cycle [0:N_SLOTS-1];
    reg [31:0] combo_cycle;

    wire [N_SLOTS-1:0] job_valid_s, job_ready_s;
    wire [N_SLOTS-1:0] operand_valid_s, operand_ready_s;
    wire [N_SLOTS-1:0] tile_last_s;
    wire [N_SLOTS-1:0] result_valid_s;
    wire [3:0] np_state_s [0:N_SLOTS-1];

    genvar s;
    generate
        for (s = 0; s < N_SLOTS; s = s + 1) begin : GEN_SLOT
            wire gate = (combo_cycle >= s * stagger_cfg);
            assign job_valid_s[s] = gate && !job_started[s];
            assign act_req_valid[s] = job_started[s] && !done_flag[s];
            assign operand_valid_s[s] = act_ack[s];
            assign tile_last_s[s] = (consumed_count[s] == (NTILES - 1));

            wire tile_consumed = operand_valid_s[s] && operand_ready_s[s];

            always @(posedge clk) begin
                if (rst) begin
                    tile_idx[s] <= 32'd0;
                    consumed_count[s] <= 32'd0;
                    job_started[s] <= 1'b0;
                    done_flag[s] <= 1'b0;
                    done_cycle[s] <= 32'd0;
                end else begin
                    // must gate on the ACTUAL accepted handshake
                    // (job_valid && job_ready), not job_ready alone --
                    // job_ready is asserted whenever neural_processor.v is
                    // idle REGARDLESS of job_valid, so gating on job_ready
                    // alone latched job_started before the staggered
                    // job_valid pulse ever actually fired, permanently
                    // starving every non-lockstep slot (found via a hang:
                    // np_state stuck at NP_IDLE forever while this
                    // testbench's own bookkeeping believed the job had
                    // started).
                    if (!job_started[s] && job_valid_s[s] && job_ready_s[s]) job_started[s] <= 1'b1;
                    if (tile_consumed) begin
                        tile_idx[s] <= tile_idx[s] + 32'd1;
                        consumed_count[s] <= consumed_count[s] + 32'd1;
                    end
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
                .job_valid(job_valid_s[s]), .job_ready(job_ready_s[s]),
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

    // ---- runtime-bank-count activation model (modulo done with a
    // runtime register, not the compile-time N_BANKS parameter) ----
    //
    // Per-bank ROUND-ROBIN priority (not fixed lowest-index-wins): fixed
    // priority made the lowest-index slot always win every tie at
    // N_BANKS=1, permanently starving every other slot (they never
    // advance, done_flag never sets -> the sweep driver's own
    // "while(!all_done)" loop hangs forever) -- found by N_SLOTS>=2 runs
    // literally hanging. Round-robin rotates the winning index after
    // each cycle it wins, guaranteeing every requester eventually gets
    // served even under permanent bank contention.
    reg [N_SLOTS-1:0] bank_ack;
    integer bi, bj, bb;
    reg [31:0] bank_served_addr [0:63]; // supports up to 64 banks
    reg        bank_have_served [0:63];
    integer    bank_winner_idx [0:63];
    reg [31:0] bank_rr [0:63];          // rotating start-scan pointer/bank
    integer    scan_i, cand;

    always @* begin
        bank_ack = {N_SLOTS{1'b0}};
        for (bb = 0; bb < 64; bb = bb + 1) begin
            bank_have_served[bb] = 1'b0;
            bank_served_addr[bb] = 32'd0;
            bank_winner_idx[bb]  = 0;
        end
        for (bb = 0; bb < n_banks_cfg; bb = bb + 1) begin
            for (scan_i = 0; scan_i < N_SLOTS; scan_i = scan_i + 1) begin
                cand = (bank_rr[bb] + scan_i) % N_SLOTS;
                if (act_req_valid[cand] && ((tile_idx[cand] % n_banks_cfg) == bb) && !bank_have_served[bb]) begin
                    bank_served_addr[bb] = tile_idx[cand];
                    bank_have_served[bb] = 1'b1;
                    bank_winner_idx[bb]  = cand;
                end
            end
            if (bank_have_served[bb]) begin
                for (bj = 0; bj < N_SLOTS; bj = bj + 1) begin
                    if (act_req_valid[bj] && ((tile_idx[bj] % n_banks_cfg) == bb) && (tile_idx[bj] == bank_served_addr[bb]))
                        bank_ack[bj] = 1'b1;
                end
            end
        end
    end
    assign act_ack = bank_ack;

    always @(posedge clk) begin
        if (rst) begin
            for (bb = 0; bb < 64; bb = bb + 1) bank_rr[bb] <= 32'd0;
        end else begin
            for (bb = 0; bb < 64; bb = bb + 1) begin
                if (bb < n_banks_cfg && bank_have_served[bb])
                    bank_rr[bb] <= (bank_winner_idx[bb] + 1) % N_SLOTS;
            end
        end
    end

    always @(posedge clk) begin
        if (rst) combo_cycle <= 32'd0;
        else     combo_cycle <= combo_cycle + 32'd1;
    end

    integer ni, si_, fh;
    integer bank_list [0:3];
    integer stag_list [0:4];
    integer all_done, max_cycle;
    integer min_util_ppm, max_util_ppm, sum_util_ppm;
    real util_r;

    initial begin
        bank_list[0]=1; bank_list[1]=2; bank_list[2]=4; bank_list[3]=8;
        stag_list[0]=0; stag_list[1]=1; stag_list[2]=2; stag_list[3]=4; stag_list[4]=8;

        fh = $fopen("/tmp/nms_bank_contention.csv", "a");

        for (ni = 0; ni < 4; ni = ni + 1) begin
            for (si_ = 0; si_ < 5; si_ = si_ + 1) begin
                rst = 1'b1;
                n_banks_cfg = bank_list[ni];
                stagger_cfg = stag_list[si_];
                repeat (3) @(posedge clk);
                rst = 1'b0;

                all_done = 0;
                while (all_done == 0) begin
                    @(posedge clk);
                    all_done = 1;
                    for (bi = 0; bi < N_SLOTS; bi = bi + 1)
                        if (!done_flag[bi]) all_done = 0;
                end

                max_cycle = 0;
                min_util_ppm = 1000000; max_util_ppm = 0; sum_util_ppm = 0;
                for (bi = 0; bi < N_SLOTS; bi = bi + 1)
                    if (done_cycle[bi] > max_cycle) max_cycle = done_cycle[bi];
                for (bi = 0; bi < N_SLOTS; bi = bi + 1) begin
                    util_r = (done_cycle[bi] > 0) ? (1000000.0 * NTILES / done_cycle[bi]) : 0.0;
                    if (util_r > 1000000.0) util_r = 1000000.0;
                    if (util_r < min_util_ppm) min_util_ppm = util_r;
                    if (util_r > max_util_ppm) max_util_ppm = util_r;
                    sum_util_ppm = sum_util_ppm + util_r;
                end

                $fdisplay(fh, "%0d,%0d,%0d,%0d,%0d,%0.4f,%0.4f,%0.4f",
                    N_SLOTS, n_banks_cfg, stagger_cfg, max_cycle, NTILES,
                    min_util_ppm/1000000.0, max_util_ppm/1000000.0, (sum_util_ppm/N_SLOTS)/1000000.0);
            end
        end
        $fclose(fh);
        $display("BANK_CONTENTION_DONE N_SLOTS=%0d", N_SLOTS);
        $finish;
    end
endmodule
