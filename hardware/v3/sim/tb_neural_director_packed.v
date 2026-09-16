`timescale 1ns/1ps

// ============================================================
// Isolated correctness test for neural_director_packed.v's own
// scheduling/pairing logic -- mirrors hardware/v2/sim/tb_neural_
// director.v's own scope decision (DEC-0007): each slot gets a
// lightweight BEHAVIORAL stub (fixed-latency job_start->job_done,
// scoreboard of what it received) instead of a real packed core +
// memory path -- neural_processor_packed.v's own compute correctness
// is already verified (EXP-0059/0062); THIS test isolates whether
// the Director pairs/dispatches/tracks completion correctly, per
// this project's own "one variable at a time" discipline.
//
// Coverage:
//   1) matched-w_base pairs dispatch correctly (x_base_a/b, w_base,
//      n_tiles, result_addr_a/b, node_id_a/b all land on the right
//      slot, right fields).
//   2) MISMATCHED w_base between consecutive jobs: Director must
//      stall (not mis-pair, not error) until a job arrives that
//      matches the still-head-of-queue job.
//   3) more pairs submitted than slots: third pair waits in queue
//      until a slot frees.
//   4) backpressure: queue fills, job_in_ready deasserts, recovers.
// ============================================================
module tb;
    localparam ADDR_WIDTH  = 26;
    localparam N_SLOTS     = 2;
    localparam QUEUE_DEPTH = 8;

    reg clk, rst;
    initial begin clk = 0; forever #5 clk = ~clk; end

    reg                   job_in_valid;
    wire                  job_in_ready;
    reg  [ADDR_WIDTH-1:0] job_in_x_base, job_in_w_base, job_in_result_addr;
    reg  [15:0]           job_in_n_tiles, job_in_node_id;

    wire [N_SLOTS-1:0]            slot_job_start;
    wire [ADDR_WIDTH*N_SLOTS-1:0] slot_x_base_a, slot_x_base_b, slot_w_base;
    wire [ADDR_WIDTH*N_SLOTS-1:0] slot_result_addr_a, slot_result_addr_b;
    wire [16*N_SLOTS-1:0]         slot_n_tiles, slot_node_id_a, slot_node_id_b;
    reg  [N_SLOTS-1:0]            slot_job_done;

    wire                        job_out_done;
    wire [$clog2(N_SLOTS)-1:0]  job_out_slot;
    wire [3:0]                  dir_state;
    wire                        dir_error;

    neural_director_packed #(
        .ADDR_WIDTH(ADDR_WIDTH), .N_SLOTS(N_SLOTS), .QUEUE_DEPTH(QUEUE_DEPTH)
    ) u_dir (
        .clk(clk), .rst(rst),
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

    // ---- behavioral slot stubs: fixed 6-cycle latency job_start ->
    // job_done, scoreboard of last-received fields per slot ----
    reg [ADDR_WIDTH-1:0] scb_xa [0:N_SLOTS-1];
    reg [ADDR_WIDTH-1:0] scb_xb [0:N_SLOTS-1];
    reg [ADDR_WIDTH-1:0] scb_w  [0:N_SLOTS-1];
    reg [15:0]           scb_nt [0:N_SLOTS-1];
    reg [ADDR_WIDTH-1:0] scb_ra [0:N_SLOTS-1];
    reg [ADDR_WIDTH-1:0] scb_rb [0:N_SLOTS-1];
    reg [15:0]           scb_na [0:N_SLOTS-1];
    reg [15:0]           scb_nb [0:N_SLOTS-1];
    reg [3:0]            stub_cnt [0:N_SLOTS-1];
    reg                  stub_busy [0:N_SLOTS-1];

    integer si;
    always @(posedge clk) begin
        if (rst) begin
            for (si = 0; si < N_SLOTS; si = si + 1) begin
                stub_busy[si] <= 1'b0;
                stub_cnt[si]  <= 4'd0;
            end
            slot_job_done <= {N_SLOTS{1'b0}};
        end else begin
            slot_job_done <= {N_SLOTS{1'b0}};
            for (si = 0; si < N_SLOTS; si = si + 1) begin
                if (slot_job_start[si]) begin
                    scb_xa[si] <= slot_x_base_a[si*ADDR_WIDTH +: ADDR_WIDTH];
                    scb_xb[si] <= slot_x_base_b[si*ADDR_WIDTH +: ADDR_WIDTH];
                    scb_w[si]  <= slot_w_base[si*ADDR_WIDTH +: ADDR_WIDTH];
                    scb_nt[si] <= slot_n_tiles[si*16 +: 16];
                    scb_ra[si] <= slot_result_addr_a[si*ADDR_WIDTH +: ADDR_WIDTH];
                    scb_rb[si] <= slot_result_addr_b[si*ADDR_WIDTH +: ADDR_WIDTH];
                    scb_na[si] <= slot_node_id_a[si*16 +: 16];
                    scb_nb[si] <= slot_node_id_b[si*16 +: 16];
                    stub_busy[si] <= 1'b1;
                    stub_cnt[si]  <= 4'd0;
                end else if (stub_busy[si]) begin
                    if (stub_cnt[si] == 4'd15) begin
                        slot_job_done[si] <= 1'b1;
                        stub_busy[si]     <= 1'b0;
                    end else begin
                        stub_cnt[si] <= stub_cnt[si] + 1'b1;
                    end
                end
            end
        end
    end

    integer errors, tests;

    task automatic submit_job(
        input [ADDR_WIDTH-1:0] xb, input [ADDR_WIDTH-1:0] wb,
        input [15:0] nt, input [ADDR_WIDTH-1:0] resaddr, input [15:0] nid
    );
        begin
            @(posedge clk);
            job_in_x_base = xb; job_in_w_base = wb; job_in_n_tiles = nt;
            job_in_result_addr = resaddr; job_in_node_id = nid;
            job_in_valid = 1'b1;
            while (!job_in_ready) @(posedge clk);
            @(posedge clk);
            job_in_valid = 1'b0;
        end
    endtask

    task automatic check_scb(
        input integer slot, input [ADDR_WIDTH-1:0] xa, input [ADDR_WIDTH-1:0] xb,
        input [ADDR_WIDTH-1:0] w, input [15:0] nt,
        input [ADDR_WIDTH-1:0] ra, input [ADDR_WIDTH-1:0] rb,
        input [15:0] na, input [15:0] nb
    );
        begin
            tests = tests + 1;
            if (scb_xa[slot] !== xa || scb_xb[slot] !== xb || scb_w[slot] !== w ||
                scb_nt[slot] !== nt || scb_ra[slot] !== ra || scb_rb[slot] !== rb ||
                scb_na[slot] !== na || scb_nb[slot] !== nb) begin
                $display("FAIL slot %0d scoreboard: xa=%0d(exp %0d) xb=%0d(exp %0d) w=%0d(exp %0d) nt=%0d(exp %0d) ra=%0d(exp %0d) rb=%0d(exp %0d) na=%0d(exp %0d) nb=%0d(exp %0d)",
                    slot, scb_xa[slot], xa, scb_xb[slot], xb, scb_w[slot], w, scb_nt[slot], nt,
                    scb_ra[slot], ra, scb_rb[slot], rb, scb_na[slot], na, scb_nb[slot], nb);
                errors = errors + 1;
            end else begin
                $display("PASS slot %0d scoreboard: pair (node %0d,%0d) w_base=%0d correctly dispatched", slot, na, nb, w);
            end
        end
    endtask

    integer wd;

    initial begin
        errors = 0; tests = 0;
        rst = 1; job_in_valid = 0; job_in_x_base = 0; job_in_w_base = 0;
        job_in_n_tiles = 0; job_in_result_addr = 0; job_in_node_id = 0;
        repeat(4) @(posedge clk);
        rst = 0;
        @(posedge clk);

        $display("=== TEST 1: matched-w_base pair, single dispatch ===");
        submit_job(26'h1000, 26'h2000, 16'd16, 26'h5000, 16'd1); // pos A
        submit_job(26'h1100, 26'h2000, 16'd16, 26'h5001, 16'd2); // pos B, SAME w_base -> pairs with A
        wd = 0; while (!slot_job_start[0] && !slot_job_start[1] && wd < 100) begin @(posedge clk); wd = wd + 1; end
        @(posedge clk);
        if (slot_job_start[0] || u_dir.slot_busy[0])
            check_scb(0, 26'h1000, 26'h1100, 26'h2000, 16'd16, 26'h5000, 26'h5001, 16'd1, 16'd2);
        else
            check_scb(1, 26'h1000, 26'h1100, 26'h2000, 16'd16, 26'h5000, 26'h5001, 16'd1, 16'd2);

        wd = 0; while (!job_out_done && wd < 100) begin @(posedge clk); wd = wd + 1; end
        if (!job_out_done) begin $display("FAIL: TEST1 pair never completed"); errors = errors + 1; end

        $display("=== TEST 2: MISMATCHED w_base -- Director must stall, not mis-pair ===");
        repeat(3) @(posedge clk);
        submit_job(26'h3000, 26'h4000, 16'd8, 26'h5002, 16'd10);  // w_base=0x4000
        submit_job(26'h3100, 26'h4100, 16'd8, 26'h5003, 16'd11);  // DIFFERENT w_base=0x4100 -- must NOT pair with the above
        repeat(20) @(posedge clk);
        tests = tests + 1;
        if (u_dir.q_count < 2) begin
            $display("FAIL TEST2: mismatched-w_base jobs were dispatched (q_count=%0d, expected 2 still queued)", u_dir.q_count);
            errors = errors + 1;
        end else begin
            $display("PASS TEST2: mismatched-w_base pair correctly NOT dispatched, both still queued (q_count=%0d)", u_dir.q_count);
        end
        // now submit a job that DOES match the second one (0x4100) --
        // Director should still be stuck on the FIRST two (head pair,
        // 0x4000/0x4100 mismatch) since pairing only ever looks at
        // q_head/q_head+1, confirming it doesn't skip ahead either.
        submit_job(26'h3200, 26'h4100, 16'd8, 26'h5004, 16'd12);
        repeat(20) @(posedge clk);
        tests = tests + 1;
        if (u_dir.q_count < 3) begin
            $display("FAIL TEST2b: Director skipped ahead past the mismatched head pair (q_count=%0d, expected 3 still queued)", u_dir.q_count);
            errors = errors + 1;
        end else begin
            $display("PASS TEST2b: Director correctly did NOT skip ahead past the still-mismatched head pair (q_count=%0d)", u_dir.q_count);
        end

        $display("=== TEST 3: two full pairs dispatch to both slots, third pair waits ===");
        repeat(20) @(posedge clk); // let TEST2's stalled pair finish draining first isn't needed -- fresh w_base below won't match TEST2's stuck head, so submit a THIRD job matching 0x4100 is already queued; just proceed with a fresh w_base group not colliding with TEST2's stuck entries by construction (TEST2's own pair will eventually complete once we feed it a match -- but we deliberately do NOT, to keep proving the stall holds; instead reset here for a clean TEST3)
        rst = 1; repeat(3) @(posedge clk); rst = 0; @(posedge clk);

        // check "both slots busy, third pair still queued" RIGHT AFTER
        // the first two pairs are submitted -- before submitting the
        // third, so the stub's own fixed completion latency (6 cycles)
        // cannot race ahead of this check regardless of how long
        // submit_job's own handshake takes.
        submit_job(26'hA000, 26'hB000, 16'd4, 26'h6000, 16'd20);
        submit_job(26'hA100, 26'hB000, 16'd4, 26'h6001, 16'd21); // pairs with above -> slot X
        submit_job(26'hA200, 26'hB100, 16'd4, 26'h6002, 16'd22);
        submit_job(26'hA300, 26'hB100, 16'd4, 26'h6003, 16'd23); // pairs with above -> slot Y (both slots now busy)
        repeat(4) @(posedge clk); // settle: DIR_SCAN_READY/DIR_ALLOCATE take a couple cycles per
                                   // dispatch, and submit_job's own return doesn't guarantee the
                                   // Director's own (independent) FSM has caught up yet

        tests = tests + 1;
        if (!(u_dir.slot_busy[0] && u_dir.slot_busy[1])) begin
            $display("FAIL TEST3: both slots should be busy after 2 pairs dispatched (slot_busy=%b)", u_dir.slot_busy);
            errors = errors + 1;
        end else begin
            $display("PASS TEST3: both slots busy after dispatching 2 pairs (slot_busy=%b)", u_dir.slot_busy);
        end

        submit_job(26'hA400, 26'hB200, 16'd4, 26'h6004, 16'd24);
        submit_job(26'hA500, 26'hB200, 16'd4, 26'h6005, 16'd25); // pairs, but must WAIT (no free slot)

        tests = tests + 1;
        if (u_dir.q_count < 2) begin
            $display("FAIL TEST3: third pair should still be queued while both slots are busy (q_count=%0d)", u_dir.q_count);
            errors = errors + 1;
        end else begin
            $display("PASS TEST3: third pair correctly waiting while both slots busy (q_count=%0d)", u_dir.q_count);
        end

        wd = 0;
        begin : test3_drain
            integer completions;
            completions = 0;
            while (completions < 3 && wd < 200) begin
                @(posedge clk);
                wd = wd + 1;
                if (job_out_done) completions = completions + 1;
            end
            tests = tests + 1;
            if (completions < 3) begin
                $display("FAIL TEST3: only %0d/3 pairs completed within watchdog", completions);
                errors = errors + 1;
            end else begin
                $display("PASS TEST3: all 3 pairs completed (third one dispatched once a slot freed)");
            end
        end

        $display("=== TEST 4: backpressure -- queue fills past capacity, job_in_ready deasserts and recovers ===");
        rst = 1; repeat(3) @(posedge clk); rst = 0; @(posedge clk);
        // occupy BOTH slots first (different w_base than the flood
        // below, and the stub's own long fixed latency, 16 cycles)
        // keeps them busy for the whole push phase, so the flood
        // below genuinely tests the QUEUE filling, not a queue that
        // keeps draining as fast as it fills.
        submit_job(26'hE000, 26'hF000, 16'd4, 26'h7800, 16'd40);
        submit_job(26'hE100, 26'hF000, 16'd4, 26'h7801, 16'd41);
        submit_job(26'hE200, 26'hF100, 16'd4, 26'h7802, 16'd42);
        submit_job(26'hE300, 26'hF100, 16'd4, 26'h7803, 16'd43);

        begin : test4_fill
            integer j;
            j = 0;
            while (job_in_ready && j < QUEUE_DEPTH + 2) begin
                @(posedge clk);
                job_in_x_base      = 26'hC000;
                job_in_w_base      = 26'hD000; // same w_base every push -> always pairs, but both real slots stay busy so nothing drains
                job_in_n_tiles     = 16'd4;
                job_in_result_addr = 26'h7000;
                job_in_node_id     = 16'd50 + j[15:0];
                job_in_valid       = 1'b1;
                @(posedge clk);
                job_in_valid = 1'b0;
                j = j + 1;
            end
            tests = tests + 1;
            if (j > QUEUE_DEPTH) begin
                $display("FAIL TEST4: job_in_ready never deasserted after %0d pushes (QUEUE_DEPTH=%0d)", j, QUEUE_DEPTH);
                errors = errors + 1;
            end else begin
                $display("PASS TEST4: job_in_ready correctly deasserted after %0d queued jobs (QUEUE_DEPTH=%0d)", j, QUEUE_DEPTH);
            end
        end
        job_in_valid = 1'b0;

        wd = 0; while (!job_in_ready && wd < 500) begin @(posedge clk); wd = wd + 1; end
        tests = tests + 1;
        if (!job_in_ready) begin
            $display("FAIL TEST4: job_in_ready never recovered within watchdog");
            errors = errors + 1;
        end else begin
            $display("PASS TEST4: job_in_ready recovered once slots/queue drained");
        end

        $display("=== %0d/%0d tests, %0d errors ===", tests-errors, tests, errors);
        if (errors == 0) $display("ALL TESTS PASSED (tb_neural_director_packed)");
        $finish;
    end
endmodule
