-- tb_link_arb.vhd : sound_link + ram_snoop wired exactly as SYS80 does, with every
-- internal cycle count scaled by exactly 1/10 (clk 5 MHz, baud 115200) so that all
-- ratios are identical to the real 50 MHz / 115200 design:
--   DIV = 43 (real 434) -> byte = 430 clk (real 4340)
--   HB  = 250 000 (real 2 500 000)          -> heartbeat every 50 "ms"
--   TICK_MAX = 5 000 000 (real 50 000 000)  -> snapshot every 1 "s"
--   frame 1281 bytes = 550 830 clk = 11.0 % of the period (real 11.1 %)
-- 1 simulated second therefore corresponds 1:1 to 1 second of real machine time.
--
-- The TX line is decoded back into bytes and classified, reproducing the ESP-side
-- statistic (fpgalink.cpp: g_lastByte / per-class counts) offline.
--
-- MODE selects the stimulus:
--   0 = game_running static '1'   (what count_to_zero actually produces after boot)
--   1 = game_running toggling at 1 kHz
--   2 = sound[] toggling at 1 kHz
--   3 = ball[]  toggling at 1 kHz
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_link_arb is
  generic ( MODE : integer := 0 );
end tb_link_arb;

architecture sim of tb_link_arb is
  constant TCLK  : time := 200 ns;              -- 5 MHz
  constant BIT_T : time := 43 * TCLK;           -- one UART bit = DIV clocks

  signal clk  : std_logic := '0';
  signal rst  : std_logic := '1';
  signal tx   : std_logic;

  signal game_running : std_logic := '1';
  signal diag  : std_logic := '0';
  signal sound : std_logic_vector(4 downto 0) := "00011";
  signal game  : std_logic_vector(5 downto 0) := "010101";
  signal ball  : std_logic_vector(3 downto 0) := "0000";

  signal snap_data : std_logic_vector(7 downto 0);
  signal snap_req  : std_logic;
  signal snap_ack  : std_logic;

  signal running : boolean := true;

  shared variable n_mode, n_state, n_ball, n_game, n_snd : integer := 0;
  shared variable n_mark, n_hi, n_lo, n_other            : integer := 0;
  shared variable n_f3 : integer := 0;   -- 0xF3 specifically (state = running)
  shared variable last_byte : integer := -1;
begin

  clk <= not clk after TCLK/2 when running else '0';

  DUT_LINK : entity work.sound_link
    generic map ( clk_hz => 5000000, baud => 115200, hb_ms => 50 )
    port map (
      clk => clk, rst => rst, diag => diag,
      sound => sound, game => game, game_running => game_running, ball => ball,
      snap_data => snap_data, snap_req => snap_req, snap_ack => snap_ack,
      tx => tx );

  DUT_SNOOP : entity work.ram_snoop
    generic map ( clk_hz => 5000000, period_ms => 1000, n_bytes => 640 )
    port map (
      clk => clk, rst => rst,
      wr_addr => "0000000000", wr_data => x"5A", wr_en => '0',
      snap_data => snap_data, snap_req => snap_req, snap_ack => snap_ack );

  STIM : process
  begin
    rst <= '1';
    wait for 20 us;
    rst <= '0';
    wait;
  end process;

  TOG : process
    variable p : time;
  begin
    wait for 25 us;
    if MODE >= 4 then p := 400 ns;                        -- 2 clk: pending every cycle
    else              p := 500 us; end if;                -- 1 kHz
    while running loop
      wait for p;
      case MODE is
        when 1 | 4 => game_running <= not game_running;
        when 2 | 5 => sound <= not sound;
        when 3 | 6 => ball  <= not ball;
        when others => null;
      end case;
    end loop;
    wait;
  end process;

  RX : process
    variable b : std_logic_vector(7 downto 0);
  begin
    wait until falling_edge(tx);
    wait for BIT_T/2;
    if tx = '0' then
      for i in 0 to 7 loop
        wait for BIT_T;
        b(i) := tx;
      end loop;
      wait for BIT_T;
      last_byte := to_integer(unsigned(b));
      if    b(7 downto 1) = "1111000" then n_mode  := n_mode  + 1;   -- 0xF0/0xF1
      elsif b(7 downto 1) = "1111001" then n_state := n_state + 1;   -- 0xF2/0xF3
        if b(0) = '1' then n_f3 := n_f3 + 1; end if;
      elsif b            = x"BF"      then n_mark  := n_mark  + 1;   -- frame marker
      elsif b(7 downto 4) = "1010"    then n_ball  := n_ball  + 1;   -- 0xAx
      elsif b(7 downto 4) = "1100"    then n_hi    := n_hi    + 1;   -- 0xCx
      elsif b(7 downto 4) = "1101"    then n_lo    := n_lo    + 1;   -- 0xDx
      elsif b(7 downto 5) = "100"     then n_snd   := n_snd   + 1;   -- 0x8x
      elsif b(7 downto 6) = "01"      then n_game  := n_game  + 1;   -- 0x4x
      else                                 n_other := n_other + 1;
      end if;
    end if;
  end process;

  REPORTP : process
    variable l : line;
  begin
    wait for 3 sec;
    write(l, string'("MODE="));            write(l, MODE);
    write(l, string'("  mode_F0F1="));     write(l, n_mode);
    write(l, string'("  state_F2F3="));    write(l, n_state);
    write(l, string'("  ofwhich_F3="));    write(l, n_f3);
    write(l, string'("  ball_Ax="));       write(l, n_ball);
    write(l, string'("  game_4x="));       write(l, n_game);
    write(l, string'("  snd_8x="));        write(l, n_snd);
    write(l, string'("  MARK_BF="));       write(l, n_mark);
    write(l, string'("  hi_Cx="));         write(l, n_hi);
    write(l, string'("  lo_Dx="));         write(l, n_lo);
    write(l, string'("  other="));         write(l, n_other);
    write(l, string'("  LAST="));          write(l, last_byte);
    writeline(output, l);
    running <= false;
    wait for 1 us;
    assert false report "END-OF-SIM" severity failure;
  end process;

end sim;
