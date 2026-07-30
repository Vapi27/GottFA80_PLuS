#!/usr/bin/env bash
# =============================================================================
# GottFA80_PLuS / Pstore -- reproducible FPGA build
# =============================================================================
# One script, one command, one set of artefacts with provenance.
#
#   ./build.sh                        release build, tag = git describe
#   ./build.sh -t rc2                 name the artefacts SYS80_rc2.*
#   ./build.sh -g disp80b_diag_enable=true
#   ./build.sh --clean --jic          scratch build, also emit the .jic
#   ./build.sh --no-sim               skip the GHDL regression run
#
# It fails, loudly and with a non-zero exit code, if ANY of these is not true:
#   * quartus_sh returns 0 and the flow reports "Successful"
#   * the Timing Analyzer ran and every multicorner worst-case slack is >= 0
#   * every requested artefact was actually produced and is non-empty
#   * (unless --no-sim) the GHDL suite reports no unexpected failure
#
# Everything it learns goes into  <outdir>/MANIFEST.txt : sha256 of each
# artefact, the git commit, the Quartus version, the generics actually used,
# the LE/LAB/memory figures and the timing slacks.  No artefact leaves this
# script without one.
#
# ARTEFACTS
#   SYS80_<tag>.sof   Quartus native.  Input to everything below.
#   SYS80_<tag>.svf   VOLATILE SRAM load over JTAG/XVC.  Lost at power-off.
#                     openFPGALoader --cable xvc-client --ip <esp> --port 2542 <f>.svf
#                     ^ MUST be .svf for SRAM: a .rbf reports "Done" and the
#                       design never starts.
#   SYS80_<tag>.rbf   PERMANENT EPCS burn, via the spiOverJtag bridge.
#                     caffeinate -dimsu openFPGALoader ... -f --verify <f>.rbf
#                     ^ wrap in caffeinate: a Mac sleeping mid-write leaves the
#                       EPCS half-programmed.
#   SYS80_<tag>.jic   (--jic) EPCS image for the Quartus programmer.
#
# NOTE the pinball must be POWERED OFF for none of this -- this script never
# touches the network or the hardware.  It is build-time only.
# =============================================================================
set -u
set -o pipefail

# ---------------------------------------------------------------- locations --
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
PROJ=SYS80
QSF="$HERE/$PROJ.qsf"
OUT="$HERE/output_files"

QUARTUS_BIN="${QUARTUS_BIN:-/opt/quartus/quartus/bin}"
[ -x "$QUARTUS_BIN/quartus_sh" ] || QUARTUS_BIN="$(dirname "$(command -v quartus_sh 2>/dev/null || echo /nonexistent/x)")"

# ------------------------------------------------------------------ options --
TAG=""; OUTDIR=""; DO_SVF=1; DO_RBF=1; DO_JIC=0; DO_CLEAN=0; DO_SIM=1
declare -a GENERICS=()

usage() { sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -t|--tag)      TAG="$2"; shift 2 ;;
    -o|--outdir)   OUTDIR="$2"; shift 2 ;;
    -g|--generic)  GENERICS+=("$2"); shift 2 ;;
    --jic)         DO_JIC=1; shift ;;
    --no-svf)      DO_SVF=0; shift ;;
    --no-rbf)      DO_RBF=0; shift ;;
    --no-sim)      DO_SIM=0; shift ;;
    -c|--clean)    DO_CLEAN=1; shift ;;
    -h|--help)     usage 0 ;;
    *) echo "build.sh: unknown option '$1'" >&2; usage 1 ;;
  esac
done

GEN_ARGS=""
for g in "${GENERICS[@]:-}"; do [ -n "$g" ] && GEN_ARGS="$GEN_ARGS -g $g"; done

die() { echo; echo "BUILD FAILED: $*" >&2; exit 1; }
step() { echo; echo "=== $* ==================================================" ; }

[ -x "$QUARTUS_BIN/quartus_sh" ] || die "quartus_sh not found (set QUARTUS_BIN=, currently '$QUARTUS_BIN')"
export PATH="$QUARTUS_BIN:$PATH"

# ------------------------------------------------------------- git identity --
cd "$REPO"
GIT_COMMIT="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
GIT_SHORT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
GIT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
GIT_DESCRIBE="$(git describe --tags --always --dirty 2>/dev/null || echo unknown)"
GIT_DIRTY_FILES="$(git status --porcelain 2>/dev/null | sed 's/^/                         /')"
if [ -n "$GIT_DIRTY_FILES" ]; then GIT_DIRTY="YES"; else GIT_DIRTY="no"; fi

[ -n "$TAG" ] || TAG="$GIT_DESCRIBE"
TAG="${TAG//\//_}"
[ -n "$OUTDIR" ] || OUTDIR="$REPO/artifacts/$TAG"
BASE="${PROJ}_${TAG}"

# --------------------------------------------------------- generics into QSF --
# Quartus takes top-level VHDL generics from the QSF as `set_parameter`.  They
# are written into a guarded block so the file stays diffable, and the block is
# restored to its default (empty) form on exit -- a non-default build must not
# leave the project silently reconfigured.
MARK_A="# >>> build.sh generics (auto-generated, do not edit) >>>"
MARK_B="# <<< build.sh generics <<<"
QSF_BACKUP="$(mktemp)"
cp "$QSF" "$QSF_BACKUP"
restore_qsf() { cp "$QSF_BACKUP" "$QSF"; rm -f "$QSF_BACKUP"; }
trap restore_qsf EXIT

{
  echo "$MARK_A"
  for g in "${GENERICS[@]:-}"; do
    [ -n "$g" ] || continue
    n="${g%%=*}"; v="${g#*=}"
    [ "$n" != "$g" ] || die "bad -g argument '$g' (want name=value)"
    echo "set_parameter -name $n $v"
  done
  echo "$MARK_B"
} >> "$QSF"

# generics as they will really be: the VHDL default unless overridden here
declare -A GEN_EFF
while read -r n v; do [ -n "$n" ] && GEN_EFF["$n"]="$v (VHDL default)"; done <<'EOF'
lisy_enable true
esp_sound true
hybrid false
disp80b_diag_enable false
EOF
for g in "${GENERICS[@]:-}"; do
  [ -n "$g" ] || continue
  GEN_EFF["${g%%=*}"]="${g#*=} (OVERRIDDEN on the command line)"
done

# ------------------------------------------------------------------- GHDL ----
SIM_RESULT="not run (--no-sim)"
if [ "$DO_SIM" = 1 ]; then
  if command -v ghdl >/dev/null 2>&1; then
    step "GHDL regression suite"
    SIM_OUT="$(bash "$REPO/sim/run_all.sh" 2>&1)"; SIM_RC=$?
    echo "$SIM_OUT"
    [ $SIM_RC -eq 0 ] || die "GHDL suite reported a REGRESSION (a testbench that should pass did not). See sim/run_all.log"
    SIM_RESULT="$(printf '%s\n' "$SIM_OUT" | grep -E '^(PASS|KNOWN-BAD|FAIL) ' | sed 's/  */ /g')"
    [ -n "$SIM_RESULT" ] || SIM_RESULT="no unexpected failure (see sim/run_all.log)"
  else
    SIM_RESULT="not run (ghdl not installed)"
    echo "WARNING: ghdl not found -- the RTL is going into a bitstream unsimulated." >&2
  fi
fi

# ------------------------------------------------------------------ compile --
cd "$HERE"
if [ "$DO_CLEAN" = 1 ]; then
  step "clean"
  rm -rf db incremental_db greybox_tmp
fi

step "Quartus compile ($PROJ)"
LOGDIR="$OUTDIR"
mkdir -p "$LOGDIR"
BUILD_LOG="$LOGDIR/${BASE}.build.log"
T0=$(date +%s)
quartus_sh --flow compile "$PROJ" > "$BUILD_LOG" 2>&1
RC=$?
T1=$(date +%s)
if [ $RC -ne 0 ]; then
  grep -iE "^(Error|Critical Warning)" "$BUILD_LOG" | head -20
  die "quartus_sh --flow compile returned $RC (full log: $BUILD_LOG)"
fi
grep -qE '^; Flow Status +; Successful' "$OUT/$PROJ.flow.rpt" \
  || die "the flow did not report Successful (see $OUT/$PROJ.flow.rpt)"
echo "compile OK in $((T1-T0))s"

# ------------------------------------------------------------ timing gate ----
# The gate is the Multicorner Timing Analysis Summary: one worst-case number per
# check across every operating corner and every clock.  Anything negative means
# the design did not close and the bitstream must not be shipped.
step "timing closure"
STA="$OUT/$PROJ.sta.rpt"
[ -f "$STA" ] || die "no Timing Analyzer report -- the flow did not run quartus_sta"

read -r T_SETUP T_HOLD T_RECOV T_REMOV T_MPW <<<"$(
  awk -F'[;]' '/Multicorner Timing Analysis Summary/{f=1}
       f && /^; Worst-case Slack/{gsub(/ /,"",$3);gsub(/ /,"",$4);gsub(/ /,"",$5);gsub(/ /,"",$6);gsub(/ /,"",$7);
                               print $3,$4,$5,$6,$7; exit}' "$STA"
)"
[ -n "${T_SETUP:-}" ] || die "could not parse the multicorner worst-case slack out of $STA"

TIMING_BAD=""
for pair in "setup:$T_SETUP" "hold:$T_HOLD" "recovery:$T_RECOV" "removal:$T_REMOV" "mpw:$T_MPW"; do
  k="${pair%%:*}"; v="${pair#*:}"
  case "$v" in ''|*[!0-9.eE+-]*) die "unparseable $k slack '$v' in $STA";; esac
  awk -v x="$v" 'BEGIN{exit !(x+0 < 0)}' && TIMING_BAD="$TIMING_BAD $k=$v"
  printf '  %-9s slack %s ns\n' "$k" "$v"
done
[ -z "$TIMING_BAD" ] || die "TIMING NOT CLOSED:$TIMING_BAD  (see $STA)"

# The design has no I/O timing model (no set_input_delay / set_output_delay).
# That is a real, pre-existing limitation, so it is recorded rather than hidden.
UNC_IN="$(awk -F';'  '/^; Unconstrained Input Ports  +;/{gsub(/ /,"",$3);print $3;exit}'  "$STA")"
UNC_OUT="$(awk -F';' '/^; Unconstrained Output Ports  +;/{gsub(/ /,"",$3);print $3;exit}' "$STA")"
UNC_CLK="$(awk -F';' '/^; Unconstrained Clocks  +;/{gsub(/ /,"",$3);print $3;exit}'       "$STA")"
echo "  unconstrained: clocks=${UNC_CLK:-?} inputs=${UNC_IN:-?} outputs=${UNC_OUT:-?}"
[ "${UNC_CLK:-0}" = "0" ] || die "there is an UNCONSTRAINED CLOCK -- the timing result above is meaningless"

# ------------------------------------------------------------- conversions ---
step "artefacts"
mkdir -p "$OUTDIR"
declare -a ARTS=()

cp "$OUT/$PROJ.sof" "$OUTDIR/$BASE.sof" || die "no .sof produced"
ARTS+=("$BASE.sof|Quartus native output; source of every file below")

if [ "$DO_SVF" = 1 ]; then
  quartus_cpf -c -q 6MHz -g 3.3 -n p "$OUT/$PROJ.sof" "$OUTDIR/$BASE.svf" >>"$BUILD_LOG" 2>&1 \
    || die "quartus_cpf (.svf) failed -- see $BUILD_LOG"
  ARTS+=("$BASE.svf|VOLATILE SRAM load over JTAG/XVC (openFPGALoader --cable xvc-client)")
fi
if [ "$DO_RBF" = 1 ]; then
  quartus_cpf -c "$OUT/$PROJ.sof" "$OUTDIR/$BASE.rbf" >>"$BUILD_LOG" 2>&1 \
    || die "quartus_cpf (.rbf) failed -- see $BUILD_LOG"
  ARTS+=("$BASE.rbf|PERMANENT EPCS burn via spiOverJtag (openFPGALoader -f --verify)")
fi
if [ "$DO_JIC" = 1 ]; then
  quartus_cpf -c -d EPCS16 -s 10CL006YE144C8G "$OUT/$PROJ.sof" "$OUTDIR/$BASE.jic" >>"$BUILD_LOG" 2>&1 \
    || die "quartus_cpf (.jic) failed -- see $BUILD_LOG"
  ARTS+=("$BASE.jic|EPCS16 image for the Quartus programmer")
fi

for a in "${ARTS[@]}"; do
  f="$OUTDIR/${a%%|*}"
  [ -s "$f" ] || die "artefact ${a%%|*} is missing or empty"
done

cp "$OUT/$PROJ.fit.summary" "$OUTDIR/$BASE.fit.summary" 2>/dev/null
cp "$OUT/$PROJ.sta.summary" "$OUTDIR/$BASE.sta.summary" 2>/dev/null

# ---------------------------------------------------------------- manifest ---
step "manifest"
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
        else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
fitline() { grep -m1 "$1" "$OUT/$PROJ.fit.summary" 2>/dev/null | sed 's/^[^:]*: *//'; }

LABS="$(grep -m1 'Total LABs:  partially or completely used' "$OUT/$PROJ.fit.rpt" \
        | awk -F';' '{gsub(/^ +| +$/,"",$3); print $3}')"
M9K="$(grep -m1 '^; M9Ks  ' "$OUT/$PROJ.fit.rpt" | awk -F';' '{gsub(/^ +| +$/,"",$3); print $3}')"
DEVICE="$(fitline 'Device ')"
FAMILY="$(fitline 'Family ')"
QVER="$(fitline 'Quartus Prime Version')"

MAN="$OUTDIR/MANIFEST.txt"
{
echo "GottFA80_PLuS / Pstore -- FPGA BUILD MANIFEST"
echo "============================================="
echo
echo "build.tag              : $TAG"
echo "build.utc              : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "build.host             : $(hostname)"
echo "build.duration_s       : $((T1-T0))"
echo "build.command          : build.sh -t $TAG $GEN_ARGS (svf=$DO_SVF rbf=$DO_RBF jic=$DO_JIC clean=$DO_CLEAN sim=$DO_SIM)"
echo
echo "source.git.commit      : $GIT_COMMIT"
echo "source.git.short       : $GIT_SHORT"
echo "source.git.branch      : $GIT_BRANCH"
echo "source.git.describe    : $GIT_DESCRIBE"
echo "source.git.dirty       : $GIT_DIRTY"
[ "$GIT_DIRTY" = "no" ] || { echo "source.git.dirty.files :"; echo "$GIT_DIRTY_FILES"; }
echo "source.qsf.sha256      : $(sha "$QSF_BACKUP")   (SYS80.qsf as committed, before the generics block)"
echo "source.sdc.sha256      : $(sha "$HERE/$PROJ.sdc")"
echo "source.top.sha256      : $(sha "$HERE/$PROJ.vhd")"
echo
echo "toolchain.quartus      : $QVER"
echo "toolchain.quartus.bin  : $QUARTUS_BIN"
echo "toolchain.ghdl         : $(ghdl --version 2>/dev/null | head -1 || echo 'not installed')"
echo
echo "generics (top-level VHDL, as actually compiled):"
for k in lisy_enable esp_sound hybrid disp80b_diag_enable; do
  printf '  %-22s : %s\n' "$k" "${GEN_EFF[$k]}"
done
echo
echo "device.family          : $FAMILY"
echo "device.part            : $DEVICE"
echo
echo "resources.logic_elements  : $(fitline 'Total logic elements')"
echo "resources.comb_functions  : $(fitline 'Total combinational functions')"
echo "resources.registers       : $(fitline 'Dedicated logic registers')"
echo "resources.labs            : ${LABS:-unknown}"
echo "resources.memory_bits     : $(fitline 'Total memory bits')"
echo "resources.m9k             : ${M9K:-see fit.rpt}"
echo "resources.pins            : $(fitline 'Total pins')"
echo "resources.plls            : $(fitline 'Total PLLs')"
echo
echo "timing.method             : Multicorner Timing Analysis Summary (Slow 85C, Slow 0C, Fast 0C)"
echo "timing.setup_slack_ns     : $T_SETUP"
echo "timing.hold_slack_ns      : $T_HOLD"
echo "timing.recovery_slack_ns  : $T_RECOV"
echo "timing.removal_slack_ns   : $T_REMOV"
echo "timing.mpw_slack_ns       : $T_MPW"
echo "timing.verdict            : CLOSED (every worst-case slack >= 0)"
echo "timing.unconstrained      : clocks=${UNC_CLK:-?} input_ports=${UNC_IN:-?} output_ports=${UNC_OUT:-?}"
echo "timing.caveat             : the SDC constrains the two CLOCKS only.  There is no"
echo "                            set_input_delay/set_output_delay, so the I/O paths"
echo "                            (switch matrix, display segments, SPI) are NOT timed"
echo "                            by this analysis.  They are slow, source-synchronous"
echo "                            1970s-era buses and have always worked on hardware,"
echo "                            but 'timing CLOSED' above means the INTERNAL logic"
echo "                            closed -- not the pins."
echo
echo "simulation.ghdl           :"
printf '  %s\n' "$SIM_RESULT" | sed 's/^/  /'
echo "                              (GHDL suite: sim/run_all.sh; full log sim/run_all.log.  The"
echo "                               two KNOWN-BAD entries are a stale coil-idle polarity"
echo "                               expectation in the testbench, not an RTL defect -- see the"
echo "                               header of sim/run_all.sh.)"
echo
echo "artifacts (sha256):"
for a in "${ARTS[@]}"; do
  n="${a%%|*}"; d="${a#*|}"
  printf '  %s  %10s  %s\n' "$(sha "$OUTDIR/$n")" "$(wc -c <"$OUTDIR/$n" | tr -d ' ')" "$n"
  printf '  %s              %s\n' "$(printf '%64s' '')" "$d"
done
echo
echo "reproducibility           : MEASURED, not assumed.  Established 2026-07-30 by"
echo "                            repeating this build (including --clean runs, and one run"
echo "                            from the PRE-freeze commit 291c042) and comparing bytes:"
echo "                              .rbf  byte-identical every time.  This is the raw"
echo "                                    configuration bitstream -- the only artefact whose"
echo "                                    content IS the logic.  Compare THIS to tell a real"
echo "                                    change from a re-run."
echo "                              .jic  byte-identical every time."
echo "                              .sof  NOT reproducible: it carries a build stamp.  Six"
echo "                                    bytes move; the configuration payload does not."
echo "                              .svf  NOT reproducible: its leading comment lines record"
echo "                                    the .sof path and the date.  Strip those and the"
echo "                                    payload is byte-identical  (grep -v '^!')."
echo
echo "verify with:  cd $(basename "$OUTDIR") && sha256sum -c SHA256SUMS"
} > "$MAN"

( cd "$OUTDIR" && for a in "${ARTS[@]}"; do n="${a%%|*}"; \
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$n"; else shasum -a 256 "$n"; fi; done > SHA256SUMS )

cat "$MAN"
echo
echo "=== BUILD OK -> $OUTDIR"
