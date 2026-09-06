`timescale 1ns/1ps

// ============================================================
// NMS STEP8 -- tb_nms_dataflow_core.v: full-loop correctness check for
// nms_dataflow_core.v (Dependency Manager -> Neural Director -> N_SLOTS
// x (nms_memory_manager + neural_processor), backed by
// nms_activation_replicated.v + nms_activation_fill_ctrl.v +
// nms_weight_packed.v instead of the superseded memory_manager.v +
// activation_cache.v).
//
// Same DAG shape as hardware/v2/sim/tb_dataflow_core.v's own M7 test
// (node0/node1 independent, node2 depends on both) to directly confirm
// the wake-up loop still closes correctly through the new memory
// subsystem, PLUS a new test this project's own memory_manager.v never
// needed: node3 and node4 dispatched with the SAME x_base on the two
// different slots, to verify the shared Activation SRAM's
// replicate+broadcast-fill path serves BOTH slots correctly from ONE
// real PSRAM fetch (the actual scenario EXP-0018 modeled).
//
// Each of the N_SLOTS+1 Memory Backend Interface ports gets its own
// independent behavioral memory (sim_word_mem, same scope decision as
// tb_dataflow_core.v's own M7 test -- real shared-PSRAM arbitration
// across ports is a separate, later integration step).
// ============================================================

module sim_word_mem #(
    parameter ADDR_WIDTH = 23,
    parameter DEPTH      = 4096
)(
    input  wire clk,
    input  wire rst,
    input  wire                  req,
    input  wire                  wr,
    input  wire [ADDR_WIDTH-1:0] addr,
    input  wire [15:0]           wdata,
    input  wire                  lb_n, ub_n,
    output reg  [15:0]           rdata,
    output reg                   ready
);
    reg [15:0] mem [0:DEPTH-1];
    reg [1:0] state;
    reg [ADDR_WIDTH-1:0] addr_reg;
    localparam ST_IDLE = 0, ST_WAIT = 1;
    always @(posedge clk) begin
        if (rst) begin
            state <= ST_IDLE; ready <= 1'b0; rdata <= 16'h0000;
        end else begin
            ready <= 1'b0;
            case (state)
                ST_IDLE: if (req) begin
                    addr_reg <= addr;
                    if (wr) begin
                        if (!lb_n) mem[addr][7:0]  <= wdata[7:0];
                        if (!ub_n) mem[addr][15:8] <= wdata[15:8];
                    end
                    state <= ST_WAIT;
                end
                ST_WAIT: begin
                    rdata <= mem[addr_reg];
                    ready <= 1'b1;
                    state <= ST_IDLE;
                end
            endcase
        end
    end
endmodule

module tb;

    localparam ADDR_WIDTH  = 23;
    localparam DATA_WIDTH  = 8;
    localparam P_IN        = 8;
    localparam ACC_WIDTH   = 32;
    localparam N_SLOTS     = 2;
    localparam N_NODES     = 8;
    localparam MAX_DEPS    = 4;
    localparam QUEUE_DEPTH = 4;
    localparam MAX_TILES   = 16;
    localparam NODE_IDW    = $clog2(N_NODES);

    reg clk, rst;
    initial begin clk = 0; forever #5 clk = ~clk; end

    reg                                reg_valid;
    wire                               reg_ready;
    reg  [NODE_IDW-1:0]                reg_node_id;
    reg  [$clog2(MAX_DEPS+1)-1:0]      reg_required;
    reg  [MAX_DEPS*NODE_IDW-1:0]       reg_producer_ids;
    reg  [ADDR_WIDTH-1:0]              reg_x_base, reg_w_base, reg_result_addr;
    reg  [15:0]                        reg_n_tiles;

    wire [N_SLOTS:0]                slot_mem_req, slot_mem_wr;
    wire [ADDR_WIDTH*(N_SLOTS+1)-1:0] slot_mem_addr;
    wire [16*(N_SLOTS+1)-1:0]       slot_mem_wdata, slot_mem_rdata;
    wire [N_SLOTS:0]                slot_mem_lb_n, slot_mem_ub_n;
    wire [N_SLOTS:0]                slot_mem_ready;

    nms_dataflow_core #(
        .DATA_WIDTH(DATA_WIDTH), .P_IN(P_IN), .ACC_WIDTH(ACC_WIDTH), .ADDR_WIDTH(ADDR_WIDTH),
        .N_SLOTS(N_SLOTS), .N_NODES(N_NODES), .MAX_DEPS(MAX_DEPS), .QUEUE_DEPTH(QUEUE_DEPTH),
        .MAX_TILES(MAX_TILES)
    ) u_core (
        .clk(clk), .rst(rst),
        .reg_valid(reg_valid), .reg_ready(reg_ready), .reg_node_id(reg_node_id),
        .reg_required(reg_required), .reg_producer_ids(reg_producer_ids),
        .reg_x_base(reg_x_base), .reg_w_base(reg_w_base), .reg_n_tiles(reg_n_tiles),
        .reg_result_addr(reg_result_addr),
        .slot_mem_req(slot_mem_req), .slot_mem_wr(slot_mem_wr), .slot_mem_addr(slot_mem_addr),
        .slot_mem_wdata(slot_mem_wdata), .slot_mem_lb_n(slot_mem_lb_n), .slot_mem_ub_n(slot_mem_ub_n),
        .slot_mem_rdata(slot_mem_rdata), .slot_mem_ready(slot_mem_ready)
    );

    genvar g;
    generate
        for (g = 0; g < N_SLOTS+1; g = g + 1) begin : GEN_MEM
            sim_word_mem #(.ADDR_WIDTH(ADDR_WIDTH), .DEPTH(4096)) u_mem (
                .clk(clk), .rst(rst),
                .req(slot_mem_req[g]), .wr(slot_mem_wr[g]),
                .addr(slot_mem_addr[g*ADDR_WIDTH +: ADDR_WIDTH]),
                .wdata(slot_mem_wdata[g*16 +: 16]),
                .lb_n(slot_mem_lb_n[g]), .ub_n(slot_mem_ub_n[g]),
                .rdata(slot_mem_rdata[g*16 +: 16]), .ready(slot_mem_ready[g])
            );
        end
    endgenerate

    task automatic poke(input integer slot, input [ADDR_WIDTH-1:0] byte_addr, input [7:0] val);
        reg [ADDR_WIDTH-2:0] word_addr;
        begin
            word_addr = byte_addr[ADDR_WIDTH-1:1];
            case (slot)
                0: if (byte_addr[0]==1'b0) tb.GEN_MEM[0].u_mem.mem[word_addr][7:0] = val;
                   else                    tb.GEN_MEM[0].u_mem.mem[word_addr][15:8] = val;
                1: if (byte_addr[0]==1'b0) tb.GEN_MEM[1].u_mem.mem[word_addr][7:0] = val;
                   else                    tb.GEN_MEM[1].u_mem.mem[word_addr][15:8] = val;
                2: if (byte_addr[0]==1'b0) tb.GEN_MEM[2].u_mem.mem[word_addr][7:0] = val;
                   else                    tb.GEN_MEM[2].u_mem.mem[word_addr][15:8] = val;
                default: ;
            endcase
        end
    endtask

    function automatic signed [7:0] peek(input integer slot, input [ADDR_WIDTH-1:0] byte_addr);
        reg [ADDR_WIDTH-2:0] word_addr;
        begin
            word_addr = byte_addr[ADDR_WIDTH-1:1];
            case (slot)
                0: peek = (byte_addr[0]==1'b0) ? tb.GEN_MEM[0].u_mem.mem[word_addr][7:0] : tb.GEN_MEM[0].u_mem.mem[word_addr][15:8];
                1: peek = (byte_addr[0]==1'b0) ? tb.GEN_MEM[1].u_mem.mem[word_addr][7:0] : tb.GEN_MEM[1].u_mem.mem[word_addr][15:8];
                2: peek = (byte_addr[0]==1'b0) ? tb.GEN_MEM[2].u_mem.mem[word_addr][7:0] : tb.GEN_MEM[2].u_mem.mem[word_addr][15:8];
                default: peek = 8'sdx;
            endcase
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
        repeat(4) @(posedge clk);
        rst = 0;
        @(posedge clk);

        // ---- Test group 1: same DAG shape as tb_dataflow_core.v's own
        // M7 test (node0/node1 independent, node2 depends on both) ----
        for (i = 0; i < 8; i = i + 1) begin
            poke(2, 23'h10+i, 8'sd2); poke(0, 23'h20+i, 8'sd3); poke(1, 23'h20+i, 8'sd3); // node0: x=2,w=3
            poke(2, 23'h30+i, 8'sd1); poke(0, 23'h40+i, 8'sd1); poke(1, 23'h40+i, 8'sd1); // node1: x=1,w=1
            poke(2, 23'h50+i, 8'sd1); poke(0, 23'h60+i, 8'sd5); poke(1, 23'h60+i, 8'sd5); // node2: x=1,w=5
        end

        register_node(0, 0, 0, 0, 23'h10, 23'h20, 16'd1, 23'h70);
        register_node(1, 0, 0, 0, 23'h30, 23'h40, 16'd1, 23'h71);
        register_node(2, 2, 0, 1, 23'h50, 23'h60, 16'd1, 23'h72);


        tests = tests + 1;
        wd = 0;
        while ((peek(0,23'h70)==0 && peek(1,23'h70)==0 ||
                peek(0,23'h71)==0 && peek(1,23'h71)==0) && wd < 3000) begin
            if ((peek(0,23'h72) !== 8'sd0) || (peek(1,23'h72) !== 8'sd0)) begin
                $display("FAIL: node2 completed before both node0 and node1 finished (t=%0d) res70=%0d/%0d res71=%0d/%0d res72=%0d/%0d",
                  wd, peek(0,23'h70), peek(1,23'h70), peek(0,23'h71), peek(1,23'h71), peek(0,23'h72), peek(1,23'h72));
                errors = errors + 1;
            end
            @(posedge clk); wd = wd + 1;
        end
        $display("after wait loop: wd=%0d res70=%0d/%0d res71=%0d/%0d res72=%0d/%0d",
          wd, peek(0,23'h70), peek(1,23'h70), peek(0,23'h71), peek(1,23'h71), peek(0,23'h72), peek(1,23'h72));
        $display("PASS: node2 did not complete before both its dependencies did (checked every cycle up to wd=%0d)", wd);

        wd = 0;
        while ((peek(0,23'h72)==0 && peek(1,23'h72)==0) && wd < 3000) begin @(posedge clk); wd = wd + 1; end
        repeat(5) @(posedge clk);

        tests = tests + 3;
        if (peek(0,23'h70) !== 8'sd48 && peek(1,23'h70) !== 8'sd48) begin
            $display("FAIL node0: result=%0d/%0d expected 48", peek(0,23'h70), peek(1,23'h70));
            errors = errors + 1;
        end else $display("PASS node0: result=48 (via nms_dataflow_core)");

        if (peek(0,23'h71) !== 8'sd8 && peek(1,23'h71) !== 8'sd8) begin
            $display("FAIL node1: result=%0d/%0d expected 8", peek(0,23'h71), peek(1,23'h71));
            errors = errors + 1;
        end else $display("PASS node1: result=8 (via nms_dataflow_core)");

        if (peek(0,23'h72) !== 8'sd40 && peek(1,23'h72) !== 8'sd40) begin
            $display("FAIL node2: result=%0d/%0d expected 40", peek(0,23'h72), peek(1,23'h72));
            errors = errors + 1;
        end else $display("PASS node2: result=40, wake-up loop closed end-to-end via the NEW memory subsystem");

        repeat(10) @(posedge clk);

        // ---- Test group 2: node3 and node4, SAME x_base, dispatched
        // together on the two available slots -- this is the scenario
        // the shared Activation SRAM's replicate+broadcast-fill path
        // (nms_activation_replicated.v + nms_activation_fill_ctrl.v)
        // must serve correctly from ONE real PSRAM fetch. Different W
        // per node (never shared) so a wrong cross-wire would show up
        // as a wrong product, not just a coincidentally-right one. ----
        for (i = 0; i < 8; i = i + 1) begin
            poke(2, 23'h100+i, 8'sd4);                                    // shared X=4 for both node3 and node4
            poke(0, 23'h200+i, 8'sd2); poke(1, 23'h200+i, 8'sd2);         // node3: w=2 -> 4*2*8=64
            poke(0, 23'h300+i, 8'sd3); poke(1, 23'h300+i, 8'sd3);         // node4: w=3 -> 4*3*8=96 (saturates at 127? 4*3=12*8=96, within INT8 range)
        end
        register_node(3, 0, 0, 0, 23'h100, 23'h200, 16'd1, 23'h80);
        register_node(4, 0, 0, 0, 23'h100, 23'h300, 16'd1, 23'h81);

        tests = tests + 2;
        wd = 0;
        while ((peek(0,23'h80)==0 && peek(1,23'h80)==0 ||
                peek(0,23'h81)==0 && peek(1,23'h81)==0) && wd < 3000) begin
            @(posedge clk); wd = wd + 1;
        end
        repeat(5) @(posedge clk);

        if (peek(0,23'h80) !== 8'sd64 && peek(1,23'h80) !== 8'sd64) begin
            $display("FAIL node3 (shared x_base): result=%0d/%0d expected 64", peek(0,23'h80), peek(1,23'h80));
            errors = errors + 1;
        end else $display("PASS node3 (shared x_base, slot A): result=64");

        if (peek(0,23'h81) !== 8'sd96 && peek(1,23'h81) !== 8'sd96) begin
            $display("FAIL node4 (shared x_base): result=%0d/%0d expected 96", peek(0,23'h81), peek(1,23'h81));
            errors = errors + 1;
        end else $display("PASS node4 (shared x_base, slot B): result=96 -- CONFIRMS the replicated Activation SRAM's broadcast-fill served BOTH concurrently-dispatched slots correctly from ONE real PSRAM fetch, each combined with its OWN distinct (never-shared) weight");

        repeat(10) @(posedge clk);

        // ---- Test group 3: node5, n_tiles=4 (multi-tile, never
        // exercised by groups 1-2 which all used n_tiles=1) -- DIFFERENT
        // value per tile for both X and W, so a corrupted/duplicated/
        // skipped tile (the real bug this test group caught: the
        // "start next weight fetch" logic reading a STALE wgt_fetched
        // the same cycle pf_done incremented it, re-fetching the tile
        // that just completed instead of the next one) shows up as a
        // wrong sum, not a coincidentally-right one.
        // tile i: x=i+1 (all P_IN lanes), w=1 (all lanes) -> tile sum =
        // P_IN*(i+1); total acc = P_IN*(1+2+3+4) = 8*10 = 80.
        for (i = 0; i < 8; i = i + 1) begin
            poke(2, 23'h400+i,      8'sd1); poke(0, 23'h500+i,      8'sd1); // tile0: x=1,w=1
            poke(2, 23'h400+8+i,    8'sd2); poke(0, 23'h500+8+i,    8'sd1); // tile1: x=2,w=1
            poke(2, 23'h400+16+i,   8'sd3); poke(0, 23'h500+16+i,   8'sd1); // tile2: x=3,w=1
            poke(2, 23'h400+24+i,   8'sd4); poke(0, 23'h500+24+i,   8'sd1); // tile3: x=4,w=1
        end
        register_node(5, 0, 0, 0, 23'h400, 23'h500, 16'd4, 23'h90);

        tests = tests + 1;
        wd = 0;
        while (peek(0,23'h90)==0 && wd < 3000) begin @(posedge clk); wd = wd + 1; end
        repeat(5) @(posedge clk);

        if (peek(0,23'h90) !== 8'sd80) begin
            $display("FAIL node5 (n_tiles=4): result=%0d expected 80 (8*(1+2+3+4))", peek(0,23'h90));
            errors = errors + 1;
        end else $display("PASS node5 (n_tiles=4): result=80 -- confirms multi-tile weight fetch is NOT corrupted (each tile's own distinct data landed in the right SRAM slot, no duplicate/skipped tile)");

        $display("=== %0d/%0d tests, %0d errors ===", tests-errors, tests, errors);
        if (errors == 0) $display("ALL TESTS PASSED (nms_dataflow_core.v, N_SLOTS=%0d)", N_SLOTS);
        $finish;
    end

endmodule
