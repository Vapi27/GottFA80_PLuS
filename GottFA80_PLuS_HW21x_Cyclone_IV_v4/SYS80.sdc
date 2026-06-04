

#**************************************************************
# Time Information
#**************************************************************

set_time_format -unit ns -decimal_places 3



#**************************************************************
# Create Clock
#**************************************************************

create_clock -name {clk_50} -period 20.000 -waveform { 0.000 10.000 } [get_ports {clk_50}]

#**************************************************************
# Create Generated Clock
#**************************************************************

create_generated_clock -name {cpu_clk_out} -source [get_ports {clk_50}] -divide_by 56 -master_clock {clk_50} [get_registers {cpu_clk_gen:clock_gen|cpu_clk_out}] 


derive_pll_clocks -create_base_clocks

derive_clock_uncertainty
