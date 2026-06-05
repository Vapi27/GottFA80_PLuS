# System 80B sound on GottFA80_PLuS — analysis + roadmap

## Where it stands
GOSOF80 emulates the System 80/80A sound boards (a 6502 + RIOT + sound ROMs + DAC +
SC-01 speech) plus an MP3/DFPlayer path for speech/samples. Per lisy.dev, integrated
sound currently works for **3 early 80B games** (Bounty Hunter, Chicago Cubs Triple
Play, Tag Team); the rest of System 80B is **work in progress** (bontango).

## ✅ Decision: GOSOWAV (WAV samples) — the 10CL006-viable path
The faithful-emulation route (below) does **not** fit the 10CL006 (see the fit
constraint). The route that DOES fit is **GOSOWAV** — bontango's existing WAV-trigger
sound board: it plays recorded WAV samples selected by the MPU's sound command, so it
needs **no chip emulation**. "Make 80B sound work" then = capture the command + map
each command to a sample (per game).

**RE of the original boards** (from PinMAME `gts80s.c` / `gts80.c`, bundled in
`lisy_5_28/src/wpc`):
- **The MPU sound command is 5-bit** (a nibble + 1 bit), strobed — `gts80.c`
  `GTS80_sndCmd_w` and the `SNDBRD_GTS80B` encoding `(lampMatrix[0]&0x10) | (data&0x0f)`.
  GottFA80 **already captures this** as `Sound_Meta` (S1,S2,S4,S8,S16) — the same 5
  lines for 80/80A and 80B. So the command capture is essentially done.
- **80B sound board** = 2× 6502 + DAC + speech (**SP0250**, Gen-1) + a music chip that
  is **AY-8913 / AY-3-8912** (some gens) **or YM2151** (later gens); 3 generations +
  an extra DAC board for Bone Busters.
- The per-game richness is the board's own ROM/CPU turning 32 commands into many
  sounds/sequences — for GOSOWAV that's a **per-game command→WAV table + the samples**.

**Remaining work for the GOSOWAV path:** (a) per-game WAV sample sets — which can be
**rendered by PinMAME itself** (it emulates these boards, right here in `lisy_5_28`) by
capturing each command's audio; (b) the GOSOWAV player (bontango's board, or a light
FPGA/ESP WAV mixer); (c) the per-game command→sample map. **Almost no new FPGA logic,
and it fits the 10CL006.**

> The `ay_3_8910.vhd` core in this repo is therefore for the **faithful** route only
> (an AY-based 80B generation or System 3, on a *bigger* FPGA). It's validated and
> reusable, but the GOSOWAV path on the 10CL006 does not need it.

## Why the late 80B board is hard
The later System 80B "Sound & Speech" board is a dual-processor design:
**2× 6502, 2× AY-3-8912 PSG, an "Orator" speech chip, and a DAC.** GOSOF80 has no
AY-3-89xx core, so the synthesized music/effects of those games can't be produced by
emulation yet.

## What this adds: a validated AY-3-8910/8912 core
`lib_common/ay_3_8910.vhd` — a clean GPL-3.0 PSG core: 3 tone channels, noise
(17-bit LFSR), envelope (all 8 shapes), per-channel mixer, 4-bit logarithmic
amplitude DAC, and a summed audio output. Self-checked by `sim/tb_ay_3_8910.vhd`
(register R/W, tone square + period, volume table, silence, envelope sweep) →
`===== AY TESTS PASSED =====` (also in `sim/run_all.sh`).

## ⚠️ The fit constraint (the headline)
Measured with Quartus Prime Lite 22.1 for the target `10CL006YE144C8G`:
- one AY-3-8910 core ≈ **456 logic cells**.
- GottFA80_PLuS *with lisyctrl* already uses **5,801 / 6,272 LEs (92 %)** — only
  ~470 free.

A faithful late-80B sound board (2× AY ≈ 912 + a sound 6502 ≈ 1,800 + glue ≈ 500 ≈
**~3,200 LEs**) **does not fit the 10CL006.**

| Path | What | Device |
|---|---|---|
| **A — faithful emulation** | this AY core ×2 + a sound CPU + DAC + speech | needs a bigger FPGA (10CL025 / EP4CE15-22) |
| **B — MP3 / samples** | capture the 80B sound command → play recorded samples (as the 3 supported games do) | fits the 10CL006; needs the sample content + per-game mapping |

On a **10CL006, Path B is the only one that fits**; Path A is ready (this AY core)
for a larger device or a System 3 build.

## Roadmap (numbered)
1. ✅ **AY-3-8910/8912 PSG core** — validated in sim (this).
2. **80B sound-command capture** (the MPU sound byte + strobe) — verify/route.
3. **80B "Gen2/3" board glue** (dual-6502 memory map around 2× AY + DAC) — Path A.
4. **Speech**: emulate "Orator"/SP0256, or keep the MP3/DFPlayer fallback.
5. **80B sound-ROM loading** from SD/NOR (bigger than the current 2 KB blocks).
6. **GOSOF80 board-type dispatch** + per-game table entry for 80B.
7. **Mix** 2× AY + DAC + speech → audio out (reuse `dac.vhd`).
8. **Diagnostic 80B sound** in lisyctrl (widen `SOUND` to the 80B command width).
9. **Fit / validate** (pick the device per the table) + hardware test with real ROMs.
10. **Coordinate with bontango** — this is his active WIP; align before a PR.
