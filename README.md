# GottFA80_PLuS — Pstore fork, ported to the Spartan-6 "Smart FA" module

VHDL replacement CPU board for **Gottlieb System 80 / 80A / 80B** pinball machines.
*(Version française : [`README.fr.md`](README.fr.md).)*

This repository is a **modified version of [bontango](https://github.com/bontango/GottFA80_PLuS)'s
GottFA80 / GottFA80_PLuS** (GPL v3+, [lisy.dev](https://www.lisy.dev)). The structure is his:
the `SYS80.vhd` top level, the memory map and address decode, the RIOTs, the display, lamps and
solenoids, `boot_message`, `read_the_dips`, `EEprom`, `SD_Card`, `GOSOF80` and its sound chain,
`attract`, the SN74xx models and the Quartus project. **Read [`NOTICE`](NOTICE)**: it attributes
the work file by file and states your rights if you receive a board or a bitstream.

## Which branch to read

| Branch | What it holds |
|---|---|
| **`spartan6-feasibility`** (default) | The Pstore work: the design ported to the **Xilinx Spartan-6 XC6SLX9** of the [Smart FA module](https://github.com/Vapi27/SmartFA), plus the modules listed below. Every bitstream on a shipped Smart FA board is built from this branch. |
| `main` | bontango's upstream, untouched (Cyclone 10 / Cyclone IV). |
| `lisyctrl` | The first diagnostic-bridge work on the Cyclone target (June 2026), superseded by the branch above. |

Related repositories: [**SmartFA**](https://github.com/Vapi27/SmartFA) (the module: schematics,
pinout, the ESP↔FPGA link), [**gottfa-esp32**](https://github.com/Vapi27/gottfa-esp32) (the
ESP32-S3 companion firmware this design talks to),
[esp-fpga-flasher](https://github.com/Vapi27/esp-fpga-flasher) (Cyclone configuration flash
programmed from an ESP32).

## What this fork adds

All of it written by Pstore, GPL-3 like the rest. In `lib_common/`:

| Module | Role |
|---|---|
| `nor_flash` | boots the game ROM from the module's SPI NOR (U6) instead of a microSD card |
| `lisyctrl`, `spi_slave` | LISYcontrol diagnostic bridge over the shared SPI bus: switches, coils, lamps, sound, 80B text, watchdog |
| `game_beacon` | FPGA → ESP status beacon: game number, family, 6502 alive, 80A/80B, as one atomic 4-byte frame |
| `sound_link` | sound commands and telemetry FPGA → ESP on one UART wire, arbitrated |
| `audio_uart` | 14-bit audio samples ESP → FPGA, summed with GOSOF80 before the single delta-sigma modulator |
| `ram_snoop` | periodic snapshot of the game RAM on the serial link (the "glass mirror") |
| `disp_inject` | display injection and the control line driven from the ESP |
| `disp80b_diag` | 80B alphanumeric display writer (10941 latch protocol) for diag mode |
| `gts_family` | System 80 / 80A / 80B decode from the game number, cross-checked against PinMAME |
| `snd_bus` | strobe-qualified sound-bus event extraction |
| `ta_overlay`, `tourney_*` | time-attack mode: a countdown on the display without stealing the score |
| `EEprom` (modified) | NVRAM save on the M95256 in **two alternating banks**, pointer written last |

And around it: `lib_portable/` (vendor-independent memory primitives — the reason one source
tree fits both Cyclone and Spartan), [`GottFA80_SLX9.ucf`](GottFA80_SLX9.ucf) (the Spartan-6
pin constraints), `construire_spartan6.sh` (the reproducible ISE build), `sim/` (GHDL
testbenches). In the top level: the System 80 display spy feeding the glass mirror, speech in
attract mode, and the P141 control line.

## Building

Spartan-6 target, Xilinx ISE 14.7 (installation notes: [`INSTALL_ISE.md`](INSTALL_ISE.md)):

```sh
sh construire_spartan6.sh /tmp/myfit "use_sd=false esp_sound=false hybrid=true"
```

> 🔴 **`use_sd=false` is not optional on the Smart FA module.** It has no SD card. Building
> with the source defaults gives a design that waits for an absent card, never releases
> `reset_l`, and leaves the board **completely silent** — while the configuration LED says
> it is programmed. Paid for twice.

Cyclone target: the Quartus project in `GottFA80_PLuS_HW21x_Cyclone_10/`.

### The generics that decide the behaviour

| Generic | Effect |
|---|---|
| `use_sd` | `true` = game ROM from the SD card; `false` = from the NOR U6 |
| `esp_sound` / `hybrid` | sound from the ESP, from `GOSOF80`, or both summed (`hybrid`, the shipped build) |
| `ctrl_line_en` | enables the P141 control line (see the warning below) |
| `bench_game` | forces a game number on the bench instead of reading the DIP switches |
| `lamp_snoop_en` | lamp spy — **leave at `false`**, see below |

## Measured on hardware

Each of these cost time; each is documented in the code at the exact place where it bites.

**The P141 control line accepted 1 ms.** One millisecond low was enough to assert
`lisy_active` — hold the 6502 in reset and hand the lamps to `lisyctrl`, which writes nothing.
A plain ESP reboot produces such a dip, and **opening the serial port reboots the ESP**: the
machine froze on every attempt to observe it. The threshold is 100 ms now. ⚠️ The prescaler
must stay a constant **distinct** from the threshold, or the 2 s arming becomes 200 s.

**A spy can sustain the fault it observes.** The lamp spy masked a valid fix for five
burns. It now sits under `generate` and defaults to `false`: it must cost nothing, in logic or
in trust, until somebody asks for it.

**The DIP switches are read at reset only.** Flipping one with the power on does nothing.

**`ram_snoop` offsets its reads** by +128 past index 384 to cover the 5101 at 512..767, so
frame index 640 reads `shadow(768)`.

**An `out` port cannot be read back** in VHDL: the internal signals `u5_pa_i` and `disp_seg_i`
exist for that.

## Documents

Most of these are in French. [`FAISABILITE_SPARTAN6.md`](FAISABILITE_SPARTAN6.md) (the
port), [`BUILD_VARIANTS.md`](BUILD_VARIANTS.md) (generic combinations, Cyclone era),
[`INSTALL_ISE.md`](INSTALL_ISE.md), [`LISYCTRL.md`](LISYCTRL.md) (the diagnostic protocol),
[`NOR_FLASH.md`](NOR_FLASH.md), [`SOUND_80B.md`](SOUND_80B.md).

Testbenches: `sh sim/run_all.sh` (GHDL).

## Licence

GNU GPL v3 or later, as upstream. If you receive a board or a bitstream built from this tree
you are entitled to the complete corresponding source — see [`NOTICE`](NOTICE), section
"OBLIGATIONS WHEN YOU SHIP THIS". Gottlieb game ROM images are not part of this repository
and never will be: the owner of a machine supplies their own dump.
