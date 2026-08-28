# Faisabilité — migration vers Spartan-6 XC6SLX9-2TQG144C

Branche `spartan6-feasibility`, ouverte depuis `eddf13b` (le freeze prouvé).
Étude du 2026-08-13.

## Pourquoi cette étude

Le 10CL006 se raréfie chez JLCPCB. Relevé du catalogue réel (base publique jlcparts,
898 références FPGA/CPLD) :

| référence | stock | prix à 10 | prix à 124+ | logique |
|---|---|---|---|---|
| **XC6SLX9-2TQG144C** | **2 237** | **6,83 $** | **5,66 $** | 9 152 cellules |
| EP4CE10E22C8N | 349 | 18,72 $ | 18,72 $ | 10 320 LE |
| EP4CE6E22C8N *(≡ 10CL006)* | 356 | 24,97 $ | 22,20 $ | 6 272 LE |

→ Le Spartan-6 est **3 à 4× moins cher** et **6× mieux approvisionné**.
Gowin : **0 référence** dans la catégorie FPGA de JLC — piste abandonnée.

## ✅ VERDICT : FAISABLE, et le périmètre est bien plus petit qu'annoncé

⚠️ Mon estimation initiale — « 60 `altsyncram`, 7 `altpll` » — était **fausse** : elle
comptait des lignes sur les deux bibliothèques et des déclarations dupliquées.

**Périmètre réel : 5 modules mémoire.** Tout le reste du design est du VHDL portable.

| module | géométrie | mode | difficulté |
|---|---|---|---|
| RIOT_RAM | 256 × 8 | simple port | ✅ **converti et validé** |
| SB_RAM | 128 × 8 | simple port | triviale |
| GAME_ROM | 2048 × 8 | simple port | triviale |
| SYSTEM_ROM | 8192 × 8 | simple port | triviale |
| R5101 | 256 × 4 | **bidirectionnel double port** | modérée |

**Trois bonnes nouvelles :**

1. **Aucune PLL.** `cpu_clk_gen.vhd` est un simple compteur diviseur, portable tel quel.
   L'`altpll` n'existe que dans `lib_cyclone_IV/`, non compilé par ce projet.
2. **Aucun fichier d'initialisation** (`.mif` / `.hex`). Les « ROM » n'en sont pas : ce
   sont des RAM que le chargeur SD/NOR remplit au démarrage. Or le format d'init des ROM
   est **le point le plus pénible** d'un changement de fondeur — il n'existe pas ici.
3. Les mémoires entrent par 5 entrées `QIP_FILE` du `.qsf` : le remplacement est local,
   fichier par fichier, sans toucher au reste.

## Preuve de concept — RIOT_RAM converti et compilé

`lib_portable/RIOT_RAM.vhd` : 47 lignes de VHDL inféré, **interface identique** à
l'original, donc aucun changement d'appel dans `SYS80.vhd`.

Sémantique reproduite fidèlement depuis les generiques de la mégafonction : sortie
**registrée** (`outdata_reg_a => CLOCK0`) et **écriture prioritaire**
(`read_during_write = NEW_DATA_NO_NBE_READ`) — d'où l'affectation de `data` à la sortie
quand `wren = '1'` ; lire la mémoire y rendrait l'ancienne valeur.

### 🚨 La simulation a trouvé un défaut que la synthèse ne voyait pas

Premier jet : ressources identiques, timing tenu — et **pourtant faux**. La simulation
d'équivalence (`sim/tb_riot_ram_equiv.vhd`, les deux versions côte à côte sous GHDL avec
la vraie `altera_mf` de Quartus) a rendu **2 540 divergences sur 2 580**, avec un motif
sans ambiguïté :

```
cycle 2569  orig=68    port=239
cycle 2570  orig=239   port=19      <- port(N) = orig(N+1)
```

**La version portable était en avance d'un cycle.** `altsyncram` avec
`outdata_reg_a => CLOCK0` a **deux** étages de registre — celui interne de la mémoire
plus celui de sortie — là où l'inféré n'en avait qu'un.

→ **Leçon : ressources identiques ≠ comportement identique.** Ce décalage d'un cycle
serait passé la synthèse, le timing, et aurait fait n'importe quoi sur la machine.
Aucune des deux vérifications de synthèse ne pouvait le voir.

### Résultat après correction (deuxième étage de registre)

| | mégafonction Altera | **VHDL inféré** |
|---|---|---|
| **équivalence simulée** | — | **2 324 comparaisons, 0 divergence** |
| LAB | 374 / 392 | 378 / 392 |
| éléments logiques | — | 4 802 / 6 272 (77 %) |
| bits mémoire | 113 712 | **113 712** |
| timing | CLOSED | **CLOSED** |

Couverture de la simulation : 256 lectures séquentielles, 32 cycles de
lecture-pendant-écriture (écriture prioritaire), 2 000 accès pseudo-aléatoires.
Coût du second étage : **4 LAB**. Les bits mémoire restent identiques — Quartus mappe
bien sur la mémoire bloc, sinon la logique aurait explosé en registres.

⚠️ **Piège de banc d'essai rencontré** : une première correction avait laissé le drapeau
de comparaison à `false`, et la simulation annonçait « 0 divergence » sur **0 comparaison**.
Un vert sans test est pire qu'un rouge. **Toujours vérifier le nombre de comparaisons.**

## 🧪 PROTOTYPE COMPLET — les 5 mémoires converties et simulées

### Équivalence prouvée sur les 5, sans exception

Chaque module a son banc d'essai (`sim/tb_*_equiv.vhd`) qui fait tourner **l'original et
la version portable côte à côte**, mêmes stimuli, avec la vraie `altera_mf` de Quartus
compilée sous GHDL.

| module | comparaisons | divergences |
|---|---|---|
| RIOT_RAM | 2 324 | **0** |
| SB_RAM | 2 196 | **0** |
| GAME_ROM | 4 116 | **0** |
| SYSTEM_ROM | 10 260 | **0** |
| R5101 *(double port, largeurs mixtes)* | 2 773 | **0** |
| **total** | **21 669** | **0** |

`R5101` confirme au passage la **convention des quartets** — le mot A d'adresse paire
occupe les bits de poids faible de l'octet B — qui était une hypothèse et qui est
désormais mesurée.

⚠️ Latences relevées, **différentes selon les modules** : `RIOT_RAM` et `SB_RAM` sont
en `outdata_reg_a => CLOCK0` donc **2 cycles** ; `GAME_ROM`, `SYSTEM_ROM` et `R5101` sont
`UNREGISTERED` donc **1 cycle**. Appliquer un patron unique aux cinq aurait réintroduit
le décalage d'un cycle sur trois d'entre elles.

### ❌ MAIS deux ne s'implémentent PAS en mémoire bloc

Build complet avec les 5 portables : **échec de placement**, 7 162 nœuds combinatoires
pour 6 272 disponibles. Diagnostic par le rapport de mapping : `GAME_ROM`, `SYSTEM_ROM`
et `RIOT_RAM` s'infèrent bien en `altsyncram`, mais **`SB_RAM` et `R5101` partent en
logique** — combinatoire de 4 772 à 7 162, registres de 2 364 à 3 181.

- **`SB_RAM`** : 1 024 bits seulement. Quartus **choisit** délibérément des bascules
  plutôt que de consacrer un bloc M9K entier à si peu. L'`altsyncram` d'origine, elle,
  forçait le bloc.
- **`R5101`** : double port à **largeurs mixtes** (256×4 d'un côté, 128×8 de l'autre).
  Structure que l'inférence ne sait pas reconnaître.

⚠️ **L'attribut `ramstyle => "M9K"` (plus `ram_style => "block"` pour Xilinx) n'a rien
changé** — vérifié sur une reconstruction complète `--clean`. Ce n'est donc pas un oubli
de directive mais une limite de l'inférence sur ces deux structures.

### ✅ État hybride retenu — 3 portables, 2 d'origine

| | avant | 3 mémoires portables |
|---|---|---|
| LAB | 374 / 392 | **368 / 392** |
| éléments logiques | — | 4 812 / 6 272 (77 %) |
| bits mémoire | 113 712 | **113 712** |
| timing | CLOSED | **CLOSED** |

C'est l'état laissé sur la branche : il **compile, tient le timing, et occupe 6 LAB de
moins** que l'original.

### Ce que ça change pour la migration

Le portage n'est donc **pas** intégralement mécanique : 3 mémoires sur 5 traversent sans
effort, 2 demandent un traitement.

### 🧪 Scission de R5101 : ESSAYÉE, ÉCHOUÉE

L'idée était de scinder en deux mémoires de **même largeur** — quartets pairs et impairs,
128×4 chacune — le port B lisant les deux en parallèle et le port A choisissant par le bit
de poids faible. Structure censée être plus banale, donc plus inférable.

Écrite (`lib_portable/R5101.vhd`, version scindée), **équivalence reconfirmée en
simulation** (2 773 comparaisons, 0 divergence), attributs `ramstyle`/`ram_style` posés
sur les deux tableaux. Résultat en synthèse :

| tentative | nœuds combinatoires | inférée en bloc ? |
|---|---|---|
| tableau unique 256×4 | 7 162 | non |
| **deux tableaux 128×4** | **7 277** | **non** |

**Pas d'amélioration, et même un peu pire.** Deux approches, deux échecs d'inférence.
Je n'en ai pas tenté une troisième à l'aveugle.

⚠️ **MAIS cet échec est mesuré sur le MAUVAIS outil.** La cible est le Spartan-6, donc
**ISE**, pas Quartus — et deux choses y diffèrent :
- l'inférence de mémoire n'obéit pas aux mêmes règles d'un synthétiseur à l'autre ;
- le Spartan-6 offre **9 152 cellules contre 6 272**, donc le surcoût en logique qui fait
  échouer le placement ici pourrait très bien y tenir.

→ **Conclusion honnête : le portage de `R5101` n'est ni prouvé possible ni prouvé
impossible.** Il faut le mesurer sur ISE. Tout le reste, si.

### Options si l'inférence échoue aussi sur ISE
1. **Accepter les deux en logique.** `SB_RAM` fait 1 024 bits (~128 LE) et `R5101` autant.
   Sur 9 152 cellules la place existe ; c'est un arbitrage, pas un blocage.
2. **Enrobage par fondeur** pour ces deux modules uniquement — le reste du design restant
   portable, on ne maintient que deux fichiers en double.
3. Instancier la primitive Xilinx `RAMB8BWER` directement pour `R5101`.

## 🎯 VERDICT MESURÉ SUR ISE — **LE DESIGN TIENT DANS LE XC6SLX9**

ISE 14.7 installé sur le VPS (9,8 Go), synthèse XST réelle du design complet avec les
**5 mémoires portables**, cible `6slx9tqg144-2`.

| ressource | optim. **vitesse** | optim. **surface** | disponible |
|---|---|---|---|
| **LUT** | 5 827 — **101 %** ❌ | **5 566 — 97 %** ✅ | 5 720 |
| registres | 2 803 — 24 % | 2 792 — **24 %** | 11 440 |
| E/S | 84 — 82 % | 84 — **82 %** | 102 |
| mémoire bloc | 9 — 28 % | 9 — **28 %** | 32 |
| BUFG | 2 — 12 % | 2 — 12 % | 16 |

**Le seul levier a suffi** : passer de `-opt_mode Speed -opt_level 1` à
`-opt_mode Area -opt_level 2` rend **261 LUT** et fait passer le design de 101 % à 97 %.

### Ce que ça confirme et ce que ça corrige

✅ **La saturation du Cyclone disparaît.** Registres à **24 %** contre 98 % de LAB sur
l'Altera — le problème de packing qui bloquait tout n'existe plus. Mémoire bloc à 28 %,
E/S à 82 % avec 18 broches libres.

⚠️ **Mais la marge en LUT est mince : 154 LUT, soit 3 %.** Mon estimation antérieure de
« 45 à 70 % » était **trop optimiste** — la réalité est 97 %. Les LUT sont, et resteront,
la ressource contrainte.

Leviers restants si besoin de place : `lisy_enable=false` (~522 LE côté Altera,
proportionnellement significatif ici), la duplication `ta_overlay`/`boot_message`, et les
3 copies inutilisées de `SPI_Master` dans le bloc EEprom.

### 🔧 Corrections de portabilité nécessaires pour XST

Quartus tolère qu'on associe une **partie** des bits d'un port vectoriel ; XST le refuse
(`ERROR:HDLCompiler:1346 - Not all partial formals of <port> have actual`). Trois cas dans
`SYS80.vhd`, tous corrigés en associant le port **entier** à un signal puis en extrayant
les bits utiles — comportement rigoureusement identique :

| ligne | port | était |
|---|---|---|
| 919 | `sn74175_Game_O.Qn` (4 bits) | `Qn(0)` seul |
| 1565 | `T65.A` (**24 bits**) | `A(15 downto 0)` seul |
| 1820 / 1829 | `sn74175.Q` (4 bits) | `Q(1)` / `Q(0)` seuls |

### Sur les deux mémoires récalcitrantes

`R5101` (version scindée) et `SB_RAM` partent en **RAM distribuée** chez XST, pas en
mémoire bloc — mais sur Spartan-6 la RAM distribuée coûte peu (28 LUT au total pour les
deux) et **le design tient quand même**. Le problème qui bloquait sur Quartus n'en est
donc pas un ici : il ne fallait pas le mesurer sur le mauvais outil.

## Ce qui reste à faire

1. **Convertir les 4 autres mémoires** — 3 triviales, `R5101` demande un double port
   bidirectionnel. Chacune se valide par le même critère : ressources et timing inchangés
   sur Quartus, avant même de parler de Xilinx.
2. **Brochage** : établir la correspondance des 84 E/S sur le XC6SLX9 (**102 E/S
   disponibles contre 89**, donc de la marge) et écrire le fichier de contraintes `.ucf`.
3. **Outillage** : ISE 14.7 (Windows/Linux, ~20 Go, abandonné depuis 2013 — Vivado ne
   supporte pas le Spartan-6). À installer sur le VPS.
4. **Configuration** : le Spartan-6 **n'a pas de flash interne** — prévoir une flash SPI
   et adapter la séquence de démarrage. C'est un composant de plus que sur un Gowin, mais
   la carte en a déjà une (`U1`, l'EPCS16).
5. **Niveaux** : 3,3 V max sur les E/S, comme le Cyclone. Les `74HCT240` / `244` de la
   carte porteuse font déjà l'adaptation 5 V — point neutre entre les deux.

## Stratégie recommandée

**Convertir les 5 mémoires d'abord, sur le Cyclone qui marche.**

Le travail se valide à chaque étape par un build Quartus, sans rien casser, et il vaut
**quel que soit** le fondeur retenu ensuite. Une fois fait, changer de FPGA devient un
travail de brochage et de contraintes — pas une réécriture.

C'est aussi l'assurance : si le Spartan se raréfie à son tour, on ne recommence pas.
