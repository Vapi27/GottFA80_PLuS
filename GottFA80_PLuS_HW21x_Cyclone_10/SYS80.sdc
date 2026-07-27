

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

#**************************************************************
# Clock domain crossings
#**************************************************************
# disp_inject (clk_50) -> boot_message (cpu_clk_out, a divide-by-56 of clk_50).
#
# cpu_clk_out reaches its registers ~2.76 ns AFTER clk_50 reaches theirs (it is a
# register output on a global net, so it carries that much extra insertion delay).
# Any clk_50 -> cpu_clk_out data path with less than ~3 ns of routing therefore
# fails HOLD no matter what the logic does; whether a given path passes is pure
# placement luck.  The injected display string is exactly such a path and it has
# been in the design since the disp_inject build -- it happened to route long
# enough before and short enough now.
#
# Cutting it is correct rather than cosmetic: disp_inject publishes dreg ONLY when
# a complete 7-character frame has been received (it is double buffered precisely
# so a half-received string can never be presented), i.e. the bus is quasi-static
# for tens of milliseconds at a time, while boot_message re-reads it every 1.1 ms
# refresh slot.  There is no cycle-by-cycle relationship for the timing analyser to
# enforce.  Scope is deliberately narrow: this one source group to this one sink.
set_false_path -from [get_registers {disp_inject:DINJ|dreg[*][*]}] -to [get_registers {boot_message:BM|*}]
