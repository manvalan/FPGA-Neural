// ================================================================
// SYNTHESIS-ONLY TIMING HARNESS -- NOT a functional deliverable.
// Same pattern as harness_nms_activation_replicated.v /
// hardware/v2/synthesis/harness_memory_manager.v: reduces
// nms_activation_banked's wide ports to an LFSR-driven input side and
// an XOR-checksum output side, keeping only clk/rst/seed/checksum as
// real pins.
// ================================================================
module harness_nms_activation_banked #(
    parameter DATA_WIDTH = 8,
    parameter P_IN       = 8,
    parameter N_SLOTS    = 4,
    parameter N_BANKS    = 4,
    parameter MAX_TILES  = 16,
    parameter TIW        = (MAX_TILES <= 1) ? 1 : $clog2(MAX_TILES)
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

    wire fill_we = lfsr[0];
    wire [TIW-1:0] fill_tile_idx = lfsr[TIW-1:0];
    wire [DATA_WIDTH*P_IN-1:0] fill_data = {(DATA_WIDTH*P_IN/32+1){lfsr}};

    wire [N_SLOTS-1:0] req_valid = lfsr[N_SLOTS-1:0];
    wire [N_SLOTS*TIW-1:0] req_tile_idx_flat = {(N_SLOTS*TIW/32+1){lfsr}};
    wire [N_SLOTS-1:0] ack;
    wire [N_SLOTS*DATA_WIDTH*P_IN-1:0] rd_data_flat;

    nms_activation_banked #(
        .DATA_WIDTH(DATA_WIDTH), .P_IN(P_IN), .N_SLOTS(N_SLOTS), .N_BANKS(N_BANKS), .MAX_TILES(MAX_TILES)
    ) dut (
        .clk(clk), .rst(rst),
        .fill_we(fill_we), .fill_tile_idx(fill_tile_idx), .fill_data(fill_data),
        .req_valid(req_valid), .req_tile_idx_flat(req_tile_idx_flat),
        .ack(ack), .rd_data_flat(rd_data_flat)
    );

    integer k;
    reg [7:0] chk;
    reg [7:0] chk_next;
    always @(posedge clk) begin
        if (rst) begin
            chk <= 8'h0;
        end else begin
            chk_next = chk ^ {7'h0, ack[0]};
            for (k = 0; k < N_SLOTS; k = k + 1)
                chk_next = chk_next ^ rd_data_flat[k*DATA_WIDTH*P_IN +: 8];
            chk <= chk_next;
        end
    end
    assign checksum = chk;

endmodule
