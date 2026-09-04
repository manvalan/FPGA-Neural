`timescale 1ns/1ps

// ================================================================
// GRAPH_ENGINE (Phase G3 -- Type #2 sparse-graph network)
//
// Orchestrates an arbitrary feed-forward DAG of neurons on top of
// the validated neuron_parallel core, exactly the way neuron_memory
// / layer_sequencer orchestrate the dense Type #1 path -- the
// compute datapath itself (neuron_parallel/mac8/mac_unit) is
// instantiated unmodified, never edited. See docs spec §2-§7 for
// the full design rationale; this header only covers what a reader
// of THIS file needs.
//
// REGISTER REUSE (no new SET_BASE selectors beyond sel 9/10):
// dense (#1) and graph (#2) modes are mutually exclusive at runtime
// (net_type dispatch, see spi_engine.v), so this module reuses three
// existing SET_BASE-driven registers for a different purpose while
// in graph mode -- documented here since it is not spelled out
// verbatim in the data-format spec:
//   x_base         -> base address of the N_in input bytes in PSRAM
//                      (same register/opcode host already uses to
//                      preload inputs for dense mode)
//   table_base     -> base of the graph descriptor table (§4.2),
//                      instead of the dense layer descriptor table
//   buf_a_base     -> out_base: where the n_out output bytes are
//                      copied to in PSRAM at the end of the run
//                      (dense mode's ping-pong buffer A is unused
//                      while graph mode runs, so no conflict)
//   n_inputs_real  -> N_in: number of graph input ids (0..N_in-1),
//                      instead of a dense layer's real input count
//
// OUTPUT COPY, FOLDED INTO THE MAIN LOOP: §6 describes a WRITE_OUTPUTS
// state as a separate pass after all neurons are computed. Since the
// spec's own out_id ordering guarantee (§4.4: "out_ids ... finiscono
// naturalmente con gli id piu alti") makes the output set EXACTLY
// the last n_out entries of the descriptor table, this engine copies
// a neuron's result to out_base the moment it computes it, if that
// neuron is one of the last n_out (WRITE_ACT / WRITE_OUT below) --
// no second pass over act_buf or extra id bookkeeping needed.
//
// GUARD (§7): a load-time check that src_id < out_id and
// src_id < N_TOTAL is done per-edge, right as each edge's src_id is
// read. On violation, `err` is raised (sticky until `rst`) and the
// run stops immediately -- no further memory traffic, no result
// written -- instead of silently computing a wrong answer. This
// module ALSO checks out_id < N_TOTAL and n_conn_padded (post-
// PARALLEL-padding) <= MAX_CONN for the same reason (out-of-range
// addressing / MAX_CONN overflow are just as unsafe as the two
// checks the spec calls out by name, and "stop instead of silently
// misbehaving" is the whole point of this section) -- an addition
// beyond the literal spec text, noted here for anyone diffing
// against it.
//
// PARALLEL-multiple padding (§2.6) is entirely a HOST/assembler
// responsibility: the edge blocks in PSRAM already physically
// contain the zero-weight padding edges tools/netasm inserts, so
// this engine just reads n_conn_padded = ceil(n_conn/PARALLEL)*
// PARALLEL physical edges per neuron -- no special-casing here, and
// neuron_parallel's own n_inputs_real convention (must already be a
// PARALLEL multiple) is satisfied by construction. A neuron with 0
// real connections still needs padding to a full PARALLEL group from
// the host: n_conn_padded==0 is treated as a load-time error (see
// guard above) rather than being forwarded to neuron_parallel, which
// would hang on it (documented hang mode of neuron_parallel/GROUPS=0,
// see rtl/neuron_parallel.v).
//
// ACTIVATION BUFFER GATHER TIMING: act_buffer's read port is
// registered (1-cycle latency, see rtl/act_buffer.v). This engine
// drives act_buf's read address directly (combinationally) from the
// edge's src_id as soon as it is known (after the edge's 2nd byte),
// and only consumes rd_data one FULL state later (ST_GATHER), by
// which point at least two more PSRAM byte round-trips (weight +
// reserved bytes of the same edge) have elapsed -- comfortably more
// than the 1 cycle act_buffer needs, on any realistic memory. See
// the ST_EDGE_WAIT / ST_GATHER case comments below.
// ================================================================

module graph_engine #(
    parameter ADDR_WIDTH = 23,
    parameter DATA_WIDTH = 8,
    parameter ACC_WIDTH  = 32,
    parameter PARALLEL   = 8,
    parameter MAX_CONN   = 32,    // build-time max real+padding connections per neuron (must be a PARALLEL multiple -- enforced by neuron_parallel's own elaboration-time guard)
    parameter N_TOTAL    = 4096   // activation buffer depth / signal id space ceiling (§2)
)(
    input wire clk,
    input wire rst,

    // ------------------------------------------------------------
    // Trigger / status (from spi_engine's RUN_NETWORK dispatch when
    // net_type == graph)
    // ------------------------------------------------------------

    input  wire run_start,   // one-cycle pulse
    output reg  busy,
    output reg  done,        // one-cycle pulse
    output reg  err,         // sticky guard-violation flag (§7), cleared on rst or the next run_start

    // ------------------------------------------------------------
    // Config registers (see REGISTER REUSE note above for x_base /
    // table_base / buf_a_base / n_inputs_real)
    // ------------------------------------------------------------

    input wire [ADDR_WIDTH-1:0] x_base,
    input wire [ADDR_WIDTH-1:0] table_base,
    input wire [ADDR_WIDTH-1:0] out_base,
    input wire [15:0]           n_inputs_graph,    // N_in
    input wire [15:0]           num_neurons_graph, // SET_BASE sel 9
    input wire [15:0]           n_out,             // SET_BASE sel 10

    // ------------------------------------------------------------
    // Byte-level RAM master port (own arbiter port; shared with
    // layer_sequencer's at the top level -- the two run modes are
    // mutually exclusive, see rtl/spi_neuron_top.v)
    // ------------------------------------------------------------

    output reg                   ram_req,
    output reg                   ram_wr,
    output reg  [ADDR_WIDTH-1:0] ram_addr,
    output reg  signed [7:0]     ram_wdata,

    input wire signed [7:0]      ram_rdata,
    input wire                   ram_ready
);

    // ============================================================
    // DERIVED WIDTHS
    // ============================================================

    localparam BUF_ADDR_WIDTH = $clog2(N_TOTAL);
    localparam CONN_IDX_WIDTH = (MAX_CONN <= 1) ? 1 : $clog2(MAX_CONN + 1);
    localparam PAR_SHIFT      = $clog2(PARALLEL);

    // ============================================================
    // STATES / FSM REGISTERS
    //
    // Declared before the submodule instantiations below because
    // act_buffer's read address is wired directly (combinationally)
    // to src_id_acc.
    // ============================================================

    localparam ST_IDLE           = 4'd0;
    localparam ST_COPY_IN_RD     = 4'd1;
    localparam ST_COPY_IN_WAIT   = 4'd2;
    localparam ST_DESC_RD        = 4'd3;
    localparam ST_DESC_WAIT      = 4'd4;
    localparam ST_EDGE_RD        = 4'd5;
    localparam ST_EDGE_WAIT      = 4'd6;
    localparam ST_GATHER         = 4'd7;
    localparam ST_START_N        = 4'd8;
    localparam ST_WAIT_N         = 4'd9;
    localparam ST_WRITE_OUT_ISS  = 4'd10;
    localparam ST_WRITE_OUT_WAIT = 4'd11;
    localparam ST_ERROR          = 4'd12;

    reg [3:0] state;

    reg [15:0] in_idx;
    reg [15:0] neuron_idx;

    reg [ADDR_WIDTH-1:0] desc_addr;
    reg [3:0]  desc_byte_idx;
    reg [23:0] conn_ptr_acc;
    reg [15:0] n_conn_acc;
    reg [15:0] out_id_acc;

    reg [CONN_IDX_WIDTH-1:0] conn_i;
    reg [1:0]  edge_byte_idx;
    reg [15:0] src_id_acc;
    reg [7:0]  weight_acc;

    // Last n_out descriptor-table entries are the output sinks (§4.4):
    // entries are in ascending out_id order, so this is a static
    // range check on neuron_idx, no separate id lookup needed.
    wire [15:0] out_threshold = num_neurons_graph - n_out;
    wire        is_output_sink = (neuron_idx >= out_threshold);
    wire [15:0] out_offset     = neuron_idx - out_threshold;

    // ============================================================
    // ACTIVATION BUFFER (private to this engine -- dense mode does
    // not use it at all)
    // ============================================================

    reg                          act_wr_en;
    reg  [BUF_ADDR_WIDTH-1:0]    act_wr_addr;
    reg  signed [DATA_WIDTH-1:0] act_wr_data;

    wire signed [DATA_WIDTH-1:0] act_rd_data;

    act_buffer #(
        .N_TOTAL(N_TOTAL),
        .DATA_WIDTH(DATA_WIDTH)
    ) u_act_buffer (
        .clk(clk),
        .wr_en(act_wr_en), .wr_addr(act_wr_addr), .wr_data(act_wr_data),
        .rd_addr(src_id_acc[BUF_ADDR_WIDTH-1:0]), .rd_data(act_rd_data)
    );

    // ============================================================
    // NEURON (private instance, reused across every graph neuron --
    // same "one neuron computed at a time, memory-bound" design as
    // neuron_memory.v)
    // ============================================================

    reg  signed [DATA_WIDTH-1:0] x_mem [0:MAX_CONN-1];
    reg  signed [DATA_WIDTH-1:0] w_mem [0:MAX_CONN-1];

    wire signed [DATA_WIDTH*MAX_CONN-1:0] x_bus;
    wire signed [DATA_WIDTH*MAX_CONN-1:0] w_bus;

    genvar gi;
    generate
        for (gi = 0; gi < MAX_CONN; gi = gi + 1) begin : GEN_BUS
            assign x_bus[gi*DATA_WIDTH +: DATA_WIDTH] = x_mem[gi];
            assign w_bus[gi*DATA_WIDTH +: DATA_WIDTH] = w_mem[gi];
        end
    endgenerate

    reg               neuron_start;
    reg  signed [7:0] bias_reg;
    reg  [1:0]        activation_reg;
    reg  [15:0]       n_conn_padded_reg;

    wire signed [7:0] neuron_y;
    wire              neuron_busy;
    wire              neuron_done;

    neuron_parallel #(
        .DATA_WIDTH(DATA_WIDTH),
        .N_INPUTS(MAX_CONN),
        .PARALLEL(PARALLEL),
        .ACC_WIDTH(ACC_WIDTH)
    ) u_neuron (
        .clk(clk), .rst(rst), .start(neuron_start),
        .x_bus(x_bus), .w_bus(w_bus), .bias(bias_reg),
        .activation(activation_reg),
        .n_inputs_real(n_conn_padded_reg),
        .y(neuron_y), .busy(neuron_busy), .done(neuron_done)
    );

    // ============================================================
    // MAIN FSM
    // ============================================================

    integer ri;

    always @(posedge clk) begin

        if (rst) begin

            state       <= ST_IDLE;
            busy        <= 1'b0;
            done        <= 1'b0;
            err         <= 1'b0;

            in_idx      <= 16'h0;
            neuron_idx  <= 16'h0;

            desc_addr     <= {ADDR_WIDTH{1'b0}};
            desc_byte_idx <= 4'h0;
            conn_ptr_acc  <= 24'h0;
            n_conn_acc    <= 16'h0;
            out_id_acc    <= 16'h0;
            n_conn_padded_reg <= 16'h0;

            conn_i        <= {CONN_IDX_WIDTH{1'b0}};
            edge_byte_idx <= 2'h0;
            src_id_acc    <= 16'h0;
            weight_acc    <= 8'h0;

            bias_reg       <= 8'sd0;
            activation_reg <= 2'd1;

            act_wr_en   <= 1'b0;
            act_wr_addr <= {BUF_ADDR_WIDTH{1'b0}};
            act_wr_data <= 8'sd0;

            neuron_start <= 1'b0;

            ram_req   <= 1'b0;
            ram_wr    <= 1'b0;
            ram_addr  <= {ADDR_WIDTH{1'b0}};
            ram_wdata <= 8'sd0;

            for (ri = 0; ri < MAX_CONN; ri = ri + 1) begin
                x_mem[ri] <= 8'sd0;
                w_mem[ri] <= 8'sd0;
            end

        end else begin

            // --------------------------------------------------
            // Default pulses
            // --------------------------------------------------
            ram_req      <= 1'b0;
            act_wr_en    <= 1'b0;
            neuron_start <= 1'b0;
            done         <= 1'b0;

            case (state)

                // =============================================
                // IDLE / ERROR: both accept run_start identically.
                // A fresh run_start clears a stale `err` and gives
                // the engine another attempt.
                // =============================================

                ST_IDLE, ST_ERROR: begin

                    if (run_start) begin

                        busy       <= 1'b1;
                        err        <= 1'b0;
                        in_idx     <= 16'h0;
                        neuron_idx <= 16'h0;
                        desc_addr  <= table_base;

                        state <= ST_COPY_IN_RD;

                    end

                end

                // =============================================
                // COPY_INPUTS: act_buf[0..N_in-1] <- PSRAM[x_base..]
                // =============================================

                ST_COPY_IN_RD: begin

                    ram_req  <= 1'b1;
                    ram_wr   <= 1'b0;
                    ram_addr <= x_base + in_idx;

                    state <= ST_COPY_IN_WAIT;

                end

                ST_COPY_IN_WAIT: begin

                    if (ram_ready) begin

                        act_wr_en   <= 1'b1;
                        act_wr_addr <= in_idx[BUF_ADDR_WIDTH-1:0];
                        act_wr_data <= ram_rdata;

                        if (in_idx == n_inputs_graph - 16'd1) begin

                            // BUG-006 fix (docs/validation/bugs.md):
                            // num_neurons_graph==0 has no neuron to
                            // process at all -- the original code
                            // always computed at least "neuron 0"
                            // before its own termination check
                            // (`neuron_idx == num_neurons_graph-1`,
                            // further down) could even run, and that
                            // check had the same unguarded-wraparound
                            // structure as BUG-002/003/004/005. Report
                            // done immediately instead of entering the
                            // descriptor-read loop (real-edge-guard
                            // protection incidentally limited the
                            // practical damage here, per
                            // docs/validation/06-graph-engine.md, but
                            // the structural gap is closed properly
                            // now rather than left to that
                            // side-effect).
                            if (num_neurons_graph == 16'h0) begin
                                busy  <= 1'b0;
                                done  <= 1'b1;
                                state <= ST_IDLE;
                            end else begin
                                desc_byte_idx <= 4'h0;
                                state         <= ST_DESC_RD;
                            end

                        end else begin
                            in_idx <= in_idx + 16'd1;
                            state  <= ST_COPY_IN_RD;
                        end

                    end

                end

                // =============================================
                // READ_DESC: 11-byte graph descriptor (§4.2)
                // =============================================

                ST_DESC_RD: begin

                    ram_req  <= 1'b1;
                    ram_wr   <= 1'b0;
                    ram_addr <= desc_addr + desc_byte_idx;

                    state <= ST_DESC_WAIT;

                end

                ST_DESC_WAIT: begin

                    if (ram_ready) begin

                        case (desc_byte_idx)
                            4'd0:  conn_ptr_acc[23:16] <= ram_rdata;
                            4'd1:  conn_ptr_acc[15:8]  <= ram_rdata;
                            4'd2:  conn_ptr_acc[7:0]   <= ram_rdata;
                            4'd3:  n_conn_acc[15:8]    <= ram_rdata;
                            4'd4:  n_conn_acc[7:0]     <= ram_rdata;
                            4'd5:  out_id_acc[15:8]    <= ram_rdata;
                            4'd6:  out_id_acc[7:0]     <= ram_rdata;
                            4'd7:  activation_reg      <= ram_rdata[1:0];
                            4'd8:  bias_reg            <= ram_rdata;
                            default: ; // reserved bytes 9-10, ignored
                        endcase

                        if (desc_byte_idx == 4'd10) begin

                            // n_conn_acc is fully committed (bytes
                            // 3-4, several cycles ago) by now.
                            n_conn_padded_reg <=
                                ((n_conn_acc + (PARALLEL - 1)) >> PAR_SHIFT) << PAR_SHIFT;

                            conn_i        <= {CONN_IDX_WIDTH{1'b0}};
                            edge_byte_idx <= 2'h0;
                            state         <= ST_EDGE_RD;

                        end else begin
                            desc_byte_idx <= desc_byte_idx + 4'd1;
                            state         <= ST_DESC_RD;
                        end

                    end

                end

                // =============================================
                // EDGE stream + gather (§4.3, §7)
                // =============================================

                ST_EDGE_RD: begin

                    // n_conn_padded_reg == 0 means the host sent a
                    // neuron with no padded connections at all --
                    // would forward n_inputs_real=0 to neuron_parallel,
                    // which hangs (GROUPS=0 failure mode). Treated as
                    // a load-time error instead (§7 rationale).
                    if (n_conn_padded_reg == 16'h0) begin

                        err   <= 1'b1;
                        busy  <= 1'b0;
                        state <= ST_ERROR;

                    end else begin

                        ram_req  <= 1'b1;
                        ram_wr   <= 1'b0;
                        ram_addr <= conn_ptr_acc[ADDR_WIDTH-1:0] + (conn_i * 4) + edge_byte_idx;

                        state <= ST_EDGE_WAIT;

                    end

                end

                ST_EDGE_WAIT: begin

                    if (ram_ready) begin

                        case (edge_byte_idx)
                            2'd0: src_id_acc[15:8] <= ram_rdata;
                            2'd1: src_id_acc[7:0]  <= ram_rdata;
                            2'd2: weight_acc       <= ram_rdata;
                            default: ; // reserved byte, ignored
                        endcase

                        if (edge_byte_idx == 2'd3) begin

                            edge_byte_idx <= 2'h0;

                            // §7 guard: src_id must be a strictly
                            // earlier-computed signal, and both ids
                            // must fit the activation buffer.
                            if (src_id_acc >= out_id_acc ||
                                src_id_acc >= N_TOTAL[15:0] ||
                                out_id_acc >= N_TOTAL[15:0]) begin

                                err   <= 1'b1;
                                busy  <= 1'b0;
                                state <= ST_ERROR;

                            end else begin

                                // act_buf.rd_addr is wired directly
                                // to src_id_acc (see instantiation
                                // above); it has been stable since
                                // this cycle already (both bytes of
                                // src_id are committed) and will
                                // still be stable through the
                                // ST_GATHER cycle below.
                                state <= ST_GATHER;

                            end

                        end else begin
                            edge_byte_idx <= edge_byte_idx + 2'd1;
                            state         <= ST_EDGE_RD;
                        end

                    end

                end

                // =============================================
                // GATHER: consume act_buf's registered read data
                // (valid: rd_addr has been stable since the START
                // of this same edge's byte 1, i.e. well over a full
                // PSRAM byte round-trip ago -- see header comment).
                // =============================================

                ST_GATHER: begin

                    x_mem[conn_i] <= act_rd_data;
                    w_mem[conn_i] <= $signed(weight_acc);

                    if (conn_i == n_conn_padded_reg[CONN_IDX_WIDTH-1:0] - 1'b1) begin
                        conn_i <= {CONN_IDX_WIDTH{1'b0}};
                        state  <= ST_START_N;
                    end else begin
                        conn_i <= conn_i + 1'b1;
                        state  <= ST_EDGE_RD;
                    end

                end

                // =============================================
                // START / WAIT neuron_parallel
                // =============================================

                ST_START_N: begin
                    neuron_start <= 1'b1;
                    state        <= ST_WAIT_N;
                end

                ST_WAIT_N: begin

                    if (neuron_done) begin

                        act_wr_en   <= 1'b1;
                        act_wr_addr <= out_id_acc[BUF_ADDR_WIDTH-1:0];
                        act_wr_data <= neuron_y;

                        if (is_output_sink) begin
                            state <= ST_WRITE_OUT_ISS;
                        end else if (neuron_idx == num_neurons_graph - 16'd1) begin
                            busy  <= 1'b0;
                            done  <= 1'b1;
                            state <= ST_IDLE;
                        end else begin
                            neuron_idx    <= neuron_idx + 16'd1;
                            desc_addr     <= desc_addr + 11;
                            desc_byte_idx <= 4'h0;
                            state         <= ST_DESC_RD;
                        end

                    end

                end

                // =============================================
                // Fold WRITE_OUTPUTS into the loop for sink neurons
                // =============================================

                ST_WRITE_OUT_ISS: begin

                    ram_req   <= 1'b1;
                    ram_wr    <= 1'b1;
                    ram_addr  <= out_base + out_offset;
                    ram_wdata <= neuron_y;

                    state <= ST_WRITE_OUT_WAIT;

                end

                ST_WRITE_OUT_WAIT: begin

                    if (ram_ready) begin

                        if (neuron_idx == num_neurons_graph - 16'd1) begin
                            busy  <= 1'b0;
                            done  <= 1'b1;
                            state <= ST_IDLE;
                        end else begin
                            neuron_idx    <= neuron_idx + 16'd1;
                            desc_addr     <= desc_addr + 11;
                            desc_byte_idx <= 4'h0;
                            state         <= ST_DESC_RD;
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
