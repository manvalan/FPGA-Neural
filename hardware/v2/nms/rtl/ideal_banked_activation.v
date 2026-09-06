// ============================================================
// Neural Memory System (NMS) -- STEP 3: banked activation SRAM
// contention model. SIMULATION-ONLY, NEVER SYNTHESIZED.
//
// Models a single shared activation vector striped across N_BANKS
// banks by tile index (bank = tile_idx % N_BANKS). Each bank can serve
// ONE DISTINCT address per cycle, but BROADCASTS that address's data
// to every requester currently wanting it (a shared-producer, many-
// consumer read costs exactly one read, not one per consumer -- see
// hardware/v2/nms/rtl.. STEP2's own architecture.log note and the
// user's own NMS spec §11). A cycle where two+ requesters mapped to
// the same bank want DIFFERENT tile indices serves only one of them
// (lowest-index requester wins this round); the others simply retry
// next cycle (idempotent -- an ideal SRAM read has no state cost).
//
// Read latency is modeled as ZERO cycles (grant and data-available
// are the same cycle) -- this file isolates the BANK CONTENTION
// question specifically, decoupled from backing-store latency, which
// STEP1 (hardware/v2/nms/rtl/ideal_memory_model.v, EXP-0017) already
// characterized separately. Fill-from-PSRAM is out of scope here too
// (the vector is assumed already resident, i.e. steady-state
// consumption after prefetch -- the question this file answers is
// "does the on-chip organization itself let N_SLOTS scale", not
// "how do we hide PSRAM latency" (already answered by STEP1).
// ============================================================
module ideal_banked_activation #(
    parameter NREQ    = 4,
    parameter N_BANKS = 2,
    parameter AW       = 32
)(
    input      [NREQ-1:0]        req_valid,
    input      [NREQ*AW-1:0]     req_addr_flat,
    output reg [NREQ-1:0]        ack
);
    integer b, i;
    reg [AW-1:0] req_addr [0:NREQ-1];
    reg [AW-1:0] served_addr;
    reg          have_served;
    integer bank_of_i;

    always @* begin
        for (i = 0; i < NREQ; i = i + 1)
            req_addr[i] = req_addr_flat[i*AW +: AW];

        ack = {NREQ{1'b0}};
        for (b = 0; b < N_BANKS; b = b + 1) begin
            have_served = 1'b0;
            served_addr = {AW{1'b0}};
            // first pass: lowest-index valid requester in this bank sets
            // the address served this cycle
            for (i = 0; i < NREQ; i = i + 1) begin
                bank_of_i = req_addr[i] % N_BANKS;
                if (req_valid[i] && (bank_of_i == b) && !have_served) begin
                    served_addr = req_addr[i];
                    have_served = 1'b1;
                end
            end
            // second pass: broadcast ack to every requester in this bank
            // that wants the SAME address (free, one read serves all)
            if (have_served) begin
                for (i = 0; i < NREQ; i = i + 1) begin
                    bank_of_i = req_addr[i] % N_BANKS;
                    if (req_valid[i] && (bank_of_i == b) && (req_addr[i] == served_addr))
                        ack[i] = 1'b1;
                end
            end
        end
    end
endmodule
