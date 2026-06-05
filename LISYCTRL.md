# lisyctrl — a LISYcontrol-style diagnostic bridge for GottFA80

> Proposal + reference implementation for an open (GPL-3.0) ESP32 diagnostic /
> control bridge, in the spirit of LISY's `lisy80_control`, for the GottFA80+
> (Cyclone 10 LP) board. Intended for upstreaming.

## Goal
Let an ESP32 (WiFi, modern web UI) drive/read the machine hardware exactly like
LISYcontrol does on a LISY Pi — but on GottFA the I/O belongs to the FPGA, so a
small VHDL block (`lisyctrl`) exposes it over the **existing shared SPI bus**
when a diagnostic mode is active (6502 held in reset).

## Files
| File | Role |
|---|---|
| `lib_common/spi_slave.vhd` | CS-less SPI mode-0 slave (idle-gap framed) |
| `lib_common/lisyctrl.vhd`  | register file + switch scan + coil pulse(+watchdog) + lamp refresh + display |
| `sim/tb_lisyctrl.vhd`      | self-checking testbench (GHDL/ModelSim) |

## Simulate (no hardware needed)
```sh
ghdl -a lib_common/spi_slave.vhd lib_common/lisyctrl.vhd sim/tb_lisyctrl.vhd
ghdl -e tb_lisyctrl && ghdl -r tb_lisyctrl
```
Expect `===== ALL TESTS PASSED =====` (ID/VER, CTRL r/w, switch readback, coil
gts80 pulse + auto-clear, watchdog trip + re-arm).

The **bus-sharing glue itself is validated**: `sim/sys80_glue.vhd` (= the SYS80
changes below, isolated from the Altera megafunctions) + `sim/tb_integration.vhd`
→ `INTEGRATION TESTS PASSED` — an external master reads a lisyctrl register over the
shared **inout** bus end-to-end, plus normal-mode CLK/CS passthrough and CPU-hold.
Run all three testbenches: `sh sim/run_all.sh`.

## Validated on the real toolchain
Built with **Quartus Prime Lite 22.1std.0 (Build 915)** for **both** project
variants — `10CL006YE144C8G` (Cyclone 10 LP) and `EP4CE6E22C8` (Cyclone IV E) —
the full flow passes end-to-end on the integrated `SYS80`. The table below is the
Cyclone 10 build; the Cyclone IV build is equivalent (5,729 LEs / 91 %, setup
slack +5.47 ns, its own `SYS80.sof` generated, 0 errors):

| Stage | Result |
|---|---|
| Analysis & Synthesis | **0 errors** — 3 bidirectional pins inferred (the shared SPI bus) |
| Fitter (place & route) | **0 errors** — router 14 % avg / 21 % peak interconnect |
| Assembler | **0 errors** → `SYS80.sof` bitstream generated |
| Timing (STA) | **met** — worst setup slack +4.94 ns, hold +0.40 ns (all corners positive) |

Resource impact of lisyctrl, vs the pristine `main` (same device, same flow):

| | baseline | + lisyctrl | delta |
|---|---|---|---|
| Logic elements | 5,179 (83 %) | 5,701 (91 %) | **+522 (+8 %)** |
| &nbsp;&nbsp;combinational | 4,858 | 5,351 | +493 |
| &nbsp;&nbsp;registers | 1,853 | 2,153 | +300 |
| Pins | 84 | 84 | **+0** |
| Memory bits | 139,264 | 139,264 | **+0** |

So lisyctrl costs ~522 LEs and **no extra pins and no extra memory** — it reuses
the existing shared SPI bus and the door test switch — and the design still fits
the 10CL006 with timing met. (`MOSI`/`MISO`/`CLK` land back on their original
pins 42/34/39, now as bidirectional.) For a tight device the whole bridge can be
**compiled out** via the new `lisy_enable` generic on `SYS80` (default `true`):
set it `false` and the build drops to **5,178 LEs (83 %)** — reclaiming the full
cost and folding the shared-bus muxes back to stock — also verified on this flow.
The `sim/` GHDL testbenches validate the
logic and bus-sharing behaviourally; this section validates synthesis/fit/timing
on Intel's tools. The remaining gate before merge is on-machine hardware
bring-up (with the ESP32 companion).

## Why share the bus (no dedicated SPI)
The X1P connector exposes no spare FPGA I/O. The only SPI pins are the SD/EEPROM
bus (`CLK`/`MOSI`/`MISO` + `CS_SDcard`/`CS_EEprom`). So in diagnostic mode the
FPGA **releases** that bus to the ESP and becomes an SPI **slave**:
- `CLK`,`MOSI` → tri-stated by the FPGA, driven by the ESP (read by `lisyctrl`)
- `MISO` → driven by the FPGA slave (SD+EEPROM held deselected → single driver)
- no CS line free → the slave is **CS-less**, framed by an SCLK idle gap, and the
  `active` flag is the global enable.

## SYS80.vhd integration (the changes to review)
1. **Entity port directions** (the one invasive change):
   ```vhdl
   MOSI : inout std_logic;   -- was: out
   CLK  : inout std_logic;   -- was: out
   MISO : inout std_logic;   -- was: in
   ```
2. **Instance** (new signals `lisy_*`):
   ```vhdl
   LISY: entity work.lisyctrl
     port map( clk=>clk_50, active=>lisy_active,
       sclk=>lisy_sclk, mosi=>lisy_mosi, miso=>lisy_miso,
       o_U4_PB=>lisy_u4pb, i_U4_PA=>U4_pa_in,
       o_U5_PA=>lisy_u5pa, o_U5_PB7=>lisy_u5pb7,
       o_U6_PA=>lisy_u6pa, o_U6_PB=>lisy_u6pb, o_segments=>lisy_seg,
       i_DIP_Ret=>DIP_Return, i_slam=>slam, wd_tripped=>open );
   ```
3. **Bus tri-state** (replaces the `MOSI/CLK` mux ~lines 342-343):
   ```vhdl
   CLK  <= 'Z' when lisy_active='1' else (SDcard_CLK  when reset_l='0' else EEprom_CLK);
   MOSI <= 'Z' when lisy_active='1' else (SDcard_MOSI when reset_l='0' else EEprom_MOSI);
   MISO <= lisy_miso when lisy_active='1' else 'Z';
   lisy_sclk <= CLK;  lisy_mosi <= MOSI;          -- read ESP-driven lines
   CS_SDcard <= '1' when lisy_active='1' else sd_cs_int;   -- deselect chips in diag
   CS_EEprom <= '1' when lisy_active='1' else ee_cs_int;
   ```
   (route SD_Card / EEprom `o_SPI_CS_n` to `sd_cs_int` / `ee_cs_int`).
4. **Hold the 6502** in diag:
   ```vhdl
   U1 (T65): Res_n => cpu_res_n;   cpu_res_n <= '0' when lisy_active='1' else reset_l;
   ```
5. **I/O output muxes** — `lisyctrl` emits RIOT-register semantics, so feed the
   EXISTING conditioning from `lisy_*` when active (no polarity rework):
   ```vhdl
   -- example, U6_PA (lines ~670-671):
   u6pa_src <= lisy_u6pa when lisy_active='1' else U6_pa_out;
   U6_PA(4 downto 0) <= not u6pa_src(4 downto 0) when (game_running='1' or lisy_active='1') else "00000";
   U6_PA(7 downto 5) <=     u6pa_src(7 downto 5) when (game_running='1' or lisy_active='1') else "111";
   ```
   Do the same pattern for `U6_PB`, `U4_PB`, `U5_PA(3..0)`, `disp_segments`.

## Mode entry (`lisy_active`)
**Implemented:** a **long-press of the Gottlieb door test switch** (`detect_test_sw`
`long_push`, strobe 0 / return 7) latches `lisy_active`; any reset/reboot
(`reset_l='0'`) exits it. The detector is active from attract/idle (its `rst` is
`game_running`) — the usual place to run diagnostics. No extra pin; default OFF, so
stock behaviour is unchanged until the button is held. The `Debug` pin is driven
`<= lisy_active` so the ESP companion knows when the shared SPI bus has been
released to it. (Open to bontango's preference — e.g. add a SPI/`Debug`-line exit,
or a timeout.)

## SPI register map (2-byte frames)
byte0 = `{bit7 R/W, bits6..0 addr}`, byte1 = data (read: value returned on MISO).

| Addr | R/W | Name | Meaning |
|---|---|---|---|
| 0x00 | R | ID | 0x80 |
| 0x01 | R | VER | 0x01 |
| 0x02 | R | STATUS | b0 active, b1 wd_tripped, b2 is80B |
| 0x03 | W | CTRL | b0 outputs_enabled, b1 lamp_blink |
| 0x10-0x17 | R | SW_ROW[strobe] | bit = return, 1 = **closed** |
| 0x18 | R | DIP/slam | b4..0 DIP_Return, b5 slam |
| 0x20-0x25 | W/R | LAMP[0..5] | 48 lamp bits |
| 0x30 | W | COIL | write coil # (1..9) → pulse |
| 0x31 | W/R | PULSE_MS | coil pulse width (ms) |
| 0x32 | R/W | COIL_FAULT | b0 pulse-clamped, b1 re-fire-blocked, b2 watchdog-with-coil; b7..4 coil#. Write clears |
| 0x40-0x42 | W | SEG_A/B/C | display segments (1..24) |
| 0x43 | W | U5 | b3..0 digit strobes, b7 switch-enable |
| 0x44 | W | SOUND | write System 80 sound code (0..31) → play via gosof80 |

Maps 1:1 onto LISY's model (L/C/S/D/V commands); the modern web UI on the ESP
talks this over WebSocket.

## Safety
- `outputs_enabled` defaults **off** → no lamp/coil energizing until armed.
- Coils auto-release after `PULSE_MS`; a **comms watchdog** (default 120 ms; pet
  by any SPI traffic) forces solenoids to the safe value (`U6_PA=0x00`, all
  enables off) if the ESP/WiFi stalls.
- **Coil thermal/duty guard** (the board has *no* current sensor): every pulse is
  hard-clamped to `max_pulse_ms` (default 150), a `refire_ms` cooldown (default 40)
  blocks machine-gunning one coil, and any guard trip latches `COIL_FAULT` (0x32)
  with the coil #. True over-current/short *detection* needs an added current-sense
  shunt read by the ESP ADC (optional, in the firmware) — this FPGA-side guard
  protects the drivers regardless.
- `f_coil(n)` is the **gts80 encode** (mimics the game ROM), so feeding the
  existing conditioning fires the correct solenoid *by construction*.

## TODO / confirm before hardware
- **Lamp matrix group→latch (DS) addressing** in `P_LAMP` is best-effort — verify
  against the SYS80 lamp decoders (IC11/IC13) + SN74175 chain.
- **80B vs 80/80A** display handling + `is80B` status bit.
- Final **mode-entry** mechanism (above).
- Switch return polarity (currently: strobe-high + return-high = closed).
