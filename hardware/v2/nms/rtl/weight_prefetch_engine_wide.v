`timescale 1ns/1ps

// ============================================================
// Neural Memory System (NMS) -- STEP14 Part A: parameterized-width
// experimental weight prefetch engine.
//
// SIMULATION-ONLY / EXPLORATORY (same status as ideal_memory_model.v,
// STEP11's own EXP-0017/23): establishes the ARCHITECTURAL requirement
// (what logical weight-path width removes the fetch-rate bottleneck
// EXP-0026/0027 identified) BEFORE committing to any specific real
// hardware implementation. Generalizes weight_prefetch_engine.v's own
// continuous cross-tile-boundary streaming design (STEP11, unchanged
// in spirit) to an arbitrary MEM_DATA_WIDTH instead of the real V1
// PSRAM's fixed 16 bits. Byte-lane enables (mem_lb_n/mem_ub_n) are
// dropped at this level of abstraction -- not meaningful for a
// logical bus wider than 16 bits; the real 16-bit interface (with
// lane enables) is reintroduced separately by the A5 packing adapter
// (weight_fetch_pack_adapter.v) that connects this engine's logical
// wide requests to the REAL, unmodified V1 PSRAM chain.
//
// WORDS_PER_TILE generalizes to
// ceil(DATA_WIDTH*P_IN / MEM_DATA_WIDTH), clamped to a minimum of 1
// (a bus wider than one full tile still costs exactly 1 transaction,
// with the surplus bits simply unused -- this experiment does not
// attempt multi-tile-per-transaction bursting).
// ============================================================
module weight_prefetch_engine_wide #(
    parameter DATA_WIDTH     = 8,
    parameter P_IN           = 8,
    parameter ADDR_WIDTH     = 23,
    parameter MAX_TILES      = 16,
    parameter PREFETCH_DISTANCE = 8,
    parameter MEM_DATA_WIDTH = 64,   // 16, 32, 64, 128 -- the STEP14 Part A sweep parameter
    parameter TIW   = (MAX_TILES <= 1) ? 1 : $clog2(MAX_TILES),
    parameter CNTW  = $clog2(MAX_TILES+1),
    // ceil(TILE_BITS / MEM_DATA_WIDTH), minimum 1
    parameter TILE_BITS      = DATA_WIDTH*P_IN,
    parameter WORDS_PER_TILE = (TILE_BITS + MEM_DATA_WIDTH - 1) / MEM_DATA_WIDTH,
    parameter WIW   = $clog2(WORDS_PER_TILE+1)
)(
    input  wire clk,
    input  wire rst,

    input  wire                  job_active,
    input  wire [ADDR_WIDTH-1:0] w_base,       // byte address
    input  wire [15:0]           n_tiles,
    input  wire [CNTW-1:0]       consumed_count,

    output reg                    wgt_fill_we,
    output reg  [TIW-1:0]         wgt_fill_addr,
    output reg  [DATA_WIDTH*P_IN-1:0] wgt_fill_data,

    output reg  [CNTW-1:0]        ready_count,

    // ---- logical wide memory port (ideal_memory_model_wide.v) ----
    output reg                        mem_req,
    output reg  [ADDR_WIDTH-1:0]      mem_addr,   // byte address of this transaction's first byte
    input  wire [MEM_DATA_WIDTH-1:0]  mem_rdata,
    input  wire                       mem_ready
);

    localparam BYTES_PER_WORD = MEM_DATA_WIDTH/8;
    // The backing store is packed at the tile's OWN natural byte size
    // (TILE_BITS/8 = P_IN*DATA_WIDTH/8, e.g. 8 bytes for P_IN=8/
    // DATA_WIDTH=8), regardless of MEM_DATA_WIDTH. This equals
    // WORDS_PER_TILE*BYTES_PER_WORD whenever MEM_DATA_WIDTH<=TILE_BITS
    // (no waste, e.g. 16/32/64-bit busses), but NOT when
    // MEM_DATA_WIDTH>TILE_BITS (e.g. a 128-bit bus fetching a 64-bit
    // tile in one transaction, using only its low half) -- using
    // WORDS_PER_TILE*BYTES_PER_WORD as the inter-tile address stride
    // in that case would double-count the unused surplus bits as real
    // address space and skip over the next tile's actual data in the
    // packed backing store. TILE_BYTES is the correct stride always.
    localparam TILE_BYTES = TILE_BITS/8;

    reg [CNTW-1:0] fetch_tile;
    reg [WIW-1:0]  fetch_word;
    reg            req_outstanding;
    reg [WORDS_PER_TILE*MEM_DATA_WIDTH-1:0] tile_buf; // oversized scratch, only low TILE_BITS used

    // Final-word tile assembly, selected at ELABORATION time
    // (WORDS_PER_TILE is a parameter) via generate -- avoids an
    // invalid zero/negative-width part-select on tile_buf when
    // WORDS_PER_TILE==1 (bus wider than one full tile: no "earlier
    // words" exist at all, the ternary-operator alternative would
    // still be elaborated structurally by most tools even though
    // never selected at runtime).
    wire [TILE_BITS-1:0] final_word_tile_data;
    generate
        if (WORDS_PER_TILE == 1) begin : GEN_ASSEMBLE_SINGLE
            assign final_word_tile_data = mem_rdata[TILE_BITS-1:0];
        end else begin : GEN_ASSEMBLE_MULTI
            // Yosys' Verilog frontend rejects a part-select applied
            // directly to a concatenation ({a,b}[msb:lsb]); Verilator
            // accepts it, but real synthesis requires an intermediate
            // signal instead.
            wire [WORDS_PER_TILE*MEM_DATA_WIDTH-1:0] assembled_full;
            assign assembled_full = {mem_rdata, tile_buf[(WORDS_PER_TILE-1)*MEM_DATA_WIDTH-1:0]};
            assign final_word_tile_data = assembled_full[TILE_BITS-1:0];
        end
    endgenerate

    wire [31:0] window_limit = {{(32-CNTW){1'b0}}, consumed_count} + PREFETCH_DISTANCE;
    wire more_to_fetch = job_active &&
                         ({{(16-CNTW){1'b0}}, fetch_tile} < n_tiles) &&
                         ({{(32-CNTW){1'b0}}, fetch_tile} < window_limit);

    always @(posedge clk) begin
        if (rst) begin
            fetch_tile      <= {CNTW{1'b0}};
            fetch_word      <= {WIW{1'b0}};
            ready_count     <= {CNTW{1'b0}};
            req_outstanding <= 1'b0;
            mem_req         <= 1'b0;
            wgt_fill_we     <= 1'b0;
        end else begin
            mem_req     <= 1'b0;
            wgt_fill_we <= 1'b0;

            if (!job_active) begin
                fetch_tile      <= {CNTW{1'b0}};
                fetch_word      <= {WIW{1'b0}};
                ready_count     <= {CNTW{1'b0}};
                req_outstanding <= 1'b0;
            end else if (mem_ready && req_outstanding) begin
                req_outstanding <= 1'b0;
                tile_buf[fetch_word*MEM_DATA_WIDTH +: MEM_DATA_WIDTH] <= mem_rdata;

                if (fetch_word == WORDS_PER_TILE[WIW-1:0] - 1'b1) begin
                    wgt_fill_we   <= 1'b1;
                    wgt_fill_addr <= fetch_tile[TIW-1:0];
                    wgt_fill_data <= final_word_tile_data;
                    ready_count   <= ready_count + 1'b1;
                    fetch_tile    <= fetch_tile + 1'b1;
                    fetch_word    <= {WIW{1'b0}};
                    if (({{(16-CNTW){1'b0}}, fetch_tile + 1'b1} < n_tiles) &&
                        ({{(32-CNTW){1'b0}}, fetch_tile + 1'b1} < window_limit)) begin
                        mem_req         <= 1'b1;
                        mem_addr        <= w_base + (fetch_tile + 1'b1) * TILE_BYTES[CNTW-1:0];
                        req_outstanding <= 1'b1;
                    end
                end else begin
                    fetch_word <= fetch_word + 1'b1;
                    mem_req         <= 1'b1;
                    // next word within the SAME tile (only reached when
                    // WORDS_PER_TILE>1, i.e. MEM_DATA_WIDTH<=TILE_BITS,
                    // where WORDS_PER_TILE*BYTES_PER_WORD==TILE_BYTES
                    // exactly -- no surplus/waste in that regime):
                    // byte offset = fetch_tile*TILE_BYTES + (fetch_word+1)*BYTES_PER_WORD
                    mem_addr        <= w_base + fetch_tile*TILE_BYTES[CNTW-1:0] +
                        ({{(CNTW-WIW){1'b0}}, fetch_word} + 1'b1) * BYTES_PER_WORD[CNTW-1:0];
                    req_outstanding <= 1'b1;
                end
            end else if (!req_outstanding && more_to_fetch) begin
                mem_req         <= 1'b1;
                mem_addr        <= w_base + fetch_tile*TILE_BYTES[CNTW-1:0];
                req_outstanding <= 1'b1;
            end
        end
    end

endmodule
