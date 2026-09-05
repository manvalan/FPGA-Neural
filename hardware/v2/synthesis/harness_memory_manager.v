// ================================================================
// SYNTHESIS-ONLY TIMING HARNESS -- NOT a functional deliverable.
// Same rationale/pattern as harness_neural_processor_array.v (see its
// header and hardware/v2/logs/errors.log ERR-0005): memory_manager's
// wide ports (input_data/weight_data alone, 64 bits) exceed the
// LFE5U-45F's TRELLIS_IO budget as a bare top-level module. Drives
// them from an internal LFSR and reduces outputs to a small
// checksum, keeping only clk/rst/seed/checksum as real pins, to get
// a representative Fmax for memory_manager's own logic/routing.
// ================================================================

module harness_memory_manager #(
    parameter DATA_WIDTH = 8,
    parameter P_IN       = 8,
    parameter ADDR_WIDTH = 23
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

    wire                          job_start      = lfsr[0];
    wire [ADDR_WIDTH-1:0]         x_base         = lfsr[ADDR_WIDTH-1:0];
    wire [ADDR_WIDTH-1:0]         w_base         = {lfsr[7:0], lfsr[ADDR_WIDTH-9:0]};
    wire [15:0]                   n_tiles        = lfsr[15:0];
    wire [ADDR_WIDTH-1:0]         result_addr    = {lfsr[3:0], lfsr[ADDR_WIDTH-5:0]};
    wire                          operand_ready  = lfsr[2];
    wire                          result_valid   = lfsr[3];
    wire signed [DATA_WIDTH-1:0]  result_data    = lfsr[7:0];
    wire signed [7:0]             mem_rdata      = lfsr[15:8];
    wire                          mem_ready      = lfsr[4];

    wire job_done;
    wire operand_valid;
    wire signed [DATA_WIDTH*P_IN-1:0] input_data, weight_data;
    wire tile_last;
    wire result_ready;
    wire mem_req, mem_wr;
    wire [ADDR_WIDTH-1:0] mem_addr;
    wire signed [7:0] mem_wdata;

    memory_manager #(
        .DATA_WIDTH(DATA_WIDTH), .P_IN(P_IN), .ADDR_WIDTH(ADDR_WIDTH)
    ) dut (
        .clk(clk), .rst(rst),
        .job_start(job_start), .x_base(x_base), .w_base(w_base),
        .n_tiles(n_tiles), .result_addr(result_addr), .job_done(job_done),
        .operand_valid(operand_valid), .operand_ready(operand_ready),
        .input_data(input_data), .weight_data(weight_data), .tile_last(tile_last),
        .result_valid(result_valid), .result_ready(result_ready), .result_data(result_data),
        .mem_req(mem_req), .mem_wr(mem_wr), .mem_addr(mem_addr), .mem_wdata(mem_wdata),
        .mem_rdata(mem_rdata), .mem_ready(mem_ready)
    );

    reg [7:0] chk;
    always @(posedge clk) begin
        if (rst) chk <= 8'h0;
        else chk <= chk ^ input_data[7:0] ^ weight_data[7:0] ^ {7'h0, job_done}
                        ^ {6'h0, tile_last, result_ready} ^ mem_addr[7:0]
                        ^ {7'h0, mem_req} ^ {7'h0, mem_wr} ^ mem_wdata;
    end
    assign checksum = chk;

endmodule
