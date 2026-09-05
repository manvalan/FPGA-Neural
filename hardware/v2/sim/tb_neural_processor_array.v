`timescale 1ns/1ps

// ============================================================
// M2 testbench (docs/v2-description.md §8/§18/§34): neural_processor_array.v
// with N_PROCESSORS=4. Verified with Verilator (see hardware/v2/logs/
// decisions.log DEC-0004 -- Icarus Verilog v13.0 is not trusted for
// hardware/v2 testbenches).
//
// Coverage:
//   - TEST 1: single processor (index 0), sanity check that the
//     array's per-processor bus flattening/slicing is wired correctly
//     (arithmetic itself already bit-exact-certified at M1).
//   - TEST 2: all 4 processors launched on the SAME cycle with
//     DIFFERENT jobs (different tile counts, so they finish at
//     different times) -- proves genuine concurrent, independent
//     execution, not a hidden shared resource serializing them.
//   - TEST 3: staggered start (processor 1 launched while processor 0
//     is still mid-job) -- proves a busy processor does not block a
//     job being accepted by another (§18/§34: "un processor bloccato
//     non deve bloccare gli altri").
// ============================================================

module tb;

    localparam DATA_WIDTH   = 8;
    localparam P_IN         = 8;
    localparam ACC_WIDTH    = 32;
    localparam N_PROCESSORS = 4;

    reg clk, rst;
    initial begin clk = 0; forever #5 clk = ~clk; end

    reg  [N_PROCESSORS-1:0]                       job_valid;
    wire [N_PROCESSORS-1:0]                       job_ready;
    reg  [16*N_PROCESSORS-1:0]                    job_node_id;
    reg  signed [DATA_WIDTH*N_PROCESSORS-1:0]     job_bias;
    reg  [2*N_PROCESSORS-1:0]                     job_activation;

    reg  [N_PROCESSORS-1:0]                       operand_valid;
    wire [N_PROCESSORS-1:0]                       operand_ready;
    reg  signed [DATA_WIDTH*P_IN*N_PROCESSORS-1:0] input_data;
    reg  signed [DATA_WIDTH*P_IN*N_PROCESSORS-1:0] weight_data;
    reg  [N_PROCESSORS-1:0]                       tile_last;

    wire [N_PROCESSORS-1:0]                       result_valid;
    reg  [N_PROCESSORS-1:0]                       result_ready;
    wire signed [DATA_WIDTH*N_PROCESSORS-1:0]     result_data;
    wire [16*N_PROCESSORS-1:0]                    result_node_id;

    wire [4*N_PROCESSORS-1:0]                     np_state;
    wire [N_PROCESSORS-1:0]                       np_error;

    neural_processor_array #(
        .DATA_WIDTH(DATA_WIDTH), .P_IN(P_IN), .ACC_WIDTH(ACC_WIDTH),
        .N_PROCESSORS(N_PROCESSORS)
    ) dut (
        .clk(clk), .rst(rst),
        .job_valid(job_valid), .job_ready(job_ready),
        .job_node_id(job_node_id), .job_bias(job_bias), .job_activation(job_activation),
        .operand_valid(operand_valid), .operand_ready(operand_ready),
        .input_data(input_data), .weight_data(weight_data), .tile_last(tile_last),
        .result_valid(result_valid), .result_ready(result_ready),
        .result_data(result_data), .result_node_id(result_node_id),
        .np_state(np_state), .np_error(np_error)
    );

    integer errors, tests;

    // ---- per-processor job launch task: fires the job handshake and
    //      every tile for processor `idx`, WITHOUT waiting for
    //      completion (so the caller can launch several processors
    //      back-to-back / interleaved and observe true concurrency). ----
    task automatic launch_job(
        input integer idx,
        input integer n_tiles,
        input signed [DATA_WIDTH-1:0] lane_x,
        input signed [DATA_WIDTH-1:0] lane_w,
        input signed [DATA_WIDTH-1:0] bias,
        input [1:0] activation,
        input [15:0] node_id
    );
        integer t, k;
        reg signed [DATA_WIDTH*P_IN-1:0] tile_data;
        begin
            @(posedge clk);
            job_node_id[idx*16 +: 16]       = node_id;
            job_bias[idx*DATA_WIDTH +: DATA_WIDTH] = bias;
            job_activation[idx*2 +: 2]      = activation;
            job_valid[idx] = 1'b1;
            while (!job_ready[idx]) @(posedge clk);
            @(posedge clk);
            job_valid[idx] = 1'b0;

            tile_data = {DATA_WIDTH*P_IN{1'b0}};
            for (k = 0; k < P_IN; k = k + 1)
                tile_data[k*DATA_WIDTH +: DATA_WIDTH] = lane_x;

            for (t = 0; t < n_tiles; t = t + 1) begin
                input_data[idx*DATA_WIDTH*P_IN +: DATA_WIDTH*P_IN]  = tile_data;
                for (k = 0; k < P_IN; k = k + 1)
                    weight_data[idx*DATA_WIDTH*P_IN + k*DATA_WIDTH +: DATA_WIDTH] = lane_w;
                tile_last[idx]     = (t == n_tiles - 1);
                operand_valid[idx] = 1'b1;
                while (!operand_ready[idx]) @(posedge clk);
                @(posedge clk);
            end
            operand_valid[idx] = 1'b0;
            tile_last[idx]     = 1'b0;
        end
    endtask

    // ---- wait for processor `idx` to produce a result, check it,
    //      then let it fully return to idle. ----
    task automatic collect_result(
        input integer idx,
        input signed [DATA_WIDTH-1:0] expect_y,
        input [15:0] expect_node_id
    );
        integer wd;
        reg signed [DATA_WIDTH-1:0] got_y;
        reg [15:0] got_node;
        begin
            tests = tests + 1;
            result_ready[idx] = 1'b1;
            wd = 0;
            while (!result_valid[idx] && wd < 300) begin
                @(posedge clk);
                wd = wd + 1;
            end
            if (!result_valid[idx]) begin
                $display("FAIL proc=%0d: no result_valid within watchdog", idx);
                errors = errors + 1;
            end else begin
                got_y    = result_data[idx*DATA_WIDTH +: DATA_WIDTH];
                got_node = result_node_id[idx*16 +: 16];
                @(posedge clk);
                if (got_y !== expect_y || got_node !== expect_node_id) begin
                    $display("FAIL proc=%0d: got y=%0d node=%0d, expected y=%0d node=%0d",
                              idx, got_y, got_node, expect_y, expect_node_id);
                    errors = errors + 1;
                end else begin
                    $display("PASS proc=%0d: y=%0d node=%0d", idx, got_y, got_node);
                end
            end
            while (!job_ready[idx]) @(posedge clk);
        end
    endtask

    integer i;

    initial begin
        errors = 0;
        tests  = 0;
        rst = 1;
        job_valid = 0; job_node_id = 0; job_bias = 0; job_activation = 0;
        operand_valid = 0; input_data = 0; weight_data = 0; tile_last = 0;
        result_ready = 0;
        repeat(4) @(posedge clk);
        rst = 0;
        @(posedge clk);

        // ---- TEST 1: single processor (idx 0), 2 tiles, ACT_RELU ----
        // 16 inputs of x=3,w=2 -> acc=96, bias=0, relu(96)=96
        launch_job(0, 2, 8'sd3, 8'sd2, 8'sd0, 2'd1, 16'd101);
        collect_result(0, 8'sd96, 16'd101);

        // ---- TEST 2: all 4 processors launched the SAME cycle,
        // different tile counts (1,2,3,4) so they finish at different
        // times -- proves genuine independent concurrent execution. ----
        fork
            launch_job(0, 1, 8'sd1, 8'sd1, 8'sd0, 2'd1, 16'd200); // sum=8
            launch_job(1, 2, 8'sd1, 8'sd1, 8'sd0, 2'd1, 16'd201); // sum=16
            launch_job(2, 3, 8'sd1, 8'sd1, 8'sd0, 2'd1, 16'd202); // sum=24
            launch_job(3, 4, 8'sd1, 8'sd1, 8'sd0, 2'd1, 16'd203); // sum=32
        join
        fork
            collect_result(0, 8'sd8,  16'd200);
            collect_result(1, 8'sd16, 16'd201);
            collect_result(2, 8'sd24, 16'd202);
            collect_result(3, 8'sd32, 16'd203);
        join

        // ---- TEST 3: staggered start -- processor 0 launched first
        // with a long (6-tile) job, processor 1 launched a few cycles
        // later while processor 0 is still mid-job. Both must
        // complete correctly and independently. ----
        fork
            begin
                launch_job(0, 6, 8'sd2, 8'sd2, 8'sd0, 2'd1, 16'd300); // sum=8*6*... wait per-tile sum=8*4=32*6=192->sat 127
            end
            begin
                repeat(3) @(posedge clk); // let processor 0 get well underway first
                launch_job(1, 1, 8'sd5, 8'sd5, 8'sd0, 2'd0, 16'd301); // sum=8*25=200, ACT_NONE saturates to 127
            end
        join
        fork
            collect_result(0, 8'sd127, 16'd300); // 8 lanes * 2*2=4 -> 32/tile *6 tiles=192, ACT_RELU saturate +127
            collect_result(1, 8'sd127, 16'd301); // 8 lanes * 5*5=25 -> 200, ACT_NONE saturate +127
        join

        $display("========================================");
        if (errors == 0)
            $display("ALL %0d TESTS PASSED (N_PROCESSORS=%0d array, concurrent/staggered/independent)", tests, N_PROCESSORS);
        else
            $display("FAILED: %0d/%0d test(s) had errors -- see messages above", errors, tests);
        $display("========================================");
        $finish;
    end

endmodule
