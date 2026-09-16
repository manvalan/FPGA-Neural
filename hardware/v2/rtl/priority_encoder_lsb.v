`timescale 1ns/1ps

// ============================================================
// EXP-0056 -- generic, recursive binary-tree priority encoder
// (lowest-set-bit wins), O(log2(WIDTH)) depth.
//
// MOTIVATION: dependency_manager.v's own first_ready_idx scan (a
// serial for-loop overwriting a register variable across up to
// N_NODES=1024 iterations) is the SAME architectural anti-pattern
// already found and fixed twice elsewhere in this project (ERR-0027,
// neural_director.v's free-slot scan; ERR-0028, activation_fill_
// ctrl's max-tree; ERR-0029, sdram_unified_backend.v's W-cache hit-
// index) -- a data-dependent sequential overwrite that forces a
// SERIAL dependency chain across every iteration, even though the
// result does not logically require one. Those three fixes used a
// flat one-hot compare + single-level casez priority-encode, correct
// and efficient for their own small widths (4-8 entries). N_NODES can
// be up to 1024 in this project's own real configs -- a single flat
// casez at that width is impractical to hand-write and not guaranteed
// to synthesize as a balanced tree. This module generalizes the SAME
// underlying principle (no serial dependency chain) to arbitrary
// width via recursive halving: each half is encoded independently
// and in parallel (no dependency between them), and only the FINAL
// combine step (low_valid ? low_result : high_result) depends on
// both halves -- giving real O(log2(WIDTH)) depth instead of O(WIDTH).
//
// Semantics: idx = index of the LOWEST set bit in `in` (bit 0 has
// highest priority), valid = |in. This matches dependency_manager.v's
// own original scan exactly: it iterates ri from N_NODES-1 DOWN TO 0,
// unconditionally overwriting first_ready_idx on every match -- the
// LAST (i.e. lowest-index) match therefore wins, not the first one
// found during the loop's own execution order.
// ============================================================
module priority_encoder_lsb #(
    parameter WIDTH = 16,
    parameter IDXW  = (WIDTH <= 1) ? 1 : $clog2(WIDTH)
)(
    input  wire [WIDTH-1:0] in,
    output wire [IDXW-1:0]  idx,
    output wire             valid
);
    generate
        if (WIDTH <= 1) begin : GEN_BASE
            assign valid = in[0];
            assign idx   = {IDXW{1'b0}};
        end else begin : GEN_SPLIT
            localparam LOW_W     = WIDTH/2;
            localparam HIGH_W    = WIDTH - LOW_W;
            localparam LOW_IDXW  = (LOW_W  <= 1) ? 1 : $clog2(LOW_W);
            localparam HIGH_IDXW = (HIGH_W <= 1) ? 1 : $clog2(HIGH_W);

            wire [LOW_IDXW-1:0]  low_idx;
            wire                 low_valid;
            wire [HIGH_IDXW-1:0] high_idx;
            wire                 high_valid;

            priority_encoder_lsb #(.WIDTH(LOW_W)) u_low (
                .in(in[LOW_W-1:0]), .idx(low_idx), .valid(low_valid)
            );
            priority_encoder_lsb #(.WIDTH(HIGH_W)) u_high (
                .in(in[WIDTH-1:LOW_W]), .idx(high_idx), .valid(high_valid)
            );

            assign valid = low_valid | high_valid;
            assign idx   = low_valid
                ? {{(IDXW-LOW_IDXW){1'b0}}, low_idx}
                : ({{(IDXW-HIGH_IDXW){1'b0}}, high_idx} + LOW_W[IDXW-1:0]);
        end
    endgenerate
endmodule
