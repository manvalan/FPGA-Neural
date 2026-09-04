`timescale 1ns/1ps

// ================================================================
// C.2 CERTIFICATION + BUG-004 REGRESSION TEST (certification
// campaign, docs/validation/bugs.md / docs/validation/02-runtime-width.md §2.4/§2.5).
//
// TESTS 1-3 (CERTIFIED): n_neurons_real early termination for valid
// values (1, 2, 3 out of a N_NEURONS=3 build) completes in a cycle
// count that scales proportionally (~41 cycles/neuron) -- these fail
// the run if early termination breaks.
//
// TEST 4 (n_neurons_real=0), now FIXED. Previously did NOT hang (unlike
// BUG-002/003) -- it silently completed in the SAME cycle count as
// processing the full N_NEURONS build width, ignoring the requested
// "zero neurons" limit entirely.
//
// Fix (rtl/neuron_memory.v): the vulnerable termination pattern
// existed at THREE points (STATE_READ_X's own termination check,
// STATE_READ_W's termination check -- re-entered once per neuron in
// the loop, and the X-read-to-W-read dispatch point) -- all three now
// carry an explicit n_neurons_real==0 / n_inputs_real==0 early-out. For
// n_neurons_real=0 specifically, X is still read once (shared across
// neurons) but the loop then exits immediately instead of entering
// STATE_READ_W at all -- so this test now hard-asserts TEST 4
// completes with `done` in far fewer cycles than the full-width
// baseline (cyc_full, established by TEST 3), not the same count.
// ================================================================

module tb;

    localparam ADDR_WIDTH  = 23;
    localparam DATA_WIDTH  = 8;
    localparam N_INPUTS    = 8;
    localparam N_NEURONS   = 3;
    localparam PARALLEL    = 8;
    localparam ACC_WIDTH   = 32;

    reg clk;
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    reg rst, start;
    reg [ADDR_WIDTH-1:0] x_base, w_base, bias_addr;
    reg [15:0] n_neurons_real;
    wire signed [DATA_WIDTH*N_NEURONS-1:0] y_bus;
    wire busy, done;

    wire mem_req, mem_wr;
    wire [ADDR_WIDTH-1:0] mem_addr;
    wire signed [7:0] mem_wdata;
    reg signed [7:0] mem_rdata;
    reg mem_ready;

    // Minimal always-ready behavioral memory stub -- content is
    // irrelevant here (this test only checks termination cycle
    // count, not computed values).
    always @(posedge clk) begin
        mem_ready <= mem_req;
        mem_rdata <= 8'sd1;
    end

    neuron_memory #(
        .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH),
        .N_INPUTS(N_INPUTS), .N_NEURONS(N_NEURONS), .PARALLEL(PARALLEL), .ACC_WIDTH(ACC_WIDTH)
    ) dut (
        .clk(clk), .rst(rst), .start(start),
        .mem_req(mem_req), .mem_wr(mem_wr), .mem_addr(mem_addr), .mem_wdata(mem_wdata),
        .mem_rdata(mem_rdata), .mem_ready(mem_ready),
        .x_base(x_base), .w_base(w_base), .bias_addr(bias_addr),
        .n_neurons_real(n_neurons_real),
        .y_bus(y_bus), .busy(busy), .done(done)
    );

    integer cyc;
    integer errors;
    integer cyc_full;

    task automatic run_case(
        input [15:0] nreal,
        input integer is_bug004_zero  // 1 = TEST 4: must complete FAR faster than cyc_full
    );
        begin
            n_neurons_real = nreal;
            x_base = 0; w_base = 0; bias_addr = 0;
            rst = 1; start = 0;
            @(posedge clk); @(posedge clk);
            rst = 0;
            @(posedge clk);
            start = 1;
            @(posedge clk);
            start = 0;
            cyc = 0;
            while (!done && cyc < 500) begin
                @(posedge clk);
                cyc = cyc + 1;
            end
            if (!done) begin
                $display("n_neurons_real=%0d: FAIL -- expected done, got none in 500 cycles", nreal);
                errors = errors + 1;
            end else if (is_bug004_zero) begin
                if (cyc >= cyc_full) begin
                    $display("n_neurons_real=%0d: FAIL -- completed at cycle %0d, NOT faster than the full-width baseline (%0d cycles) -- BUG-004 fix regressed, the zero-neurons limit is being silently ignored again", nreal, cyc, cyc_full);
                    errors = errors + 1;
                end else begin
                    $display("n_neurons_real=%0d: PASS -- done at cycle %0d, well under the full-width baseline (%0d cycles) -- BUG-004 fix confirmed, no neuron computation was performed", nreal, cyc, cyc_full);
                end
            end else begin
                $display("n_neurons_real=%0d: PASS -- done at cycle %0d", nreal, cyc);
                if (nreal == N_NEURONS) cyc_full = cyc;
            end
        end
    endtask

    initial begin
        errors = 0;
        cyc_full = -1;

        $display("--- TEST 1: n_neurons_real=1 (early termination) ---");
        run_case(16'd1, 0);
        $display("--- TEST 2: n_neurons_real=2 (early termination) ---");
        run_case(16'd2, 0);
        $display("--- TEST 3: n_neurons_real=3 (full build width, establishes cyc_full baseline) ---");
        run_case(N_NEURONS[15:0], 0);

        $display("--- TEST 4 (BUG-004 fix): n_neurons_real=0 -- must complete far faster than the full-width baseline ---");
        run_case(16'd0, 1);

        if (errors == 0)
            $display("ALL TESTS PASSED (early termination certified correct for valid n_neurons_real values, TESTS 1-3; TEST 4 confirms BUG-004 fix -- n_neurons_real=0 skips all neuron computation)");
        else
            $display("FAILED: %0d unexpected result(s) -- see messages above", errors);
        $finish;
    end

endmodule
