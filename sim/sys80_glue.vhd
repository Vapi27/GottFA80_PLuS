-- sys80_glue.vhd : the SYS80.vhd integration glue for lisyctrl, isolated so the
-- bus-sharing (inout tri-state) can be simulated without the Altera megafunctions.
-- This is exactly the logic LISYCTRL.md asks to add to SYS80.vhd. GPL-3.0.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity sys80_glue is
  port (
    clk_50      : in    std_logic;
    lisy_active : in    std_logic;
    reset_l     : in    std_logic;                         -- normal CPU reset (from SD_Card)
    -- physical shared SPI bus (becomes inout in SYS80)
    CLK         : inout std_logic;
    MOSI        : inout std_logic;
    MISO        : inout std_logic;
    CS_SDcard   : out   std_logic;
    CS_EEprom   : out   std_logic;
    -- normal-mode bus drivers (stand-ins for SD_Card / EEprom)
    sd_clk      : in    std_logic;
    sd_mosi     : in    std_logic;
    sd_cs       : in    std_logic;
    ee_cs       : in    std_logic;
    -- machine I/O (subset to demonstrate the output mux)
    U4_PA       : in    std_logic_vector(7 downto 0);
    cpu_U6_PA   : in    std_logic_vector(7 downto 0);      -- normal-mode value
    o_U6_PA     : out   std_logic_vector(7 downto 0);
    o_U4_PB     : out   std_logic_vector(7 downto 0);
    cpu_res_n   : out   std_logic                          -- -> T65 Res_n
  );
end sys80_glue;

architecture rtl of sys80_glue is
  signal lisy_sclk, lisy_mosi, lisy_miso : std_logic;
  signal lisy_u6pa, lisy_u4pb : std_logic_vector(7 downto 0);
begin
  -- shared-bus tri-state: release to the ESP in diag mode, else FPGA drives
  CLK  <= 'Z' when lisy_active = '1' else sd_clk;
  MOSI <= 'Z' when lisy_active = '1' else sd_mosi;
  MISO <= lisy_miso when lisy_active = '1' else 'Z';
  lisy_sclk <= CLK;                       -- FPGA reads the (ESP-driven) lines
  lisy_mosi <= MOSI;
  CS_SDcard <= '1' when lisy_active = '1' else sd_cs;   -- deselect chips in diag
  CS_EEprom <= '1' when lisy_active = '1' else ee_cs;
  cpu_res_n <= '0' when lisy_active = '1' else reset_l; -- hold 6502 in diag

  -- output mux: feed existing conditioning from lisyctrl when active
  o_U6_PA <= lisy_u6pa when lisy_active = '1' else cpu_U6_PA;
  o_U4_PB <= lisy_u4pb when lisy_active = '1' else (others => '0');

  LISY : entity work.lisyctrl
    port map (
      clk => clk_50, active => lisy_active,
      sclk => lisy_sclk, mosi => lisy_mosi, miso => lisy_miso,
      o_U4_PB => lisy_u4pb, i_U4_PA => U4_PA,
      o_U5_PA => open, o_U5_PB7 => open,
      o_U6_PA => lisy_u6pa, o_U6_PB => open, o_segments => open,
      i_DIP_Ret => "00000", i_slam => '0', wd_tripped => open
    );
end rtl;
