# ============================================================
# V3 -- top-level pin/IOSTANDARD constraints for n2_system_ddr3_top.v,
# real xc7a100tcsg324-2, board is the user's own custom design (bare
# chip + DDR3, no dev board). DDR3 pins themselves are NOT here --
# those come from the MIG-generated mig_7series_0.xdc (dictated by
# the FPGA's internal DDR3 PHY hardware, not a free choice).
#
# Verified against the real device via a routed checkpoint query
# (open_checkpoint + get_package_pins/get_ports on n2_system_ddr3_
# top_routed.dcp), not guessed from a datasheet table.
# ============================================================

# ---- reserve the dedicated Master-SPI configuration-flash pins
# (bank 14) for a FUTURE external config flash -- prevents Vivado's
# auto-placement from ever landing one of THIS design's own ports on
# them (it already had, by accident, before this constraint existed:
# job_out_done on L13/FCS_B, a result bit on R16/RDWR_B, another on
# V15/CSI_B). These pins are not driven by this design at all; they
# stay free for the flash CCLK/D00_MOSI/D01_DIN/FCS_B/EMCCLK/RDWR_B/
# CSI_B wiring described in the accompanying configuration writeup.
set_property PROHIBIT true [get_package_pins {K17 K18 L13 L16 R16 V15}]

# ---- neural-processor management SPI (-> spi_host_bridge_v3.v):
# job submission + register file. Bank 15, column A/B (package edge,
# physically adjacent pins for short/easy PCB routing), well clear of
# both DDR3 (banks 34/35) and the reserved config-flash pins above.
# IOSTANDARD assumes bank 15 is powered at 3.3V on the custom board --
# change to match whatever VCCO the user's own power plan uses for
# that bank.
set_property PACKAGE_PIN A15 [get_ports sclk]
set_property PACKAGE_PIN B16 [get_ports mosi]
set_property PACKAGE_PIN B17 [get_ports miso]
set_property PACKAGE_PIN A16 [get_ports cs_n]
set_property IOSTANDARD LVCMOS33 [get_ports sclk]
set_property IOSTANDARD LVCMOS33 [get_ports mosi]
set_property IOSTANDARD LVCMOS33 [get_ports miso]
set_property IOSTANDARD LVCMOS33 [get_ports cs_n]

# ---- sys_rst: not part of the DDR3 MIG's own pin set (that's
# sys_rst too, but MIG's XDC only constrains the DDR3-facing timing,
# not necessarily IOSTANDARD for every board variant) -- pin left to
# auto-placement for now (low pin-count, no real board decision yet
# on where the reset source sits); explicitly constrain once the PCB
# layout for the reset circuit (button/supervisor IC) is decided.
