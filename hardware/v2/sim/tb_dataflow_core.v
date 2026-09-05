`timescale 1ns/1ps

// ============================================================
// M7 testbench (docs/v2-description.md §17/§19/§20): dataflow_core.v
// -- the FULL loop, end-to-end, for the first time: node registration
// -> Dependency Manager -> Neural Director -> (Memory Manager +
// Neural Processor) per slot -> completion -> wake-up of dependent
// nodes -> repeat, with NO external component gluing any of these
// stages together (all internal to dataflow_core.v).
//
// DAG (same shape as tb_dependency_manager.v's own §10-focused test,
// now driven through the WHOLE system instead of dependency_manager
// in isolation): node0 and node1 have no dependencies and run
// concurrently on the 2 available slots; node2 depends on BOTH and
// must not be dispatched until both have genuinely completed their
// real neural_processor computation (not just been "marked done" --
// its own result is checked too).
//
//   node0 (x=2,w=3,8in -> acc=48) --+
//                                   +--> node2 (x=1,w=5,8in -> acc=40)
//   node1 (x=1,w=1,8in -> acc=8)  --+
//
// Verified with Verilator (decisions.log DEC-0004). Each slot gets
// its own independent behavioral memory (sim_word_mem, same as
// tb_neural_director.v/tb_memory_manager.v's own scope decisions --
// DEC-0006/DEC-0007: shared-PSRAM arbitration across slots is
// explicitly M8's job, not exercised here).
//
// WORD-level (16-bit, + lb_n/ub_n) post-M10 (decisions.log DEC-0015),
// matching memory_manager.v's own backend port width after the
// burst-read rewrite (see prefetch_engine.v/memory_manager.v headers).
// ============================================================

module sim_word_mem #(
    parameter ADDR_WIDTH = 23,
    parameter DEPTH      = 4096
)(
    input  wire clk,
    input  wire rst,
    input  wire                  req,
    input  wire                  wr,
    input  wire [ADDR_WIDTH-1:0] addr,   // WORD address
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

    // Arrays sized N_SLOTS+1 post-M10 (decisions.log DEC-0016) -- index
    // N_SLOTS is the shared activation_cache's own backend port. Each
    // index still gets its OWN independent behavioral memory (matches
    // this testbench's own pre-existing scope: real shared-PSRAM
    // arbitration across slots is M8's job, not exercised here) --
    // X data is poked ONCE into memory index N_SLOTS (the cache's own,
    // single shared backing store) rather than duplicated per-slot,
    // since X now genuinely flows through ONE shared path regardless
    // of which slot a job lands on; W data is still poked into every
    // slot's own memory (unchanged), since W is not shared.
    wire [N_SLOTS:0]                slot_mem_req, slot_mem_wr;
    wire [ADDR_WIDTH*(N_SLOTS+1)-1:0] slot_mem_addr;
    wire [16*(N_SLOTS+1)-1:0]       slot_mem_wdata, slot_mem_rdata;
    wire [N_SLOTS:0]                slot_mem_lb_n, slot_mem_ub_n;
    wire [N_SLOTS:0]                slot_mem_ready;

    dataflow_core #(
        .DATA_WIDTH(DATA_WIDTH), .P_IN(P_IN), .ACC_WIDTH(ACC_WIDTH), .ADDR_WIDTH(ADDR_WIDTH),
        .N_SLOTS(N_SLOTS), .N_NODES(N_NODES), .MAX_DEPS(MAX_DEPS), .QUEUE_DEPTH(QUEUE_DEPTH)
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

    // poke/peek stay BYTE-addressed at the testbench level (matching
    // every other testbench's own convention) -- converted to
    // word-address + byte-lane internally, same as psram_model.v's
    // own real convention.
    task automatic poke(input integer slot, input [ADDR_WIDTH-1:0] byte_addr, input [7:0] val);
        reg [ADDR_WIDTH-2:0] word_addr;
        begin
            word_addr = byte_addr[ADDR_WIDTH-1:1];
            case (slot)
                0: if (byte_addr[0]==1'b0) tb.GEN_MEM[0].u_mem.mem[word_addr][7:0] = val;
                   else                    tb.GEN_MEM[0].u_mem.mem[word_addr][15:8] = val;
                1: if (byte_addr[0]==1'b0) tb.GEN_MEM[1].u_mem.mem[word_addr][7:0] = val;
                   else                    tb.GEN_MEM[1].u_mem.mem[word_addr][15:8] = val;
                2: if (byte_addr[0]==1'b0) tb.GEN_MEM[2].u_mem.mem[word_addr][7:0] = val; // shared activation_cache backing store (N_SLOTS index)
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

        // Pre-load PSRAM-equivalent memory. W (per-slot, not shared)
        // still needs to land in EVERY slot's own memory (a job could
        // land on either slot, first-free). X (post-DEC-0016) flows
        // through the ONE shared activation_cache instead -- poked
        // once into memory index N_SLOTS(=2)'s backing store.
        for (i = 0; i < 8; i = i + 1) begin
            poke(2, 23'h10+i, 8'sd2); poke(0, 23'h20+i, 8'sd3); poke(1, 23'h20+i, 8'sd3); // node0: x=2,w=3
            poke(2, 23'h30+i, 8'sd1); poke(0, 23'h40+i, 8'sd1); poke(1, 23'h40+i, 8'sd1); // node1: x=1,w=1
            poke(2, 23'h50+i, 8'sd1); poke(0, 23'h60+i, 8'sd5); poke(1, 23'h60+i, 8'sd5); // node2: x=1,w=5
        end

        // node0, node1: no dependencies. node2: depends on BOTH.
        register_node(0, 0, 0, 0, 23'h10, 23'h20, 16'd1, 23'h70);
        register_node(1, 0, 0, 0, 23'h30, 23'h40, 16'd1, 23'h71);
        register_node(2, 2, 0, 1, 23'h50, 23'h60, 16'd1, 23'h72);

        // node2 must not complete before node0/node1 do -- checked by
        // polling: as soon as EITHER result byte at 0x70/0x71 is still
        // zero, 0x72 must also still be zero (node2 cannot have run).
        tests = tests + 1;
        wd = 0;
        while ((peek(0,23'h70)==0 && peek(1,23'h70)==0 ||
                peek(0,23'h71)==0 && peek(1,23'h71)==0) && wd < 3000) begin
            if ((peek(0,23'h72) !== 8'sd0) || (peek(1,23'h72) !== 8'sd0)) begin
                $display("FAIL: node2 completed before both node0 and node1 finished");
                errors = errors + 1;
            end
            @(posedge clk); wd = wd + 1;
        end
        $display("PASS: node2 did not complete before both its dependencies did (checked every cycle up to wd=%0d)", wd);

        // Now wait for node2 itself to complete.
        wd = 0;
        while ((peek(0,23'h72)==0 && peek(1,23'h72)==0) && wd < 3000) begin @(posedge clk); wd = wd + 1; end
        repeat(5) @(posedge clk);

        tests = tests + 3;
        if (peek(0,23'h70) !== 8'sd48 && peek(1,23'h70) !== 8'sd48) begin
            $display("FAIL node0: result=%0d/%0d expected 48 on one slot", peek(0,23'h70), peek(1,23'h70));
            errors = errors + 1;
        end else $display("PASS node0: result=48 (real neural_processor computation, via full dataflow_core)");

        if (peek(0,23'h71) !== 8'sd8 && peek(1,23'h71) !== 8'sd8) begin
            $display("FAIL node1: result=%0d/%0d expected 8 on one slot", peek(0,23'h71), peek(1,23'h71));
            errors = errors + 1;
        end else $display("PASS node1: result=8 (real neural_processor computation, via full dataflow_core)");

        if (peek(0,23'h72) !== 8'sd40 && peek(1,23'h72) !== 8'sd40) begin
            $display("FAIL node2: result=%0d/%0d expected 40 on one slot", peek(0,23'h72), peek(1,23'h72));
            errors = errors + 1;
        end else $display("PASS node2: result=40, dispatched only after BOTH node0 and node1 genuinely completed (full wake-up loop closed end-to-end)");

        $display("========================================");
        if (errors == 0)
            $display("ALL %0d TESTS PASSED (dataflow_core, full M1-M6 integration end-to-end)", tests);
        else
            $display("FAILED: %0d/%0d test(s) had errors -- see messages above", errors, tests);
        $display("========================================");
        $finish;
    end

endmodule
