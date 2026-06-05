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
echo "== ALL SIMS DONE =="
