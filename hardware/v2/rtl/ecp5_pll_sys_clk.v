`timescale 1ns/1ps

// ================================================================
// FPGA-Neural V2 -- ECP5 PLL wrapper (STEP20, real clock architecture)
//
// 16 MHz board oscillator -> EHXPLLL -> 64 MHz system clock.
//
// Parameters below are the REAL, tool-generated output of Project
// Trellis's own `ecppll` utility (v1.4):
//   ecppll -i 16 --clkin_name=clk_16mhz -o 64 --clkout0_name=clk_sys \
//          -n ecp5_pll_16to64 -f pll_64.v
//   Refclk divisor: 1, Feedback divisor: 4, clkout0 divisor: 9
//   VCO frequency: 576 MHz (within the ECP5 PLL's documented
//   400-800MHz VCO range), clkout0 frequency: 64 MHz exactly
//   (16 * 4 / (1*... ) -- integer, zero-error ratio).
//
// 64MHz was chosen (not 80MHz) per this step's own real, multi-seed
// P&R timing data on the FINAL board-level top (SPI host bridge +
// host-arb SDRAM port added on top of the STEP19 compute+memory
// design): see hardware/v2/docs/TIMING.md for the full seed table.
// A single lucky seed reaching into the 80s MHz range is NOT treated
// as the operating frequency -- 64MHz is the highest frequency at
// which ALL measured seeds close timing with real margin.
//
// SIMULATION: EHXPLLL has no open, licensable behavioral model (Lattice
// ships it only inside their own encrypted simulation libraries), so
// this wrapper provides a behavioral bypass under `SIM` for iverilog
// and Verilator alike -- clk_sys tracks clk_16mhz directly and
// `locked` is tied high. This is a DECLARED simulation-only stand-in,
// not a claim that PLL lock timing has been simulated; real lock
// behavior is only characterized by nextpnr-ecp5 static timing and,
// eventually, real hardware bring-up (see FIRST_POWER_ON.md).
// ================================================================

module ecp5_pll_sys_clk (
    input  wire clk_16mhz,
    output wire clk_sys,
    output wire locked
);

`ifdef SIM

    assign clk_sys = clk_16mhz;
    assign locked  = 1'b1;

`else

    (* FREQUENCY_PIN_CLKI="16" *)
    (* FREQUENCY_PIN_CLKOP="64" *)
    (* ICP_CURRENT="12" *) (* LPF_RESISTOR="8" *) (* MFG_ENABLE_FILTEROPAMP="1" *) (* MFG_GMCREF_SEL="2" *)
    EHXPLLL #(
        .PLLRST_ENA("DISABLED"),
        .INTFB_WAKE("DISABLED"),
        .STDBY_ENABLE("DISABLED"),
        .DPHASE_SOURCE("DISABLED"),
        .OUTDIVIDER_MUXA("DIVA"),
        .OUTDIVIDER_MUXB("DIVB"),
        .OUTDIVIDER_MUXC("DIVC"),
        .OUTDIVIDER_MUXD("DIVD"),
        .CLKI_DIV(1),
        .CLKOP_ENABLE("ENABLED"),
        .CLKOP_DIV(9),
        .CLKOP_CPHASE(4),
        .CLKOP_FPHASE(0),
        .FEEDBK_PATH("CLKOP"),
        .CLKFB_DIV(4)
    ) pll_i (
        .RST(1'b0),
        .STDBY(1'b0),
        .CLKI(clk_16mhz),
        .CLKOP(clk_sys),
        .CLKFB(clk_sys),
        .CLKINTFB(),
        .PHASESEL0(1'b0),
        .PHASESEL1(1'b0),
        .PHASEDIR(1'b1),
        .PHASESTEP(1'b1),
        .PHASELOADREG(1'b1),
        .PLLWAKESYNC(1'b0),
        .ENCLKOP(1'b0),
        .LOCK(locked)
    );

`endif

endmodule
