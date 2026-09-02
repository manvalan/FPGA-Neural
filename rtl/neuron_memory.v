`timescale 1ns/1ps

module neuron_memory #(
    parameter ADDR_WIDTH = 22,
    parameter DATA_WIDTH = 8,
    parameter N_INPUTS   = 32,
    parameter PARALLEL   = 8,
    parameter ACC_WIDTH  = 32
)(
    input wire clk,
    input wire rst,
    input wire start,

    // ------------------------------------------------------------
    // Memory interface
    //
    // BYTE-ADDRESS / INT8 interface
    // ------------------------------------------------------------

    output wire                   mem_req,
    output wire                   mem_wr,
    output wire [ADDR_WIDTH-1:0]  mem_addr,
    output wire signed [7:0]      mem_wdata,

    input wire signed [7:0]       mem_rdata,
    input wire                    mem_ready,

    // ------------------------------------------------------------
    // Network memory layout
    // ------------------------------------------------------------

    input wire [ADDR_WIDTH-1:0]   x_base,
    input wire [ADDR_WIDTH-1:0]   w_base,
    input wire [ADDR_WIDTH-1:0]   bias_addr,

    // ------------------------------------------------------------
    // Result
    // ------------------------------------------------------------

    output reg signed [7:0]       y,
    output reg                    busy,
    output reg                    done
);

    // ============================================================
    // STATES
    // ============================================================

    localparam STATE_IDLE       = 4'd0;
    localparam STATE_READ_X     = 4'd1;
    localparam STATE_READ_W     = 4'd2;
    localparam STATE_READ_BIAS  = 4'd3;
    localparam STATE_START_N    = 4'd4;
    localparam STATE_WAIT_N     = 4'd5;

    reg [3:0] state;

    reg [$clog2(N_INPUTS+1)-1:0] index;

    // ============================================================
    // LOCAL MEMORY ARRAYS
    // ============================================================

    reg signed [7:0] x_mem [0:N_INPUTS-1];
    reg signed [7:0] w_mem [0:N_INPUTS-1];

    reg signed [7:0] bias_reg;

    // ============================================================
    // NEURON BUS
    // ============================================================

    wire signed [DATA_WIDTH*N_INPUTS-1:0] x_bus;
    wire signed [DATA_WIDTH*N_INPUTS-1:0] w_bus;

    genvar i;

    generate
        for (i = 0; i < N_INPUTS; i = i + 1) begin : GEN_BUS

            assign x_bus[i*DATA_WIDTH +: DATA_WIDTH] = x_mem[i];
            assign w_bus[i*DATA_WIDTH +: DATA_WIDTH] = w_mem[i];

        end
    endgenerate

    // ============================================================
    // INT8 MEMORY ACCESS
    //
    // This converts BYTE addresses into 16-bit word accesses.
    //
    // IMPORTANT:
    // The memory side of this block is connected to the EXTERNAL
    // memory_interface through the neuron_memory ports.
    //
    // It must NOT be connected directly to the PSRAM controller.
    // ============================================================

    reg                   access_req;
    reg                   access_wr;
    reg [ADDR_WIDTH-1:0]  access_addr;
    reg signed [7:0]      access_wdata;

    wire signed [7:0]     access_rdata;
    wire                  access_ready;

    wire                  access_mem_req;
    wire                  access_mem_wr;
    wire [ADDR_WIDTH-1:0] access_mem_addr;
    wire [15:0]           access_mem_wdata;
    wire                   access_mem_lb_n;
    wire                   access_mem_ub_n;

    // ------------------------------------------------------------
    // Return data from the external memory interface.
    //
    // memory_interface returns a 16-bit word, while neuron_memory
    // exposes only the requested INT8 byte.
    //
    // int8_memory_access expects the complete 16-bit word.
    // ------------------------------------------------------------

    wire [15:0] access_mem_rdata;

    assign access_mem_rdata =
        access_addr[0]
            ? {mem_rdata, 8'h00}
            : {8'h00, mem_rdata};

    // ------------------------------------------------------------
    // IMPORTANT:
    //
    // mem_ready comes from the EXTERNAL memory_interface.
    // mem_rdata comes from the EXTERNAL memory_interface.
    //
    // This fixes the previous deadlock where int8_memory_access
    // was waiting for the PSRAM controller's mem_ready directly.
    // ------------------------------------------------------------

    int8_memory_access #(
        .ADDR_WIDTH(ADDR_WIDTH)
    ) u_mem (
        .clk       (clk),
        .rst       (rst),

        .req       (access_req),
        .wr        (access_wr),
        .addr      (access_addr),
        .wdata     (access_wdata),

        .rdata     (access_rdata),
        .ready     (access_ready),

        .mem_req   (access_mem_req),
        .mem_wr    (access_mem_wr),
        .mem_addr  (access_mem_addr),
        .mem_wdata (access_mem_wdata),
        .mem_lb_n  (access_mem_lb_n),
        .mem_ub_n  (access_mem_ub_n),

        .mem_rdata (access_mem_rdata),
        .mem_ready (mem_ready)
    );

    // ============================================================
    // EXTERNAL MEMORY INTERFACE
    //
    // The external interface expects the INT8-level signals.
    // The testbench converts these into its 16-bit bus.
    //
    // IMPORTANT:
    // access_mem_addr is already a WORD address.
    // However, the external neuron_memory interface is defined
    // as a BYTE address.
    //
    // Therefore expose the original byte address here.
    // ============================================================

    assign mem_req   = access_mem_req;
    assign mem_wr    = access_mem_wr;

    assign mem_addr =
        access_addr;

    assign mem_wdata =
        access_wdata;

    // ============================================================
    // NEURON
    // ============================================================

    reg neuron_start;

    wire signed [7:0] neuron_y;
    wire              neuron_busy;
    wire              neuron_done;

    neuron_parallel #(
        .DATA_WIDTH(DATA_WIDTH),
        .N_INPUTS(N_INPUTS),
        .PARALLEL(PARALLEL),
        .ACC_WIDTH(ACC_WIDTH)
    ) u_neuron (
        .clk(clk),
        .rst(rst),
        .start(neuron_start),

        .x_bus(x_bus),
        .w_bus(w_bus),
        .bias(bias_reg),

        .y(neuron_y),
        .busy(neuron_busy),
        .done(neuron_done)
    );

    // ============================================================
    // CONTROLLER
    // ============================================================

    always @(posedge clk) begin

        if (rst) begin

            state <= STATE_IDLE;
            index <= 0;

            bias_reg <= 0;

            access_req   <= 1'b0;
            access_wr    <= 1'b0;
            access_addr  <= 0;
            access_wdata <= 0;

            neuron_start <= 1'b0;

            y    <= 0;
            busy <= 1'b0;
            done <= 1'b0;

        end else begin

            // ----------------------------------------------------
            // Default pulse signals
            // ----------------------------------------------------

            access_req   <= 1'b0;
            neuron_start <= 1'b0;
            done         <= 1'b0;

            case (state)

                // =================================================
                // IDLE
                // =================================================

                STATE_IDLE: begin

                    busy <= 1'b0;

                    if (start) begin

                        busy  <= 1'b1;
                        index <= 0;

                        // First X byte
                        access_addr <= x_base;
                        access_wr   <= 1'b0;
                        access_req  <= 1'b1;

                        state <= STATE_READ_X;

                    end

                end

                // =================================================
                // READ X
                // =================================================

                STATE_READ_X: begin

                    if (access_ready) begin

                        x_mem[index] <= access_rdata;

                        if (index == N_INPUTS-1) begin

                            index <= 0;

                            access_addr <= w_base;
                            access_wr   <= 1'b0;
                            access_req  <= 1'b1;

                            state <= STATE_READ_W;

                        end else begin

                            index <= index + 1'b1;

                            access_addr <= x_base + index + 1'b1;
                            access_req  <= 1'b1;

                        end

                    end

                end

                // =================================================
                // READ W
                // =================================================

                STATE_READ_W: begin

                    if (access_ready) begin

                        w_mem[index] <= access_rdata;

                        if (index == N_INPUTS-1) begin

                            access_addr <= bias_addr;
                            access_wr   <= 1'b0;
                            access_req  <= 1'b1;

                            state <= STATE_READ_BIAS;

                        end else begin

                            index <= index + 1'b1;

                            access_addr <= w_base + index + 1'b1;
                            access_req  <= 1'b1;

                        end

                    end

                end

                // =================================================
                // READ BIAS
                // =================================================

                STATE_READ_BIAS: begin

                    if (access_ready) begin

                        bias_reg <= access_rdata;

                        state <= STATE_START_N;

                    end

                end

                // =================================================
                // START NEURON
                // =================================================

                STATE_START_N: begin

                    neuron_start <= 1'b1;

                    state <= STATE_WAIT_N;

                end

                // =================================================
                // WAIT NEURON
                // =================================================

                STATE_WAIT_N: begin

                    if (neuron_done) begin

                        y    <= neuron_y;
                        busy <= 1'b0;
                        done <= 1'b1;

                        state <= STATE_IDLE;

                    end

                end

                // =================================================
                // DEFAULT
                // =================================================

                default: begin

                    state <= STATE_IDLE;
                    busy  <= 1'b0;

                end

            endcase

        end

    end

endmodule