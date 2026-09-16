`timescale 1ns/1ps

// ============================================================
// v3 (Artix-7 port) -- 2 INT8 MACs sharing one resident weight, packed
// into a single DSP48E1-shaped 25x18 multiply.
//
// Fits this project's own weight-stationary reuse architecture
// (layer_weight_buffer.v, EXP-0057/0058) exactly: one weight stays
// resident and is multiplied against MANY different activations
// (spatial reuse positions). This packs TWO of those activations
// (x0, x1) against the SAME shared weight into one multiply, instead
// of two separate DSP48 multiplies -- doubling effective MAC/DSP
// throughput for exactly this access pattern.
//
// Packing scheme (signed INT8 x0, x1, weight, all in [-128, 127]):
//   packed_a = (x1 <<< 16) + sign_extend(x0, 25)   (25 bits, matches
//              DSP48E1 port A width)
//   product  = packed_a * weight                    (33 bits here;
//              widens to 43 bits with a real 18-bit weight port on
//              actual DSP48E1 silicon)
//
// packed_a is built with a real ARITHMETIC add, not bit concatenation
// -- concatenating two independently sign-extended fields ({sext(x1,9),
// sext(x0,16)}) looks equivalent on paper but is NOT: whenever x0 is
// negative, its own two's-complement encoding contributes an extra
// +2^16 into the concatenated field's value that a real sum x1*2^16+x0
// does not have (found via exhaustive verification below -- an earlier
// concatenation-based version failed exactly 8,355,840 / 16,777,216
// vectors, all sharing x0<0). The explicit shift-and-add avoids this
// class of bug entirely by construction.
//
// Because x1's field sits at bit 16 (a multiple of 2^16), the low 16
// bits of `product` always equal x0*weight exactly, taken as signed
// (modular arithmetic: (x1<<16)*weight is a multiple of 2^16, so it
// never disturbs bits [15:0] of the sum). x0*weight's magnitude is at
// most 128*128=16384, safely inside signed 16-bit range
// (-32768..32767), so no truncation.
//
// Extracting x1*weight from the upper bits needs one correction: an
// arithmetic right-shift of `product` by 16 computes
// floor(product / 2^16), which is x1*weight - 1 (not exactly
// x1*weight) whenever the low-16-bit product (x0*weight) is negative
// -- the classic "borrow" of splitting one real two's-complement sum
// into two fields after the fact (concatenating BEFORE the multiply is
// exact by construction; recovering the two products AFTER a real
// multiply-and-add requires this one correction). Fixed by adding 1
// back whenever the low product's sign bit is set.
// ============================================================
module mac2_dsp_packed #(
    parameter DATA_WIDTH = 8
)(
    input  wire clk,
    input  wire rst,

    input  wire signed [DATA_WIDTH-1:0] weight,   // shared, resident
    input  wire signed [DATA_WIDTH-1:0] x0,
    input  wire signed [DATA_WIDTH-1:0] x1,
    input  wire                         valid_in,

    output reg  signed [2*DATA_WIDTH-1:0] p0,      // = x0 * weight, exact
    output reg  signed [2*DATA_WIDTH-1:0] p1,      // = x1 * weight, exact
    output reg                            valid_out
);
    localparam A_WIDTH = 3*DATA_WIDTH + 1; // 25 for DATA_WIDTH=8
    localparam PROD_WIDTH = A_WIDTH + DATA_WIDTH; // 43 for DATA_WIDTH=8

    wire signed [A_WIDTH-1:0] x0_sext25 = {{(A_WIDTH-DATA_WIDTH){x0[DATA_WIDTH-1]}}, x0};
    wire signed [A_WIDTH-1:0] x1_shifted = $signed(x1) <<< (2*DATA_WIDTH);

    wire signed [A_WIDTH-1:0] packed_a = x1_shifted + x0_sext25;

    wire signed [PROD_WIDTH-1:0] product = packed_a * weight;

    // NOTE: a Verilog part-select (product[hi:lo]) always yields an
    // UNSIGNED value regardless of the source's own `signed` keyword
    // (LRM rule -- part-selects are never signed) -- explicit $signed()
    // casts below are therefore load-bearing, not decorative: without
    // them the arithmetic right shift used to recover p1_raw would
    // truncate/zero-extend instead of sign-extending, corrupting every
    // case where x1*weight is negative (found via exhaustive
    // verification, tb_mac2_dsp_packed.v -- an earlier version without
    // these casts, and with an off-by-one in p1_raw's declared width,
    // failed ~50% of all 16,777,216 (weight,x0,x1) vectors).
    wire signed [2*DATA_WIDTH-1:0] p0_comb = product[2*DATA_WIDTH-1:0];
    wire signed [A_WIDTH+DATA_WIDTH-2*DATA_WIDTH-1:0] p1_raw = $signed(product) >>> (2*DATA_WIDTH);
    wire signed [2*DATA_WIDTH-1:0] p1_comb = p1_raw[2*DATA_WIDTH-1:0] + (p0_comb[2*DATA_WIDTH-1] ? 1'b1 : 1'b0);

    always @(posedge clk) begin
        if (rst) begin
            p0 <= {2*DATA_WIDTH{1'b0}};
            p1 <= {2*DATA_WIDTH{1'b0}};
            valid_out <= 1'b0;
        end else begin
            p0 <= p0_comb;
            p1 <= p1_comb;
            valid_out <= valid_in;
        end
    end
endmodule
