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
echo "== ta_overlay (strobe map, cross-checked against boot_message AND PinMAME) =="
ghdl -a lib_common/SN7448_GTB.vhd lib_common/ta_overlay.vhd lib_common/boot_message.vhd sim/tb_ta_overlay.vhd
ghdl -e tb_ta_overlay
ghdl -r tb_ta_overlay --stop-time=200ms
echo "== detect_sw (short_push / long_push pulse contract) =="
# detect_sw.vhd uses std_logic_unsigned -> -fsynopsys is needed for -a, -e AND -r
ghdl -a -fsynopsys lib_common/detect_sw.vhd sim/tb_detect_sw.vhd
ghdl -e -fsynopsys tb_detect_sw
ghdl -r -fsynopsys tb_detect_sw --stop-time=12sec
echo "== gts_family (System 80/80A/80B family decode, all 64 game numbers) =="
ghdl -a lib_common/gts_family.vhd sim/tb_gts_family.vhd
ghdl -e tb_gts_family
ghdl -r tb_gts_family --stop-time=1ms
echo "== snd_wire (SOUND_WIRE contract: strobe qualification, FIFO, 0x30/0x31) =="
ghdl -a lib_common/snd_bus.vhd lib_common/sound_link.vhd sim/sound_link_old.vhd sim/tb_snd_wire.vhd
ghdl -e tb_snd_wire
ghdl -r tb_snd_wire --stop-time=30ms
echo "== ALL SIMS DONE =="
