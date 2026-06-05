# GottFA80_PLuS — build variants (Pstore)

Two compile-time generics on `SYS80` select the product. Both default to the
**stock** behaviour, so an unchanged build is bit-for-bit the original board and the
diff to bontango stays non-invasive.

| generic | default | effect when changed |
|---|---|---|
| `lisy_enable` | `true` | include the lisyctrl diagnostic bridge + coil protection (diag-mode only). `false` compiles it out (back to stock). |
| `esp_sound` | `false` | `true` = the ESP/GOSOWAV is the sound source: **GOSOF80 + the DFPlayer are dropped**, and a single UART on the **Debug pin (PIN_11 / K2)** carries the diag-mode token + the live sound#/game# to the ESP. PIN_2 (Audio_RX) and PIN_7 (Sound) are freed. |

## The two Pstore SKUs (both `esp_sound=true`)

| SKU | `lisy_enable` | `esp_sound` | What | LE on 10CL006 |
|---|---|---|---|---|
| **FULL** (connected) | `true` | `true` | ESP does everything: diagnostics, sound (GOSOWAV WAV), coil protection, ROM/OTA. ESP required. | **4,145 / 6,272 (66 %)** |
| **LITE** (bare MPU) | `false` | `true` | Pure pinball MPU — no diag, no protection, no sound. Smallest bitstream. No ESP. | **3,539 / 6,272 (56 %)** |

(Stock, no ESP, on-board GOSOF80 sound = the upstream default `lisy_enable=true, esp_sound=false`. Validated separately.)

## Why one wire on Debug

Diagnostics and gameplay sound never happen at the same time (in diag the 6502 is held,
so no sound is generated). So the single FPGA→ESP UART on the Debug pin safely carries
both: a diag-mode token (`0xF0` normal / `0xF1` diag, + a 50 ms heartbeat) and the
gameplay sound/game bytes (`0x80|sound[4:0]`, `0x40|game[5:0]`). The ESP mounts next to
the FPGA (SPI diag at J3a, reset at S8, this link at K2); the only thing in the audio
section is the **MCP4921** DAC (near the TDA7267) fed by 3 SPI wires from the ESP.

## Building a SKU

Set the generics (e.g. edit the `SYS80` entity defaults, or pass `set_parameter`) and run
the normal Quartus flow for the target in `GottFA80_PLuS_HW21x_Cyclone_10/`
(`10CL006YE144C8G`). Both SKUs and the stock default pass map/fit/asm/timing with 0
errors and add **no new pin** (the link reuses the Debug pin).

The matching ESP firmware is `Vapi27/gottfa-esp32` (FULL = `esp32s3` env with sound; a
diag-only ESP can use `esp32c3`).
