#!/bin/sh
# construire_spartan6.sh — SYS80 (GottFA80_PLuS) sur XC6SLX9, chaine ISE 14.7.
#
#   sh construire_spartan6.sh [repertoire] [generics...]
#   ex :  sh construire_spartan6.sh /tmp/fit_hybride "esp_sound=false hybrid=true"
#
# POURQUOI CE FICHIER EXISTE. Les bitstreams Spartan-6 livres jusqu'ici
# (gottfa-bitstreams/spartan6/*.svf) n'etaient reconstructibles par PERSONNE :
# aucun script ne les produit, et aucun .ucf n'est reference nulle part. Les
# generics reellement compiles sont donc inconnus -- or ce sont eux qui decident
# du chemin d'affichage, de la source du jeu et du mode son. Trou de tracabilite
# releve le 2026-09-04 ; ce script le ferme.
#
# LES CONTRAINTES viennent de gottfa-hw/pinout/GottFA80_SLX9.ucf, le seul fichier
# de brochage qui existe pour cette cible. Il n'etait, lui non plus, reference par
# aucun build.
#
# /!\ UnusedPin:Pulldown N'EST PAS UN DETAIL. Les broches non affectees sortent sur
#     les connecteurs. Sur le module Smart FA les grilles des MOSFET de bobines sont
#     actives au niveau HAUT : un Pullup les met sous tension. Couper l'alimentation
#     de puissance de toute facon, HSWAPEN etant tire a la masse.
#
# /!\ NE JAMAIS alimenter l'USB et P6 en meme temps : meme noeud +5 V, sans diode.
set -e
ISE=${ISE:-/opt/Xilinx/14.7/ISE_DS}
[ -f "$ISE/settings64.sh" ] && . "$ISE/settings64.sh" >/dev/null 2>&1 || true
X=$ISE/ISE/bin/lin64
[ -x "$X/xst" ] || { echo "ISE introuvable dans $ISE (poser ISE=...)"; exit 1; }

R=$(cd "$(dirname "$0")" && pwd)
D=${1:-/tmp/sys80_spartan}
GEN=${2:-}
UCF=${UCF:-$R/GottFA80_SLX9.ucf}
COMPOSANT=xc6slx9-2-tqg144
TOP=SYS80

[ -f "$UCF" ] || { echo "brochage introuvable : $UCF"; exit 1; }
rm -rf "$D"; mkdir -p "$D/xst/projnav.tmp"
cp "$UCF" "$D/$TOP.ucf"
echo "   generics : ${GEN:-(defauts du source)}"

# --- sources -------------------------------------------------------------------
# ⚠️ LA LISTE VIENT DU .QSF, PAS D'UN GLOB DU REPERTOIRE, et c'est la seule facon
#    correcte : lib_common contient des fichiers qui ne font PAS partie du design
#    et qui ne compilent meme pas (boot_message_80B.vhd, par exemple, reference
#    des signaux inexistants). Un `ls lib_common/*.vhd` les ramasse et le build
#    echoue sur du code mort -- piege paye le 2026-09-04. Le .qsf est la liste que
#    Quartus construit reellement : on batit le MEME design.
QSF="$R/GottFA80_PLuS_HW21x_Cyclone_10/SYS80.qsf"
[ -f "$QSF" ] || { echo "projet Quartus introuvable : $QSF"; exit 1; }

# Le paquet T65 D'ABORD (les autres unites l'utilisent), puis les memoires
# PORTABLES -- surtout pas lib_cyclone_10, qui instancie des primitives Altera.
# R5101 et SB_RAM ne sont PAS dans la liste VHDL_FILE : cote Quartus ils arrivent
# par les .qip de lib_cyclone_10. Ici on prend leurs equivalents portables.
: > "$D/p.prj"
for f in lib_common/T65/T65_Pack.vhd \
         lib_portable/GAME_ROM.vhd lib_portable/SYSTEM_ROM.vhd \
         lib_portable/RIOT_RAM.vhd lib_portable/R5101.vhd lib_portable/SB_RAM.vhd
do echo "vhdl work \"$R/$f\"" >> "$D/p.prj"; done

grep -oE 'VHDL_FILE [^ ]+' "$QSF" | sed 's/VHDL_FILE //; s/"//g; s|^\.\./||' | while read -r f; do
  case "$f" in
    */T65_Pack.vhd) continue ;;                       # deja pose en tete
    SYS80.vhd)      continue ;;                       # pose en dernier
    lib_cyclone*)   continue ;;                       # primitives Altera : jamais ici
  esac
  [ -f "$R/$f" ] && echo "vhdl work \"$R/$f\"" >> "$D/p.prj"
done
# ⚠️ LE .QSF EST AUTORITAIRE MAIS IL ROUILLE. `game_beacon.vhd` a ete ajoute au RTL
#    (commit ba94eed) et instancie dans SYS80 SANS etre declare dans le projet
#    Quartus : le build s'arretait sur « Cannot find <game_beacon> in library
#    <work> ». Plutot que de rattraper a la main a chaque fois, on RESOUT les
#    entites reellement instanciees. Un fichier ajoute au RTL et oublie dans le
#    .qsf ne cassera donc plus ce build -- et l'ecart est signale, parce qu'il
#    veut dire que le projet Quartus, lui, est incomplet.
for e in $(cat "$R/GottFA80_PLuS_HW21x_Cyclone_10/SYS80.vhd" "$R"/lib_common/*.vhd 2>/dev/null \
           | grep -oiE 'entity[[:space:]]+work\.[A-Za-z0-9_]+' \
           | sed 's/.*\.//' | tr 'A-Z' 'a-z' | sort -u); do
  for cand in "lib_common/$e.vhd" "lib_common/T65/$e.vhd" "lib_portable/$e.vhd"; do
    real=$(cd "$R" && ls $(dirname "$cand")/*.vhd 2>/dev/null | while read -r p; do
             b=$(basename "$p" .vhd); [ "$(echo "$b" | tr 'A-Z' 'a-z')" = "$e" ] && echo "$p"; done | head -1)
    if [ -n "$real" ] && ! grep -qi "/$(basename "$real")\"" "$D/p.prj"; then
      echo "vhdl work \"$R/$real\"" >> "$D/p.prj"
      echo "   + $real (instancie mais ABSENT du .qsf)"
    fi
  done
done
echo "vhdl work \"$R/GottFA80_PLuS_HW21x_Cyclone_10/SYS80.vhd\"" >> "$D/p.prj"
echo "   sources : $(wc -l < "$D/p.prj") (liste du .qsf + memoires portables + entites resolues)"

cat > "$D/p.xst" <<FIN
set -tmpdir "$D/xst/projnav.tmp"
set -xsthdpdir "$D/xst"
run
-ifn $D/p.prj
-ofn $TOP
-ofmt NGC
-p $COMPOSANT
-top $TOP
-opt_mode Speed
-opt_level 1
-ifmt mixed
-iobuf YES
FIN
[ -n "$GEN" ] && echo "-generics {$GEN}" >> "$D/p.xst"

cd "$D"
echo "== 1/5 synthese (xst) =="
$X/xst -intstyle silent -ifn p.xst -ofn $TOP.syr > xst.log 2>&1 || true
if grep -qE '^ERROR' $TOP.syr xst.log 2>/dev/null; then
  echo "XST : erreurs, ARRET"; grep -hE '^ERROR' $TOP.syr xst.log | head -15; exit 1
fi
echo "   synthese : $(grep -oE 'Number of Slice LUTs: *[0-9,]+' $TOP.syr | head -1 | grep -oE '[0-9,]+$') LUT (estimation)"

echo "== 2/5 ngdbuild =="
$X/ngdbuild -intstyle silent -p $COMPOSANT -uc $TOP.ucf $TOP.ngc $TOP.ngd > ngd.log 2>&1 || {
  echo "NGDBUILD a echoue :"; grep -E "^ERROR" ngd.log | head -12; exit 1; }

echo "== 3/5 map =="
$X/map -intstyle silent -p $COMPOSANT -detail -pr b -w -o m.ncd $TOP.ngd $TOP.pcf > map.log 2>&1 || {
  echo "MAP a echoue :"; grep -E "^ERROR" map.log m.mrp 2>/dev/null | head -12; exit 1; }

echo "== 4/5 par (placement-routage) =="
$X/par -w -intstyle silent m.ncd $TOP.ncd $TOP.pcf > par.log 2>&1 || {
  echo "PAR a echoue :"; grep -E "^ERROR" par.log | head -12; exit 1; }

echo "== 5/5 timing =="
$X/trce -intstyle silent -v 10 $TOP.ncd $TOP.pcf -o $TOP.twr > trce.log 2>&1 || true
grep -m1 -E "All constraints were met|constraints were not met" $TOP.par | sed 's/^/   /' || true

echo
echo "== OCCUPATION REELLE, APRES PLACEMENT (pas l'estimation de synthese) =="
grep -E "Slice Registers|Slice LUTs|occupied Slices|RAMB(8|16)BWER|bonded IOB|DSP48" m.mrp | head -10
echo
echo "   repertoire : $D"
