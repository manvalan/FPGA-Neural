`timescale 1ns/1ps

// ================================================================
// LAYER_SEQUENCER (Phase 5 - Multi-Layer Network)
//
// Chains up to N_LAYERS runs of a single, reused neuron_memory
// instance to execute a feedforward network of N_LAYERS dense
// layers, without touching neuron_memory.v or the validated compute
// core (neuron_parallel/mac8/mac_unit) at all.
//
// KEY DESIGN CHOICE: neuron_memory's N_INPUTS and N_NEURONS are both
// fixed at synthesis to the SAME value (this module's N_WIDTH
// parameter, e.g. 256). A logical layer with fewer real inputs or
// neurons than N_WIDTH is handled entirely by DATA convention, not
// RTL: the host zero-pads that layer's weight matrix beyond its
// real input count (so the extra MAC lanes contribute 0 regardless
// of input value) and its bias beyond its real neuron count. This
// sequencer then always reads/writes the FULL N_WIDTH-byte buffer
// for every layer transition -- it does not need to know any
// layer's "real" input/neuron count at all. Trade-off: a layer with
// few real inputs still takes as long as a full N_WIDTH-wide layer
// (wasted MAC cycles on zero-weighted padding); documented as a
// known Phase 7 (Optimization) follow-up, not solved here.
//
// Layer descriptor table (host-written via WRITE_RAM, read-only to
// this module): N_LAYERS entries of 11 bytes each, MSB-first,
// starting at `table_base`:
//   w_base(3B), bias_addr(3B), activation(1B, low 2 bits --
//   see rtl/neuron_parallel.v's ACT_* localparams),
//   n_inputs_real(2B), n_neurons_real(2B)
// Layer 0's input is the external `x_base` (same register used for
// single-layer/manual mode). Layer k>0's input is the ping-pong
// output buffer (`buf_a_base`/`buf_b_base`) written by layer k-1.
// The final layer's output is left both in neuron_memory's own
// y_bus (readable via the existing READ_OUTPUT opcode, unchanged)
// and in the ping-pong buffer it was copied to.
//
// n_inputs_real/n_neurons_real let ONE synthesized bitstream (fixed
// N_WIDTH = neuron_memory's build-time max) serve any real network
// topology up to that width: forwarded to neuron_memory verbatim
// (see rtl/neuron_memory.v), and this sequencer copies exactly
// n_neurons_real bytes of y_bus into the ping-pong buffer -- NOT the
// full N_WIDTH -- so a narrower layer both computes AND is copied
// out faster, no zero-padding required in RAM.
// ================================================================

module layer_sequencer #(
    parameter ADDR_WIDTH = 22,
    parameter DATA_WIDTH = 8,
    parameter N_WIDTH    = 256,   // = neuron_memory's N_INPUTS = N_NEURONS
    parameter N_LAYERS   = 4
)(
    input wire clk,
    input wire rst,

    // ------------------------------------------------------------
    // Trigger (from spi_engine's RUN_NETWORK opcode)
    // ------------------------------------------------------------

    input  wire       run_start,       // one-cycle pulse
    input  wire [7:0] run_num_layers,  // 1..N_LAYERS

    output reg seq_busy,
    output reg seq_done,               // one-cycle pulse, mirrors neuron_memory.done

    // ------------------------------------------------------------
    // Config registers (from spi_engine's SET_BASE)
    // ------------------------------------------------------------

    input wire [ADDR_WIDTH-1:0] x_base,       // layer 0's external input
    input wire [ADDR_WIDTH-1:0] table_base,
    input wire [ADDR_WIDTH-1:0] buf_a_base,
    input wire [ADDR_WIDTH-1:0] buf_b_base,

    // ------------------------------------------------------------
    // neuron_memory control (sequencer-owned; only meaningful while
    // seq_busy -- the top level muxes these against spi_engine's
    // own direct-drive outputs based on seq_busy)
    // ------------------------------------------------------------

    output reg [ADDR_WIDTH-1:0] nm_x_base,
    output reg [ADDR_WIDTH-1:0] nm_w_base,
    output reg [ADDR_WIDTH-1:0] nm_bias_addr,
    output reg [1:0]            nm_activation,
    output reg [15:0]           nm_n_inputs,
    output reg [15:0]           nm_n_neurons,
    output reg                  nm_start,

    input wire nm_busy,
    input wire nm_done,   // one-cycle pulse

    input wire signed [DATA_WIDTH*N_WIDTH-1:0] y_bus,

    // ------------------------------------------------------------
    // Byte-level RAM master port (own arbiter port)
    // ------------------------------------------------------------

    output reg                   ram_req,
    output reg                   ram_wr,
    output reg  [ADDR_WIDTH-1:0] ram_addr,
    output reg  signed [7:0]     ram_wdata,

    input wire signed [7:0]      ram_rdata,
    input wire                   ram_ready
);

    // ============================================================
    // STATES
    // ============================================================

    localparam ST_IDLE        = 4'd0;
    localparam ST_READ_DESC   = 4'd1;
    localparam ST_READ_WAIT   = 4'd2;
    localparam ST_START_LAYER = 4'd3;
    localparam ST_WAIT_LAYER  = 4'd4;
    localparam ST_COPY_ISSUE  = 4'd5;
    localparam ST_COPY_WAIT   = 4'd6;

    reg [3:0] state;

    reg [7:0] layer_idx;
    reg [7:0] num_layers_reg;

    reg [ADDR_WIDTH-1:0] desc_table_addr;
    reg [3:0]  desc_byte_idx;   // 0..10
    reg [23:0] w_base_acc;
    reg [23:0] bias_addr_acc;
    reg [7:0]  activation_acc;
    reg [15:0] n_inputs_acc;
    reg [15:0] n_neurons_acc;

    reg cur_sel;    // which ping-pong buffer to READ from for this layer (layer_idx>0)
    reg write_sel;  // which ping-pong buffer to WRITE this layer's output to

    reg [$clog2(N_WIDTH+1)-1:0] copy_idx;

    always @(posedge clk) begin

        if (rst) begin

            state           <= ST_IDLE;
            layer_idx       <= 8'd0;
            num_layers_reg  <= 8'd0;
            desc_table_addr <= {ADDR_WIDTH{1'b0}};
            desc_byte_idx   <= 4'd0;
            w_base_acc      <= 24'h0;
            bias_addr_acc   <= 24'h0;
            activation_acc  <= 8'h0;
            n_inputs_acc    <= 16'h0;
            n_neurons_acc   <= 16'h0;
            cur_sel         <= 1'b0;
            write_sel       <= 1'b0;
            copy_idx        <= 0;

            nm_x_base     <= {ADDR_WIDTH{1'b0}};
            nm_w_base     <= {ADDR_WIDTH{1'b0}};
            nm_bias_addr  <= {ADDR_WIDTH{1'b0}};
            nm_activation <= 2'd1; // ACT_RELU
            nm_n_inputs   <= 16'h0;
            nm_n_neurons  <= 16'h0;
            nm_start      <= 1'b0;

            ram_req   <= 1'b0;
            ram_wr    <= 1'b0;
            ram_addr  <= {ADDR_WIDTH{1'b0}};
            ram_wdata <= 8'sd0;

            seq_busy <= 1'b0;
            seq_done <= 1'b0;

        end else begin

            // --------------------------------------------------
            // Default pulses
            // --------------------------------------------------
            nm_start <= 1'b0;
            ram_req  <= 1'b0;
            seq_done <= 1'b0;

            case (state)

                // =================================================
                // IDLE
                // =================================================

                ST_IDLE: begin

                    if (run_start) begin

                        seq_busy        <= 1'b1;
                        layer_idx       <= 8'd0;
                        num_layers_reg  <= run_num_layers;
                        desc_table_addr <= table_base;
                        desc_byte_idx   <= 4'd0;
                        write_sel       <= 1'b0;

                        state <= ST_READ_DESC;

                    end

                end

                // =================================================
                // READ DESCRIPTOR (6 bytes: w_base, bias_addr)
                // =================================================

                ST_READ_DESC: begin

                    ram_req  <= 1'b1;
                    ram_wr   <= 1'b0;
                    ram_addr <= desc_table_addr + desc_byte_idx;

                    state <= ST_READ_WAIT;

                end

                ST_READ_WAIT: begin

                    if (ram_ready) begin

                        case (desc_byte_idx)
                            4'd0:  w_base_acc[23:16]    <= ram_rdata;
                            4'd1:  w_base_acc[15:8]     <= ram_rdata;
                            4'd2:  w_base_acc[7:0]      <= ram_rdata;
                            4'd3:  bias_addr_acc[23:16] <= ram_rdata;
                            4'd4:  bias_addr_acc[15:8]  <= ram_rdata;
                            4'd5:  bias_addr_acc[7:0]   <= ram_rdata;
                            4'd6:  activation_acc       <= ram_rdata;
                            4'd7:  n_inputs_acc[15:8]   <= ram_rdata;
                            4'd8:  n_inputs_acc[7:0]    <= ram_rdata;
                            4'd9:  n_neurons_acc[15:8]  <= ram_rdata;
                            4'd10: n_neurons_acc[7:0]   <= ram_rdata;
                        endcase

                        if (desc_byte_idx == 4'd10) begin
                            desc_byte_idx <= 4'd0;
                            state         <= ST_START_LAYER;
                        end else begin
                            desc_byte_idx <= desc_byte_idx + 4'd1;
                            state         <= ST_READ_DESC;
                        end

                    end

                end

                // =================================================
                // START LAYER
                // =================================================

                ST_START_LAYER: begin

                    nm_w_base     <= w_base_acc[ADDR_WIDTH-1:0];
                    nm_bias_addr  <= bias_addr_acc[ADDR_WIDTH-1:0];
                    nm_activation <= activation_acc[1:0];
                    nm_n_inputs   <= n_inputs_acc;
                    nm_n_neurons  <= n_neurons_acc;

                    nm_x_base <= (layer_idx == 8'd0)
                        ? x_base
                        : (cur_sel ? buf_b_base : buf_a_base);

                    nm_start <= 1'b1;

                    state <= ST_WAIT_LAYER;

                end

                // =================================================
                // WAIT FOR THIS LAYER TO FINISH
                // =================================================

                ST_WAIT_LAYER: begin

                    if (nm_done) begin
                        copy_idx <= 0;
                        state    <= ST_COPY_ISSUE;
                    end

                end

                // =================================================
                // COPY y_bus INTO THE PING-PONG OUTPUT BUFFER
                // =================================================

                ST_COPY_ISSUE: begin

                    ram_req   <= 1'b1;
                    ram_wr    <= 1'b1;
                    ram_addr  <= (write_sel ? buf_b_base : buf_a_base) + copy_idx;
                    ram_wdata <= y_bus[copy_idx*DATA_WIDTH +: DATA_WIDTH];

                    state <= ST_COPY_WAIT;

                end

                ST_COPY_WAIT: begin

                    if (ram_ready) begin

                        if (copy_idx == n_neurons_acc[$clog2(N_WIDTH+1)-1:0] - 1'b1) begin

                            if (layer_idx == num_layers_reg - 8'd1) begin

                                // Last layer done.
                                seq_busy <= 1'b0;
                                seq_done <= 1'b1;
                                state    <= ST_IDLE;

                            end else begin

                                // The buffer just written becomes
                                // the next layer's input.
                                cur_sel         <= write_sel;
                                write_sel       <= ~write_sel;
                                layer_idx       <= layer_idx + 8'd1;
                                desc_table_addr <= desc_table_addr + 22'd11;
                                desc_byte_idx   <= 4'd0;

                                state <= ST_READ_DESC;

                            end

                        end else begin

                            copy_idx <= copy_idx + 1'b1;
                            state    <= ST_COPY_ISSUE;

                        end

                    end

                end

                default: begin
                    state <= ST_IDLE;
                end

            endcase

        end

    end

endmodule
