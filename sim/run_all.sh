#!/bin/bash
# ---------------------------------------------------------------------------
# GottFA80_PLuS / Pstore -- GHDL regression suite.
#
#   sh sim/run_all.sh              run every testbench, print a summary table
#   sh sim/run_all.sh tb_snd_wire  run one testbench (by the name in the table)
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
#   tb_sound_link  encodage des sons refait depuis. Le banc date de juin et
#                  attend « 0x80 | son » (son 5 -> 0x85). Le module a ete
#                  entierement repense depuis : file d'attente, et une carte
#                  d'octets ou 0x00-0x2F doit rester SANS EFFET -- un fil coupe
#                  se decode en 0x00 -- et ou un relachement de bus vaut 0x30.
#                  Le RTL est juste, le banc est perime. Reecrire ses attentes
#                  demande d'etablir la nouvelle carte d'octets en entier :
#                  c'est un travail de banc, pas une rustine.
# Fixing them means rewriting the expectations against the hardware-proven
# polarity; that is a testbench job, deliberately out of scope of the v1
# freeze, and doing it silently would hide the only two red lights in the run.
#
# ---------------------------------------------------------------------------
# ANTI-FAUX-VERT (2026-08-13).  `ghdl -r` returns 0 when it is stopped by
# --stop-time, so a testbench whose verdict sits past the stop time was scored
# PASS while executing zero checks.  That is exactly how tb_link_arb was green
# for weeks with --stop-time=50ms against a verdict at 3 sec.  Every run is now
# scanned for "stopped by --stop-time": a testbench that never reached its own
# end is reported CUT and counts as a failure, whatever ghdl returned.  The
# stop times below are therefore SAFETY NETS, not the end of the test -- every
# bench must terminate on its own.
# ---------------------------------------------------------------------------
cd "$(dirname "$0")/.." || exit 2
mkdir -p sim/work
LOG=sim/run_all.log
: > "$LOG"

KNOWN_BAD="tb_lisyctrl tb_integration tb_sound_link"
PASSED=""; FAILED=""; XFAILED=""; UNEXPECTED_PASS=""; CUTLIST=""

is_known_bad() { case " $KNOWN_BAD " in *" $1 "*) return 0;; *) return 1;; esac; }

# run_tb <entity> <stop-time> <ghdl-flags> <source files...>
#   LABEL=<x>    optional, consumed by the next call: name shown in the table
#                (needed when the same entity is run more than once)
#   RUNFLAGS=..  optional, consumed by the next call: flags given to `ghdl -r`
#                only -- generic overrides such as -gMODE=4
run_tb() {
    tb=$1; shift
    stop=$1; shift
    flags=$1; shift
    label=${LABEL:-$tb}; runflags=$RUNFLAGS; LABEL=""; RUNFLAGS=""
    [ -n "$ONLY" ] && [ "$ONLY" != "$label" ] && return 0
    printf '== %-20s ' "$label"
    tmp=$(mktemp)
    {
        echo "########## $label ##########"
        ghdl -a $flags "$@"                             && \
        ghdl -e $flags "$tb"                            && \
        ghdl -r $flags "$tb" $runflags --stop-time="$stop"
    } > "$tmp" 2>&1
    rc=$?
    cat "$tmp" >> "$LOG"
    cut=0
    if grep -q 'stopped by --stop-time' "$tmp"; then cut=1; rc=1; fi
    rm -f "$tmp"
    if [ $cut -eq 1 ]; then
        echo "FAIL  <-- COUPE par --stop-time=$stop, verdict jamais atteint"
        FAILED="$FAILED $label"; CUTLIST="$CUTLIST $label"
    elif [ $rc -eq 0 ]; then
        if is_known_bad "$label"; then
            echo "PASS  (was KNOWN-BAD -- update the KNOWN_BAD list)"
            UNEXPECTED_PASS="$UNEXPECTED_PASS $label"
        else
            echo "PASS"; PASSED="$PASSED $label"
        fi
    else
        if is_known_bad "$label"; then
            echo "FAIL  (KNOWN-BAD, pre-existing -- see header)"
            XFAILED="$XFAILED $label"
        else
            echo "FAIL  <-- regression"; FAILED="$FAILED $label"
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

# Bancs recuperes de la branche `lisyctrl` le 2026-08-28. Les modules qu'ils
# eprouvent etaient dans spartan6 depuis juillet, mais SANS banc : sept modules
# synthetises et jamais rejoues. Les durees d'arret viennent du lanceur
# d'origine ; l'ordre des sources est corrige -- `value_to_dispstr` instancie
# `bin_to_bcd`, que la declaration d'origine n'analysait pas avant lui.
run_tb tb_ay_3_8910        3ms  ""           lib_common/ay_3_8910.vhd sim/tb_ay_3_8910.vhd
run_tb tb_bin_to_bcd       1us  ""           lib_common/bin_to_bcd.vhd sim/tb_bin_to_bcd.vhd
run_tb tb_sound_link       2ms  ""           lib_common/sound_link.vhd sim/tb_sound_link.vhd
run_tb tb_tourney_block    1us  ""           lib_common/tourney_block.vhd sim/tb_tourney_block.vhd
run_tb tb_tourney_countdown 10us ""          lib_common/tourney_countdown.vhd sim/tb_tourney_countdown.vhd
run_tb tb_value_to_dispstr 1us  ""           lib_common/bin_to_bcd.vhd lib_common/value_to_dispstr.vhd sim/tb_value_to_dispstr.vhd
run_tb tb_tourney_display_top 20us ""        lib_common/bin_to_bcd.vhd lib_common/value_to_dispstr.vhd lib_common/tourney_countdown.vhd lib_common/tourney_display_top.vhd sim/tb_tourney_display_top.vhd

# ---------------------------------------------------------------------------
# tb_link_arb -- sound_link + ram_snoop, 1 simulated second = 1 second of real
# machine time, so each run is ~40 s of wall clock.  Three stimuli are run
# because each one, and only that one, was proven by mutation to catch a
# distinct defect (see the header of sim/tb_link_arb.vhd):
#   MODE=0  nominal        -- catches a corrupted snapshot payload
#                             (ram_snoop hi/lo nibble swap -> 1204/1280 wrong)
#   MODE=4  level flood    -- catches a dead LEVEL rate limit
#                             (lvl_hold <= 0 -> 29151 level tokens for a cap of 2182)
#   MODE=5  sound flood    -- catches a dead anti-starvation credit
#                             (starve override disabled -> 0 complete frame)
# MODE=1/2/3/6 exist and pass too; they are not automated because nothing was
# shown to slip past MODE 0/4/5.  Run them by hand with -gMODE=<n>.
# ---------------------------------------------------------------------------
LINK_ARB_SRC="lib_common/sound_link.vhd lib_common/ram_snoop.vhd sim/tb_link_arb.vhd"
run_tb tb_link_arb 4sec "" $LINK_ARB_SRC
LABEL=tb_link_arb_M4; RUNFLAGS=-gMODE=4
run_tb tb_link_arb 4sec "" $LINK_ARB_SRC
LABEL=tb_link_arb_M5; RUNFLAGS=-gMODE=5
run_tb tb_link_arb 4sec "" $LINK_ARB_SRC

# ---------------------------------------------------------------------------
# EQUIVALENCE megafonction Altera <-> memoire portable (lib_portable/).
# Each bench drives the ORIGINAL Cyclone-10 megafunction (library `orig`) and
# the portable rewrite with the same stimuli at the same instant and compares
# the outputs cycle by cycle.  They need three things the rest of the suite
# does not: the Quartus altera_mf simulation model, --std=93c, and
# -fsynopsys -fexplicit (without -fexplicit, altera_mf.vhd:31259 raises an
# overload ambiguity on ">=" that cascades into altsyncram).  They therefore
# get their own GHDL work directory -- units analysed with -fsynopsys must not
# be mixed with the rest of the suite.
# ---------------------------------------------------------------------------
AMF_SRC=/opt/quartus/quartus/eda/sim_lib
EQW=sim/work/equiv
EQFLAGS="--workdir=$EQW -P$EQW/amf -P$EQW/orig -fsynopsys -fexplicit --std=93c"
EQ_LIST="tb_riot_ram_equiv tb_SB_RAM_equiv tb_GAME_ROM_equiv tb_SYSTEM_ROM_equiv tb_R5101_equiv"

need_equiv() {
    [ -z "$ONLY" ] && return 0
    case " $EQ_LIST " in *" $ONLY "*) return 0;; *) return 1;; esac
}

if need_equiv; then
    printf '== %-20s ' "prep-equivalence"
    rm -rf "$EQW"; mkdir -p "$EQW/amf" "$EQW/orig"
    EQ_OK=1
    {
        echo "########## prep-equivalence ##########"
        ghdl -a --workdir=$EQW/amf --work=altera_mf -fsynopsys -fexplicit --std=93c \
             $AMF_SRC/altera_mf_components.vhd $AMF_SRC/altera_mf.vhd && \
        ghdl -a --workdir=$EQW/orig --work=orig -P$EQW/amf -fsynopsys -fexplicit --std=93c \
             lib_cyclone_10/RIOT_RAM.vhd lib_cyclone_10/SB_RAM.vhd lib_cyclone_10/GAME_ROM.vhd \
             lib_cyclone_10/SYSTEM_ROM.vhd lib_cyclone_10/R5101.vhd
    } >> "$LOG" 2>&1 || EQ_OK=0
    if [ $EQ_OK -eq 1 ]; then
        echo "OK    (bibliotheques altera_mf + orig construites)"
        run_tb tb_riot_ram_equiv   10ms "$EQFLAGS" lib_portable/RIOT_RAM.vhd   sim/tb_riot_ram_equiv.vhd
        run_tb tb_SB_RAM_equiv     10ms "$EQFLAGS" lib_portable/SB_RAM.vhd     sim/tb_SB_RAM_equiv.vhd
        run_tb tb_GAME_ROM_equiv   10ms "$EQFLAGS" lib_portable/GAME_ROM.vhd   sim/tb_GAME_ROM_equiv.vhd
        run_tb tb_SYSTEM_ROM_equiv 10ms "$EQFLAGS" lib_portable/SYSTEM_ROM.vhd sim/tb_SYSTEM_ROM_equiv.vhd
        run_tb tb_R5101_equiv      10ms "$EQFLAGS" lib_portable/R5101.vhd      sim/tb_R5101_equiv.vhd
    else
        echo "FAIL  <-- altera_mf/orig introuvables ($AMF_SRC) : les 5 bancs d equivalence NE SONT PAS joues"
        FAILED="$FAILED prep-equivalence"
    fi
fi

echo
echo "-----------------------------------------------------------------"
echo "PASS      :${PASSED:- none}"
echo "KNOWN-BAD :${XFAILED:- none}    (expected to fail, see header)"
echo "FAIL      :${FAILED:- none}"
[ -n "$CUTLIST" ] && echo "COUPES    :$CUTLIST   (--stop-time trop court : verdict jamais atteint)"
[ -n "$UNEXPECTED_PASS" ] && echo "NOTE      : known-bad now passing:$UNEXPECTED_PASS"
echo "comptages : grep -E 'comparaisons|verifications|octets' $LOG"
echo "full log  : $LOG"
echo "-----------------------------------------------------------------"
[ -z "$FAILED" ] || exit 1
exit 0
