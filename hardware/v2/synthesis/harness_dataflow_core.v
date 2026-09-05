// ================================================================
// SYNTHESIS-ONLY TIMING HARNESS -- NOT a functional deliverable.
// Same rationale/pattern as harness_neural_processor_array.v and
// harness_memory_manager.v (see their headers, and
// hardware/v2/logs/errors.log ERR-0005): dataflow_core's own ports
// (per-slot mem_addr/wdata/rdata buses, node registration fields)
// exceed the LFE5U-45F's ~245 TRELLIS_IO budget as a bare top-level
// module well before N_SLOTS=2 (measured: N_SLOTS=4 alone needs 280
// bits just for the per-slot Memory Backend Interface arrays).
//
// dataflow_core.v additionally instantiates N_SLOTS REAL copies of
// (memory_manager + neural_processor) via `generate` -- exactly the
// same CSE risk already hit and fixed once in
// harness_neural_processor_array.v (giving every instance IDENTICAL
// LFSR data lets Yosys collapse all N_SLOTS copies down to 1). This
// harness reuses that fix: each slot's mem_rdata/mem_ready input gets
// its own distinct bit-rotated LFSR slice, and the checksum folds in
// a real bit from EVERY slot's own outputs, not just slot 0's.
//
// Only clk/rst/seed/checksum are exposed as real top-level pins.
// ================================================================

module harness_dataflow_core #(
    parameter DATA_WIDTH  = 8,
    parameter P_IN        = 8,
    parameter ACC_WIDTH   = 32,
    parameter ADDR_WIDTH  = 23,
    parameter N_SLOTS     = 4,
    parameter N_NODES     = 16,
    parameter MAX_DEPS    = 4,
    parameter QUEUE_DEPTH = 8
)(
    input  wire clk,
    input  wire rst,
    input  wire [7:0] seed,
    output wire [7:0] checksum
);

    localparam NODE_IDW = $clog2(N_NODES);

    reg [31:0] lfsr;
    always @(posedge clk) begin
        if (rst) lfsr <= {24'h0, seed} | 32'h1;
        else     lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
    end

    // ---- node-registration side: a single port, no per-instance
    // CSE risk -- plain LFSR slices are enough. ----
    wire                                        reg_valid  = lfsr[0];
    wire [NODE_IDW-1:0]                         reg_node_id  = lfsr[NODE_IDW-1:0];
    wire [$clog2(MAX_DEPS+1)-1:0]               reg_required = lfsr[$clog2(MAX_DEPS+1)-1:0];
    wire [MAX_DEPS*NODE_IDW-1:0]                reg_producer_ids;
    wire [ADDR_WIDTH-1:0]                       reg_x_base   = lfsr[ADDR_WIDTH-1:0];
    wire [ADDR_WIDTH-1:0]                       reg_w_base   = {lfsr[3:0], lfsr[ADDR_WIDTH-5:0]};
    wire [15:0]                                 reg_n_tiles  = lfsr[15:0];
    wire [ADDR_WIDTH-1:0]                       reg_result_addr = {lfsr[6:0], lfsr[ADDR_WIDTH-8:0]};
    genvar pgi;
    generate
        for (pgi = 0; pgi < MAX_DEPS; pgi = pgi + 1) begin : GEN_PID
            wire [31:0] prot = {lfsr[pgi:0], lfsr[31:pgi+1]};
            assign reg_producer_ids[pgi*NODE_IDW +: NODE_IDW] = prot[NODE_IDW-1:0];
        end
    endgenerate

    // ---- per-slot Memory Backend Interface inputs: EACH slot needs
    // a DISTINCT rotated slice (see file header) so the N_SLOTS
    // memory_manager+neural_processor pairs stay N_SLOTS real,
    // distinguishable instances instead of collapsing to 1. ----
    wire signed [8*N_SLOTS-1:0] slot_mem_rdata;
    wire [N_SLOTS-1:0]          slot_mem_ready;
    genvar sgi;
    generate
        for (sgi = 0; sgi < N_SLOTS; sgi = sgi + 1) begin : GEN_SLOT_DRIVE
            wire [31:0] srot = {lfsr[sgi:0], lfsr[31:sgi+1]};
            assign slot_mem_rdata[sgi*8 +: 8] = srot[7:0];
            assign slot_mem_ready[sgi]        = srot[8];
        end
    endgenerate

    wire                          reg_ready;
    wire [N_SLOTS-1:0]            slot_mem_req, slot_mem_wr;
    wire [ADDR_WIDTH*N_SLOTS-1:0] slot_mem_addr;
    wire signed [8*N_SLOTS-1:0]   slot_mem_wdata;

    dataflow_core #(
        .DATA_WIDTH(DATA_WIDTH), .P_IN(P_IN), .ACC_WIDTH(ACC_WIDTH), .ADDR_WIDTH(ADDR_WIDTH),
        .N_SLOTS(N_SLOTS), .N_NODES(N_NODES), .MAX_DEPS(MAX_DEPS), .QUEUE_DEPTH(QUEUE_DEPTH)
    ) dut (
        .clk(clk), .rst(rst),
        .reg_valid(reg_valid), .reg_ready(reg_ready), .reg_node_id(reg_node_id),
        .reg_required(reg_required), .reg_producer_ids(reg_producer_ids),
        .reg_x_base(reg_x_base), .reg_w_base(reg_w_base), .reg_n_tiles(reg_n_tiles),
        .reg_result_addr(reg_result_addr),
        .slot_mem_req(slot_mem_req), .slot_mem_wr(slot_mem_wr), .slot_mem_addr(slot_mem_addr),
        .slot_mem_wdata(slot_mem_wdata), .slot_mem_rdata(slot_mem_rdata), .slot_mem_ready(slot_mem_ready)
    );

    // Fold in a real bit from EVERY slot's own outputs (not just slot
    // 0's) -- otherwise all slots but one have no observable output
    // path and Yosys correctly strips them as dead logic.
    wire [N_SLOTS-1:0] addr_lsb, wdata_lsb;
    generate
        for (sgi = 0; sgi < N_SLOTS; sgi = sgi + 1) begin : GEN_CHK_LANE
            assign addr_lsb[sgi]  = slot_mem_addr[sgi*ADDR_WIDTH];
            assign wdata_lsb[sgi] = slot_mem_wdata[sgi*8];
        end
    endgenerate

    reg [7:0] chk;
    always @(posedge clk) begin
        if (rst) chk <= 8'h0;
        else chk <= chk ^ {7'h0, reg_ready} ^ slot_mem_req ^ slot_mem_wr
                        ^ addr_lsb ^ wdata_lsb;
    end
    assign checksum = chk;

endmodule
