`timescale 1ns/1ps

// ================================================================
// CRC32_BYTE - combinational one-byte CRC32 update (IEEE 802.3 /
// zlib.crc32 algorithm: reflected polynomial 0xEDB88320, MSB-first
// byte order, init 0xFFFFFFFF, final XOR 0xFFFFFFFF applied by the
// CALLER when reading out the finished CRC, not baked in here so
// this block is a pure, reusable byte-update step).
//
// This exact reflected-polynomial bit-serial-per-byte construction
// is the standard, widely-documented way to compute the same CRC32
// zlib/PNG/Ethernet use; it is NOT re-derived from the flash
// subsystem's own design -- the independent oracle for this
// project is tools/flash_catalog/oracle.py's `crc32()`, which calls
// Python's stdlib `zlib.crc32` (a completely separate implementation
// in a different language). The two are cross-checked bit-for-bit
// by sim/crc32_tb.v -- see WORKLOG.md's F4 entry for the numbers.
//
// Usage: register `crc_out` into your own accumulator on the cycle
// a new byte is valid, seeded at 32'hFFFFFFFF before the first byte
// of a message; XOR the final accumulated value with 32'hFFFFFFFF
// to get the conventional CRC32 result.
// ================================================================

module crc32_byte (
    input  wire [31:0] crc_in,
    input  wire [7:0]  data,
    output wire [31:0] crc_out
);

    function [31:0] next_crc;
        input [31:0] c_in;
        input [7:0]  d;
        reg [31:0] c;
        integer k;
        begin
            c = c_in ^ {24'h0, d};
            for (k = 0; k < 8; k = k + 1) begin
                if (c[0])
                    c = (c >> 1) ^ 32'hEDB88320;
                else
                    c = c >> 1;
            end
            next_crc = c;
        end
    endfunction

    assign crc_out = next_crc(crc_in, data);

endmodule
