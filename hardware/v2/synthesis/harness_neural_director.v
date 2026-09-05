// ================================================================
// SYNTHESIS-ONLY TIMING HARNESS -- NOT a functional deliverable.
// Same rationale as harness_neural_processor_array.v / harness_
// memory_manager.v (see errors.log ERR-0005): neural_director's
// per-slot arrayed ports (N_SLOTS=4 * 23-bit addresses x3) exceed the
// LFE5U-45F's TRELLIS_IO budget as a bare top-level module.
// ================================================================

module harness_neural_director #(
    parameter ADDR_WIDTH  = 23,
    parameter N_SLOTS     = 4,
    parameter QUEUE_DEPTH = 8
)(
    input  wire clk,
    input  wire rst,
    input  wire [7:0] seed,
    output wire [7:0] checksum
);

    reg [31:0] lfsr;
    always @(posedge clk) begin
        if (rst) lfsr <= {24'h0, seed} | 32'h1;
        else     lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
    end

    wire                     job_in_valid = lfsr[0];
    wire [ADDR_WIDTH-1:0]    job_in_x_base = lfsr[ADDR_WIDTH-1:0];
    wire [ADDR_WIDTH-1:0]    job_in_w_base = {lfsr[3:0], lfsr[ADDR_WIDTH-5:0]};
    wire [15:0]              job_in_n_tiles = lfsr[15:0];
    wire [ADDR_WIDTH-1:0]    job_in_result_addr = {lfsr[7:0], lfsr[ADDR_WIDTH-9:0]};
    wire [15:0]              job_in_node_id = lfsr[31:16];
    wire [N_SLOTS-1:0]       slot_job_done = lfsr[N_SLOTS-1:0];

    wire job_in_ready;
    wire [N_SLOTS-1:0] slot_job_start;
    wire [ADDR_WIDTH*N_SLOTS-1:0] slot_x_base, slot_w_base, slot_result_addr;
    wire [16*N_SLOTS-1:0] slot_n_tiles;
    wire job_out_done;
    wire [$clog2(N_SLOTS)-1:0] job_out_slot;
    wire [3:0] dir_state;
    wire dir_error;

    neural_director #(
        .ADDR_WIDTH(ADDR_WIDTH), .N_SLOTS(N_SLOTS), .QUEUE_DEPTH(QUEUE_DEPTH)
    ) dut (
        .clk(clk), .rst(rst),
        .job_in_valid(job_in_valid), .job_in_ready(job_in_ready),
        .job_in_x_base(job_in_x_base), .job_in_w_base(job_in_w_base),
        .job_in_n_tiles(job_in_n_tiles), .job_in_result_addr(job_in_result_addr),
        .job_in_node_id(job_in_node_id),
        .slot_job_start(slot_job_start), .slot_x_base(slot_x_base), .slot_w_base(slot_w_base),
        .slot_n_tiles(slot_n_tiles), .slot_result_addr(slot_result_addr), .slot_job_done(slot_job_done),
        .job_out_done(job_out_done), .job_out_slot(job_out_slot),
        .dir_state(dir_state), .dir_error(dir_error)
    );

    reg [7:0] chk;
    always @(posedge clk) begin
        if (rst) chk <= 8'h0;
        else chk <= chk ^ {7'h0, job_in_ready} ^ slot_job_start ^ slot_x_base[7:0]
                        ^ slot_w_base[7:0] ^ slot_result_addr[7:0] ^ slot_n_tiles[7:0]
                        ^ {7'h0, job_out_done} ^ {6'h0, job_out_slot} ^ dir_state ^ {7'h0, dir_error};
    end
    assign checksum = chk;

endmodule
