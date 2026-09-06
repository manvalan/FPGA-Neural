// ================================================================
// SYNTHESIS-ONLY TIMING HARNESS -- NOT a functional deliverable.
// Same pattern as hardware/v2/synthesis/harness_memory_manager.v (see
// its own header and errors.log ERR-0005): nms_activation_replicated's
// wide ports (rd_data_flat alone is N_SLOTS*DATA_WIDTH*P_IN bits, e.g.
// 512 bits at N_SLOTS=8) exceed the LFE5U-45F's TRELLIS_IO budget as a
// bare top-level module (confirmed: nextpnr placement failed with
// "no BELs remaining to implement cell type TRELLIS_IO" before this
// harness existed). Drives every input from an internal LFSR and
// reduces every output to a small XOR checksum, keeping only
// clk/rst/seed/checksum as real pins, to get a representative Fmax for
// the module's own logic/routing/BRAM.
// ================================================================
module harness_nms_activation_replicated #(
    parameter DATA_WIDTH = 8,
    parameter P_IN       = 8,
    parameter N_SLOTS    = 4,
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
    wire [TIW-1:0] fill_addr = lfsr[TIW-1:0];
    wire [DATA_WIDTH*P_IN-1:0] fill_data = {(DATA_WIDTH*P_IN/32+1){lfsr}};

    wire [N_SLOTS-1:0] rd_en = lfsr[N_SLOTS-1:0];
    wire [N_SLOTS*TIW-1:0] rd_addr_flat = {(N_SLOTS*TIW/32+1){lfsr}};
    wire [N_SLOTS*DATA_WIDTH*P_IN-1:0] rd_data_flat;

    nms_activation_replicated #(
        .DATA_WIDTH(DATA_WIDTH), .P_IN(P_IN), .N_SLOTS(N_SLOTS), .MAX_TILES(MAX_TILES)
    ) dut (
        .clk(clk), .rst(rst),
        .fill_we(fill_we), .fill_addr(fill_addr), .fill_data(fill_data),
        .rd_en(rd_en), .rd_addr_flat(rd_addr_flat), .rd_data_flat(rd_data_flat)
    );

    integer k;
    reg [7:0] chk;
    reg [7:0] chk_next;
    always @(posedge clk) begin
        if (rst) begin
            chk <= 8'h0;
        end else begin
            chk_next = chk;
            for (k = 0; k < N_SLOTS; k = k + 1)
                chk_next = chk_next ^ rd_data_flat[k*DATA_WIDTH*P_IN +: 8];
            chk <= chk_next;
        end
    end
    assign checksum = chk;

endmodule
