read_verilog -sv /home/michele/Develop/FPGA-Neural/hardware/v3/rtl/neural_director_packed.v
read_verilog -sv /home/michele/Develop/FPGA-Neural/hardware/v3/rtl/sdram_slot_arbiter2.v
read_verilog -sv /home/michele/Develop/FPGA-Neural/hardware/v2/nms/rtl/sdram_controller.v
read_verilog -sv /home/michele/Develop/FPGA-Neural/hardware/v3/rtl/packed_slot.v
read_verilog -sv /home/michele/Develop/FPGA-Neural/hardware/v2/rtl/layer_prefetch_ctrl.v
read_verilog -sv /home/michele/Develop/FPGA-Neural/hardware/v2/rtl/layer_weight_buffer.v
read_verilog -sv /home/michele/Develop/FPGA-Neural/hardware/v3/rtl/weight_tile_gather.v
read_verilog -sv /home/michele/Develop/FPGA-Neural/hardware/v3/rtl/neural_processor_packed.v
read_verilog -sv /home/michele/Develop/FPGA-Neural/hardware/v3/rtl/n2_system_top.v
synth_design -top n2_system_top -part xc7a100tcsg324-1 -mode out_of_context
create_clock -name clk -period 5.000 [get_ports clk]
opt_design
report_utilization -file /tmp/util_n2_system_postsynth.rpt
place_design
route_design
report_utilization -file /tmp/util_n2_system_postroute.rpt
report_timing_summary -file /tmp/timing_n2_system_postroute.rpt
write_checkpoint -force /tmp/n2_system_postroute.dcp
