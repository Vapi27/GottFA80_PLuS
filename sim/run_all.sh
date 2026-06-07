#!/bin/sh
# Run all GottFA80 testbenches with GHDL.  Usage:  sh sim/run_all.sh
set -e
cd "$(dirname "$0")/.."
echo "== lisyctrl =="
ghdl -a lib_common/spi_slave.vhd lib_common/lisyctrl.vhd sim/tb_lisyctrl.vhd
ghdl -e tb_lisyctrl
ghdl -r tb_lisyctrl --stop-time=5ms
echo "== nor_flash =="
ghdl -a lib_common/SPI_Master.vhd lib_common/nor_flash.vhd sim/tb_nor_flash.vhd
ghdl -e tb_nor_flash
ghdl -r tb_nor_flash --stop-time=10ms
echo "== integration (inout bus sharing) =="
ghdl -a lib_common/spi_slave.vhd lib_common/lisyctrl.vhd sim/sys80_glue.vhd sim/tb_integration.vhd
ghdl -e tb_integration
ghdl -r tb_integration --stop-time=20ms
echo "== ay_3_8910 (PSG for 80B / System 3) =="
ghdl -a lib_common/ay_3_8910.vhd sim/tb_ay_3_8910.vhd
ghdl -e tb_ay_3_8910
ghdl -r tb_ay_3_8910 --stop-time=3ms
echo "== sound_link (FPGA->ESP UART: sound# + game#) =="
ghdl -a lib_common/sound_link.vhd sim/tb_sound_link.vhd
ghdl -e tb_sound_link
ghdl -r tb_sound_link --stop-time=2ms
echo "== tourney_block (tournament-mode solenoid suppressor) =="
ghdl -a lib_common/tourney_block.vhd sim/tb_tourney_block.vhd
ghdl -e tb_tourney_block
ghdl -r tb_tourney_block --stop-time=1us
echo "== tourney_countdown (time-attack score timer) =="
ghdl -a lib_common/tourney_countdown.vhd sim/tb_tourney_countdown.vhd
ghdl -e tb_tourney_countdown
ghdl -r tb_tourney_countdown --stop-time=10us
echo "== bin_to_bcd (binary -> BCD for the display) =="
ghdl -a lib_common/bin_to_bcd.vhd sim/tb_bin_to_bcd.vhd
ghdl -e tb_bin_to_bcd
ghdl -r tb_bin_to_bcd --stop-time=1us
echo "== value_to_dispstr (countdown value -> 7-char display string) =="
ghdl -a lib_common/value_to_dispstr.vhd sim/tb_value_to_dispstr.vhd
ghdl -e tb_value_to_dispstr
ghdl -r tb_value_to_dispstr --stop-time=1us
echo "== tourney_display_top (full time-attack display subsystem) =="
ghdl -a lib_common/tourney_countdown.vhd lib_common/tourney_display_top.vhd sim/tb_tourney_display_top.vhd
ghdl -e tb_tourney_display_top
ghdl -r tb_tourney_display_top --stop-time=20us
echo "== disp_inject (ESP->FPGA display UART, option B) =="
ghdl -a lib_common/disp_inject.vhd sim/tb_disp_inject.vhd
ghdl -e tb_disp_inject
ghdl -r tb_disp_inject --stop-time=100us
echo "== ALL SIMS DONE =="
