`timescale 1ns/1ps

// ================================================================
// C.5 certification: rtl/layer_sequencer.v with run_num_layers=0.
//
// The header documents run_num_layers as "1..N_LAYERS" but there is
// no elaboration-time or runtime guard visible in the RTL enforcing
// that range (unlike rtl/neuron_parallel.v's PARAMETER GUARD for
// N_INPUTS%PARALLEL). layer_idx (rtl/layer_sequencer.v:121) is a full
// 8-bit register, and the loop terminates on
// `layer_idx == num_layers_reg - 8'd1` (line 303). For
// num_layers_reg=0, that wraps to `layer_idx == 255` -- a value
// layer_idx CAN naturally reach by counting up from 0 (unlike
// BUG-002's 1-bit group_index, which could never represent the
// wrapped value at all) -- so this is hypothesized to NOT hang, but
// instead run through all 256 possible layer indices, each one
// dispatching a full neuron_memory run with whatever garbage
// descriptor bytes it reads from far beyond the real, N_LAYERS-sized
// table. This test checks that hypothesis empirically rather than
// asserting it.
//
// neuron_memory is NOT instantiated -- layer_sequencer only needs
// nm_busy/nm_done as far as its own control-flow is concerned, so a
// minimal fake responder (assert busy the cycle after nm_start, done
// one cycle later) is enough to observe how many layer iterations
// actually occur, without needing the full memory stack.
// ================================================================

module tb;

    localparam ADDR_WIDTH = 23;
    localparam DATA_WIDTH = 8;
    localparam N_WIDTH    = 8;
    localparam N_LAYERS   = 4;

    reg clk, rst;
    reg run_start;
    reg [7:0] run_num_layers;
    wire seq_busy, seq_done;
    reg [ADDR_WIDTH-1:0] x_base, table_base, buf_a_base, buf_b_base;

    wire [ADDR_WIDTH-1:0] nm_x_base, nm_w_base, nm_bias_addr;
    wire [1:0] nm_activation;
    wire [15:0] nm_n_inputs, nm_n_neurons;
    wire nm_start;
    reg nm_busy, nm_done;
    reg signed [DATA_WIDTH*N_WIDTH-1:0] y_bus;

    wire ram_req, ram_wr;
    wire [ADDR_WIDTH-1:0] ram_addr;
    wire signed [7:0] ram_wdata;
    reg signed [7:0] ram_rdata;
    reg ram_ready;

    layer_sequencer #(
        .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH), .N_WIDTH(N_WIDTH), .N_LAYERS(N_LAYERS)
    ) dut (
        .clk(clk), .rst(rst),
        .run_start(run_start), .run_num_layers(run_num_layers),
        .seq_busy(seq_busy), .seq_done(seq_done),
        .x_base(x_base), .table_base(table_base), .buf_a_base(buf_a_base), .buf_b_base(buf_b_base),
        .nm_x_base(nm_x_base), .nm_w_base(nm_w_base), .nm_bias_addr(nm_bias_addr),
        .nm_activation(nm_activation), .nm_n_inputs(nm_n_inputs), .nm_n_neurons(nm_n_neurons),
        .nm_start(nm_start), .nm_busy(nm_busy), .nm_done(nm_done), .y_bus(y_bus),
        .ram_req(ram_req), .ram_wr(ram_wr), .ram_addr(ram_addr), .ram_wdata(ram_wdata),
        .ram_rdata(ram_rdata), .ram_ready(ram_ready)
    );

    initial begin clk = 0; forever #5 clk = ~clk; end

    // Minimal always-1-cycle-latency RAM stub: any request completes
    // next cycle, content is a fixed byte (irrelevant to this check --
    // only iteration COUNT and eventual termination matter here).
    always @(posedge clk) begin
        ram_ready <= ram_req;
        ram_rdata <= 8'sd0;
    end

    // Minimal fake neuron_memory: busy one cycle after start, done one
    // cycle after that.
    reg [1:0] nm_state;
    always @(posedge clk) begin
        if (rst) begin
            nm_busy <= 0; nm_done <= 0; nm_state <= 0;
        end else begin
            nm_done <= 0;
            case (nm_state)
                0: if (nm_start) begin nm_busy <= 1; nm_state <= 1; end
                1: begin nm_busy <= 0; nm_done <= 1; nm_state <= 0; end
            endcase
        end
    end

    integer watchdog;

    initial begin
        rst <= 1;
        run_start <= 0; run_num_layers <= 0;
        x_base <= 0; table_base <= 0; buf_a_base <= 0; buf_b_base <= 0;
        y_bus <= 0;
        repeat(3) @(posedge clk);
        rst <= 0;
        @(posedge clk);

        $display("--- run_num_layers=0: does it hang, or run through 256 garbage layers? ---");
        run_num_layers <= 8'd0;
        run_start <= 1;
        @(posedge clk);
        run_start <= 0;

        watchdog = 0;
        while (!seq_done && watchdog < 200000) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end

        if (!seq_done) begin
            $display("RESULT: run_num_layers=0 HANGS -- no seq_done in %0d cycles, seq_busy=%b, layer_idx=%0d", watchdog, seq_busy, dut.layer_idx);
        end else begin
            $display("RESULT: run_num_layers=0 completed after %0d cycles -- dut.layer_idx ended at %0d (0=terminated immediately as if 0 real layers, 255=ran all 256 possible indices before the wraparound check fired, something else=partial)", watchdog, dut.layer_idx);
        end
        $finish;
    end

endmodule
