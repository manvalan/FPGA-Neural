read_verilog -sv /home/michele/Develop/FPGA-Neural/hardware/v3/rtl/neural_processor_packed.v
synth_design -top neural_processor_packed -part xc7a100tcsg324-1 -mode out_of_context
create_clock -name clk -period 5.000 [get_ports clk]
opt_design
report_utilization -file /tmp/util_np_packed.rpt
report_timing_summary -file /tmp/timing_np_packed.rpt
report_timing -delay_type min_max -sort_by group -max_paths 5 -path_type full -file /tmp/timing_np_packed_paths.rpt

place_design
route_design
report_utilization -file /tmp/util_np_packed_postroute.rpt
report_timing_summary -file /tmp/timing_np_packed_postroute.rpt
report_timing -delay_type min_max -sort_by group -max_paths 5 -path_type full -file /tmp/timing_np_packed_postroute_paths.rpt
write_checkpoint -force /tmp/np_packed_postroute.dcp
