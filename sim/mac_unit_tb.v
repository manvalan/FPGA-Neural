`timescale 1ns/1ps

// ================================================================
// MAC_UNIT TESTBENCH (certification campaign, aspect C.1)
//
// rtl/mac_unit.v had NO dedicated unit-level testbench before this
// (docs/validation/00-inventario.md §0.4/§0.5): only indirect coverage
// through neuron_parallel_tb.v and friends, where acc_in is always
// hardwired to 0 by mac8.v and a bug isolated to this module would only
// surface if it happened to propagate visibly through the full layer.
//
// Oracle: tools/validation/mac_oracle.py, an independent Python
// reimplementation (two's complement from first principles, not a
// transcription of this RTL) -- see that file's own header. Vectors are
// pre-generated (tools/validation/mac_unit_vectors_*.hex) rather than
// computed at Verilog runtime, so the comparison at each step is purely
// mechanical (no chance of Verilog-side arithmetic accidentally
// re-deriving the same bug the oracle exists to catch).
//
// Coverage: EXHAUSTIVE on (x,w) at DATA_WIDTH=8 -- all 256*256=65536
// combinations, acc_in=0 (matches mac8.v's real usage). Plus a second,
// separate file exercising the module's own full port contract
// (acc_out = acc_in + product for ANY acc_in, not just the acc_in=0 case
// this design happens to use today) across boundary/random acc_in values
// including the four true product-magnitude corners
// (-128*-128, 127*127, -128*127, 127*-128).
// ================================================================

module tb;

    localparam DATA_WIDTH = 8;
    localparam ACC_WIDTH  = 32;

    reg  signed [DATA_WIDTH-1:0] x;
    reg  signed [DATA_WIDTH-1:0] w;
    reg  signed [ACC_WIDTH-1:0]  acc_in;
    wire signed [ACC_WIDTH-1:0]  acc_out;

    mac_unit #(.DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH)) dut (
        .x(x), .w(w), .acc_in(acc_in), .acc_out(acc_out)
    );

    // 80-bit packed vector: x[79:72] w[71:64] acc_in[63:32] expected[31:0]
    reg [79:0] exhaustive_vec [0:65535];
    reg [79:0] boundary_vec   [0:485];

    integer i;
    integer errors;
    integer checked;

    reg [7:0]  vx;
    reg [7:0]  vw;
    reg [31:0] vacc_in;
    reg [31:0] vexpected;

    task automatic check_one(input [79:0] packed_vec);
        begin
            vx        = packed_vec[79:72];
            vw        = packed_vec[71:64];
            vacc_in   = packed_vec[63:32];
            vexpected = packed_vec[31:0];
            x      = vx;
            w      = vw;
            acc_in = vacc_in;
            #1;
            checked = checked + 1;
            if (acc_out !== $signed(vexpected)) begin
                errors = errors + 1;
                if (errors <= 20) begin
                    $display("MISMATCH: x=%0d w=%0d acc_in=%0d -> got=%0d expected=%0d",
                        $signed(vx), $signed(vw), $signed(vacc_in), acc_out, $signed(vexpected));
                end
            end
        end
    endtask

    initial begin
        errors  = 0;
        checked = 0;

        $readmemh("tools/validation/mac_unit_vectors_exhaustive.hex", exhaustive_vec);
        $readmemh("tools/validation/mac_unit_vectors_boundary_accin.hex", boundary_vec);

        $display("--- TEST 1: exhaustive (x,w), acc_in=0 -- 65536 combinations ---");
        for (i = 0; i < 65536; i = i + 1) begin
            check_one(exhaustive_vec[i]);
        end
        $display("  checked %0d, errors so far %0d", checked, errors);

        $display("--- TEST 2: full port contract, boundary/random acc_in -- 486 vectors ---");
        for (i = 0; i < 486; i = i + 1) begin
            check_one(boundary_vec[i]);
        end
        $display("  checked %0d total, errors %0d", checked, errors);

        if (errors == 0) begin
            $display("ALL TESTS PASSED (%0d vectors, 0 mismatches against independent Python oracle)", checked);
        end else begin
            $display("FAILED: %0d/%0d vectors mismatched", errors, checked);
        end
        $finish;
    end

endmodule
