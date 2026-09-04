`timescale 1ns/1ps

// ================================================================
// C.2 CERTIFICATION + BUG-003 OBSERVATION (certification campaign,
// docs/validation/bugs.md / docs/validation/02-runtime-width.md).
//
// TESTS 1-3 (SOLID, CERTIFIED): early termination for valid
// n_inputs_real values is real -- a "poison" region at indices 16-31
// with saturating x=w=100 would corrupt the result if the RTL ever
// read past the real limit. It doesn't. These three checks DO fail
// the run (errors counted) if early termination breaks.
//
// TEST 4 (n_inputs_real=0) is DELIBERATELY NOT a hard pass/fail
// assertion. Unlike BUG-002 (N_INPUTS=0, a compile-time parameter),
// this runtime-reachable twin (n_inputs_real=0, exactly the port an
// SPI host drives via SET_BASE sel=7,
// docs/FPGA-NeuralNetwork-Engine.md §8.1) produced DIFFERENT results
// across nearly-identical repeated test runs while investigating this
// aspect -- sometimes a clean hang (busy/done never move), sometimes
// a normal-looking completion that silently processes the FULL build
// width instead of zero elements. The exact triggering condition was
// NOT isolated despite multiple attempts -- see
// docs/validation/02-runtime-width.md §2.3 for the full, undiscarded
// record of every attempt. This test only REPORTS which of the two
// (already known-incorrect) symptoms shows up on this particular run
// -- it does not assert one is "the" correct current behavior, because
// that has not been established.
// ================================================================

module tb;

    localparam DATA_WIDTH = 8;
    localparam N_INPUTS   = 32;
    localparam PARALLEL   = 8;
    localparam ACC_WIDTH  = 32;

    reg clk;
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    reg rst, start;
    reg signed [DATA_WIDTH*N_INPUTS-1:0] x_bus, w_bus;
    reg [1:0] activation;
    reg [15:0] n_inputs_real;
    wire busy, done;
    wire signed [DATA_WIDTH-1:0] y;

    integer cyc, i;
    integer errors;

    neuron_parallel #(
        .DATA_WIDTH(DATA_WIDTH), .N_INPUTS(N_INPUTS), .PARALLEL(PARALLEL), .ACC_WIDTH(ACC_WIDTH)
    ) dut (
        .clk(clk), .rst(rst), .start(start),
        .x_bus(x_bus), .w_bus(w_bus), .bias(8'sd0),
        .activation(activation), .n_inputs_real(n_inputs_real),
        .y(y), .busy(busy), .done(done)
    );

    task automatic run_case(
        input [15:0] nreal,
        input integer is_bug003_probe,  // 1 = TEST 4: observe-only, never counts as a failure either way (see file header)
        input signed [7:0] expect_y     // meaningful only if is_bug003_probe == 0
    );
        begin
            n_inputs_real = nreal;
            rst = 1; start = 0;
            @(posedge clk); @(posedge clk);
            rst = 0;
            @(posedge clk);
            start = 1;
            @(posedge clk);
            start = 0;
            cyc = 0;
            while (!done && cyc < 200) begin
                @(posedge clk);
                cyc = cyc + 1;
            end
            if (is_bug003_probe) begin
                if (done)
                    $display("n_inputs_real=%0d: OBSERVED -- completed at cycle %0d, y=%0d (limit silently ignored -- one of two known-incorrect symptoms, see docs/validation/02-runtime-width.md §2.3; NOT counted as pass or fail here)", nreal, cyc, y);
                else
                    $display("n_inputs_real=%0d: OBSERVED -- no done in 200 cycles, busy=%b (hang -- the OTHER known-incorrect symptom, see docs/validation/02-runtime-width.md §2.3; NOT counted as pass or fail here)", nreal, busy);
            end else begin
                if (!done) begin
                    $display("n_inputs_real=%0d: FAIL -- expected done, got none in 200 cycles", nreal);
                    errors = errors + 1;
                end else if (y !== expect_y) begin
                    $display("n_inputs_real=%0d: FAIL -- y=%0d expected=%0d", nreal, y, expect_y);
                    errors = errors + 1;
                end else begin
                    $display("n_inputs_real=%0d: PASS -- y=%0d cycles=%0d (no over-read into poison region)", nreal, y, cyc);
                end
            end
        end
    endtask

    initial begin
        errors = 0;
        activation = 2'd1; // ACT_RELU

        // real region (0-15): x=w=1 -> contributes 1 each if read
        for (i = 0; i < 16; i = i + 1) begin
            x_bus[i*8 +: 8] = 8'sd1;
            w_bus[i*8 +: 8] = 8'sd1;
        end
        // "poison" region (16-31): x=w=100 -> would saturate to 127 if
        // ever read past the real limit
        for (i = 16; i < 32; i = i + 1) begin
            x_bus[i*8 +: 8] = 8'sd100;
            w_bus[i*8 +: 8] = 8'sd100;
        end

        $display("--- TEST 1: n_inputs_real=16 -- early termination must NOT read the poison region ---");
        run_case(16'd16, 0, 8'sd16);

        $display("--- TEST 2: n_inputs_real=8 -- smaller early termination ---");
        run_case(16'd8, 0, 8'sd8);

        $display("--- TEST 3: n_inputs_real=32 (full) -- sanity: DOES read the poison region, saturates ---");
        run_case(16'd32, 0, 8'sd127);

        $display("--- TEST 4 (BUG-003 probe, observe-only): n_inputs_real=0 ---");
        run_case(16'd0, 1, 8'sd0);

        if (errors == 0)
            $display("ALL TESTS PASSED (early termination certified correct for valid n_inputs_real values, TESTS 1-3; TEST 4 is an observe-only BUG-003 probe, see docs/validation/02-runtime-width.md §2.3 -- not scored)");
        else
            $display("FAILED: %0d unexpected result(s) in TESTS 1-3 -- see messages above", errors);
        $finish;
    end

endmodule
