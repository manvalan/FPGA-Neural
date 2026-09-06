// ============================================================
// Neural Memory System (NMS) -- STEP4/5 candidate A: REPLICATED
// activation memory.
//
// One full copy of the shared activation vector's tile storage per
// slot (N_SLOTS independent single-write/single-read BRAMs). A shared
// fill engine broadcasts each filled tile to EVERY copy on the same
// cycle (one PSRAM-side write, N_SLOTS on-chip writes) -- after fill,
// every slot's own read port is completely private: zero contention,
// ever, by construction (no arbitration logic at all on the read
// side). Real cost is N_SLOTS x the single-copy storage; this file
// exists to MEASURE that real DP16KD/LUT/Fmax cost against Candidate
// B (nms_activation_banked.v) rather than assume replication is too
// expensive a priori (EXP-0019/DEC-0019).
// ============================================================
module nms_activation_replicated #(
    parameter DATA_WIDTH = 8,
    parameter P_IN       = 8,
    parameter N_SLOTS    = 4,
    parameter MAX_TILES  = 16,
    parameter TIW        = (MAX_TILES <= 1) ? 1 : $clog2(MAX_TILES)
)(
    input clk,
    input rst,

    // ---- fill port: one write, broadcast to every copy ----
    input                          fill_we,
    input      [TIW-1:0]           fill_addr,
    input      [DATA_WIDTH*P_IN-1:0] fill_data,

    // ---- per-slot private read port ----
    input      [N_SLOTS-1:0]                    rd_en,
    input      [N_SLOTS*TIW-1:0]                rd_addr_flat,
    output     [N_SLOTS*DATA_WIDTH*P_IN-1:0]     rd_data_flat
);

    genvar g;
    generate
        for (g = 0; g < N_SLOTS; g = g + 1) begin : GEN_COPY
            reg [DATA_WIDTH*P_IN-1:0] mem [0:MAX_TILES-1];
            reg [DATA_WIDTH*P_IN-1:0] rd_data_reg;

            always @(posedge clk) begin
                if (fill_we)
                    mem[fill_addr] <= fill_data;
                if (rd_en[g])
                    rd_data_reg <= mem[rd_addr_flat[g*TIW +: TIW]];
            end

            assign rd_data_flat[g*DATA_WIDTH*P_IN +: DATA_WIDTH*P_IN] = rd_data_reg;
        end
    endgenerate

endmodule
