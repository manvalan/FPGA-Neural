read_verilog -sv /home/michele/Develop/FPGA-Neural/hardware/v3/rtl/neural_processor_packed.v
read_verilog -sv /home/michele/Develop/FPGA-Neural/hardware/v3/rtl/np_packed_array.v
synth_design -top np_packed_array -part xc7a100tcsg324-1 -mode out_of_context -generic N_CORES=8
create_clock -name clk -period 5.000 [get_ports clk]
opt_design
report_utilization -file /tmp/util_np_array_n8_postsynth.rpt
place_design
route_design
report_utilization -file /tmp/util_np_array_n8_postroute.rpt
report_timing_summary -file /tmp/timing_np_array_n8_postroute.rpt
write_checkpoint -force /tmp/np_array_n8_postroute.dcp
