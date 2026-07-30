#!/bin/bash
# ---------------------------------------------------------------------------
# GottFA80_PLuS / Pstore -- GHDL regression suite.
#
#   sh sim/run_all.sh              run every testbench, print a summary table
#   sh sim/run_all.sh tb_snd_wire  run one testbench
#
# Exit code:  0 = no unexpected failure.  1 = a testbench that is supposed to
# pass did not.  The two entries marked KNOWN-BAD below are reported as such:
# they fail for a pre-existing, unrelated reason that has never been
# back-ported, and they do NOT make the suite red.  They are never skipped and
# never silenced -- their output is in the log like everybody else's.
#
# KNOWN-BAD (pre-existing, not a regression of the Pstore work):
#   tb_lisyctrl    coil idle polarity.  lisyctrl drives the coil port idle-HIGH
#                  (0xFF) because the real board inverts it -- proven on
#                  hardware, see MEMORY/lisyctrl_coil_idle_polarity.  The
#                  testbench still expects the pre-fix active-high encoding
#                  (exp=32/exp=0).  The RTL is right, the testbench is stale.
#   tb_integration same expectation, through sys80_glue.
# Fixing them means rewriting the expectations against the hardware-proven
# polarity; that is a testbench job, deliberately out of scope of the v1
# freeze, and doing it silently would hide the only two red lights in the run.
# ---------------------------------------------------------------------------
cd "$(dirname "$0")/.." || exit 2
mkdir -p sim/work
LOG=sim/run_all.log
: > "$LOG"

KNOWN_BAD="tb_lisyctrl tb_integration"
PASSED=""; FAILED=""; XFAILED=""; UNEXPECTED_PASS=""

is_known_bad() { case " $KNOWN_BAD " in *" $1 "*) return 0;; *) return 1;; esac; }

# run_tb <name> <stop-time> <ghdl-flags> <source files...>
run_tb() {
    tb=$1; shift
    stop=$1; shift
    flags=$1; shift
    [ -n "$ONLY" ] && [ "$ONLY" != "$tb" ] && return 0
    printf '== %-16s ' "$tb"
    {
        echo "########## $tb ##########"
        ghdl -a $flags "$@"        && \
        ghdl -e $flags "$tb"       && \
        ghdl -r $flags "$tb" --stop-time="$stop"
    } >> "$LOG" 2>&1
    rc=$?
    if [ $rc -eq 0 ]; then
        if is_known_bad "$tb"; then
            echo "PASS  (was KNOWN-BAD -- update the KNOWN_BAD list)"
            UNEXPECTED_PASS="$UNEXPECTED_PASS $tb"
        else
            echo "PASS"; PASSED="$PASSED $tb"
        fi
    else
        if is_known_bad "$tb"; then
            echo "FAIL  (KNOWN-BAD, pre-existing -- see header)"
            XFAILED="$XFAILED $tb"
        else
            echo "FAIL  <-- regression"; FAILED="$FAILED $tb"
        fi
    fi
}

ONLY=$1

run_tb tb_lisyctrl    5ms   ""           lib_common/spi_slave.vhd lib_common/lisyctrl.vhd sim/tb_lisyctrl.vhd
run_tb tb_nor_flash   10ms  ""           lib_common/SPI_Master.vhd lib_common/nor_flash.vhd sim/tb_nor_flash.vhd
run_tb tb_integration 20ms  ""           lib_common/spi_slave.vhd lib_common/lisyctrl.vhd sim/sys80_glue.vhd sim/tb_integration.vhd
run_tb tb_ta_overlay  200ms ""           lib_common/SN7448_GTB.vhd lib_common/ta_overlay.vhd lib_common/boot_message.vhd sim/tb_ta_overlay.vhd
# detect_sw.vhd uses std_logic_unsigned -> -fsynopsys is needed for -a, -e AND -r
run_tb tb_detect_sw   12sec "-fsynopsys" lib_common/detect_sw.vhd sim/tb_detect_sw.vhd
run_tb tb_gts_family  1ms   ""           lib_common/gts_family.vhd sim/tb_gts_family.vhd
run_tb tb_snd_wire    30ms  ""           lib_common/snd_bus.vhd lib_common/sound_link.vhd sim/sound_link_old.vhd sim/tb_snd_wire.vhd
run_tb tb_disp_inject 200ms ""           lib_common/disp_inject.vhd sim/tb_disp_inject.vhd
run_tb tb_link_arb    50ms  ""           lib_common/sound_link.vhd lib_common/ram_snoop.vhd sim/tb_link_arb.vhd

echo
echo "-----------------------------------------------------------------"
echo "PASS      :${PASSED:- none}"
echo "KNOWN-BAD :${XFAILED:- none}    (expected to fail, see header)"
echo "FAIL      :${FAILED:- none}"
[ -n "$UNEXPECTED_PASS" ] && echo "NOTE      : known-bad now passing:$UNEXPECTED_PASS"
echo "full log  : $LOG"
echo "-----------------------------------------------------------------"
[ -z "$FAILED" ] || exit 1
exit 0
