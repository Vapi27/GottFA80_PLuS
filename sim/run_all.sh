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
echo "== ta_overlay (time-attack display injection strobe map) =="
ghdl -a lib_common/SN7448_GTB.vhd lib_common/ta_overlay.vhd sim/tb_ta_overlay.vhd
ghdl -e tb_ta_overlay
ghdl -r tb_ta_overlay --stop-time=1ms
echo "== gts_family (System 80/80A/80B family decode, all 64 game numbers) =="
ghdl -a lib_common/gts_family.vhd sim/tb_gts_family.vhd
ghdl -e tb_gts_family
ghdl -r tb_gts_family --stop-time=1ms
echo "== ALL SIMS DONE =="
