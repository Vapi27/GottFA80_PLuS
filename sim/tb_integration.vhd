-- tb_integration.vhd : validates the SYS80 bus-sharing glue (sys80_glue) end-to-end.
-- Proves: normal mode = FPGA drives the bus / CPU path; diag mode = FPGA tri-states
-- the bus, deselects SD/EEPROM, holds the CPU, and an external SPI master (the ESP)
-- talks to lisyctrl THROUGH the inout bus. GPL-3.0.
--   ghdl -a lib_common/spi_slave.vhd lib_common/lisyctrl.vhd sim/sys80_glue.vhd sim/tb_integration.vhd
--   ghdl -e tb_integration && ghdl -r tb_integration --stop-time=20ms

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity tb_integration is end tb_integration;

architecture sim of tb_integration is
  signal clk       : std_logic := '0';
  signal active    : std_logic := '0';
  signal reset_l   : std_logic := '1';
  signal bclk      : std_logic;
  signal bmosi     : std_logic;
  signal bmiso     : std_logic;
  signal CS_SD     : std_logic;
  signal CS_EE     : std_logic;
  signal sd_clk    : std_logic := '0';
  signal sd_mosi   : std_logic := '0';
  signal sd_cs     : std_logic := '1';
  signal ee_cs     : std_logic := '1';
  signal U4_PA     : std_logic_vector(7 downto 0) := (others => '0');
  signal cpu_U6_PA : std_logic_vector(7 downto 0) := x"5A";
  signal o_U6_PA   : std_logic_vector(7 downto 0);
  signal o_U4_PB   : std_logic_vector(7 downto 0);
  signal cpu_res_n : std_logic;

  signal eclk : std_logic := 'Z';   -- ESP master drivers onto the shared bus
  signal emosi: std_logic := 'Z';
  signal done : boolean := false;

  constant HALF : time := 300 ns;
  constant GAP  : time := 2 us;
begin
  clk <= not clk after 10 ns when not done else '0';
  bclk  <= eclk;    -- ESP side shares the inout bus with the glue
  bmosi <= emosi;

  DUT : entity work.sys80_glue
    port map ( clk_50 => clk, lisy_active => active, reset_l => reset_l,
      CLK => bclk, MOSI => bmosi, MISO => bmiso, CS_SDcard => CS_SD, CS_EEprom => CS_EE,
      sd_clk => sd_clk, sd_mosi => sd_mosi, sd_cs => sd_cs, ee_cs => ee_cs,
      U4_PA => U4_PA, cpu_U6_PA => cpu_U6_PA, o_U6_PA => o_U6_PA,
      o_U4_PB => o_U4_PB, cpu_res_n => cpu_res_n );

  stim : process
    variable fails : integer := 0;
    variable r : std_logic_vector(7 downto 0);

    procedure chk1(name : string; got, exp : std_logic) is
    begin
      if got = exp then report "PASS " & name severity note;
      else report "FAIL " & name severity error; fails := fails + 1; end if;
    end procedure;
    procedure chk8(name : string; got, exp : std_logic_vector(7 downto 0)) is
    begin
      if got = exp then report "PASS " & name severity note;
      else report "FAIL " & name & " got=" & integer'image(to_integer(unsigned(got))) severity error; fails := fails + 1; end if;
    end procedure;
    procedure spi_rd(addr : in std_logic_vector(7 downto 0); rd : out std_logic_vector(7 downto 0)) is
    begin
      for i in 7 downto 0 loop emosi <= addr(i); wait for HALF; eclk <= '1'; wait for HALF; eclk <= '0'; end loop;
      for i in 7 downto 0 loop emosi <= '1';     wait for HALF; eclk <= '1'; wait for HALF; rd(i) := bmiso; eclk <= '0'; end loop;
      emosi <= '0'; wait for GAP;
    end procedure;
  begin
    wait for 1 us;

    -- ---- normal mode: FPGA owns the bus / CPU path ----
    sd_clk <= '1'; wait for 200 ns; chk1("normal_CLK_passthru_hi", bclk, '1');
    sd_clk <= '0'; wait for 200 ns; chk1("normal_CLK_passthru_lo", bclk, '0');
    sd_cs  <= '0'; wait for 200 ns; chk1("normal_CS_passthru", CS_SD, '0');
    chk1("normal_cpu_running", cpu_res_n, '1');
    chk8("normal_U6PA_is_cpu", o_U6_PA, x"5A");

    -- ---- diag mode: FPGA releases bus, holds CPU, ESP talks to lisyctrl ----
    eclk <= '0'; emosi <= '0';        -- ESP takes the bus
    active <= '1';
    wait for 1 us;
    chk1("diag_cpu_held", cpu_res_n, '0');
    chk1("diag_CS_SD_deselected", CS_SD, '1');
    chk1("diag_CS_EE_deselected", CS_EE, '1');
    spi_rd(x"00", r); chk8("diag_ID_over_inout_bus", r, x"80");   -- end-to-end!
    chk8("diag_U6PA_safe", o_U6_PA, x"00");                       -- outputs disabled

    if fails = 0 then report "===== INTEGRATION TESTS PASSED =====" severity note;
    else report "===== INTEGRATION TESTS FAILED =====" severity failure; end if;
    done <= true; wait;
  end process;
end sim;
