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

            always @(posedge clk) begin
                if (fill_we)
                    mem[fill_addr] <= fill_data;
            end

            // ROOT CAUSE (found via STEP20's own board-level SPI
            // integration smoke test, ERR-0025 Part B): this read used
            // to be REGISTERED (rd_data_reg <= mem[addr], gated by
            // rd_en[g]) -- a full extra clock cycle of latency beyond
            // what nms_memory_manager_stream_wide.v's own read-ahead
            // pipeline (its `rd_pending` bit) actually assumes. That
            // pipeline issues a read one cycle and captures the result
            // the VERY NEXT cycle -- correct only if this memory's own
            // read is COMBINATIONAL (address in this cycle, data
            // already valid this same cycle), not registered (address
            // in this cycle, data valid only the cycle after). A busy,
            // multi-tile job never exposes the extra cycle because its
            // own weight/activation prefetch always runs far enough
            // ahead that, by the time a given tile is actually
            // consumed, that data has been sitting stable for many
            // cycles already. An uncontested single-tile job has zero
            // such margin: its first (only) tile's read fires on the
            // exact edge the data becomes nominally "ready", and the
            // consumer captured one real cycle before the registered
            // output ever updated -- permanently latching stale
            // (all-zero, reset-value) data. Fixed by making the read
            // itself combinational, matching the consumer's actual
            // latency assumption, with NO change to any FSM timing.
            // The same-cycle fill/read-to-the-same-address case (fill_we
            // and this slot's own read targeting the identical tile on
            // the identical edge) is bypassed explicitly, since mem[]
            // itself will not show a same-edge write until the NEXT
            // cycle even with a combinational read.
            wire rd_bypass = fill_we && (fill_addr == rd_addr_flat[g*TIW +: TIW]);
            assign rd_data_flat[g*DATA_WIDTH*P_IN +: DATA_WIDTH*P_IN] =
                rd_bypass ? fill_data : mem[rd_addr_flat[g*TIW +: TIW]];
        end
    endgenerate

endmodule
