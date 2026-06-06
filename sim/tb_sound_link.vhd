-- tb_sound_link.vhd : self-checking testbench for sound_link (FPGA->ESP UART).
-- ghdl -a lib_common/sound_link.vhd sim/tb_sound_link.vhd
-- ghdl -e tb_sound_link && ghdl -r tb_sound_link
-- Expect: "===== SOUND_LINK TESTS PASSED ====="
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_sound_link is end tb_sound_link;

architecture sim of tb_sound_link is
  constant CP     : time := 10 ns;          -- clk period
  constant BITT   : time := 10 * CP;        -- DIV = clk_hz/baud = 1e6/1e5 = 10 clk per bit
  signal clk   : std_logic := '0';
  signal rst   : std_logic := '1';
  signal diag  : std_logic := '0';
  signal sound : std_logic_vector(4 downto 0) := (others => '0');
  signal game  : std_logic_vector(5 downto 0) := (others => '0');
  signal game_running : std_logic := '0';
  signal tx    : std_logic;
  signal done  : boolean := false;
begin
  -- hb_ms huge so the heartbeat never fires during this short test (we test the
  -- change-driven mode token instead).
  DUT : entity work.sound_link
    generic map ( clk_hz => 1000000, baud => 100000, hb_ms => 100000 )
    port map ( clk => clk, rst => rst, diag => diag, sound => sound, game => game,
               game_running => game_running, tx => tx );

  clk <= not clk after CP/2 when not done else '0';

  stim : process
    variable b : std_logic_vector(7 downto 0);
    procedure rxb(bb : out std_logic_vector(7 downto 0)) is
    begin
      wait until tx = '0';        -- start bit (falling edge)
      wait for BITT * 3 / 2;      -- to the middle of data bit 0
      for i in 0 to 7 loop
        bb(i) := tx;              -- LSB first
        wait for BITT;
      end loop;
    end procedure;
  begin
    rst <= '1'; wait for 100 ns; wait until rising_edge(clk); rst <= '0';
    wait for 50 ns;

    -- after reset the link announces the current mode first (diag=0 -> 0xF0)
    rxb(b);
    assert b = x"F0" report "FAIL initial mode byte = " & integer'image(to_integer(unsigned(b))) severity failure;
    report "PASS initial mode 0xF0";

    game <= "000011";             -- game 3 -> expect 0x40 | 3 = 0x43
    rxb(b);
    assert b = x"43" report "FAIL game byte = " & integer'image(to_integer(unsigned(b))) severity failure;
    report "PASS game 0x43";

    sound <= "00101";             -- sound 5 -> expect 0x80 | 5 = 0x85
    rxb(b);
    assert b = x"85" report "FAIL sound byte = " & integer'image(to_integer(unsigned(b))) severity failure;
    report "PASS sound 0x85";

    diag <= '1';                  -- enter diag -> expect mode token 0xF0 | 1 = 0xF1
    rxb(b);
    assert b = x"F1" report "FAIL diag-on token = " & integer'image(to_integer(unsigned(b))) severity failure;
    report "PASS diag token 0xF1";

    game_running <= '1';          -- game starts -> expect game-state 0xF2 | 1 = 0xF3
    rxb(b);
    assert b = x"F3" report "FAIL game-running byte = " & integer'image(to_integer(unsigned(b))) severity failure;
    report "PASS game-running 0xF3";

    game_running <= '0';          -- game over -> expect 0xF2
    rxb(b);
    assert b = x"F2" report "FAIL game-over byte = " & integer'image(to_integer(unsigned(b))) severity failure;
    report "PASS game-over 0xF2";

    report "===== SOUND_LINK TESTS PASSED =====";
    done <= true; wait;
  end process;
end sim;
