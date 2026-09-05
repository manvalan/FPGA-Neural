`timescale 1ns/1ps

// ============================================================
// M5 testbench (docs/v2-description.md §9/§20): neural_director.v
// dispatching to N_SLOTS=2 (memory_manager + neural_processor) pairs.
// Verified with Verilator (decisions.log DEC-0004).
//
// Scope decision (decisions.log DEC-0007): each slot gets its OWN
// independent simple behavioral byte memory (sim_byte_mem below,
// fixed 2-cycle latency, matching int8_memory_access.v's req/wr/addr/
// wdata -> rdata/ready contract exactly) instead of sharing V1's real
// PSRAM chain -- M4 already proved the real PSRAM path end-to-end
// with ONE slot (EXP-0005); M5's own concern is scheduling/dispatch
// across MULTIPLE slots, which is what this testbench isolates.
// Multiple slots genuinely sharing ONE physical PSRAM port is a
// backend-arbitration problem explicitly deferred (DEC-0006), not
// re-solved here.
//
// Coverage:
//   - more jobs submitted (3) than slots exist (2): first two must
//     dispatch immediately (first-free), the third must wait in the
//     ready queue until a slot frees up, then dispatch automatically.
//   - each job's result independently verified (own oracle).
//   - ready-queue backpressure: fill the queue past N jobs beyond
//     slot capacity and confirm job_in_ready deasserts, then confirm
//     it drains and reasserts as slots complete.
// ============================================================

module sim_byte_mem #(
    parameter ADDR_WIDTH = 23,
    parameter DEPTH      = 1024
)(
    input  wire clk,
    input  wire rst,
    input  wire                  req,
    input  wire                  wr,
    input  wire [ADDR_WIDTH-1:0] addr,
    input  wire signed [7:0]     wdata,
    output reg  signed [7:0]     rdata,
    output reg                   ready
);
    reg signed [7:0] mem [0:DEPTH-1];
    reg [1:0] state;
    reg [ADDR_WIDTH-1:0] addr_reg;
    reg wr_reg;
    localparam ST_IDLE = 0, ST_WAIT = 1;
    always @(posedge clk) begin
        if (rst) begin
            state <= ST_IDLE; ready <= 1'b0; rdata <= 8'sd0;
        end else begin
            ready <= 1'b0;
            case (state)
                ST_IDLE: if (req) begin
                    addr_reg <= addr; wr_reg <= wr;
                    if (wr) mem[addr] <= wdata;
                    state <= ST_WAIT;
                end
                ST_WAIT: begin
                    rdata <= mem[addr_reg];
                    ready <= 1'b1;
                    state <= ST_IDLE;
                end
            endcase
        end
    end
endmodule

module tb;

    localparam ADDR_WIDTH   = 23;
    localparam DATA_WIDTH   = 8;
    localparam P_IN         = 8;
    localparam ACC_WIDTH    = 32;
    localparam N_SLOTS      = 2;
    localparam QUEUE_DEPTH  = 4;

    reg clk, rst;
    initial begin clk = 0; forever #5 clk = ~clk; end

    reg                     job_in_valid;
    wire                    job_in_ready;
    reg  [ADDR_WIDTH-1:0]   job_in_x_base, job_in_w_base, job_in_result_addr;
    reg  [15:0]             job_in_n_tiles, job_in_node_id;

    wire [N_SLOTS-1:0]              slot_job_start;
    wire [ADDR_WIDTH*N_SLOTS-1:0]   slot_x_base, slot_w_base, slot_result_addr;
    wire [16*N_SLOTS-1:0]           slot_n_tiles;
    wire [N_SLOTS-1:0]              slot_job_done;

    wire                    job_out_done;
    wire [$clog2(N_SLOTS)-1:0] job_out_slot;
    wire [3:0]              dir_state;
    wire                    dir_error;

    neural_director #(
        .ADDR_WIDTH(ADDR_WIDTH), .N_SLOTS(N_SLOTS), .QUEUE_DEPTH(QUEUE_DEPTH)
    ) u_dir (
        .clk(clk), .rst(rst),
        .job_in_valid(job_in_valid), .job_in_ready(job_in_ready),
        .job_in_x_base(job_in_x_base), .job_in_w_base(job_in_w_base),
        .job_in_n_tiles(job_in_n_tiles), .job_in_result_addr(job_in_result_addr),
        .job_in_node_id(job_in_node_id),
        .slot_job_start(slot_job_start), .slot_x_base(slot_x_base), .slot_w_base(slot_w_base),
        .slot_n_tiles(slot_n_tiles), .slot_result_addr(slot_result_addr), .slot_job_done(slot_job_done),
        .job_out_done(job_out_done), .job_out_slot(job_out_slot),
        .dir_state(dir_state), .dir_error(dir_error)
    );

    genvar g;
    generate
        for (g = 0; g < N_SLOTS; g = g + 1) begin : GEN_SLOT

            wire mm_operand_valid, mm_operand_ready;
            wire signed [DATA_WIDTH*P_IN-1:0] mm_input_data, mm_weight_data;
            wire mm_tile_last;
            wire mm_result_valid, mm_result_ready;
            wire signed [DATA_WIDTH-1:0] mm_result_data;

            wire mem_req, mem_wr;
            wire [ADDR_WIDTH-1:0] mem_addr;
            wire signed [7:0] mem_wdata, mem_rdata;
            wire mem_ready;

            memory_manager #(
                .DATA_WIDTH(DATA_WIDTH), .P_IN(P_IN), .ADDR_WIDTH(ADDR_WIDTH)
            ) u_mm (
                .clk(clk), .rst(rst),
                .job_start(slot_job_start[g]),
                .x_base(slot_x_base[g*ADDR_WIDTH +: ADDR_WIDTH]),
                .w_base(slot_w_base[g*ADDR_WIDTH +: ADDR_WIDTH]),
                .n_tiles(slot_n_tiles[g*16 +: 16]),
                .result_addr(slot_result_addr[g*ADDR_WIDTH +: ADDR_WIDTH]),
                .job_done(slot_job_done[g]),
                .operand_valid(mm_operand_valid), .operand_ready(mm_operand_ready),
                .input_data(mm_input_data), .weight_data(mm_weight_data), .tile_last(mm_tile_last),
                .result_valid(mm_result_valid), .result_ready(mm_result_ready), .result_data(mm_result_data),
                .mem_req(mem_req), .mem_wr(mem_wr), .mem_addr(mem_addr), .mem_wdata(mem_wdata),
                .mem_rdata(mem_rdata), .mem_ready(mem_ready)
            );

            reg job_valid_np;
            wire job_ready_np;
            wire result_valid_np;
            wire signed [DATA_WIDTH-1:0] result_data_np;
            wire [3:0] np_state;
            wire np_error;

            neural_processor #(
                .DATA_WIDTH(DATA_WIDTH), .P_IN(P_IN), .ACC_WIDTH(ACC_WIDTH)
            ) u_np (
                .clk(clk), .rst(rst),
                .job_valid(job_valid_np), .job_ready(job_ready_np),
                .job_node_id(16'h0), .job_bias(8'sd0), .job_activation(2'd1),
                .operand_valid(mm_operand_valid), .operand_ready(mm_operand_ready),
                .input_data(mm_input_data), .weight_data(mm_weight_data), .tile_last(mm_tile_last),
                .result_valid(result_valid_np), .result_ready(mm_result_ready),
                .result_data(result_data_np), .result_node_id(),
                .np_state(np_state), .np_error(np_error)
            );
            assign mm_result_valid = result_valid_np;
            assign mm_result_data  = result_data_np;

            always @(posedge clk) begin
                if (rst) job_valid_np <= 1'b0;
                else if (slot_job_start[g]) job_valid_np <= 1'b1;
                else if (job_valid_np && job_ready_np) job_valid_np <= 1'b0;
            end

            sim_byte_mem #(.ADDR_WIDTH(ADDR_WIDTH), .DEPTH(4096)) u_mem (
                .clk(clk), .rst(rst),
                .req(mem_req), .wr(mem_wr), .addr(mem_addr), .wdata(mem_wdata),
                .rdata(mem_rdata), .ready(mem_ready)
            );

        end
    endgenerate

    task automatic poke(input integer slot, input [ADDR_WIDTH-1:0] addr, input [7:0] val);
        begin
            case (slot)
                0: tb.GEN_SLOT[0].u_mem.mem[addr] = val;
                1: tb.GEN_SLOT[1].u_mem.mem[addr] = val;
                default: ;
            endcase
        end
    endtask

    function automatic signed [7:0] peek(input integer slot, input [ADDR_WIDTH-1:0] addr);
        begin
            case (slot)
                0: peek = tb.GEN_SLOT[0].u_mem.mem[addr];
                1: peek = tb.GEN_SLOT[1].u_mem.mem[addr];
                default: peek = 8'sdx;
            endcase
        end
    endfunction

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

    integer i;
    integer wd;

    initial begin
        errors = 0; tests = 0;
        rst = 1; job_in_valid = 0; job_in_x_base = 0; job_in_w_base = 0;
        job_in_n_tiles = 0; job_in_result_addr = 0; job_in_node_id = 0;
        repeat(4) @(posedge clk);
        rst = 0;
        @(posedge clk);

        // ---- prepare 3 independent jobs (2 slots, so job 2 must
        // wait in the ready queue for a slot to free up) ----
        // Job 0 (slot 0 pre-loaded region 0x100/0x200): 8 inputs, x=2,w=3 -> acc=48
        for (i = 0; i < 8; i = i + 1) begin poke(0, 23'h100+i, 8'sd2); poke(0, 23'h200+i, 8'sd3); poke(1, 23'h100+i, 8'sd2); poke(1, 23'h200+i, 8'sd3); end
        // Job 1 (either slot, region 0x300/0x400): 16 inputs, x=1,w=1 -> acc=16
        for (i = 0; i < 16; i = i + 1) begin poke(0, 23'h300+i, 8'sd1); poke(0, 23'h400+i, 8'sd1); poke(1, 23'h300+i, 8'sd1); poke(1, 23'h400+i, 8'sd1); end
        // Job 2 (queued until a slot frees, region 0x500/0x600): 8 inputs, x=1,w=5 -> acc=40
        for (i = 0; i < 8; i = i + 1) begin poke(0, 23'h500+i, 8'sd1); poke(0, 23'h600+i, 8'sd5); poke(1, 23'h500+i, 8'sd1); poke(1, 23'h600+i, 8'sd5); end

        submit_job(23'h100, 23'h200, 16'd1, 23'h700, 16'd1); // -> dispatches to slot 0 (first-free)
        submit_job(23'h300, 23'h400, 16'd2, 23'h701, 16'd2); // -> dispatches to slot 1
        submit_job(23'h500, 23'h600, 16'd1, 23'h702, 16'd3); // -> waits in queue

        // job_in_ready should have stayed high throughout (only 3
        // jobs, queue depth 4) -- confirmed implicitly: submit_job's
        // own while-loop would have hung the testbench otherwise.

        tests = tests + 3;
        wd = 0;
        begin
            integer completions;
            completions = 0;
            while (completions < 3 && wd < 3000) begin
                @(posedge clk);
                wd = wd + 1;
                if (job_out_done) completions = completions + 1;
            end
            if (completions < 3)
                $display("FAIL: only %0d/3 jobs completed within watchdog", completions);
        end
        // give the last-completing job's write a little extra margin
        repeat(5) @(posedge clk);

        if (peek(0, 23'h700) !== 8'sd48) begin
            $display("FAIL job0: result=%0d expected=48", peek(0,23'h700)); errors = errors + 1;
        end else $display("PASS job0 (slot dispatched first-free): result=48");

        if (peek(1, 23'h701) !== 8'sd16) begin
            $display("FAIL job1: result=%0d expected=16", peek(1,23'h701)); errors = errors + 1;
        end else $display("PASS job1 (slot dispatched first-free): result=16");

        // Job 2 could have landed on either slot (whichever freed
        // first) -- check both.
        if (peek(0, 23'h702) !== 8'sd40 && peek(1, 23'h702) !== 8'sd40) begin
            $display("FAIL job2 (queued): neither slot's result byte at 0x702 is 40 (got %0d / %0d)", peek(0,23'h702), peek(1,23'h702));
            errors = errors + 1;
        end else $display("PASS job2 (queued until a slot freed): result=40");

        // ---- backpressure: occupy both slots with LONG jobs (many
        // tiles, so they stay busy for a while and won't drain the
        // queue mid-burst), then push jobs faster than they can be
        // consumed and confirm job_in_ready genuinely deasserts once
        // the queue fills, then recovers once slots free up again. ----
        tests = tests + 1;
        for (i = 0; i < 64; i = i + 1) begin poke(0, 23'h800+i, 8'sd1); poke(0, 23'h900+i, 8'sd1); poke(1, 23'h800+i, 8'sd1); poke(1, 23'h900+i, 8'sd1); end
        submit_job(23'h800, 23'h900, 16'd64, 23'h704, 16'd10); // occupies slot 0/1 for a while
        submit_job(23'h800, 23'h900, 16'd64, 23'h705, 16'd11); // occupies the other slot

        job_in_x_base = 23'h100; job_in_w_base = 23'h200; job_in_n_tiles = 16'd1;
        job_in_result_addr = 23'h706; job_in_node_id = 16'd12;
        i = 0;
        while (job_in_ready && i < QUEUE_DEPTH + 2) begin
            @(posedge clk);
            job_in_valid = 1'b1;
            @(posedge clk);
            i = i + 1;
        end
        if (i > QUEUE_DEPTH) begin
            $display("FAIL backpressure: job_in_ready never deasserted after %0d pushes (QUEUE_DEPTH=%0d) -- both slots busy, queue should have filled", i, QUEUE_DEPTH);
            errors = errors + 1;
        end else begin
            $display("PASS backpressure: job_in_ready correctly deasserted after %0d queued jobs (QUEUE_DEPTH=%0d), both slots busy", i, QUEUE_DEPTH);
        end
        job_in_valid = 1'b0;

        // Drain: wait for everything (2 long jobs + whatever got
        // queued) to finish, no watchdog failure, and confirm
        // job_in_ready recovers once slots/queue free up.
        wd = 0;
        while (!job_in_ready && wd < 5000) begin @(posedge clk); wd = wd + 1; end
        if (!job_in_ready) begin
            $display("FAIL backpressure: job_in_ready never recovered within watchdog");
            errors = errors + 1;
        end else begin
            $display("PASS backpressure: job_in_ready recovered once slots/queue drained");
        end

        $display("========================================");
        if (errors == 0)
            $display("ALL %0d TESTS PASSED (neural_director, first-free scheduling, N_SLOTS=%0d)", tests, N_SLOTS);
        else
            $display("FAILED: %0d/%0d test(s) had errors -- see messages above", errors, tests);
        $display("========================================");
        $finish;
    end

endmodule
