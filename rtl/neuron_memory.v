`timescale 1ns/1ps

module neuron_memory #(
    parameter ADDR_WIDTH = 23,
    parameter DATA_WIDTH = 8,
    parameter N_INPUTS   = 32,
    parameter N_NEURONS  = 1,
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

    // Activation function for this run, forwarded to neuron_parallel
    // (see rtl/neuron_parallel.v's ACT_* localparams). Defaults to
    // ACT_RELU (2'd1), neuron_parallel's own default, so any caller
    // that leaves this unconnected is unaffected.
    input wire [1:0]              activation = 2'd1,

    // Real (runtime) width for THIS run: how many of the N_INPUTS/
    // N_NEURONS this instance was BUILT for are actually real for
    // the network currently loaded. Lets one synthesized bitstream
    // serve any network topology up to its build-time max width --
    // X/W are read from RAM for n_inputs_real elements per neuron
    // (not N_INPUTS), and only n_neurons_real neurons are computed
    // (not N_NEURONS); n_inputs_real must be a multiple of PARALLEL
    // (the caller's responsibility -- same constraint N_INPUTS
    // itself is held to at elaboration time, see
    // rtl/neuron_parallel.v's PARAMETER GUARD). Defaults to the
    // full build-time width, so any caller that leaves these
    // unconnected is completely unaffected.
    input wire [15:0]             n_inputs_real  = N_INPUTS[15:0],
    input wire [15:0]             n_neurons_real = N_NEURONS[15:0],

    // ------------------------------------------------------------
    // Result
    //
    // One INT8 output per neuron, packed neuron-major (same
    // convention as layer.v's y_bus): neuron n occupies
    // y_bus[n*DATA_WIDTH +: DATA_WIDTH].
    // ------------------------------------------------------------

    output wire signed [DATA_WIDTH*N_NEURONS-1:0] y_bus,
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
    // NEURON LOOP (Phase 3: multi-neuron memory integration)
    //
    // X is shared and read once per layer invocation. W and bias
    // are re-read from memory for each neuron in turn and fed to a
    // single, reused neuron_parallel instance (memory-bound design:
    // one neuron computed at a time). w_group_base/bias_group_addr
    // track the current neuron's base address and are advanced by
    // N_INPUTS / 1 byte respectively between neurons, following the
    // same neuron-major layout as layer.v's weights_bus/bias_bus.
    // ============================================================

    localparam NEURON_INDEX_WIDTH =
        (N_NEURONS <= 1) ? 1 : $clog2(N_NEURONS);

    reg [NEURON_INDEX_WIDTH-1:0] neuron_index;

    reg [ADDR_WIDTH-1:0] w_group_base;
    reg [ADDR_WIDTH-1:0] bias_group_addr;

    reg signed [7:0] y_reg [0:N_NEURONS-1];

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

    genvar j;

    generate
        for (j = 0; j < N_NEURONS; j = j + 1) begin : GEN_Y_BUS

            assign y_bus[j*DATA_WIDTH +: DATA_WIDTH] = y_reg[j];

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

    integer rst_i;

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
        .activation(activation),
        .n_inputs_real(n_inputs_real),

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

            neuron_index    <= 0;
            w_group_base    <= 0;
            bias_group_addr <= 0;

            bias_reg <= 0;

            access_req   <= 1'b0;
            access_wr    <= 1'b0;
            access_addr  <= 0;
            access_wdata <= 0;

            neuron_start <= 1'b0;

            for (rst_i = 0; rst_i < N_NEURONS; rst_i = rst_i + 1)
                y_reg[rst_i] <= 0;

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

                        neuron_index    <= 0;
                        w_group_base    <= w_base;
                        bias_group_addr <= bias_addr;

                        // First X byte. (BUG-004 fix, docs/validation/
                        // bugs.md: STATE_READ_X/STATE_READ_W's own
                        // termination checks are patched below to
                        // treat n_inputs_real==0 as "done after this
                        // one byte" instead of wrapping -- see those
                        // states for the full rationale. One harmless
                        // extra byte is still read here for n_inputs_
                        // real==0 before the fixed check short-
                        // circuits; x_base/w_group_base are always
                        // valid addresses, so this costs one cycle,
                        // not correctness.)
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

                        // BUG-004 fix (docs/validation/bugs.md):
                        // `n_inputs_real[...]-1'b1` wraps for
                        // n_inputs_real==0 to a value `index` (sized
                        // to the SAME width) could reach by counting
                        // up from 0, reading well past the intended
                        // (empty) real region. Explicit `==0` check
                        // terminates after this one already-issued
                        // byte instead.
                        if (n_inputs_real == 16'h0 ||
                            index == n_inputs_real[$clog2(N_INPUTS+1)-1:0]-1'b1) begin

                            index <= 0;

                            // BUG-004 fix (docs/validation/bugs.md):
                            // n_neurons_real==0 means there is no
                            // neuron 0 to compute at all -- the
                            // original code always ran at least one
                            // full neuron (W/bias read + a real
                            // neuron_parallel invocation) before its
                            // own termination check could even be
                            // reached, and that check
                            // (`neuron_index == n_neurons_real-1`)
                            // had the same unguarded-wraparound issue
                            // as the other BUG-00x cases besides.
                            // Report done immediately, y_reg/y_bus
                            // left untouched (nothing was asked to be
                            // computed), instead of entering the
                            // neuron loop at all.
                            if (n_neurons_real == 16'h0) begin

                                busy <= 1'b0;
                                done <= 1'b1;
                                state <= STATE_IDLE;

                            end else begin

                                access_addr <= w_group_base;
                                access_wr   <= 1'b0;
                                access_req  <= 1'b1;

                                state <= STATE_READ_W;

                            end

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

                        // BUG-004 fix (docs/validation/bugs.md): same
                        // wraparound issue and same fix as
                        // STATE_READ_X above -- this state is
                        // re-entered once per neuron (the per-neuron
                        // loop-back), so the guard matters on every
                        // iteration, not just the first.
                        if (n_inputs_real == 16'h0 ||
                            index == n_inputs_real[$clog2(N_INPUTS+1)-1:0]-1'b1) begin

                            access_addr <= bias_group_addr;
                            access_wr   <= 1'b0;
                            access_req  <= 1'b1;

                            state <= STATE_READ_BIAS;

                        end else begin

                            index <= index + 1'b1;

                            access_addr <= w_group_base + index + 1'b1;
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

                        y_reg[neuron_index] <= neuron_y;

                        if (neuron_index == n_neurons_real[NEURON_INDEX_WIDTH-1:0]-1'b1) begin

                            // Last neuron of the layer: done.
                            busy <= 1'b0;
                            done <= 1'b1;

                            state <= STATE_IDLE;

                        end else begin

                            // Advance to the next neuron: X stays
                            // in x_mem (shared), reload W and bias
                            // for neuron_index+1 from memory.
                            neuron_index    <= neuron_index + 1'b1;
                            w_group_base    <= w_group_base + n_inputs_real;
                            bias_group_addr <= bias_group_addr + 1'b1;

                            index <= 0;

                            access_addr <= w_group_base + n_inputs_real;
                            access_wr   <= 1'b0;
                            access_req  <= 1'b1;

                            state <= STATE_READ_W;

                        end

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