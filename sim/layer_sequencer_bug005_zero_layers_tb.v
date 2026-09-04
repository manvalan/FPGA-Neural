`timescale 1ns/1ps

// ================================================================
// C.5 / BUG-005 REGRESSION TEST: rtl/layer_sequencer.v with
// run_num_layers=0.
//
// BUG-005 (docs/validation/bugs.md), now FIXED: run_num_layers=0
// used to make layer_idx (a full 8-bit register) wrap the termination
// check to 255, running through all 256 possible layer indices and
// executing 256 fabricated "layers" from garbage PSRAM bytes far past
// the real, N_LAYERS-sized descriptor table -- confirmed via this
// exact test before the fix: 21761 cycles, layer_idx ending at 255.
//
// Fix (rtl/layer_sequencer.v, ST_IDLE): run_num_layers==0 is now an
// explicit, immediate no-op -- seq_done pulses without ever entering
// ST_READ_DESC, same convention as spi_engine.v's WRITE_RAM/READ_RAM
// len==0 guard. This test now ASSERTS that behavior (previously it
// only observed and reported, since the pre-fix outcome was the bug
// itself, not a pass/fail condition).
// ================================================================
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

        $display("--- run_num_layers=0: must complete immediately, must NOT run through 256 garbage layers ---");
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
            $display("FAIL: run_num_layers=0 HANGS -- no seq_done in %0d cycles, seq_busy=%b, layer_idx=%0d (BUG-005 fix regressed)", watchdog, seq_busy, dut.layer_idx);
        end else if (dut.layer_idx !== 8'd0) begin
            $display("FAIL: seq_done reached after %0d cycles but layer_idx=%0d (expected 0 -- the sequencer entered the descriptor-read loop instead of taking the immediate no-op path, BUG-005 fix regressed)", watchdog, dut.layer_idx);
        end else if (watchdog > 5) begin
            $display("FAIL: seq_done reached in %0d cycles with layer_idx=0, but that is far more than the ~1-2 cycles an immediate no-op should take -- worth re-examining even though layer_idx itself looks correct", watchdog);
        end else begin
            $display("PASS: run_num_layers=0 completed as an immediate no-op in %0d cycle(s), layer_idx stayed 0 -- BUG-005 fix confirmed, no garbage layers executed", watchdog);
        end
        $finish;
    end

endmodule
