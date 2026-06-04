# nor_flash — SPI NOR as the game-ROM store (SD card replacement)

> `lib_common/nor_flash.vhd` is a drop-in replacement for `SD_Card.vhd`: same
> entity ports, but it reads the 16 KByte game image from a standard SPI NOR
> flash (e.g. Winbond W25Q32) instead of an SD card. GPL-3.0, for upstreaming.

## Why
- No SD socket to corrupt / nothing mechanical.
- The **ESP32 can (re)program the NOR over WiFi** (same SPI pins), enabling remote
  ROM / game-pack updates while the FPGA is held in reset.

## Swap into SYS80.vhd
Replace the `SD_CARD:` instance with `nor_flash` (identical port map):
```vhdl
SD_CARD: entity work.nor_flash
  generic map ( spi_hz => 8000000, base_addr => 0, last_addr => 16#3FFF# )
  port map (
    i_clk => clk_50, i_Rst_L => not readingdips,
    o_SPI_Clk => SDcard_CLK, i_SPI_MISO => MISO, o_SPI_MOSI => SDcard_MOSI,
    o_SPI_CS_n => CS_SDcard,
    selection => "0" & opt_freeplay & not game_select,
    address_sd_card => address_sd_card, data_sd_card => data_sd_card, wr_rom => wr_rom,
    cpu_reset_l => reset_l, SDcard_error => SDcard_error );
```
No other SYS80 change needed (the ROM-load path downstream is unchanged).

## NOR layout
- Game N image at byte offset `base_addr + N*0x4000` (16 KByte each).
- Same 16 KByte content as the SD image (lower 8 KB game-ROM region ×4, upper 8 KB
  system ROM) — see the GottFA80 SD image format.
- W25Q32 (4 MB) ≈ 256 games.

## ESP programming (gottfa-esp32/src/norprog.cpp)
1. `enter()` — pull the FPGA `Reset` line low (FPGA tri-states the SPI bus), take
   the bus as SPI master. (TODO: confirm release via the Debug-line handshake.)
2. erase 4 KB sectors, page-program (256 B), read-back **verify**.
3. `leave()` — release bus + reset → FPGA reboots and reads the new image.
W25Q commands used: 0x9F JEDEC-ID, 0x06 WREN, 0x05 status(BUSY), 0x20 sector-erase,
0x02 page-program, 0x03 read.

## Validation
`sim/tb_nor_flash.vhd` (behavioral SPI-NOR model) → `NOR TESTS PASSED`
(correct 0x03+addr command, data pattern, address sequence, `cpu_reset_l` release).
