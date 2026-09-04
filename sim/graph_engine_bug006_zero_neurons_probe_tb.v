`timescale 1ns/1ps

// ================================================================
// C.6 probe (NOT a certified bug entry by itself -- see file header
// note below and docs/validation/06-graph-engine.md): does
// num_neurons_graph=0 reproduce the same class of issue as BUG-005
// (rtl/layer_sequencer.v)?
//
// Structural analysis: rtl/graph_engine.v's neuron_idx (line 159) is
// a full 16-bit register, and the termination check
// `neuron_idx == num_neurons_graph-16'd1` (lines 527/561) wraps to
// 65535 for num_neurons_graph=0 -- a value neuron_idx CAN naturally
// reach, structurally identical to BUG-005's layer_idx pattern. This
// probe checks empirically what actually happens within a BOUNDED
// window (a full 65536-iteration run was not attempted -- would take
// far longer per iteration than layer_sequencer's simpler dispatch,
// impractical for this campaign's effort budget; see docs/validation/
// 06-graph-engine.md for the honesty note about this limitation).
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

        $display("--- num_neurons_graph=0, bounded 5000-cycle observation window ---");
        run_start <= 1;
        @(posedge clk);
        run_start <= 0;

        watchdog = 0;
        while (!done && !err && watchdog < 5000) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end

        if (err)
            $display("RESULT: err fired at cycle %0d (neuron_idx=%0d) -- the src_id<out_id/N_TOTAL guard caught the garbage descriptor data before completion. Self-limiting for THIS data pattern (not proof it always does for every possible PSRAM content).", watchdog, dut.neuron_idx);
        else if (done)
            $display("RESULT: done fired at cycle %0d (neuron_idx=%0d) -- completed without err", watchdog, dut.neuron_idx);
        else
            $display("RESULT: neither done nor err in %0d cycles -- neuron_idx=%0d, busy=%b (consistent with BUG-005's pattern: running through many garbage iterations rather than hanging outright; NOT run to full completion, see docs/validation/06-graph-engine.md for why)", watchdog, dut.neuron_idx, busy);
        $finish;
    end

endmodule
