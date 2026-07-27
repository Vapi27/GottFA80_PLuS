

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
# cpu_clk_out is a divide-by-56 of clk_50 produced by a REGISTER (cpu_clk_gen)
# and distributed on a global net, so it reaches its own registers ~2.5-2.8 ns
# AFTER clk_50 reaches theirs.  Every clk_50 -> cpu_clk_out data path with less
# than about 3 ns of routing therefore fails HOLD no matter what the logic does;
# whether a given path passes is pure placement luck.
#
# WHAT ACTUALLY CROSSES.  Measured, not assumed -- with the exception removed,
# `report_timing -from_clock clk_50 -to_clock cpu_clk_out -hold` returns paths
# ending in exactly these registers:
#
#   (a) T65:U1|*                       CPU sampling GAME_ROM / RIOT_RAM / R5101
#   (b) R6532:U4_IO|*, U5_IO|*, U6_IO|*  RIOT internals, incl. nor_flash cpu_reset_l
#   (c) detect_sw:*|*, detect_sw_trigger:*|*   released from reset by game_running
#   (d) boot_message:BM|*              display data + `show`
#   (e) anti_thunk:AT|*                `is_active` = not game_running
#
# (a) and (b) are REAL synchronous logic -- the 6502 reading its own memory map
# and coming out of reset.  They must stay timed, which is why a blanket
# `set_false_path -from [get_clocks clk_50] -to [get_clocks cpu_clk_out]` would
# be wrong here; it would silently un-time the CPU bus.  (c) currently has
# +0.7 ns of hold slack and is left timed as well.
#
# (d) and (e) are the untimed crossing.  Both are display / lamp REFRESH data:
#   * boot_message's inputs are the injected string (disp_inject dreg, published
#     only when a complete 7-character frame has been received -- it is double
#     buffered precisely so a half-received string can never be presented), the
#     DIP-derived banner digits (byte_to_ascii, static after the DIP scan), and
#     the two level signals ta_arm (disp_inject ctrl_r[1] AND dval_i) and
#     game_running.  Everything is quasi-static for tens of milliseconds while
#     boot_message re-reads it every 1.1 ms refresh slot.
#   * anti_thunk's only clk_50 input is is_active = not game_running, a level
#     that transitions exactly once per power-up.
#   No endpoint in (d) or (e) has persistent state that a wrong or metastable
#   sample could corrupt: Din_Seg_A/B/C feed only the SN7448 decoders and the
#   segment pins, `count`/`bm_digit_strobe` are re-driven every refresh, and
#   anti_thunk is held in reset for good once game_running latches high.  A
#   per-bit 2-FF synchroniser would cost >100 registers (the string alone is 56
#   bits) for a bus where per-bit synchronisation does not even remove the real
#   hazard -- bit skew -- and would eat the LAB budget reserved for the 80B
#   alphanumeric back-end.  So these two destinations are cut, and nothing else.
#
# WHY -to A REGISTER SET AND NOT -from A REGISTER SET.  The previous exception
# was `-from disp_inject:DINJ|dreg[*][*] -to boot_message:BM|*`, i.e. scoped by
# SOURCE.  That missed every other clk_50 source feeding the same destinations:
# byte_to_ascii:CONV*|dig*_ascii[*] (worst remaining hold slack +0.574 ns),
# disp_inject:DINJ|ctrl_r[1] (+0.842) and disp_inject:DINJ|dval_i (+0.904) --
# all of them one placement away from the same failure the dreg[] paths hit.
# Scoping by DESTINATION and qualifying the SOURCE CLOCK is complete by
# construction: any clk_50-domain signal that is added to boot_message or
# anti_thunk in future is covered automatically, while cpu_clk_out -> same
# destination paths (boot_message's own counter, anti_thunk's own counter) stay
# fully timed because they do not launch from clk_50.
set_false_path -from [get_clocks {clk_50}] -to [get_registers {boot_message:BM|*}]
set_false_path -from [get_clocks {clk_50}] -to [get_registers {anti_thunk:AT|*}]
