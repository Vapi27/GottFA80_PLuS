# Installer ISE 14.7 sur le VPS — marche à suivre

Nécessaire pour mesurer si le design tient dans le **XC6SLX9** et si `R5101` s'infère en
mémoire bloc chez Xilinx. Vivado ne supporte pas le Spartan-6 : ISE 14.7 est le seul
chemin.

## ✅ Ce qui est déjà fait (VPS prêt)

| | |
|---|---|
| espace disque | **1,7 To libres** (ISE ≈ 30 Go installé) |
| système | Ubuntu 22.04.5 LTS, x86_64, 62 Go de RAM |
| dépendances | `libncurses5`, `libxi6`, `libxtst6`, `libgtk2.0-0`, `libcanberra-gtk-module`, `xterm` — **installées** |
| **`libXp.so.6`** | ✅ **résolue** — voir ci-dessous, c'était un piège réel |

### 🚨 Le piège `libXp.so.6` — signalé par [codepainters/ise14](https://github.com/codepainters/ise14)

> *« it is necessary to go so low for `libXp.so.6`. It disappears in Ubuntu 15.10, and
> 14.04 is the last LTS release including it. »*

Notre VPS est en **Ubuntu 22.04** : cette bibliothèque n'y existe plus et **n'est dans
aucun dépôt**. ISE aurait échoué après le téléchargement, sans rapport évident avec la
cause.

⚠️ Piège dans le piège : `ldconfig -p | grep libXp` **rend un résultat trompeur** — il
matche `libXpm.so.4`, qui est une tout autre bibliothèque. Chercher `libXp\.so`.

**Résolu sans Docker**, en extrayant la seule bibliothèque nécessaire des archives
Debian (le `.deb` refuse de s'installer, pré-dépendance multiarch incompatible) :
```bash
curl -O http://archive.debian.org/debian/pool/main/libx/libxp/libxp6_1.0.2-2_amd64.deb
dpkg-deb -x libxp6_1.0.2-2_amd64.deb xp
cp -a xp/usr/lib/x86_64-linux-gnu/libXp.so.6* /usr/local/lib/
echo /usr/local/lib > /etc/ld.so.conf.d/local-ise.conf && ldconfig
```
→ **Docker n'est donc pas nécessaire.** Le conteneur du dépôt vise l'usage graphique ;
nous n'avons besoin que de `xst`, `map`, `par` et `bitgen`, tous en ligne de commande.

## 🔑 Ce qui demande ton compte (je ne le ferai pas)

Je ne crée pas de compte et je ne saisis pas d'identifiants. Ces deux étapes sont les
tiennes.

### 1. Télécharger l'installeur Linux — 6,09 Go

<https://www.amd.com/en/support/downloads/adaptive-socs-and-fpgas/legacy-ise/14_7-windows.html>
→ choisir la version **Linux**, *ISE Design Suite 14.7 Full Installer for Linux*.
Un compte AMD/Xilinx (gratuit) est exigé pour le téléchargement.

Nom de fichier exact et empreinte à vérifier après téléchargement :
```
Xilinx_ISE_DS_Lin_14.7_1015_1.tar
sha1  4a1d86acd78854b039c88c429854612823942977
```

Puis le déposer sur le VPS :
```bash
scp Xilinx_ISE_DS_Lin_14.7_*.tar claude:/root/
```

### 2. Obtenir la licence WebPACK — gratuite et perpétuelle

Sur le portail de licences AMD, générer une **ISE WebPACK License**.
Elle couvre bien le **XC6SLX9**, et elle n'expire pas.

⚠️ **La licence est liée à une adresse MAC.** Celle du VPS est :

```
10:66:6a:03:d9:c5
```

C'est cette valeur qu'il faut donner au portail. Le fichier `.lic` reçu par courriel se
dépose ensuite ici :
```bash
scp Xilinx.lic claude:/root/.Xilinx/Xilinx.lic
```

🚨 **Risque à connaître** : le VPS est un conteneur, et rien ne garantit que sa MAC
survive à un redémarrage de l'hôte. Si elle change, la licence devient invalide et il faut
la régénérer. À vérifier après le premier redémarrage — et si la MAC s'avère instable, la
parade est de la figer côté hôte.

## Ce que je fais dès que les deux fichiers sont là

```bash
tar xf /root/Xilinx_ISE_DS_Lin_14.7_*.tar -C /root/
cd /root/Xilinx_ISE_DS_Lin_14.7_*/ && ./xsetup -b Batch -a XilinxEULA,3rdPartyEULA \
    -p "ISE WebPACK" -l /opt/Xilinx
```
Installation **en mode batch**, sans interface graphique — le VPS n'a pas de serveur X.

Puis, dans l'ordre :

1. **Porter le projet** : un `.xise` visant le `XC6SLX9-2TQG144C`, avec les 43 fichiers
   VHDL de `lib_common` + `SYS80.vhd` + les 5 mémoires portables.
2. **Mesurer** ce que la branche n'a pas pu trancher :
   - `R5101` et `SB_RAM` s'infèrent-elles en mémoire bloc chez Xilinx ?
   - le design entier tient-il dans les **9 152 cellules** du XC6SLX9 ?
3. **Contraintes** : écrire le `.ucf` à partir du brochage des 84 E/S
   (`devboard/src/BROCHAGE.md`), en profitant des **102 E/S** du Spartan contre 89.

## Rappel du contexte

L'étude sur Quartus a établi que 3 mémoires sur 5 se portent sans effort, et que
`SB_RAM` et `R5101` partent en logique — **mais c'est mesuré sur le mauvais outil**.
L'inférence mémoire diffère d'un synthétiseur à l'autre, et le Spartan-6 offre 46 % de
cellules en plus. Détail complet : `FAISABILITE_SPARTAN6.md`.
