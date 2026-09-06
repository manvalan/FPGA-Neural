// ============================================================
// Neural Memory System (NMS) -- STEP4/5 candidate B: BANKED activation
// memory with broadcast-on-same-address and round-robin arbitration.
//
// ONE logical copy of the shared activation vector, striped across
// N_BANKS single-port BRAMs by tile index (bank = tile_idx % N_BANKS).
// Real per-bank round-robin arbitration (same policy validated in
// simulation, EXP-0018): the lowest-index requester currently pointed
// to by that bank's own rotating pointer wins ties; every requester
// wanting the SAME tile index as the winner is broadcast-acked for
// free (one read serves them all).
//
// Two register stages (request -> arbitration decision -> BRAM
// address; BRAM address -> BRAM data -> crossbar mux), register-to-
// register throughout -- deliberately NOT the single-cycle
// combinational hit-detection/broadcast structure that cost
// activation_cache.v its Fmax margin at N_SLOTS=4 (DEC-0016). Request
// accepted at cycle T; ack + data both become valid at cycle T+2.
//
// Real per-bank storage depth is MAX_TILES/N_BANKS -- N_BANKS times
// LESS total on-chip storage than nms_activation_replicated.v's
// N_SLOTS full copies, at the cost of the arbitration/crossbar logic
// below. Both candidates are measured (EXP-0019/DEC-0019), not chosen
// a priori.
// ============================================================
module nms_activation_banked #(
    parameter DATA_WIDTH = 8,
    parameter P_IN       = 8,
    parameter N_SLOTS    = 4,
    parameter N_BANKS    = 4,
    parameter MAX_TILES  = 16,
    parameter TIW        = (MAX_TILES <= 1) ? 1 : $clog2(MAX_TILES),
    parameter BDEPTH     = (MAX_TILES + N_BANKS - 1) / N_BANKS,
    parameter BAW        = (BDEPTH <= 1) ? 1 : $clog2(BDEPTH),
    parameter SLOTW      = (N_SLOTS <= 1) ? 1 : $clog2(N_SLOTS),
    parameter BANKW      = (N_BANKS <= 1) ? 1 : $clog2(N_BANKS)
)(
    input clk,
    input rst,

    // ---- fill port: one tile write, routed to its own bank ----
    input                          fill_we,
    input      [TIW-1:0]           fill_tile_idx,
    input      [DATA_WIDTH*P_IN-1:0] fill_data,

    // ---- per-slot request/response (2-cycle latency: ack+data valid
    // at T+2 for a request presented at T) ----
    input      [N_SLOTS-1:0]         req_valid,
    input      [N_SLOTS*TIW-1:0]     req_tile_idx_flat,
    output reg [N_SLOTS-1:0]         ack,
    output     [N_SLOTS*DATA_WIDTH*P_IN-1:0] rd_data_flat
);

    integer i, b;

    // ---- bank storage (N_BANKS separate 1D arrays -> N_BANKS BRAMs) ----
    genvar gb;
    wire [DATA_WIDTH*P_IN-1:0] bank_rd_data_reg [0:N_BANKS-1];
    reg  [BAW-1:0] bank_rd_addr_stage1 [0:N_BANKS-1];
    reg            bank_rd_en_stage1  [0:N_BANKS-1];

    generate
        for (gb = 0; gb < N_BANKS; gb = gb + 1) begin : GEN_BANK
            reg [DATA_WIDTH*P_IN-1:0] mem [0:BDEPTH-1];
            reg [DATA_WIDTH*P_IN-1:0] rd_data_r;
            wire this_bank_we = fill_we && ((fill_tile_idx % N_BANKS) == gb);

            always @(posedge clk) begin
                if (this_bank_we)
                    mem[fill_tile_idx / N_BANKS] <= fill_data;
                if (bank_rd_en_stage1[gb])
                    rd_data_r <= mem[bank_rd_addr_stage1[gb]];
            end
            assign bank_rd_data_reg[gb] = rd_data_r;
        end
    endgenerate

    // ---- stage 0 (combinational): per-bank round-robin arbitration +
    // broadcast-ack decision, using THIS cycle's req_valid/req_tile_idx ----
    reg [TIW-1:0]  req_tile_idx [0:N_SLOTS-1];
    reg [BANKW-1:0] req_bank    [0:N_SLOTS-1];
    reg [SLOTW-1:0] rr_ptr      [0:N_BANKS-1];

    reg            win_valid     [0:N_BANKS-1];
    reg [TIW-1:0]  win_tile_idx  [0:N_BANKS-1];
    reg [SLOTW-1:0] win_first    [0:N_BANKS-1];
    reg [N_SLOTS-1:0] ack_comb;
    reg [BANKW-1:0] slot_bank_comb [0:N_SLOTS-1];
    integer scan_i, cand;

    always @* begin
        for (i = 0; i < N_SLOTS; i = i + 1) begin
            req_tile_idx[i] = req_tile_idx_flat[i*TIW +: TIW];
            req_bank[i]     = req_tile_idx[i] % N_BANKS;
            slot_bank_comb[i] = req_bank[i];
        end
        ack_comb = {N_SLOTS{1'b0}};
        for (b = 0; b < N_BANKS; b = b + 1) begin
            win_valid[b]    = 1'b0;
            win_tile_idx[b] = {TIW{1'b0}};
            win_first[b]    = {SLOTW{1'b0}};
            for (scan_i = 0; scan_i < N_SLOTS; scan_i = scan_i + 1) begin
                cand = (rr_ptr[b] + scan_i) % N_SLOTS;
                if (req_valid[cand] && (req_bank[cand] == b) && !win_valid[b]) begin
                    win_valid[b]    = 1'b1;
                    win_tile_idx[b] = req_tile_idx[cand];
                    win_first[b]    = cand[SLOTW-1:0];
                end
            end
            if (win_valid[b]) begin
                for (i = 0; i < N_SLOTS; i = i + 1) begin
                    if (req_valid[i] && (req_bank[i] == b) && (req_tile_idx[i] == win_tile_idx[b]))
                        ack_comb[i] = 1'b1;
                end
            end
        end
    end

    // ---- stage 1 registers: arbitration decision -> BRAM address,
    // plus the per-slot bookkeeping needed to route data back 1 cycle
    // later (stage 2) ----
    reg [N_SLOTS-1:0] ack_stage1;
    reg [BANKW-1:0]   slot_bank_stage1 [0:N_SLOTS-1];

    always @(posedge clk) begin
        if (rst) begin
            for (b = 0; b < N_BANKS; b = b + 1) begin
                rr_ptr[b] <= {SLOTW{1'b0}};
                bank_rd_en_stage1[b] <= 1'b0;
                bank_rd_addr_stage1[b] <= {BAW{1'b0}};
            end
            ack_stage1 <= {N_SLOTS{1'b0}};
            ack        <= {N_SLOTS{1'b0}};
            for (i = 0; i < N_SLOTS; i = i + 1) begin
                slot_bank_stage1[i] <= {BANKW{1'b0}};
            end
        end else begin
            for (b = 0; b < N_BANKS; b = b + 1) begin
                bank_rd_en_stage1[b]   <= win_valid[b];
                bank_rd_addr_stage1[b] <= win_tile_idx[b] / N_BANKS;
                if (win_valid[b]) rr_ptr[b] <= win_first[b] + 1'b1;
            end
            ack_stage1 <= ack_comb;
            for (i = 0; i < N_SLOTS; i = i + 1)
                slot_bank_stage1[i] <= slot_bank_comb[i];

            // stage 2: ack becomes valid the cycle the BRAM's own
            // registered read output (bank_rd_data_reg) is valid
            ack <= ack_stage1;
        end
    end

    // ---- stage 2 (combinational crossbar): route each bank's
    // registered read output to whichever slot(s) it was serving,
    // using the stage1-registered bank assignment ----
    genvar gs;
    generate
        for (gs = 0; gs < N_SLOTS; gs = gs + 1) begin : GEN_XBAR
            assign rd_data_flat[gs*DATA_WIDTH*P_IN +: DATA_WIDTH*P_IN] =
                bank_rd_data_reg[slot_bank_stage1[gs]];
        end
    endgenerate

endmodule
