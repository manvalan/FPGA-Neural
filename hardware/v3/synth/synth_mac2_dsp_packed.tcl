read_verilog -sv /home/michele/Develop/FPGA-Neural/hardware/v3/rtl/mac2_dsp_packed.v
synth_design -top mac2_dsp_packed -part xc7a100tcsg324-1 -mode out_of_context
report_utilization -file /tmp/util_mac2.rpt
report_timing_summary -file /tmp/timing_mac2.rpt
