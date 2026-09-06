`timescale 1ns/1ps

// ================================================================
// FPGA-Neural V2 -- reset synchronizer (STEP20, real reset/POR path)
//
// Standard async-assert / sync-deassert double-flop reset bridge.
// Asserts `rst` IMMEDIATELY (combinationally) when either the
// external POR/supervisor (ext_rst_n, active-low) is asserted OR the
// PLL has not yet reported LOCK -- both real, physical conditions
// under which no downstream logic (SDRAM controller, dependency
// manager, SPI bridge) may be considered valid. Deassertion is
// synchronized to `clk_sys` through two flip-flops so no downstream
// flop ever sees an asynchronous release edge.
// ================================================================

module reset_sync (
    input  wire clk_sys,
    input  wire ext_rst_n,   // external POR/supervisor, active-low
    input  wire pll_locked,
    output wire rst          // synchronous-deassert, active-high
);

    wire async_rst_n = ext_rst_n & pll_locked;

    reg [1:0] sync_ff;

    always @(posedge clk_sys or negedge async_rst_n) begin
        if (!async_rst_n) sync_ff <= 2'b00;
        else               sync_ff <= {sync_ff[0], 1'b1};
    end

    assign rst = ~sync_ff[1];

endmodule
