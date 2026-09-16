read_verilog -sv /home/michele/Develop/FPGA-Neural/hardware/v2/rtl/layer_prefetch_ctrl.v
read_verilog -sv /home/michele/Develop/FPGA-Neural/hardware/v2/rtl/layer_weight_buffer.v
read_verilog -sv /home/michele/Develop/FPGA-Neural/hardware/v3/rtl/weight_tile_gather.v
read_verilog -sv /home/michele/Develop/FPGA-Neural/hardware/v3/rtl/neural_processor_packed.v
read_verilog -sv /home/michele/Develop/FPGA-Neural/hardware/v2/nms/rtl/sdram_controller.v
read_verilog -sv /home/michele/Develop/FPGA-Neural/hardware/v3/rtl/np_packed_weight_reuse_top.v
synth_design -top np_packed_weight_reuse_top -part xc7a100tcsg324-1 -mode out_of_context
create_clock -name clk -period 5.000 [get_ports clk]
opt_design
place_design
route_design
report_utilization -file /tmp/util_weight_reuse_top_postroute.rpt
report_timing_summary -file /tmp/timing_weight_reuse_top_postroute.rpt
write_checkpoint -force /tmp/weight_reuse_top_postroute.dcp
