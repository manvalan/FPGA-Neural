// ============================================================
// Neural Memory System (NMS) -- Weight SRAM candidate W1 "direct":
// N_SLOTS private, single-port, natively P_IN*DATA_WIDTH-wide memories
// (one per slot). Weights are NEVER shared across neurons (STEP2's own
// analytical conclusion), so there is no arbitration to design at all
// here -- every slot's own fill+read port is fully private. This
// candidate mirrors hardware/v2/rtl/weight_buffer.v's own original
// width/depth structure (EXP-0004/M3) exactly, replicated N_SLOTS
// times, to measure the REAL total DP16KD cost of that replication
// rather than assume it from the single-copy number alone.
// ============================================================
module nms_weight_direct #(
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

    genvar g;
    generate
        for (g = 0; g < N_SLOTS; g = g + 1) begin : GEN_SLOT
            reg [DATA_WIDTH*P_IN-1:0] mem [0:MAX_TILES-1];
            reg [DATA_WIDTH*P_IN-1:0] rd_data_reg;

            always @(posedge clk) begin
                if (fill_we[g])
                    mem[fill_addr_flat[g*TIW +: TIW]] <= fill_data_flat[g*DATA_WIDTH*P_IN +: DATA_WIDTH*P_IN];
                if (rd_en[g])
                    rd_data_reg <= mem[rd_addr_flat[g*TIW +: TIW]];
            end

            assign rd_data_flat[g*DATA_WIDTH*P_IN +: DATA_WIDTH*P_IN] = rd_data_reg;
        end
    endgenerate

endmodule
