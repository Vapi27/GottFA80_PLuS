-- tb_lisyctrl.vhd : self-checking testbench for lisyctrl + spi_slave
-- part of GottFA80 (GPL-3.0). Run e.g.:
--   ghdl -a lib_common/spi_slave.vhd lib_common/lisyctrl.vhd sim/tb_lisyctrl.vhd
--   ghdl -e tb_lisyctrl && ghdl -r tb_lisyctrl
-- (generics are scaled down so the run completes in microseconds)

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_lisyctrl is end tb_lisyctrl;

architecture sim of tb_lisyctrl is
  signal clk      : std_logic := '0';
  signal active   : std_logic := '0';
  signal sclk     : std_logic := '0';
  signal mosi     : std_logic := '0';
  signal miso     : std_logic;
  signal o_U4_PB  : std_logic_vector(7 downto 0);
  signal i_U4_PA  : std_logic_vector(7 downto 0) := (others => '0');
  signal o_U5_PA  : std_logic_vector(3 downto 0);
  signal o_U5_PB7 : std_logic;
  signal o_U6_PA  : std_logic_vector(7 downto 0);
  signal o_U6_PB  : std_logic_vector(7 downto 0);
  signal o_seg    : std_logic_vector(1 to 24);
  signal i_DIP    : std_logic_vector(4 downto 0) := "00000";
  signal i_slam   : std_logic := '0';
  signal wd       : std_logic;

  constant HALF : time := 300 ns;   -- SCLK half period (~1.6 MHz)
  constant GAP  : time := 1500 ns;  -- inter-frame gap (> gap_clocks*clk)
  signal done : boolean := false;
begin

  clk <= not clk after 10 ns when not done else '0';   -- 50 MHz

  DUT : entity work.lisyctrl
    generic map ( clk_hz => 100000, wd_timeout_ms => 5, gap_clocks => 32, scan_div => 40 )
    port map (
      clk => clk, active => active, sclk => sclk, mosi => mosi, miso => miso,
      o_U4_PB => o_U4_PB, i_U4_PA => i_U4_PA, o_U5_PA => o_U5_PA, o_U5_PB7 => o_U5_PB7,
      o_U6_PA => o_U6_PA, o_U6_PB => o_U6_PB, o_segments => o_seg,
      i_DIP_Ret => i_DIP, i_slam => i_slam, wd_tripped => wd
    );

  stim : process
    variable r : std_logic_vector(7 downto 0);
    variable fails : integer := 0;

    procedure spi_xfer(cmd, dat : in std_logic_vector(7 downto 0);
                       rd : out std_logic_vector(7 downto 0)) is
    begin
      for i in 7 downto 0 loop
        mosi <= cmd(i); wait for HALF; sclk <= '1'; wait for HALF; sclk <= '0';
      end loop;
      for i in 7 downto 0 loop
        mosi <= dat(i); wait for HALF; sclk <= '1'; wait for HALF; rd(i) := miso; sclk <= '0';
      end loop;
      mosi <= '0'; wait for GAP;
    end procedure;

    procedure check(name : string; got, exp : std_logic_vector(7 downto 0)) is
    begin
      if got = exp then
        report "PASS " & name severity note;
      else
        report "FAIL " & name & " got=" & integer'image(to_integer(unsigned(got)))
             & " exp=" & integer'image(to_integer(unsigned(exp))) severity error;
        fails := fails + 1;
      end if;
    end procedure;
  begin
    wait for 1 us;
    active <= '1';
    wait for 1 us;

    -- 1) identity
    spi_xfer(x"00", x"00", r); check("ID",  r, x"80");
    spi_xfer(x"01", x"00", r); check("VER", r, x"01");

    -- 2) CTRL write/read (enable outputs)
    spi_xfer(x"83", x"01", r);             -- W 0x03 = 0x01
    spi_xfer(x"03", x"00", r); check("CTRL", r, x"01");

    -- 3) switch scan readback (hold returns, let the scanner latch all strobes)
    i_U4_PA <= x"A5";
    wait for 12 us;
    spi_xfer(x"10", x"00", r); check("SW_ROW0", r, x"A5");

    -- 4) coil pulse: short pulse, expect gts80 encode then auto-clear
    spi_xfer(x"B1", x"03", r);             -- W 0x31 PULSE_MS = 3 ms
    spi_xfer(x"B0", x"01", r);             -- W 0x30 COIL = 1  -> f_coil(1)=0x20
    wait for 1 us;
    check("COIL1_on", o_U6_PA, x"20");
    wait for 9 us;                          -- > 3 ms-ticks at scaled clk
    check("COIL_off", o_U6_PA, x"00");

    -- 5) watchdog: stop traffic with outputs enabled -> trips, coils forced safe
    wait for 20 us;
    if wd = '1' then report "PASS WD_trip" severity note;
    else report "FAIL WD_trip" severity error; fails := fails + 1; end if;
    check("WD_safe_coil", o_U6_PA, x"00");
    -- traffic re-arms the watchdog
    spi_xfer(x"00", x"00", r);
    wait for 1 us;
    if wd = '0' then report "PASS WD_rearm" severity note;
    else report "FAIL WD_rearm" severity error; fails := fails + 1; end if;

    if fails = 0 then report "===== ALL TESTS PASSED =====" severity note;
    else report "===== TESTS FAILED =====" severity failure; end if;

    done <= true;
    wait;
  end process;
end sim;
