# GottFA80_PLuS — fork Pstore, porté sur Spartan-6

Carte CPU de remplacement pour les flippers **Gottlieb System 80 / 80A / 80B**, en VHDL.

Ce dépôt est une **version modifiée du travail de [bontango](https://github.com/bontango/GottFA80)**
(GottFA80 / GottFA80_PLuS, GPL v3+, [lisy.dev](https://www.lisy.dev)). L'essentiel de la
structure est la sienne : le haut niveau `SYS80.vhd`, la carte mémoire et le décodage
d'adresse, les RIOT, l'afficheur, les lampes et les bobines, `boot_message`,
`read_the_dips`, `EEprom`, `SD_Card`, `GOSOF80` et sa chaîne son, `attract`, les modèles
SN74xx et le projet Quartus. **Lire [`NOTICE`](NOTICE)** : l'attribution y est détaillée
fichier par fichier, ainsi que vos droits si vous recevez une carte ou un bitstream.

La branche `spartan6-feasibility` porte le design sur **Spartan-6 XC6SLX9** (module « Smart
FA ») en plus de la cible Cyclone d'origine. Voir [`FAISABILITE_SPARTAN6.md`](FAISABILITE_SPARTAN6.md).

## Ce que ce fork ajoute

Tout ce qui suit est écrit par Pstore et vit dans `lib_common/` :

| Module | Rôle |
|---|---|
| `game_beacon` | balise d'état du FPGA vers l'ESP : jeu, famille, vie du 6502, lampes écrites |
| `ram_snoop` | instantané périodique de la RAM du jeu, envoyé sur le lien série |
| `disp_inject` | injection d'affichage et ligne de contrôle depuis l'ESP |
| `sound_link` | codes son et télémétrie FPGA → ESP, avec arbitrage |
| `audio_uart` | échantillons audio ESP → FPGA, sommés avant l'unique modulateur |
| `disp80b_diag` | écriture de l'afficheur alphanumérique 80B (protocole à verrous 10941) |
| `ta_overlay`, `tourney_*` | mode time-attack : chrono sur l'afficheur sans voler le score |
| `EEprom` | sauvegarde NVRAM sur M95256, **deux bancs alternés**, pointeur écrit en dernier |

S'y ajoutent, dans le haut niveau : l'espion d'afficheur System 80 qui alimente le miroir du
verre, la voix dans l'attract, et la ligne de contrôle P141.

## Construire

Cible Spartan-6, chaîne ISE 14.7 :

```bash
sh construire_spartan6.sh /tmp/monfit "use_sd=false esp_sound=false hybrid=true"
```

> 🔴 **`use_sd=false` n'est pas optionnel sur le module Smart FA.** Il n'a pas de carte SD.
> Construire avec les défauts donne un design qui attend une SD absente, ne relâche **jamais**
> `reset_l`, et laisse la carte **totalement muette** — alors que la LED de configuration
> indique qu'elle est bien programmée. Piège payé deux fois.

Cible Cyclone : projet Quartus dans `GottFA80_PLuS_HW21x_Cyclone_10/`.

### Les generics qui décident du comportement

| Generic | Effet |
|---|---|
| `use_sd` | `true` = ROM depuis la carte SD ; `false` = depuis la NOR U6 |
| `esp_sound` / `hybrid` | son par l'ESP, par `GOSOF80`, ou les deux sommés |
| `ctrl_line_en` | active la ligne de contrôle P141 (voir l'avertissement ci-dessous) |
| `bench_game` | force un numéro de jeu au banc, au lieu de lire les DIP |
| `lamp_snoop_en` | espion de lampes — **laisser à `false`**, voir plus bas |

## Pièges mesurés sur matériel

Ils ont tous coûté du temps ; ils sont documentés dans le code, à l'endroit exact où ils
mordent.

**La ligne de contrôle P141 acceptait 1 ms.** Un niveau bas d'une milliseconde suffisait à
déclencher `lisy_active` — donc à tenir le 6502 en reset et à rendre les lampes à
`lisyctrl`, qui n'écrit rien. Or un simple redémarrage de l'ESP produit un tel creux, et
**ouvrir le port série redémarre l'ESP** : la machine se figeait à chaque tentative
d'observation. Le seuil est à 100 ms depuis. ⚠️ Le prescaler doit rester une constante
**distincte** du seuil, sans quoi l'armement de 2 s deviendrait 200 s.

**Un espion peut entretenir la panne qu'il observe.** L'espion de lampes a masqué un
correctif valable pendant cinq gravures. Il est désormais sous `generate` et à `false` par
défaut : il ne doit rien coûter, ni en logique ni en confiance, tant que personne ne l'a
demandé.

**Les DIP ne sont lus qu'au reset.** Changer un interrupteur sans couper l'alimentation ne
produit rien.

**`ram_snoop` translate ses lectures** de +128 au-delà de l'indice 384, pour couvrir la
5101 en 512..767. L'indice 640 de la trame lit donc `shadow(768)`.

**Un port `out` ne se relit pas** en VHDL : les signaux internes `u5_pa_i` et `disp_seg_i`
existent pour ça.

## Documents

[`FAISABILITE_SPARTAN6.md`](FAISABILITE_SPARTAN6.md) (le portage),
[`BUILD_VARIANTS.md`](BUILD_VARIANTS.md) (les combinaisons de generics),
[`INSTALL_ISE.md`](INSTALL_ISE.md), [`LISYCTRL.md`](LISYCTRL.md) (le protocole de
diagnostic), [`NOR_FLASH.md`](NOR_FLASH.md), [`SOUND_80B.md`](SOUND_80B.md).

Les bancs de test sont dans `sim/` (`sh sim/run_all.sh`).

## Licence

GNU GPL v3 ou ultérieure, comme l'amont. Si vous recevez une carte ou un bitstream construit
depuis cet arbre, vous avez droit au code source complet correspondant — voir
[`NOTICE`](NOTICE), section « OBLIGATIONS WHEN YOU SHIP THIS ».
