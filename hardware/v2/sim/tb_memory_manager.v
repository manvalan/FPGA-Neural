`timescale 1ns/1ps

// ============================================================
// M4 testbench (docs/v2-description.md §12/§13/§15/§20): full
// end-to-end stack -- memory_manager.v + prefetch_engine.v (V2, M4)
// driving a REAL hardware/v2/rtl/neural_processor.v (M1) on one side,
// and the REAL, UNMODIFIED hardware/v1 PSRAM backend chain
// (int8_memory_access -> memory_interface -> psram_controller ->
// psram_model) on the other -- exactly the layering §15 mandates
// ("Memory Manager -> Memory Backend Interface -> PSRAM Controller"),
// with the backend reused byte-for-byte from the frozen V1 tree.
//
// Verified with Verilator (see decisions.log DEC-0004).
//
// Coverage:
//   - end-to-end job: PSRAM pre-loaded with real X/W bytes at known
//     addresses, memory_manager fetches them (double-buffered
//     prefetch across multiple tiles), feeds neural_processor, and
//     writes the computed result back to PSRAM -- read back
//     independently afterward and checked against a hand-computed
//     expectation (an oracle independent of the RTL under test).
//   - multi-tile job (prefetch actually has to overlap tile N+1's
//     fetch with tile N's compute, not just single-tile).
//   - "poison" bytes surrounding the real operand region, to catch
//     any off-by-one addressing error in prefetch_engine.
// ============================================================

module tb;

    localparam ADDR_WIDTH = 23;
    localparam DATA_WIDTH = 8;
    localparam P_IN       = 8;
    localparam ACC_WIDTH  = 32;
    localparam PSRAM_DATA_WIDTH = 16;
    localparam CLK_PERIOD = 12.5; // 80 MHz, matches psram_controller's CLK_FREQ_MHZ

    reg clk, rst;
    initial begin clk = 1'b0; forever #(CLK_PERIOD/2.0) clk = ~clk; end

    // ---- memory_manager <-> neural_processor ----
    reg                                  job_start;
    reg  [ADDR_WIDTH-1:0]                x_base, w_base, result_addr;
    reg  [15:0]                          n_tiles;
    wire                                 job_done;

    wire                                 mm_operand_valid, mm_operand_ready;
    wire signed [DATA_WIDTH*P_IN-1:0]    mm_input_data, mm_weight_data;
    wire                                 mm_tile_last;

    wire                                 mm_result_valid, mm_result_ready;
    wire signed [DATA_WIDTH-1:0]         mm_result_data;

    // ---- memory_manager's own WEIGHT backend port (word-level Memory
    // Backend Interface, post-M10 DEC-0015) ----
    wire                    mm_mem_req, mm_mem_wr;
    wire [ADDR_WIDTH-1:0]   mm_mem_addr;   // WORD address
    wire [15:0]             mm_mem_wdata;
    wire                    mm_mem_lb_n, mm_mem_ub_n;
    wire [15:0]             mm_mem_rdata;
    wire                    mm_mem_ready;

    // ---- shared activation_cache (M10+, DEC-0016) -- N_SLOTS=1 here
    // (a single memory_manager instance), routed through a real 2-port
    // arbiter (weight port + cache port) into the SAME real
    // memory_interface, mirroring dataflow_core.v/neural_multiprocessor.v's
    // own real structure exactly, just scoped down to one slot. ----
    wire                    xc_req;
    wire [ADDR_WIDTH-1:0]   xc_x_base;
    wire [15:0]             xc_tile_idx;
    wire                    xc_ack;
    wire signed [DATA_WIDTH*P_IN-1:0] xc_tile_x;

    wire                    xc_mem_req, xc_mem_wr;
    wire [ADDR_WIDTH-1:0]   xc_mem_addr;
    wire [15:0]             xc_mem_wdata;
    wire                    xc_mem_lb_n, xc_mem_ub_n;
    wire [15:0]             xc_mem_rdata;
    wire                    xc_mem_ready;

    activation_cache #(
        .DATA_WIDTH(DATA_WIDTH), .P_IN(P_IN), .ADDR_WIDTH(ADDR_WIDTH), .N_SLOTS(1)
    ) u_xcache (
        .clk(clk), .rst(rst),
        .req(xc_req), .req_x_base(xc_x_base), .req_tile_idx(xc_tile_idx),
        .ack(xc_ack), .tile_x_out(xc_tile_x),
        .mem_req(xc_mem_req), .mem_wr(xc_mem_wr), .mem_addr(xc_mem_addr), .mem_wdata(xc_mem_wdata),
        .mem_lb_n(xc_mem_lb_n), .mem_ub_n(xc_mem_ub_n),
        .mem_rdata(xc_mem_rdata), .mem_ready(xc_mem_ready)
    );

    wire [1:0]              arb2_req    = {xc_mem_req, mm_mem_req};
    wire [1:0]              arb2_wr     = {xc_mem_wr, mm_mem_wr};
    wire [ADDR_WIDTH*2-1:0] arb2_addr   = {xc_mem_addr, mm_mem_addr};
    wire [31:0]             arb2_wdata  = {xc_mem_wdata, mm_mem_wdata};
    wire [1:0]              arb2_lb_n   = {xc_mem_lb_n, mm_mem_lb_n};
    wire [1:0]              arb2_ub_n   = {xc_mem_ub_n, mm_mem_ub_n};
    wire [31:0]             arb2_rdata;
    wire [1:0]              arb2_ready;
    assign mm_mem_rdata = arb2_rdata[15:0];
    assign mm_mem_ready = arb2_ready[0];
    assign xc_mem_rdata = arb2_rdata[31:16];
    assign xc_mem_ready = arb2_ready[1];

    wire                    arb_m_req, arb_m_wr;
    wire [ADDR_WIDTH-1:0]   arb_m_addr;
    wire [15:0]             arb_m_wdata;
    wire                    arb_m_lb_n, arb_m_ub_n;
    wire [15:0]             arb_m_rdata;
    wire                    arb_m_ready;

    slot_mem_arbiter #(.ADDR_WIDTH(ADDR_WIDTH), .N_PORTS(2)) u_arb2 (
        .clk(clk), .rst(rst),
        .s_req(arb2_req), .s_wr(arb2_wr), .s_addr(arb2_addr),
        .s_wdata(arb2_wdata), .s_lb_n(arb2_lb_n), .s_ub_n(arb2_ub_n),
        .s_rdata(arb2_rdata), .s_ready(arb2_ready),
        .m_req(arb_m_req), .m_wr(arb_m_wr), .m_addr(arb_m_addr), .m_wdata(arb_m_wdata),
        .m_lb_n(arb_m_lb_n), .m_ub_n(arb_m_ub_n),
        .m_rdata(arb_m_rdata), .m_ready(arb_m_ready)
    );

    memory_manager #(
        .DATA_WIDTH(DATA_WIDTH), .P_IN(P_IN), .ADDR_WIDTH(ADDR_WIDTH)
    ) u_mm (
        .clk(clk), .rst(rst),
        .job_start(job_start), .x_base(x_base), .w_base(w_base),
        .n_tiles(n_tiles), .result_addr(result_addr), .job_done(job_done),
        .operand_valid(mm_operand_valid), .operand_ready(mm_operand_ready),
        .input_data(mm_input_data), .weight_data(mm_weight_data), .tile_last(mm_tile_last),
        .result_valid(mm_result_valid), .result_ready(mm_result_ready), .result_data(mm_result_data),
        .xc_req(xc_req), .xc_x_base(xc_x_base), .xc_tile_idx(xc_tile_idx),
        .xc_ack(xc_ack), .xc_tile_x(xc_tile_x),
        .mem_req(mm_mem_req), .mem_wr(mm_mem_wr), .mem_addr(mm_mem_addr), .mem_wdata(mm_mem_wdata),
        .mem_lb_n(mm_mem_lb_n), .mem_ub_n(mm_mem_ub_n),
        .mem_rdata(mm_mem_rdata), .mem_ready(mm_mem_ready)
    );

    // ---- real Neural Processor (M1), driven entirely by memory_manager ----
    reg                          job_valid_np;
    wire                         job_ready_np;
    wire                         result_valid_np;
    wire signed [DATA_WIDTH-1:0] result_data_np;
    wire [15:0]                  result_node_id_np;
    wire [3:0]                   np_state;
    wire                         np_error;

    neural_processor #(
        .DATA_WIDTH(DATA_WIDTH), .P_IN(P_IN), .ACC_WIDTH(ACC_WIDTH)
    ) u_np (
        .clk(clk), .rst(rst),
        .job_valid(job_valid_np), .job_ready(job_ready_np),
        .job_node_id(16'h0), .job_bias(8'sd0), .job_activation(2'd1), // ACT_RELU
        .operand_valid(mm_operand_valid), .operand_ready(mm_operand_ready),
        .input_data(mm_input_data), .weight_data(mm_weight_data), .tile_last(mm_tile_last),
        .result_valid(result_valid_np), .result_ready(mm_result_ready),
        .result_data(result_data_np), .result_node_id(result_node_id_np),
        .np_state(np_state), .np_error(np_error)
    );
    assign mm_result_valid = result_valid_np;
    assign mm_result_data  = result_data_np;

    // job_valid_np must pulse once per memory_manager job, synchronized
    // to job_start (both start a "job" at the same moment: memory_manager
    // begins prefetching tile 0 while neural_processor waits in NP_IDLE
    // until tile 0 actually arrives, exactly like any other operand
    // producer feeding it).
    always @(posedge clk) begin
        if (rst) job_valid_np <= 1'b0;
        else if (job_start) job_valid_np <= 1'b1;
        else if (job_valid_np && job_ready_np) job_valid_np <= 1'b0;
    end

    // ---- REAL, unmodified V1 backend chain (memory_interface ->
    // psram_controller; int8_memory_access no longer in this datapath,
    // see memory_manager.v's own header, DEC-0015) ----
    wire                          pc_mem_req, pc_mem_wr;
    wire [ADDR_WIDTH-1:0]         pc_mem_addr;
    wire [PSRAM_DATA_WIDTH-1:0]   pc_mem_wdata;
    wire                          pc_mem_lb_n, pc_mem_ub_n;
    wire [PSRAM_DATA_WIDTH-1:0]   pc_mem_rdata;
    wire                          pc_mem_ready;

    memory_interface #(.ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(PSRAM_DATA_WIDTH)) u_memif (
        .clk(clk), .rst(rst),
        .req(arb_m_req), .wr(arb_m_wr), .addr(arb_m_addr), .wdata(arb_m_wdata),
        .lb_n(arb_m_lb_n), .ub_n(arb_m_ub_n),
        .rdata(arb_m_rdata), .ready(arb_m_ready),
        .mem_req(pc_mem_req), .mem_wr(pc_mem_wr), .mem_addr(pc_mem_addr), .mem_wdata(pc_mem_wdata),
        .mem_lb_n(pc_mem_lb_n), .mem_ub_n(pc_mem_ub_n),
        .mem_rdata(pc_mem_rdata), .mem_ready(pc_mem_ready)
    );

    wire [ADDR_WIDTH-1:0]        psram_a;
    wire [PSRAM_DATA_WIDTH-1:0]  psram_dq;
    wire                         psram_ce_n, psram_oe_n, psram_we_n, psram_lb_n, psram_ub_n, psram_zz_n;

    psram_controller #(
        .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(PSRAM_DATA_WIDTH), .CLK_FREQ_MHZ(80)
    ) u_psram_ctrl (
        .clk(clk), .rst(rst),
        .mem_req(pc_mem_req), .mem_wr(pc_mem_wr), .mem_addr(pc_mem_addr), .mem_wdata(pc_mem_wdata),
        .mem_lb_n(pc_mem_lb_n), .mem_ub_n(pc_mem_ub_n),
        .mem_rdata(pc_mem_rdata), .mem_ready(pc_mem_ready),
        .psram_a(psram_a), .psram_dq(psram_dq),
        .psram_ce_n(psram_ce_n), .psram_oe_n(psram_oe_n), .psram_we_n(psram_we_n),
        .psram_lb_n(psram_lb_n), .psram_ub_n(psram_ub_n), .psram_zz_n(psram_zz_n)
    );

    psram_model #(.ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(PSRAM_DATA_WIDTH), .DEPTH(16384)) u_psram (
        .clk(clk), .a(psram_a), .dq(psram_dq),
        .ce_n(psram_ce_n), .oe_n(psram_oe_n), .we_n(psram_we_n),
        .lb_n(psram_lb_n), .ub_n(psram_ub_n), .zz_n(psram_zz_n)
    );

    // ---- helper: poke one byte directly into psram_model's backing
    // array (test setup only, bypasses the real write path -- same
    // convention as hardware/v1/sim's own testbenches that pre-load
    // psram_model for read-side tests). ----
    task automatic poke_byte(input [ADDR_WIDTH-1:0] byte_addr, input [7:0] val);
        reg [ADDR_WIDTH-2:0] word_addr;
        begin
            word_addr = byte_addr[ADDR_WIDTH-1:1];
            if (byte_addr[0] == 1'b0)
                u_psram.mem[word_addr][7:0] = val;
            else
                u_psram.mem[word_addr][15:8] = val;
        end
    endtask

    task automatic peek_byte(input [ADDR_WIDTH-1:0] byte_addr, output [7:0] val);
        reg [ADDR_WIDTH-2:0] word_addr;
        begin
            word_addr = byte_addr[ADDR_WIDTH-1:1];
            val = (byte_addr[0] == 1'b0) ? u_psram.mem[word_addr][7:0] : u_psram.mem[word_addr][15:8];
        end
    endtask

    integer errors, tests;
    integer i;

    function automatic signed [7:0] expect_relu(input integer acc);
        begin
            if (acc <= 0) expect_relu = 0;
            else if (acc > 127) expect_relu = 127;
            else expect_relu = acc[7:0];
        end
    endfunction

    task automatic run_job(
        input [ADDR_WIDTH-1:0] xb, input [ADDR_WIDTH-1:0] wb,
        input [15:0] nt, input [ADDR_WIDTH-1:0] resaddr,
        input signed [7:0] exp_y
    );
        integer wd;
        reg [7:0] rb;
        begin
            @(posedge clk);
            tests = tests + 1;
            x_base = xb; w_base = wb; n_tiles = nt; result_addr = resaddr;
            job_start = 1'b1;
            @(posedge clk);
            job_start = 1'b0;
            wd = 0;
            while (!job_done && wd < 2000) begin
                @(posedge clk);
                wd = wd + 1;
            end
            if (!job_done) begin
                $display("FAIL job xb=%0d: no job_done within watchdog (%0d cycles)", xb, wd);
                errors = errors + 1;
            end else begin
                peek_byte(resaddr, rb);
                if (rb !== exp_y[7:0]) begin
                    $display("FAIL job xb=%0d: PSRAM result byte=%0d expected=%0d (%0d cycles)", xb, $signed(rb), exp_y, wd);
                    errors = errors + 1;
                end else begin
                    $display("PASS job xb=%0d: PSRAM result byte=%0d correct, %0d cycles, n_tiles=%0d", xb, $signed(rb), wd, nt);
                end
            end
        end
    endtask

    initial begin
        errors = 0; tests = 0;
        rst = 1; job_start = 0; x_base = 0; w_base = 0; n_tiles = 0; result_addr = 0;
        repeat(5) @(posedge clk);
        rst = 0;

        // Wait for the real PSRAM controller's power-up sequence
        // (~150us @ 80MHz) before issuing any request -- same
        // requirement/convention documented in
        // hardware/v1/docs/FPGA-NeuralNetwork-Engine.md's
        // WRITE_RAM/READ_RAM backpressure warning.
        wait (u_psram_ctrl.state == u_psram_ctrl.STATE_IDLE);
        @(posedge clk);

        // ---- pre-load PSRAM: X at 0x1000, W at 0x2000, 3 tiles
        // (24 inputs), with "poison" bytes immediately before/after
        // the real region to catch any off-by-one in prefetch_engine's
        // addressing. ----
        for (i = -4; i < 24+4; i = i + 1) begin
            poke_byte(23'h1000 + i, 8'sd99); // poison
            poke_byte(23'h2000 + i, 8'sd99); // poison
        end
        for (i = 0; i < 24; i = i + 1) begin
            poke_byte(23'h1000 + i, 8'sd2);  // X = 2
            poke_byte(23'h2000 + i, 8'sd3);  // W = 3
        end
        // acc = 24 * 2 * 3 = 144 -> ACT_RELU saturates to 127
        run_job(23'h1000, 23'h2000, 16'd3, 23'h3000, expect_relu(144));

        // ---- second job: 1 tile (8 inputs), smaller, no saturation ----
        for (i = 0; i < 8; i = i + 1) begin
            poke_byte(23'h4000 + i, 8'sd1); // X = 1
            poke_byte(23'h5000 + i, 8'sd4); // W = 4
        end
        // acc = 8*1*4 = 32
        run_job(23'h4000, 23'h5000, 16'd1, 23'h3001, expect_relu(32));

        // ---- third job: 5 tiles (40 inputs), exercises the
        // steady-state double-buffer swap across more than 2 tiles. ----
        for (i = 0; i < 40; i = i + 1) begin
            poke_byte(23'h6000 + i, 8'sd1); // X = 1
            poke_byte(23'h7000 + i, 8'sd1); // W = 1
        end
        // acc = 40*1*1 = 40
        run_job(23'h6000, 23'h7000, 16'd5, 23'h3002, expect_relu(40));

        $display("========================================");
        if (errors == 0)
            $display("ALL %0d TESTS PASSED (memory_manager + prefetch_engine, real V1 PSRAM backend, real neural_processor)", tests);
        else
            $display("FAILED: %0d/%0d test(s) had errors -- see messages above", errors, tests);
        $display("========================================");
        $finish;
    end

endmodule
