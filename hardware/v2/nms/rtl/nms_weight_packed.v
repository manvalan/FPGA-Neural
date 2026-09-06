// ============================================================
// Neural Memory System (NMS) -- Weight SRAM candidate W2 "packed":
// same private-per-slot semantics as nms_weight_direct.v, but each
// slot's P_IN*DATA_WIDTH-wide tile storage is decomposed into P_IN
// separate, narrow (DATA_WIDTH=8-bit-wide) single-port memories (one
// per MAC lane) instead of one wide 64-bit memory. Reassembly into the
// full tile word is a static concatenation of P_IN registered
// per-lane outputs -- no runtime mux, no real LUT cost expected there.
// Exists to measure whether narrower-but-more-numerous memories pack
// into fewer total DP16KD blocks than nms_weight_direct.v's wider-but-
// fewer instances, per the user's own explicit ask (NMS spec S6) to
// measure width/depth/packing real DP16KD cost rather than assume it.
// ============================================================
module nms_weight_packed #(
    parameter DATA_WIDTH = 8,
    parameter P_IN       = 8,
    parameter N_SLOTS    = 4,
    parameter MAX_TILES  = 16,
    parameter TIW        = (MAX_TILES <= 1) ? 1 : $clog2(MAX_TILES)
)(
    input clk,
    input rst,

    input      [N_SLOTS-1:0]         fill_we,
    input      [N_SLOTS*TIW-1:0]     fill_addr_flat,
    input      [N_SLOTS*DATA_WIDTH*P_IN-1:0] fill_data_flat,

    input      [N_SLOTS-1:0]                    rd_en,
    input      [N_SLOTS*TIW-1:0]                rd_addr_flat,
    output     [N_SLOTS*DATA_WIDTH*P_IN-1:0]     rd_data_flat
);

    genvar g, p;
    generate
        for (g = 0; g < N_SLOTS; g = g + 1) begin : GEN_SLOT
            for (p = 0; p < P_IN; p = p + 1) begin : GEN_LANE
                reg [DATA_WIDTH-1:0] mem [0:MAX_TILES-1];
                reg [DATA_WIDTH-1:0] rd_data_reg;

                always @(posedge clk) begin
                    if (fill_we[g])
                        mem[fill_addr_flat[g*TIW +: TIW]] <=
                            fill_data_flat[g*DATA_WIDTH*P_IN + p*DATA_WIDTH +: DATA_WIDTH];
                    if (rd_en[g])
                        rd_data_reg <= mem[rd_addr_flat[g*TIW +: TIW]];
                end

                assign rd_data_flat[g*DATA_WIDTH*P_IN + p*DATA_WIDTH +: DATA_WIDTH] = rd_data_reg;
            end
        end
    endgenerate

endmodule
