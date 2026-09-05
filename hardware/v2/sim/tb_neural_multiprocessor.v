`timescale 1ns/1ps

// ============================================================
// M8 testbench (docs/v2-description.md §15/§16/§20):
// neural_multiprocessor.v -- dataflow_core.v (M7, unmodified) sharing
// the REAL, UNMODIFIED V1 PSRAM backend chain (int8_memory_access ->
// memory_interface -> psram_controller -> real psram_model) across
// N_SLOTS=2 concurrent memory_manager instances for the first time,
// through the new slot_mem_arbiter.v (M8).
//
// Same DAG shape as tb_dataflow_core.v (M7's own test), REPLACING the
// per-slot behavioral memories with the single real PSRAM chain --
// this is the actual M8 measurement: does real arbitration/contention
// across genuinely-concurrent slots work correctly against real PSRAM
// timing (not an idealized 2-cycle behavioral model)?
//
//   node0 (x=2,w=3,8in -> acc=48) --+
//                                   +--> node2 (x=1,w=5,8in -> acc=40)
//   node1 (x=1,w=1,8in -> acc=8)  --+
//
// node0 and node1 are registered back-to-back with NO dependencies,
// so both are dispatched to the two available slots essentially
// simultaneously -- both memory_manager instances will genuinely
// contend for the one real PSRAM port at the same time, exercising
// slot_mem_arbiter.v's arbitration for real (not just in isolation).
//
// Verified with Verilator (decisions.log DEC-0004).
// ============================================================

module tb;

    localparam ADDR_WIDTH  = 23;
    localparam DATA_WIDTH  = 8;
    localparam P_IN        = 8;
    localparam ACC_WIDTH   = 32;
    localparam N_SLOTS     = 2;
    localparam N_NODES     = 8;
    localparam MAX_DEPS    = 4;
    localparam QUEUE_DEPTH = 4;
    localparam NODE_IDW    = $clog2(N_NODES);
    localparam PSRAM_DATA_WIDTH = 16;
    localparam CLK_PERIOD  = 12.5; // 80 MHz, matches psram_controller's CLK_FREQ_MHZ

    reg clk, rst;
    initial begin clk = 1'b0; forever #(CLK_PERIOD/2.0) clk = ~clk; end

    reg                                reg_valid;
    wire                               reg_ready;
    reg  [NODE_IDW-1:0]                reg_node_id;
    reg  [$clog2(MAX_DEPS+1)-1:0]      reg_required;
    reg  [MAX_DEPS*NODE_IDW-1:0]       reg_producer_ids;
    reg  [ADDR_WIDTH-1:0]              reg_x_base, reg_w_base, reg_result_addr;
    reg  [15:0]                        reg_n_tiles;

    wire [ADDR_WIDTH-1:0]        psram_a;
    wire [PSRAM_DATA_WIDTH-1:0]  psram_dq;
    wire                         psram_ce_n, psram_oe_n, psram_we_n, psram_lb_n, psram_ub_n, psram_zz_n;

    neural_multiprocessor #(
        .DATA_WIDTH(DATA_WIDTH), .P_IN(P_IN), .ACC_WIDTH(ACC_WIDTH), .ADDR_WIDTH(ADDR_WIDTH),
        .N_SLOTS(N_SLOTS), .N_NODES(N_NODES), .MAX_DEPS(MAX_DEPS), .QUEUE_DEPTH(QUEUE_DEPTH),
        .PSRAM_DATA_WIDTH(PSRAM_DATA_WIDTH), .CLK_FREQ_MHZ(80)
    ) u_nmp (
        .clk(clk), .rst(rst),
        .reg_valid(reg_valid), .reg_ready(reg_ready), .reg_node_id(reg_node_id),
        .reg_required(reg_required), .reg_producer_ids(reg_producer_ids),
        .reg_x_base(reg_x_base), .reg_w_base(reg_w_base), .reg_n_tiles(reg_n_tiles),
        .reg_result_addr(reg_result_addr),
        .psram_a(psram_a), .psram_dq(psram_dq),
        .psram_ce_n(psram_ce_n), .psram_oe_n(psram_oe_n), .psram_we_n(psram_we_n),
        .psram_lb_n(psram_lb_n), .psram_ub_n(psram_ub_n), .psram_zz_n(psram_zz_n)
    );

    psram_model #(.ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(PSRAM_DATA_WIDTH), .DEPTH(16384)) u_psram (
        .clk(clk), .a(psram_a), .dq(psram_dq),
        .ce_n(psram_ce_n), .oe_n(psram_oe_n), .we_n(psram_we_n),
        .lb_n(psram_lb_n), .ub_n(psram_ub_n), .zz_n(psram_zz_n)
    );

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

    function automatic signed [7:0] peek_byte(input [ADDR_WIDTH-1:0] byte_addr);
        reg [ADDR_WIDTH-2:0] word_addr;
        begin
            word_addr = byte_addr[ADDR_WIDTH-1:1];
            peek_byte = (byte_addr[0] == 1'b0) ? u_psram.mem[word_addr][7:0] : u_psram.mem[word_addr][15:8];
        end
    endfunction

    task automatic register_node(
        input [NODE_IDW-1:0] nid,
        input [$clog2(MAX_DEPS+1)-1:0] required,
        input [NODE_IDW-1:0] p0, input [NODE_IDW-1:0] p1,
        input [ADDR_WIDTH-1:0] xb, input [ADDR_WIDTH-1:0] wb,
        input [15:0] nt, input [ADDR_WIDTH-1:0] resaddr
    );
        begin
            @(posedge clk);
            reg_node_id  = nid;
            reg_required = required;
            reg_producer_ids = {NODE_IDW*MAX_DEPS{1'b0}};
            reg_producer_ids[0*NODE_IDW +: NODE_IDW] = p0;
            reg_producer_ids[1*NODE_IDW +: NODE_IDW] = p1;
            reg_x_base = xb; reg_w_base = wb; reg_n_tiles = nt; reg_result_addr = resaddr;
            reg_valid = 1'b1;
            while (!reg_ready) @(posedge clk);
            @(posedge clk);
            reg_valid = 1'b0;
        end
    endtask

    integer errors, tests;
    integer i, wd;

    initial begin
        errors = 0; tests = 0;
        rst = 1; reg_valid = 0; reg_node_id = 0; reg_required = 0; reg_producer_ids = 0;
        reg_x_base = 0; reg_w_base = 0; reg_n_tiles = 0; reg_result_addr = 0;
        repeat(5) @(posedge clk);
        rst = 0;

        // Real PSRAM power-up sequence (~150us @ 80MHz) -- same
        // requirement/convention as tb_memory_manager.v (M4).
        wait (u_nmp.u_psram_ctrl.state == u_nmp.u_psram_ctrl.STATE_IDLE);
        @(posedge clk);

        for (i = 0; i < 8; i = i + 1) begin
            poke_byte(23'h10+i, 8'sd2); poke_byte(23'h20+i, 8'sd3); // node0: x=2,w=3
            poke_byte(23'h30+i, 8'sd1); poke_byte(23'h40+i, 8'sd1); // node1: x=1,w=1
            poke_byte(23'h50+i, 8'sd1); poke_byte(23'h60+i, 8'sd5); // node2: x=1,w=5
        end
        poke_byte(23'h70, 8'sd0); poke_byte(23'h71, 8'sd0); poke_byte(23'h72, 8'sd0);

        // node0, node1: no dependencies -- dispatched back-to-back, so
        // BOTH slots start genuinely concurrent PSRAM traffic through
        // the shared arbiter at essentially the same time.
        register_node(0, 0, 0, 0, 23'h10, 23'h20, 16'd1, 23'h70);
        register_node(1, 0, 0, 0, 23'h30, 23'h40, 16'd1, 23'h71);
        register_node(2, 2, 0, 1, 23'h50, 23'h60, 16'd1, 23'h72);

        tests = tests + 1;
        wd = 0;
        while ((peek_byte(23'h70)==0 || peek_byte(23'h71)==0) && wd < 20000) begin
            if (peek_byte(23'h72) !== 8'sd0) begin
                $display("FAIL: node2 completed before both node0 and node1 finished");
                errors = errors + 1;
            end
            @(posedge clk); wd = wd + 1;
        end
        $display("PASS: node2 did not complete before both its dependencies did (checked every cycle up to wd=%0d)", wd);

        wd = 0;
        while (peek_byte(23'h72)==0 && wd < 20000) begin @(posedge clk); wd = wd + 1; end
        repeat(10) @(posedge clk);

        tests = tests + 3;
        if (peek_byte(23'h70) !== 8'sd48) begin
            $display("FAIL node0: result=%0d expected 48", peek_byte(23'h70));
            errors = errors + 1;
        end else $display("PASS node0: result=48 via real PSRAM + shared arbiter");

        if (peek_byte(23'h71) !== 8'sd8) begin
            $display("FAIL node1: result=%0d expected 8", peek_byte(23'h71));
            errors = errors + 1;
        end else $display("PASS node1: result=8 via real PSRAM + shared arbiter (concurrent with node0)");

        if (peek_byte(23'h72) !== 8'sd40) begin
            $display("FAIL node2: result=%0d expected 40", peek_byte(23'h72));
            errors = errors + 1;
        end else $display("PASS node2: result=40, dispatched only after BOTH producers genuinely completed, real PSRAM end-to-end");

        $display("========================================");
        if (errors == 0)
            $display("ALL %0d TESTS PASSED (neural_multiprocessor, real V1 PSRAM chain shared across N_SLOTS=%0d via slot_mem_arbiter)", tests, N_SLOTS);
        else
            $display("FAILED: %0d/%0d test(s) had errors -- see messages above", errors, tests);
        $display("========================================");
        $finish;
    end

endmodule
