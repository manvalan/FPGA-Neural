`timescale 1ns/1ps

// ============================================================
// NMS STEP14 Part A4 -- bit-exact correctness testbench for
// weight_prefetch_engine_wide.v, parametrized across MEM_DATA_WIDTH
// in {16,32,64,128}. Same methodology as tb_weight_prefetch.v
// (STEP11): a real weight SRAM (nms_weight_packed.v, unchanged,
// N_SLOTS=1), an ideal WIDE word memory (sim_wide_mem, configurable
// extra latency), bit-exact data checking against a known per-tile
// fill pattern, and the SAME edge-case coverage (n_tiles in
// {0,1,2,PFD,PFD+1,MAX_TILES-1,MAX_TILES}, back-to-back jobs,
// injected extra latency).
// ============================================================
module sim_wide_mem #(
    parameter ADDR_WIDTH = 23,
    parameter MEM_DATA_WIDTH = 64,
    parameter DEPTH_WORDS = 4096,
    parameter EXTRA_WAIT = 0
)(
    input  wire clk, rst,
    input  wire req,
    input  wire [ADDR_WIDTH-1:0] addr, // byte address of the transaction
    output reg  [MEM_DATA_WIDTH-1:0] rdata,
    output reg  ready
);
    localparam BYTES_PER_WORD = MEM_DATA_WIDTH/8;
    reg [7:0] mem [0:DEPTH_WORDS*BYTES_PER_WORD-1]; // byte-addressable backing array
    reg [3:0] state;
    reg [ADDR_WIDTH-1:0] addr_reg;
    reg [7:0] wait_cnt;
    integer k;
    localparam ST_IDLE=0, ST_WAIT=1;
    always @(posedge clk) begin
        if (rst) begin state<=ST_IDLE; ready<=0; rdata<=0; end
        else begin
            ready <= 0;
            case (state)
                ST_IDLE: if (req) begin
                    addr_reg <= addr;
                    wait_cnt <= EXTRA_WAIT[7:0];
                    state <= ST_WAIT;
                end
                ST_WAIT: begin
                    if (wait_cnt != 0) begin
                        wait_cnt <= wait_cnt - 1'b1;
                    end else begin
                        for (k = 0; k < BYTES_PER_WORD; k = k + 1)
                            rdata[k*8 +: 8] <= mem[addr_reg + k];
                        ready <= 1;
                        state <= ST_IDLE;
                    end
                end
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule

module tb #(
    parameter MEM_DATA_WIDTH = 64,
    parameter PFD = 4,
    parameter EXTRA_WAIT = 0
);
    parameter ADDR_WIDTH = 23;
    parameter DATA_WIDTH = 8;
    parameter P_IN = 8;
    parameter MAX_TILES = 16;
    localparam TIW = $clog2(MAX_TILES);
    localparam CNTW = $clog2(MAX_TILES+1);
    localparam BYTES_PER_WORD = MEM_DATA_WIDTH/8;

    reg clk = 0;
    always #5 clk = ~clk;
    reg rst;

    reg job_active;
    reg [ADDR_WIDTH-1:0] w_base;
    reg [15:0] n_tiles;
    reg [CNTW-1:0] consumed_count;

    wire wgt_fill_we;
    wire [TIW-1:0] wgt_fill_addr;
    wire [DATA_WIDTH*P_IN-1:0] wgt_fill_data;
    wire [CNTW-1:0] ready_count;

    wire mem_req;
    wire [ADDR_WIDTH-1:0] mem_addr;
    wire [MEM_DATA_WIDTH-1:0] mem_rdata;
    wire mem_ready;

    weight_prefetch_engine_wide #(
        .DATA_WIDTH(DATA_WIDTH), .P_IN(P_IN), .ADDR_WIDTH(ADDR_WIDTH),
        .MAX_TILES(MAX_TILES), .PREFETCH_DISTANCE(PFD), .MEM_DATA_WIDTH(MEM_DATA_WIDTH)
    ) dut (
        .clk(clk), .rst(rst),
        .job_active(job_active), .w_base(w_base), .n_tiles(n_tiles),
        .consumed_count(consumed_count),
        .wgt_fill_we(wgt_fill_we), .wgt_fill_addr(wgt_fill_addr), .wgt_fill_data(wgt_fill_data),
        .ready_count(ready_count),
        .mem_req(mem_req), .mem_addr(mem_addr), .mem_rdata(mem_rdata), .mem_ready(mem_ready)
    );

    sim_wide_mem #(.ADDR_WIDTH(ADDR_WIDTH), .MEM_DATA_WIDTH(MEM_DATA_WIDTH),
        .DEPTH_WORDS(4096), .EXTRA_WAIT(EXTRA_WAIT)) u_mem (
        .clk(clk), .rst(rst), .req(mem_req), .addr(mem_addr), .rdata(mem_rdata), .ready(mem_ready)
    );

    reg  wgt_rd_en;
    reg  [TIW-1:0] wgt_rd_addr;
    wire signed [DATA_WIDTH*P_IN-1:0] wgt_rd_data;
    nms_weight_packed #(.DATA_WIDTH(DATA_WIDTH), .P_IN(P_IN), .N_SLOTS(1), .MAX_TILES(MAX_TILES)) u_sram (
        .clk(clk), .rst(rst),
        .fill_we(wgt_fill_we), .fill_addr_flat(wgt_fill_addr), .fill_data_flat(wgt_fill_data),
        .rd_en(wgt_rd_en), .rd_addr_flat(wgt_rd_addr), .rd_data_flat(wgt_rd_data)
    );

    task automatic poke_byte(input [ADDR_WIDTH-1:0] byte_addr, input [7:0] val);
        begin
            u_mem.mem[byte_addr] = val;
        end
    endtask

    integer errors, tests;

    task automatic fill_pattern(input [ADDR_WIDTH-1:0] base, input integer count);
        integer t, k;
        begin
            for (t = 0; t < count; t = t + 1)
                for (k = 0; k < P_IN; k = k + 1)
                    poke_byte(base + t*P_IN + k, (t*8+k) % 251);
        end
    endtask

    reg freeze_consumer;
    always @(posedge clk) begin
        if (rst || !job_active) consumed_count <= {CNTW{1'b0}};
        else if (!freeze_consumer && consumed_count < ready_count) consumed_count <= consumed_count + 1'b1;
    end

    task automatic run_job(input [ADDR_WIDTH-1:0] base, input integer count, input integer watchdog);
        integer wd, t, k;
        reg [7:0] expected;
        begin
            w_base = base; n_tiles = count[15:0];
            job_active = 1'b1;
            wd = 0;
            while (ready_count < count[CNTW-1:0] && wd < watchdog) begin @(posedge clk); wd = wd + 1; end
            @(posedge clk); #1;
            tests = tests + 1;
            if (ready_count !== count[CNTW-1:0]) begin
                $display("FAIL n_tiles=%0d MEM_W=%0d PFD=%0d: ready_count=%0d expected=%0d (watchdog=%0d)",
                    count, MEM_DATA_WIDTH, PFD, ready_count, count, wd);
                errors = errors + 1;
            end else begin
                for (t = 0; t < count; t = t + 1) begin
                    wgt_rd_addr = t[TIW-1:0]; wgt_rd_en = 1'b1;
                    @(posedge clk); @(posedge clk); #1;
                    for (k = 0; k < P_IN; k = k + 1) begin
                        expected = (t*8+k) % 251;
                        if (wgt_rd_data[k*DATA_WIDTH +: DATA_WIDTH] !== expected) begin
                            $display("FAIL n_tiles=%0d MEM_W=%0d PFD=%0d tile=%0d lane=%0d: got=%0d expected=%0d",
                                count, MEM_DATA_WIDTH, PFD, t, k, wgt_rd_data[k*DATA_WIDTH +: DATA_WIDTH], expected);
                            errors = errors + 1;
                        end
                    end
                end
                $display("PASS n_tiles=%0d MEM_W=%0d PFD=%0d EXTRA_WAIT=%0d: ready_count=%0d, all tiles bit-exact (cycles=%0d)",
                    count, MEM_DATA_WIDTH, PFD, EXTRA_WAIT, ready_count, wd);
            end
            job_active = 1'b0;
            repeat(3) @(posedge clk);
        end
    endtask

    initial begin
        errors = 0; tests = 0;
        rst = 1; job_active = 0; w_base = 0; n_tiles = 0; consumed_count = 0; wgt_rd_en = 0; wgt_rd_addr = 0; freeze_consumer = 0;
        repeat(4) @(posedge clk);
        rst = 0;
        @(posedge clk);

        fill_pattern(23'h1000, MAX_TILES);

        run_job(23'h1000, 0, 200);
        run_job(23'h1000, 1, 200);
        run_job(23'h1000, 2, 200);
        if (PFD < MAX_TILES) begin
            run_job(23'h1000, PFD, 500);
            run_job(23'h1000, PFD+1, 500);
        end
        run_job(23'h1000, MAX_TILES-1, 2000);
        run_job(23'h1000, MAX_TILES, 2000);

        run_job(23'h1000, 3, 500);
        run_job(23'h1000, 5, 500);

        $display("=== %0d/%0d tests, %0d errors (MEM_DATA_WIDTH=%0d, PFD=%0d, MAX_TILES=%0d, EXTRA_WAIT=%0d) ===",
            tests-errors, tests, errors, MEM_DATA_WIDTH, PFD, MAX_TILES, EXTRA_WAIT);
        if (errors == 0) $display("ALL TESTS PASSED (tb_weight_prefetch_wide, MEM_DATA_WIDTH=%0d, PFD=%0d, EXTRA_WAIT=%0d)", MEM_DATA_WIDTH, PFD, EXTRA_WAIT);
        $finish;
    end
endmodule
