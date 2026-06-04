-- spi_slave.vhd : CS-less SPI slave (mode 0) for the GottFA80 lisyctrl bridge
-- part of GottFA80 (https://github.com/bontango/GottFA80)
--
-- This is free software: you can redistribute it and/or modify it under the
-- terms of the GNU General Public License as published by the Free Software
-- Foundation, either version 3 of the License, or (at your option) any later
-- version. Distributed WITHOUT ANY WARRANTY; see the GNU GPL v3 for details.
--
-- The GottFA shared SPI bus (SD card + config EEPROM) has NO chip-select line
-- free for an external master. So this slave is "CS-less": it is enabled by the
-- lisyctrl mode flag and frames are delimited by an idle gap on SCLK
-- (>= gap_clocks system-clock cycles with no SCLK edge resets the frame).
-- SCLK/MOSI are oversampled on `clk`, so clk must be >= ~6x the SCLK rate
-- (50 MHz clk -> SCLK up to a few MHz: fine for the ESP32 master).
--
-- 2-byte register protocol (see lisyctrl.vhd / LISYCTRL.md):
--   byte0 = command: bit7 = R/W (1=write,0=read), bits6..0 = register address
--   byte1 = data    (write: value; read: dummy in, register value out on MISO)

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity spi_slave is
  generic ( gap_clocks : integer := 64 );
  port (
    clk      : in  std_logic;                     -- system clock (e.g. 50 MHz)
    enable   : in  std_logic;                     -- '0' = idle (MISO low, bus ignored)
    sclk     : in  std_logic;                     -- from external master (ESP)
    mosi     : in  std_logic;
    miso     : out std_logic;
    rx_byte  : out std_logic_vector(7 downto 0);  -- last received byte
    rx_valid : out std_logic;                     -- 1-clk pulse when a byte completes
    rx_first : out std_logic;                     -- '1' if rx_byte is the frame's first byte
    tx_byte  : in  std_logic_vector(7 downto 0)   -- value to shift out for the current byte
  );
end spi_slave;

architecture rtl of spi_slave is
  signal sclk_r : std_logic_vector(2 downto 0) := (others => '0');
  signal mosi_r : std_logic_vector(1 downto 0) := (others => '0');
  signal bitcnt : unsigned(2 downto 0) := (others => '0');
  signal bidx   : unsigned(7 downto 0) := (others => '0');  -- byte index in frame
  signal rxsh   : std_logic_vector(7 downto 0) := (others => '0');
  signal txsh   : std_logic_vector(7 downto 0) := (others => '0');
  signal gapcnt : integer range 0 to gap_clocks := gap_clocks;
begin
  miso <= txsh(7) when enable = '1' else '0';

  process
    variable rise, fall : boolean;
  begin
    wait until rising_edge(clk);
    -- de-glitched edge detect on the two oldest synced samples
    rise := (sclk_r(2) = '0' and sclk_r(1) = '1');
    fall := (sclk_r(2) = '1' and sclk_r(1) = '0');
    -- synchronizers
    sclk_r   <= sclk_r(1 downto 0) & sclk;
    mosi_r   <= mosi_r(0) & mosi;
    rx_valid <= '0';
    rx_first <= '0';

    if enable = '0' then
      bitcnt <= (others => '0');
      bidx   <= (others => '0');
      gapcnt <= gap_clocks;
      txsh   <= tx_byte;
    else
      -- idle-gap framing
      if rise or fall then
        gapcnt <= gap_clocks;
      elsif gapcnt > 0 then
        gapcnt <= gapcnt - 1;
        if gapcnt = 1 then          -- gap elapsed -> start a fresh frame
          bitcnt <= (others => '0');
          bidx   <= (others => '0');
          txsh   <= tx_byte;        -- preload response for byte 0
        end if;
      end if;

      -- sample MOSI on rising edge (mode 0)
      if rise then
        rxsh <= rxsh(6 downto 0) & mosi_r(1);
        if bitcnt = 7 then
          rx_byte  <= rxsh(6 downto 0) & mosi_r(1);
          rx_valid <= '1';
          if bidx = 0 then rx_first <= '1'; end if;
          bitcnt   <= (others => '0');
          bidx     <= bidx + 1;
        else
          bitcnt <= bitcnt + 1;
        end if;
      end if;

      -- change MISO on falling edge (mode 0)
      if fall then
        if bitcnt = 0 then
          txsh <= tx_byte;                  -- load next byte to send
        else
          txsh <= txsh(6 downto 0) & '0';   -- shift out, MSB first
        end if;
      end if;
    end if;
  end process;
end rtl;
