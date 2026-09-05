`timescale 1ns/1ps

// ================================================================
// C.6 / BUG-006 REGRESSION TEST (docs/validation/bugs.md), now FIXED:
// does num_neurons_graph=0 reproduce the same class of issue as
// BUG-005 (rtl/layer_sequencer.v)?
//
// Structural analysis: rtl/graph_engine.v's neuron_idx (line 159) is
// a full 16-bit register, and the termination check
// `neuron_idx == num_neurons_graph-16'd1` (lines 527/561) wraps to
// 65535 for num_neurons_graph=0 -- a value neuron_idx CAN naturally
// reach, structurally identical to BUG-005's layer_idx pattern.
// Before the fix, this was observed to terminate via the incidental
// src_id<out_id/N_TOTAL guard tripping on garbage descriptor data at
// cycle 58 -- self-limiting only for that particular PSRAM content,
// not a real guarantee.
//
// Fix (rtl/graph_engine.v, ST_COPY_IN_WAIT, at the input-copy-complete
// transition): num_neurons_graph==0 is now an explicit, immediate
// no-op -- done pulses right after the input copy finishes, without
// ever entering ST_DESC_RD / the neuron-descriptor loop, same
// convention as layer_sequencer.v's BUG-005 fix. This test now
// hard-asserts done fires quickly with no err and neuron_idx never
// leaves 0, instead of only observing which of several
// already-known-wrong symptoms showed up.
// ================================================================

module tb;

    localparam ADDR_WIDTH = 23;
    localparam DATA_WIDTH = 8;
    localparam ACC_WIDTH  = 32;
    localparam PARALLEL   = 4;
    localparam MAX_CONN   = 8;
    localparam N_TOTAL    = 4096;

    reg clk, rst;
    reg run_start;
    wire busy, done, err;
    reg [ADDR_WIDTH-1:0] x_base, table_base, out_base;
    reg [15:0] n_inputs_graph, num_neurons_graph, n_out;

    wire ram_req, ram_wr;
    wire [ADDR_WIDTH-1:0] ram_addr;
    wire signed [7:0] ram_wdata;
    reg signed [7:0] ram_rdata;
    reg ram_ready;

    graph_engine #(
        .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH),
        .PARALLEL(PARALLEL), .MAX_CONN(MAX_CONN), .N_TOTAL(N_TOTAL)
    ) dut (
        .clk(clk), .rst(rst),
        .run_start(run_start), .busy(busy), .done(done), .err(err),
        .x_base(x_base), .table_base(table_base), .out_base(out_base),
        .n_inputs_graph(n_inputs_graph), .num_neurons_graph(num_neurons_graph), .n_out(n_out),
        .ram_req(ram_req), .ram_wr(ram_wr), .ram_addr(ram_addr), .ram_wdata(ram_wdata),
        .ram_rdata(ram_rdata), .ram_ready(ram_ready)
    );

    initial begin clk = 0; forever #5 clk = ~clk; end

    // Non-trivial (not all-zero) "garbage" pattern: a repeating ramp,
    // deliberately NOT chosen to make the src_id<out_id guard trip
    // immediately or never -- meant to be a plausible stand-in for
    // "real but wrong" PSRAM content, not a hand-picked best/worst case.
    always @(posedge clk) begin
        ram_ready <= ram_req;
        ram_rdata <= ram_addr[7:0] ^ 8'h5A;
    end

    integer watchdog;

    initial begin
        rst <= 1;
        run_start <= 0;
        x_base <= 0; table_base <= 0; out_base <= 0;
        n_inputs_graph <= 4; num_neurons_graph <= 0; n_out <= 1;
        repeat(3) @(posedge clk);
        rst <= 0;
        @(posedge clk);

        $display("--- num_neurons_graph=0: must complete as an immediate no-op right after input copy, no garbage descriptor iterations ---");
        run_start <= 1;
        @(posedge clk);
        run_start <= 0;

        watchdog = 0;
        while (!done && !err && watchdog < 5000) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end

        if (err) begin
            $display("FAIL: err fired at cycle %0d (neuron_idx=%0d) -- BUG-006 fix regressed, still falling through to the descriptor loop and tripping the src_id guard instead of taking the immediate no-op path", watchdog, dut.neuron_idx);
        end else if (!done) begin
            $display("FAIL: neither done nor err in %0d cycles -- neuron_idx=%0d, busy=%b (BUG-006 fix regressed, back to running through garbage descriptor iterations)", watchdog, dut.neuron_idx, busy);
        end else if (dut.neuron_idx !== 16'd0) begin
            $display("FAIL: done fired at cycle %0d but neuron_idx=%0d (expected 0 -- the descriptor loop was entered instead of taking the immediate no-op path, BUG-006 fix regressed)", watchdog, dut.neuron_idx);
        end else if (watchdog > 30) begin
            $display("FAIL: done fired at cycle %0d with neuron_idx=0, but that is far more than the handful of cycles an immediate no-op (after copying %0d input(s)) should take -- worth re-examining", watchdog, n_inputs_graph);
        end else begin
            $display("PASS: num_neurons_graph=0 completed as an immediate no-op at cycle %0d, neuron_idx stayed 0, no err -- BUG-006 fix confirmed, no garbage descriptor iterations executed", watchdog);
        end
        $finish;
    end

endmodule
