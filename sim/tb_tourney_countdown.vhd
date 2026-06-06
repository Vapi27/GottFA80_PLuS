-- tb_tourney_countdown.vhd : self-checking testbench for tourney_countdown.
--   ghdl -a lib_common/tourney_countdown.vhd sim/tb_tourney_countdown.vhd
--   ghdl -e tb_tourney_countdown && ghdl -r tb_tourney_countdown
-- Expect: "===== TOURNEY_COUNTDOWN TESTS PASSED ====="
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_tourney_countdown is end tb_tourney_countdown;

architecture sim of tb_tourney_countdown is
  constant CP : time := 10 ns;
  signal clk, rst, run, tick : std_logic := '0';
  signal value : unsigned(23 downto 0);
  signal dead  : std_logic;
  signal done  : boolean := false;
begin
  -- small START/DECAY so the countdown reaches 0 in a few ticks
  DUT : entity work.tourney_countdown
    generic map ( WIDTH => 24, START_VAL => 50, DECAY => 10 )
    port map ( clk => clk, rst => rst, run => run, tick => tick, value => value, dead => dead );

  clk <= not clk after CP/2 when not done else '0';

  stim : process
    procedure do_tick is
    begin
      wait until rising_edge(clk); tick <= '1';
      wait until rising_edge(clk); tick <= '0';
      wait until rising_edge(clk);            -- let the register settle
    end procedure;
    procedure chk(msg : string; ev : integer; ed : std_logic) is
    begin
      assert to_integer(value) = ev report "FAIL " & msg & " value" severity failure;
      assert dead = ed report "FAIL " & msg & " dead" severity failure;
      report "ok " & msg;
    end procedure;
  begin
    rst <= '1'; wait for 50 ns; wait until rising_edge(clk); rst <= '0';
    wait until rising_edge(clk);
    chk("reset=0/dead", 0, '1');

    run <= '1';                               -- game start -> load 50
    wait until rising_edge(clk); wait until rising_edge(clk);
    chk("start=load 50", 50, '0');

    do_tick; chk("t1 -> 40", 40, '0');
    do_tick; chk("t2 -> 30", 30, '0');
    do_tick; chk("t3 -> 20", 20, '0');
    do_tick; chk("t4 -> 10", 10, '0');
    do_tick; chk("t5 -> 0 + dead", 0, '1');
    do_tick; chk("t6 clamps at 0", 0, '1');   -- stays at 0

    run <= '0';                               -- game over: value frozen for the score read
    wait until rising_edge(clk); wait until rising_edge(clk);
    chk("game over frozen", 0, '1');

    report "===== TOURNEY_COUNTDOWN TESTS PASSED =====";
    done <= true; wait;
  end process;
end architecture;
