`timescale 1ns/1ps

// ================================================================
// V3 -- Neural Director, forked from hardware/v2/rtl/neural_director.v
// (M5) for the DSP48-packed, weight-reuse compute core
// (neural_processor_packed.v, EXP-0059/0062).
//
// KEY DIFFERENCE FROM V2: each "slot" here is one packed core, which
// processes TWO jobs (A, B) per dispatch, SHARING one weight stream
// (one w_base/n_tiles). This module therefore dispatches PAIRS of
// queued job descriptors, not single jobs.
//
// PAIRING RULE (real, disclosed scope limitation, not hidden): the
// two oldest entries in the queue (q_head, q_head+1) are dispatched
// together ONLY if they share the SAME w_base and n_tiles -- i.e.
// the job submitter is REQUIRED to enqueue reuse-position jobs for
// the same resident weight consecutively, in pairs (exactly the
// pattern this project's own EXP-0057/0058/0062 testbenches already
// use: M reuse positions per layer, submitted in order). If the two
// oldest entries do NOT share w_base/n_tiles, this Director does NOT
// dispatch (stalls, does not error, does not silently mis-pair) --
// matches this project's own "an error must not block the rest of
// the system, but a wrong dispatch must never happen" standard
// (§34). A submitter that violates the pairing assumption will see
// the queue simply stop draining, a visible, diagnosable symptom,
// not silent data corruption. Odd-length reuse-position batches (M
// odd) are therefore also not supported by this Director alone --
// the submitter must pad to an even count or handle the last single
// position through a different path (out of scope here).
//
// job_x_base becomes job_x_base_a/job_x_base_b (each position's own
// activation base); w_base/n_tiles/result region addressing convention
// stays per-job (job_result_addr_a/b) since each position still
// writes its own independent result.
// ================================================================

module neural_director_packed #(
    parameter ADDR_WIDTH  = 26,
    parameter N_SLOTS     = 4,
    parameter QUEUE_DEPTH = 8
)(
    input  wire clk,
    input  wire rst,

    // ---- job submission: unchanged single-job-descriptor producer
    // interface (pairing happens internally, on dequeue) ----
    input  wire                     job_in_valid,
    output wire                     job_in_ready,
    input  wire [ADDR_WIDTH-1:0]    job_in_x_base,
    input  wire [ADDR_WIDTH-1:0]    job_in_w_base,
    input  wire [15:0]              job_in_n_tiles,
    input  wire [ADDR_WIDTH-1:0]    job_in_result_addr,
    input  wire [15:0]              job_in_node_id,

    // ---- per-slot packed-core job control (arrayed) ----
    output wire [N_SLOTS-1:0]              slot_job_start,
    output wire [ADDR_WIDTH*N_SLOTS-1:0]   slot_x_base_a,
    output wire [ADDR_WIDTH*N_SLOTS-1:0]   slot_x_base_b,
    output wire [ADDR_WIDTH*N_SLOTS-1:0]   slot_w_base,      // shared A/B
    output wire [16*N_SLOTS-1:0]           slot_n_tiles,     // shared A/B
    output wire [ADDR_WIDTH*N_SLOTS-1:0]   slot_result_addr_a,
    output wire [ADDR_WIDTH*N_SLOTS-1:0]   slot_result_addr_b,
    output wire [16*N_SLOTS-1:0]           slot_node_id_a,
    output wire [16*N_SLOTS-1:0]           slot_node_id_b,
    input  wire [N_SLOTS-1:0]              slot_job_done,    // both A+B done together

    output reg                       job_out_done,  // one-cycle pulse
    output reg  [$clog2(N_SLOTS)-1:0] job_out_slot,

    output reg [3:0] dir_state,
    output reg       dir_error,

    output wire      queue_empty
);

    localparam DIR_IDLE       = 4'd0;
    localparam DIR_SCAN_READY = 4'd1;
    localparam DIR_ALLOCATE   = 4'd2;
    localparam DIR_ERROR      = 4'd3;

    localparam Q_ADDR_WIDTH = $clog2(QUEUE_DEPTH);

    reg [ADDR_WIDTH-1:0] q_x_base      [0:QUEUE_DEPTH-1];
    reg [ADDR_WIDTH-1:0] q_w_base      [0:QUEUE_DEPTH-1];
    reg [15:0]           q_n_tiles     [0:QUEUE_DEPTH-1];
    reg [ADDR_WIDTH-1:0] q_result_addr [0:QUEUE_DEPTH-1];
    reg [15:0]           q_node_id     [0:QUEUE_DEPTH-1];

    reg [Q_ADDR_WIDTH-1:0] q_head, q_tail;
    reg [Q_ADDR_WIDTH:0]   q_count;

    wire q_empty = (q_count == 0);
    assign queue_empty = q_empty;
    wire q_full  = (q_count == QUEUE_DEPTH[Q_ADDR_WIDTH:0]);
    wire q_has_pair = (q_count >= 2);

    assign job_in_ready = !q_full;

    // second-oldest entry's index (q_head+1, wrapping)
    wire [Q_ADDR_WIDTH-1:0] q_head_plus1 =
        (q_head == QUEUE_DEPTH[Q_ADDR_WIDTH-1:0]-1'b1) ? {Q_ADDR_WIDTH{1'b0}} : q_head + 1'b1;

    // the two oldest entries share a resident weight iff w_base AND
    // n_tiles both match -- both are checked (not just w_base) since a
    // real mismatched n_tiles with a coincidentally-equal w_base would
    // otherwise still be wrongly accepted as a pair.
    wire pair_ready = q_has_pair &&
        (q_w_base[q_head] == q_w_base[q_head_plus1]) &&
        (q_n_tiles[q_head] == q_n_tiles[q_head_plus1]);

    reg [N_SLOTS-1:0] slot_busy;
    wire [N_SLOTS-1:0] slot_free = ~slot_busy;
    wire                any_slot_free = |slot_free;

    reg [$clog2(N_SLOTS)-1:0] free_slot_idx;
    integer fi;
    always @(*) begin
        free_slot_idx = '0;
        for (fi = N_SLOTS-1; fi >= 0; fi = fi - 1) begin
            if (slot_free[fi]) free_slot_idx = fi[$clog2(N_SLOTS)-1:0];
        end
    end

    // per-slot output storage -- N_SLOTS parallel constant-indexed
    // writes, same anti-pattern-avoidance as V2's own neural_director.v
    // (see that file's own slot_x_base_r comment, ERR-0027).
    reg                  slot_job_start_r     [0:N_SLOTS-1];
    reg [ADDR_WIDTH-1:0] slot_x_base_a_r      [0:N_SLOTS-1];
    reg [ADDR_WIDTH-1:0] slot_x_base_b_r      [0:N_SLOTS-1];
    reg [ADDR_WIDTH-1:0] slot_w_base_r        [0:N_SLOTS-1];
    reg [15:0]           slot_n_tiles_r       [0:N_SLOTS-1];
    reg [ADDR_WIDTH-1:0] slot_result_addr_a_r [0:N_SLOTS-1];
    reg [ADDR_WIDTH-1:0] slot_result_addr_b_r [0:N_SLOTS-1];
    reg [15:0]           slot_node_id_a_r     [0:N_SLOTS-1];
    reg [15:0]           slot_node_id_b_r     [0:N_SLOTS-1];

    genvar gs;
    generate
        for (gs = 0; gs < N_SLOTS; gs = gs + 1) begin : GEN_SLOT_OUT
            assign slot_job_start[gs]                               = slot_job_start_r[gs];
            assign slot_x_base_a[gs*ADDR_WIDTH +: ADDR_WIDTH]        = slot_x_base_a_r[gs];
            assign slot_x_base_b[gs*ADDR_WIDTH +: ADDR_WIDTH]        = slot_x_base_b_r[gs];
            assign slot_w_base[gs*ADDR_WIDTH +: ADDR_WIDTH]          = slot_w_base_r[gs];
            assign slot_n_tiles[gs*16 +: 16]                         = slot_n_tiles_r[gs];
            assign slot_result_addr_a[gs*ADDR_WIDTH +: ADDR_WIDTH]   = slot_result_addr_a_r[gs];
            assign slot_result_addr_b[gs*ADDR_WIDTH +: ADDR_WIDTH]   = slot_result_addr_b_r[gs];
            assign slot_node_id_a[gs*16 +: 16]                       = slot_node_id_a_r[gs];
            assign slot_node_id_b[gs*16 +: 16]                       = slot_node_id_b_r[gs];
        end
    endgenerate

    reg [$clog2(N_SLOTS)-1:0] done_slot_idx;
    integer di;
    always @(*) begin
        done_slot_idx = '0;
        for (di = N_SLOTS-1; di >= 0; di = di - 1) begin
            if (slot_job_done[di]) done_slot_idx = di[$clog2(N_SLOTS)-1:0];
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            dir_state  <= DIR_IDLE;
            dir_error  <= 1'b0;
            q_head     <= {Q_ADDR_WIDTH{1'b0}};
            q_tail     <= {Q_ADDR_WIDTH{1'b0}};
            q_count    <= {(Q_ADDR_WIDTH+1){1'b0}};
            slot_busy  <= {N_SLOTS{1'b0}};
            for (fi = 0; fi < N_SLOTS; fi = fi + 1) begin
                slot_job_start_r[fi]     <= 1'b0;
                slot_x_base_a_r[fi]      <= {ADDR_WIDTH{1'b0}};
                slot_x_base_b_r[fi]      <= {ADDR_WIDTH{1'b0}};
                slot_w_base_r[fi]        <= {ADDR_WIDTH{1'b0}};
                slot_n_tiles_r[fi]       <= 16'b0;
                slot_result_addr_a_r[fi] <= {ADDR_WIDTH{1'b0}};
                slot_result_addr_b_r[fi] <= {ADDR_WIDTH{1'b0}};
                slot_node_id_a_r[fi]     <= 16'b0;
                slot_node_id_b_r[fi]     <= 16'b0;
            end
            job_out_done <= 1'b0;
            job_out_slot <= '0;
        end else begin
            for (fi = 0; fi < N_SLOTS; fi = fi + 1) slot_job_start_r[fi] <= 1'b0;
            job_out_done <= 1'b0;

            if (job_in_valid && job_in_ready) begin
                q_x_base[q_tail]      <= job_in_x_base;
                q_w_base[q_tail]      <= job_in_w_base;
                q_n_tiles[q_tail]     <= job_in_n_tiles;
                q_result_addr[q_tail] <= job_in_result_addr;
                q_node_id[q_tail]     <= job_in_node_id;
                q_tail  <= (q_tail == QUEUE_DEPTH[Q_ADDR_WIDTH-1:0]-1'b1) ? {Q_ADDR_WIDTH{1'b0}} : q_tail + 1'b1;
            end

            slot_busy <= slot_busy & ~slot_job_done;
            if (|slot_job_done) begin
                job_out_done <= 1'b1;
                job_out_slot <= done_slot_idx;
            end

            case (dir_state)

                DIR_IDLE: begin
                    dir_state <= DIR_SCAN_READY;
                end

                DIR_SCAN_READY: begin
                    if (pair_ready && any_slot_free) begin
                        dir_state <= DIR_ALLOCATE;
                    end
                end

                DIR_ALLOCATE: begin
                    for (fi = 0; fi < N_SLOTS; fi = fi + 1) begin
                        if (fi[$clog2(N_SLOTS)-1:0] == free_slot_idx) begin
                            slot_job_start_r[fi]     <= 1'b1;
                            slot_x_base_a_r[fi]      <= q_x_base[q_head];
                            slot_x_base_b_r[fi]      <= q_x_base[q_head_plus1];
                            slot_w_base_r[fi]        <= q_w_base[q_head]; // == q_w_base[q_head_plus1], checked by pair_ready
                            slot_n_tiles_r[fi]       <= q_n_tiles[q_head];
                            slot_result_addr_a_r[fi] <= q_result_addr[q_head];
                            slot_result_addr_b_r[fi] <= q_result_addr[q_head_plus1];
                            slot_node_id_a_r[fi]     <= q_node_id[q_head];
                            slot_node_id_b_r[fi]     <= q_node_id[q_head_plus1];
                        end
                    end
                    slot_busy[free_slot_idx] <= 1'b1;
                    q_head <= (q_head_plus1 == QUEUE_DEPTH[Q_ADDR_WIDTH-1:0]-1'b1)
                                  ? {Q_ADDR_WIDTH{1'b0}} : q_head_plus1 + 1'b1;
                    dir_state <= DIR_SCAN_READY;
                end

                DIR_ERROR: begin
                end

                default: dir_state <= DIR_ERROR;

            endcase

            // q_count: +1 per accepted push, -2 per dispatched PAIR
            // (not -1, unlike V2 -- each DIR_ALLOCATE cycle here
            // consumes TWO queue entries, not one)
            case ({job_in_valid && job_in_ready,
                   (dir_state == DIR_SCAN_READY) && pair_ready && any_slot_free})
                2'b10: q_count <= q_count + 1'b1;
                2'b01: q_count <= q_count - 2'b10;
                2'b11: q_count <= q_count - 2'b10 + 1'b1;
                2'b00: q_count <= q_count;
            endcase
        end
    end

endmodule
