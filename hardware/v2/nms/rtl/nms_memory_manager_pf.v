// ============================================================
// Neural Memory System (NMS) -- STEP11: per-slot memory manager, REAL
// WEIGHT PREFETCH variant ("_pf").
//
// Identical external interface to nms_memory_manager.v (drop-in, same
// Director/Dependency-Manager side, same Neural-Processor-facing
// operand/result streams) -- the ONLY change is the private weight
// path: prefetch_engine.v (single-shot, one tile in flight, real
// per-tile control-restart overhead, ERR-0013/STEP11's own analysis)
// is replaced by weight_prefetch_engine.v (continuous multi-tile
// fetch stream, configurable PREFETCH_DISTANCE lookahead window).
//
// nms_memory_manager.v itself is UNTOUCHED -- this file exists
// alongside it specifically so "Current NMS" (baseline) and "NMS +
// weight prefetch" remain independently reproducible for the A/B
// comparison STEP11 explicitly requires.
// ============================================================
module nms_memory_manager_pf #(
    parameter DATA_WIDTH = 8,
    parameter P_IN       = 8,
    parameter ADDR_WIDTH = 23,
    parameter MAX_TILES  = 16,
    parameter PREFETCH_DISTANCE = 8,
    parameter TIW        = (MAX_TILES <= 1) ? 1 : $clog2(MAX_TILES),
    parameter CNTW        = $clog2(MAX_TILES+1)
)(
    input  wire clk,
    input  wire rst,

    input  wire                      job_start,
    input  wire [ADDR_WIDTH-1:0]     x_base,
    input  wire [ADDR_WIDTH-1:0]     w_base,
    input  wire [15:0]               n_tiles,
    input  wire [ADDR_WIDTH-1:0]     result_addr,
    output reg                       job_done,

    output reg                                operand_valid,
    input  wire                               operand_ready,
    output reg  signed [DATA_WIDTH*P_IN-1:0]  input_data,
    output reg  signed [DATA_WIDTH*P_IN-1:0]  weight_data,
    output reg                                tile_last,

    input  wire                       result_valid,
    output reg                        result_ready,
    input  wire signed [DATA_WIDTH-1:0] result_data,

    output wire            job_active,
    output wire [ADDR_WIDTH-1:0] job_x_base,
    output wire [15:0]     job_n_tiles,

    input  wire [ADDR_WIDTH-1:0] act_resident_tag,
    input  wire [CNTW-1:0]       act_resident_count,

    output reg              act_rd_en,
    output reg  [TIW-1:0]   act_rd_addr,
    input  wire signed [DATA_WIDTH*P_IN-1:0] act_rd_data,

    // ---- weight SRAM fill port now driven by weight_prefetch_engine
    // (below), NOT by this FSM directly -- read port unchanged ----
    output wire              wgt_fill_we,
    output wire [TIW-1:0]    wgt_fill_addr,
    output wire [DATA_WIDTH*P_IN-1:0] wgt_fill_data,
    output reg              wgt_rd_en,
    output reg  [TIW-1:0]   wgt_rd_addr,
    input  wire signed [DATA_WIDTH*P_IN-1:0] wgt_rd_data,

    output wire                    mem_req,
    output wire                    mem_wr,
    output wire [ADDR_WIDTH-1:0]   mem_addr,
    output wire [15:0]             mem_wdata,
    output wire                    mem_lb_n,
    output wire                    mem_ub_n,
    input  wire [15:0]             mem_rdata,
    input  wire                    mem_ready
);

    localparam ST_IDLE        = 3'd0;
    localparam ST_RUN         = 3'd1;
    localparam ST_WAIT_RESULT = 3'd2;
    localparam ST_WRITE_RES   = 3'd3;
    localparam ST_DONE        = 3'd4;

    reg [2:0] state;
    reg job_active_reg;
    assign job_active  = job_active_reg;
    assign job_x_base  = x_base_reg;
    assign job_n_tiles = n_tiles_reg;

    reg [ADDR_WIDTH-1:0] x_base_reg, w_base_reg, result_addr_reg;
    reg [15:0]           n_tiles_reg;
    reg [CNTW-1:0]       tile_idx;

    reg                  read_issued;
    reg                  read_ready;

    wire [CNTW-1:0] wgt_ready_count;

    wire usable_act_count_valid = (act_resident_tag == x_base_reg);
    wire [CNTW-1:0] usable_act = usable_act_count_valid ? act_resident_count : {CNTW{1'b0}};
    wire can_present = ({{(16-CNTW){1'b0}}, tile_idx} < n_tiles_reg) &&
                        (tile_idx < wgt_ready_count) &&
                        (tile_idx < usable_act);

    // ---- REAL weight prefetch engine (STEP11): continuous multi-tile
    // fetch stream, PREFETCH_DISTANCE-bounded lookahead ahead of
    // tile_idx (this module's own consumption pointer) ----
    weight_prefetch_engine #(
        .DATA_WIDTH(DATA_WIDTH), .P_IN(P_IN), .ADDR_WIDTH(ADDR_WIDTH),
        .MAX_TILES(MAX_TILES), .PREFETCH_DISTANCE(PREFETCH_DISTANCE)
    ) u_wpf (
        .clk(clk), .rst(rst),
        .job_active(job_active_reg), .w_base(w_base_reg), .n_tiles(n_tiles_reg),
        .consumed_count(tile_idx),
        .wgt_fill_we(wgt_fill_we), .wgt_fill_addr(wgt_fill_addr), .wgt_fill_data(wgt_fill_data),
        .ready_count(wgt_ready_count),
        .mem_req(mem_req_wpf), .mem_wr(mem_wr_wpf), .mem_addr(mem_addr_wpf), .mem_wdata(mem_wdata_wpf),
        .mem_lb_n(mem_lb_n_wpf), .mem_ub_n(mem_ub_n_wpf),
        .mem_rdata(mem_rdata), .mem_ready(mem_ready)
    );
    wire mem_req_wpf, mem_wr_wpf;
    wire [ADDR_WIDTH-1:0] mem_addr_wpf;
    wire [15:0] mem_wdata_wpf;
    wire mem_lb_n_wpf, mem_ub_n_wpf;

    reg                   wr_mem_req;
    reg  [ADDR_WIDTH-1:0] wr_mem_addr;
    reg  [15:0]           wr_mem_wdata;
    reg                   wr_mem_lb_n, wr_mem_ub_n;

    wire wr_active = (state == ST_WRITE_RES) || (state == ST_DONE);
    assign mem_req   = wr_active ? wr_mem_req   : mem_req_wpf;
    assign mem_wr    = wr_active ? 1'b1         : mem_wr_wpf;
    assign mem_addr  = wr_active ? wr_mem_addr  : mem_addr_wpf;
    assign mem_wdata = wr_active ? wr_mem_wdata : mem_wdata_wpf;
    assign mem_lb_n  = wr_active ? wr_mem_lb_n  : mem_lb_n_wpf;
    assign mem_ub_n  = wr_active ? wr_mem_ub_n  : mem_ub_n_wpf;

    always @(posedge clk) begin
        if (rst) begin
            state          <= ST_IDLE;
            job_active_reg <= 1'b0;
            job_done       <= 1'b0;
            operand_valid  <= 1'b0;
            tile_last      <= 1'b0;
            result_ready   <= 1'b0;
            tile_idx       <= {CNTW{1'b0}};
            read_issued    <= 1'b0;
            read_ready     <= 1'b0;
            act_rd_en      <= 1'b0;
            wgt_rd_en      <= 1'b0;
            wr_mem_req     <= 1'b0;
            wr_mem_lb_n    <= 1'b1;
            wr_mem_ub_n    <= 1'b1;
        end else begin
            job_done     <= 1'b0;
            act_rd_en    <= 1'b0;
            wgt_rd_en    <= 1'b0;
            result_ready <= 1'b0;

            case (state)
                ST_IDLE: begin
                    if (job_start) begin
                        x_base_reg      <= x_base;
                        w_base_reg      <= w_base;
                        n_tiles_reg     <= n_tiles;
                        result_addr_reg <= result_addr;
                        tile_idx        <= {CNTW{1'b0}};
                        read_issued     <= 1'b0;
                        read_ready      <= 1'b0;
                        operand_valid   <= 1'b0;
                        job_active_reg  <= 1'b1;
                        state           <= ST_RUN;
                    end
                end

                ST_RUN: begin
                    if (!operand_valid && !read_issued && !read_ready && can_present) begin
                        act_rd_en    <= 1'b1;
                        act_rd_addr  <= tile_idx[TIW-1:0];
                        wgt_rd_en    <= 1'b1;
                        wgt_rd_addr  <= tile_idx[TIW-1:0];
                        read_issued  <= 1'b1;
                    end else if (read_issued) begin
                        read_issued <= 1'b0;
                        read_ready  <= 1'b1;
                    end else if (read_ready) begin
                        operand_valid <= 1'b1;
                        input_data    <= act_rd_data;
                        weight_data   <= wgt_rd_data;
                        tile_last     <= ({{(16-CNTW){1'b0}}, tile_idx} == n_tiles_reg - 16'd1);
                        read_ready    <= 1'b0;
                    end else if (operand_valid && operand_ready) begin
                        operand_valid <= 1'b0;
                        if ({{(16-CNTW){1'b0}}, tile_idx} + 16'd1 == n_tiles_reg) begin
                            job_active_reg <= 1'b0;
                            state <= ST_WAIT_RESULT;
                        end else begin
                            tile_idx <= tile_idx + 1'b1;
                        end
                    end
                end

                ST_WAIT_RESULT: begin
                    result_ready <= 1'b1;
                    if (result_valid && result_ready) begin
                        wr_mem_wdata <= result_addr_reg[0] ? {result_data, 8'h00} : {8'h00, result_data};
                        wr_mem_lb_n  <= result_addr_reg[0] ? 1'b1 : 1'b0;
                        wr_mem_ub_n  <= result_addr_reg[0] ? 1'b0 : 1'b1;
                        state        <= ST_WRITE_RES;
                    end
                end

                ST_WRITE_RES: begin
                    wr_mem_req  <= 1'b1;
                    wr_mem_addr <= result_addr_reg[ADDR_WIDTH-1:1];
                    state       <= ST_DONE;
                end

                ST_DONE: begin
                    wr_mem_req <= 1'b0;
                    if (mem_ready) begin
                        job_done <= 1'b1;
                        state    <= ST_IDLE;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
