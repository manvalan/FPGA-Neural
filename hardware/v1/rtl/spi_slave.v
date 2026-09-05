`timescale 1ns/1ps

// ================================================================
// SPI SLAVE - physical layer
//
// SPI Mode 0 (CPOL=0, CPHA=0), MSB-first, single SPI.
// Per docs/FPGA-NeuralNetwork-Engine.md §8.1: the FPGA is always
// SPI slave; one command per CS-low period.
//
// SCLK/MOSI/CS_N arrive from an external, clock-asynchronous SPI
// master, so they are double-flop synchronized into the `clk`
// domain before any edge detection. This module only implements
// the byte-level shift register and CS framing; opcode/protocol
// decoding lives in spi_engine.v.
//
// Mode 0 timing: MOSI is sampled on the RISING edge of SCLK; MISO
// is driven on the FALLING edge (so it is stable well before the
// master's next rising-edge sample).
// ================================================================

module spi_slave (
    input wire clk,
    input wire rst,

    // ------------------------------------------------------------
    // External SPI pins
    // ------------------------------------------------------------

    input  wire sclk,
    input  wire mosi,
    output reg  miso,
    input  wire cs_n,

    // ------------------------------------------------------------
    // Byte-level interface to spi_engine
    // ------------------------------------------------------------

    output reg  [7:0] rx_byte,
    output reg         rx_valid,   // one clk pulse: rx_byte is valid

    // IMPORTANT / load-bearing contract:
    // tx_byte_req is a PREFETCH hint, not a "byte consumed" event.
    // It fires once at cs_fell (to load byte 1) and once more after
    // EVERY byte's last bit (to have the next byte ready in time
    // for MISO, in case the master keeps clocking) -- including
    // after the LAST byte of a transaction, since the slave cannot
    // know in advance that no further byte will follow until CS
    // actually deasserts. A consumer MUST NOT treat tx_byte_req as
    // a destructive "advance/pop the next byte" trigger, or it will
    // over-advance by exactly one byte on every transaction (e.g.
    // over-incrementing a RAM read pointer). Use `rx_valid` instead
    // to advance any stateful pointer: it pulses exactly once per
    // REAL byte transferred, never an extra time, because it is
    // driven purely by counted SCLK edges that actually happened.
    input  wire [7:0] tx_byte,     // next byte to shift out on MISO
    output reg         tx_byte_req, // one clk pulse: refresh tx_byte now (prefetch hint, see above)

    output wire        cs_active,  // level: transaction in progress
    output reg          cs_start,   // one clk pulse: CS just went low
    output reg          cs_end      // one clk pulse: CS just went high
);

    // ============================================================
    // CDC SYNCHRONIZERS (double flip-flop)
    // ============================================================

    reg [2:0] sclk_sync;
    reg [2:0] mosi_sync;
    reg [2:0] cs_n_sync;

    always @(posedge clk) begin
        if (rst) begin
            sclk_sync <= 3'b000;
            mosi_sync <= 3'b000;
            cs_n_sync <= 3'b111;
        end else begin
            sclk_sync <= {sclk_sync[1:0], sclk};
            mosi_sync <= {mosi_sync[1:0], mosi};
            cs_n_sync <= {cs_n_sync[1:0], cs_n};
        end
    end

    wire sclk_s = sclk_sync[2];
    wire mosi_s = mosi_sync[2];
    wire cs_n_s = cs_n_sync[2];

    // Edge detects on the synchronized (2-deep) signal using one
    // extra history bit, so "rising"/"falling" mean the edge that
    // just became visible to `clk`.
    reg sclk_prev;
    reg cs_n_prev;

    always @(posedge clk) begin
        if (rst) begin
            sclk_prev <= 1'b0;
            cs_n_prev <= 1'b1;
        end else begin
            sclk_prev <= sclk_s;
            cs_n_prev <= cs_n_s;
        end
    end

    wire sclk_rise = sclk_s & ~sclk_prev;
    wire sclk_fall = ~sclk_s & sclk_prev;

    wire cs_fell = ~cs_n_s & cs_n_prev; // CS just went active (low)
    wire cs_rose = cs_n_s & ~cs_n_prev; // CS just went inactive (high)

    assign cs_active = ~cs_n_s;

    // ============================================================
    // BIT COUNTER / SHIFT REGISTERS
    // ============================================================

    reg [2:0] bit_count; // 0..7, counts bits received/sent within a byte
    reg [7:0] rx_shift;
    reg [7:0] tx_shift;

    always @(posedge clk) begin

        if (rst) begin

            bit_count   <= 3'd0;
            rx_shift    <= 8'h00;
            tx_shift    <= 8'h00;
            rx_byte     <= 8'h00;
            rx_valid    <= 1'b0;
            tx_byte_req <= 1'b0;
            miso        <= 1'b0;
            cs_start    <= 1'b0;
            cs_end      <= 1'b0;

        end else begin

            // ------------------------------------------------
            // Default pulses
            // ------------------------------------------------
            rx_valid    <= 1'b0;
            tx_byte_req <= 1'b0;
            cs_start    <= 1'b0;
            cs_end      <= 1'b0;

            if (cs_fell) begin

                // New transaction: reset bit counter, arm the
                // first tx byte load and pre-load MISO with its
                // MSB so it is valid before the first SCLK rise.
                bit_count   <= 3'd0;
                tx_shift    <= tx_byte;
                tx_byte_req <= 1'b1;
                miso        <= tx_byte[7];
                cs_start    <= 1'b1;

            end else if (cs_rose) begin

                cs_end <= 1'b1;

            end else if (cs_active) begin

                if (sclk_rise) begin

                    // Sample MOSI (mode 0: data valid on rising edge)
                    rx_shift <= {rx_shift[6:0], mosi_s};

                    if (bit_count == 3'd7) begin

                        bit_count <= 3'd0;
                        rx_byte   <= {rx_shift[6:0], mosi_s};
                        rx_valid  <= 1'b1;

                    end else begin

                        bit_count <= bit_count + 3'd1;

                    end

                end else if (sclk_fall) begin

                    // Drive next MISO bit (mode 0: output changes
                    // on the falling edge, ahead of the next
                    // master-side rising-edge sample).
                    if (bit_count == 3'd0) begin

                        // A byte boundary just completed on the
                        // matching rising edge above; load the
                        // next tx byte now.
                        tx_shift    <= tx_byte;
                        tx_byte_req <= 1'b1;
                        miso        <= tx_byte[7];

                    end else begin

                        tx_shift <= {tx_shift[6:0], 1'b0};
                        miso     <= tx_shift[6];

                    end

                end

            end

        end

    end

endmodule
