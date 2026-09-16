`timescale 1ns/1ps

// ============================================================
// v3 -- verifies neural_processor_packed.v against TWO instances of
// the real, already-trusted hardware/v2/rtl/neural_processor.v (one
// fed job A's activations, one fed job B's, both fed the SAME shared
// weight stream -- exactly the weight-reuse access pattern this module
// is built for). Same driving convention as hardware/v2/sim/
// tb_neural_processor.v (side-by-side DUTs, identical operands,
// bit-exact comparison).
// ============================================================
module tb;
    localparam DATA_WIDTH = 8;
    localparam P_IN       = 8;
    localparam ACC_WIDTH  = 32;
    localparam MAX_N      = 64;

    reg clk, rst;
    initial begin clk = 0; forever #5 clk = ~clk; end

    integer errors, tests;

    // ---------------- reference: two real V2 neural_processor.v cores ----------------
    reg v2a_job_valid, v2b_job_valid;
    wire v2a_job_ready, v2b_job_ready;
    reg [15:0] v2a_node_id, v2b_node_id;
    reg signed [DATA_WIDTH-1:0] v2_bias;
    reg [1:0] v2_activation;

    reg v2_operand_valid;
    wire v2a_operand_ready, v2b_operand_ready;
    reg signed [DATA_WIDTH*P_IN-1:0] input_data_a, input_data_b, weight_data;
    reg v2_tile_last;

    wire v2a_result_valid, v2b_result_valid;
    reg v2_result_ready;
    wire signed [DATA_WIDTH-1:0] v2a_result_data, v2b_result_data;
    wire [15:0] v2a_result_node_id, v2b_result_node_id;
    wire [3:0] v2a_np_state, v2b_np_state;
    wire v2a_np_error, v2b_np_error;

    neural_processor #(.DATA_WIDTH(DATA_WIDTH), .P_IN(P_IN), .ACC_WIDTH(ACC_WIDTH)) v2a (
        .clk(clk), .rst(rst),
        .job_valid(v2a_job_valid), .job_ready(v2a_job_ready),
        .job_node_id(v2a_node_id), .job_bias(v2_bias), .job_activation(v2_activation),
        .operand_valid(v2_operand_valid), .operand_ready(v2a_operand_ready),
        .input_data(input_data_a), .weight_data(weight_data), .tile_last(v2_tile_last),
        .result_valid(v2a_result_valid), .result_ready(v2_result_ready),
        .result_data(v2a_result_data), .result_node_id(v2a_result_node_id),
        .np_state(v2a_np_state), .np_error(v2a_np_error)
    );
    neural_processor #(.DATA_WIDTH(DATA_WIDTH), .P_IN(P_IN), .ACC_WIDTH(ACC_WIDTH)) v2b (
        .clk(clk), .rst(rst),
        .job_valid(v2b_job_valid), .job_ready(v2b_job_ready),
        .job_node_id(v2b_node_id), .job_bias(v2_bias), .job_activation(v2_activation),
        .operand_valid(v2_operand_valid), .operand_ready(v2b_operand_ready),
        .input_data(input_data_b), .weight_data(weight_data), .tile_last(v2_tile_last),
        .result_valid(v2b_result_valid), .result_ready(v2_result_ready),
        .result_data(v2b_result_data), .result_node_id(v2b_result_node_id),
        .np_state(v2b_np_state), .np_error(v2b_np_error)
    );

    // ---------------- DUT: v3 packed neural_processor ----------------
    reg job_valid;
    wire job_ready;
    reg [15:0] job_node_id_a, job_node_id_b;
    reg signed [DATA_WIDTH-1:0] job_bias;
    reg [1:0] job_activation;

    reg operand_valid;
    wire operand_ready;
    reg tile_last;

    wire result_valid;
    reg result_ready;
    wire signed [DATA_WIDTH-1:0] result_data_a, result_data_b;
    wire [15:0] result_node_id_a, result_node_id_b;
    wire [3:0] np_state;
    wire np_error;

    neural_processor_packed #(.DATA_WIDTH(DATA_WIDTH), .P_IN(P_IN), .ACC_WIDTH(ACC_WIDTH)) dut (
        .clk(clk), .rst(rst),
        .job_valid(job_valid), .job_ready(job_ready),
        .job_node_id_a(job_node_id_a), .job_node_id_b(job_node_id_b),
        .job_bias(job_bias), .job_activation(job_activation),
        .operand_valid(operand_valid), .operand_ready(operand_ready),
        .input_data_a(input_data_a), .input_data_b(input_data_b), .weight_data(weight_data),
        .tile_last(tile_last),
        .result_valid(result_valid), .result_ready(result_ready),
        .result_data_a(result_data_a), .result_data_b(result_data_b),
        .result_node_id_a(result_node_id_a), .result_node_id_b(result_node_id_b),
        .np_state(np_state), .np_error(np_error)
    );

    reg signed [DATA_WIDTH-1:0] xamem [0:MAX_N-1];
    reg signed [DATA_WIDTH-1:0] xbmem [0:MAX_N-1];
    reg signed [DATA_WIDTH-1:0] wmem  [0:MAX_N-1];
    integer i, t, k, n_inputs, n_tiles;
    integer watchdog;

    task automatic run_case(
        input integer n,
        input signed [DATA_WIDTH-1:0] bias,
        input [1:0] activation,
        input [15:0] node_id
    );
        begin
            @(posedge clk);
            tests = tests + 1;
            n_inputs = n;
            n_tiles  = n / P_IN;

            v2_bias = bias; v2_activation = activation;
            job_bias = bias; job_activation = activation;
            v2a_node_id = node_id; v2b_node_id = node_id + 16'd1;
            job_node_id_a = node_id; job_node_id_b = node_id + 16'd1;

            v2a_job_valid = 1; v2b_job_valid = 1; job_valid = 1;
            while (!v2a_job_ready || !v2b_job_ready || !job_ready) @(posedge clk);
            @(posedge clk); #1;
            v2a_job_valid = 0; v2b_job_valid = 0; job_valid = 0;

            for (t = 0; t < n_tiles; t = t + 1) begin
                input_data_a = {DATA_WIDTH*P_IN{1'b0}};
                input_data_b = {DATA_WIDTH*P_IN{1'b0}};
                weight_data  = {DATA_WIDTH*P_IN{1'b0}};
                for (k = 0; k < P_IN; k = k + 1) begin
                    input_data_a[k*DATA_WIDTH +: DATA_WIDTH] = xamem[t*P_IN + k];
                    input_data_b[k*DATA_WIDTH +: DATA_WIDTH] = xbmem[t*P_IN + k];
                    weight_data[k*DATA_WIDTH +: DATA_WIDTH]  = wmem[t*P_IN + k];
                end
                v2_tile_last  = (t == n_tiles - 1);
                tile_last     = v2_tile_last;
                v2_operand_valid = 1;
                operand_valid    = 1;
                while (!v2a_operand_ready || !v2b_operand_ready || !operand_ready) @(posedge clk);
                @(posedge clk); #1;
            end
            // pulse-hardening (same class of bug as consume_done/pf_start/
            // ctrl_req elsewhere today): clearing operand_valid/tile_last
            // in the SAME delta as the last handshake's own edge races
            // against the three FSMs' own evaluation of that edge, and can
            // silently drop the tile_last=1 that should trigger NP_FINISH.
            // The #1 above (after the loop's last @(posedge clk)) already
            // pushes this clear into a later time step.
            v2_operand_valid = 0;
            operand_valid    = 0;
            v2_tile_last     = 0;
            tile_last        = 0;

            v2_result_ready = 1;
            result_ready    = 1;
            watchdog = 0;
            while (!(v2a_result_valid && v2b_result_valid && result_valid) && watchdog < 300) begin
                @(posedge clk);
                watchdog = watchdog + 1;
            end

            if (!v2a_result_valid || !v2b_result_valid || !result_valid) begin
                $display("FAIL n=%0d: watchdog timeout waiting for results (v2a=%b v2b=%b dut=%b)",
                          n, v2a_result_valid, v2b_result_valid, result_valid);
                errors = errors + 1;
            end else begin
                if (result_data_a !== v2a_result_data || result_data_b !== v2b_result_data) begin
                    $display("FAIL n=%0d bias=%0d act=%0d: v2a=%0d v2b=%0d dut_a=%0d dut_b=%0d MISMATCH",
                              n, bias, activation, v2a_result_data, v2b_result_data, result_data_a, result_data_b);
                    errors = errors + 1;
                end else begin
                    $display("PASS n=%0d bias=%0d act=%0d: a=%0d b=%0d (bit-exact vs 2x real neural_processor.v)",
                              n, bias, activation, result_data_a, result_data_b);
                end
                @(posedge clk);
            end

            while (!job_ready || np_state !== 4'd0 || !v2a_job_ready || !v2b_job_ready) @(posedge clk);
        end
    endtask

    integer li, pi;
    initial begin
        errors = 0; tests = 0;
        rst = 1;
        v2a_job_valid=0; v2b_job_valid=0; job_valid=0;
        v2a_node_id=0; v2b_node_id=0; job_node_id_a=0; job_node_id_b=0;
        v2_bias=0; v2_activation=1; job_bias=0; job_activation=1;
        v2_operand_valid=0; operand_valid=0;
        input_data_a=0; input_data_b=0; weight_data=0;
        v2_tile_last=0; tile_last=0;
        v2_result_ready=0; result_ready=0;
        repeat(4) @(posedge clk);
        rst = 0;
        @(posedge clk);

        // ---- functional sweep: several N, several (li,pi)-derived
        // deterministic x_a/x_b/w patterns (matches this project's own
        // weight-reuse formula style, EXP-0058), both activations ----
        for (li = 0; li < 3; li = li + 1) begin
            for (pi = 0; pi < 4; pi = pi + 1) begin
                for (i = 0; i < 64; i = i + 1) begin
                    wmem[i]  = $signed(8'((li*17 + i*29 + 13) & 8'hFF));
                    xamem[i] = $signed(8'((li*11 + (2*pi)*41   + i*7 + 3) & 8'hFF));
                    xbmem[i] = $signed(8'((li*11 + (2*pi+1)*41 + i*7 + 3) & 8'hFF));
                end
                run_case(64, $signed(8'((li*3+pi) & 8'hFF)), (pi[0] ? 2'd1 : 2'd0), li*100+pi);
            end
        end

        // ---- extreme INT8 boundary cases, N=16 ----
        for (i = 0; i < 16; i = i + 1) begin
            wmem[i]  = (i % 2 == 0) ? -8'sd128 : 8'sd127;
            xamem[i] = (i % 3 == 0) ? -8'sd128 : ((i%3==1) ? 8'sd127 : 8'sd0);
            xbmem[i] = (i % 3 == 0) ? 8'sd127 : ((i%3==1) ? -8'sd128 : -8'sd1);
        end
        run_case(16, 8'sd0,  2'd1, 16'd9001);
        run_case(16, 8'sd127, 2'd0, 16'd9002);
        run_case(16, -8'sd128, 2'd1, 16'd9003);

        // ---- back-to-back jobs, no idle gap (throughput check) ----
        for (i = 0; i < 32; i = i + 1) begin
            wmem[i]  = $signed(8'((i*5+7) & 8'hFF));
            xamem[i] = $signed(8'((i*3+1) & 8'hFF));
            xbmem[i] = $signed(8'((i*13+2) & 8'hFF));
        end
        run_case(32, 8'sd10, 2'd1, 16'd9100);
        run_case(32, -8'sd10, 2'd0, 16'd9101);
        run_case(32, 8'sd0, 2'd1, 16'd9102);

        $display("=== RESULT: %0d/%0d PASS, %0d errors (neural_processor_packed.v vs 2x real neural_processor.v) ===",
            tests-errors, tests, errors);
        if (errors == 0) $display("ALL TESTS PASSED (tb_neural_processor_packed)");
        $finish;
    end
endmodule
