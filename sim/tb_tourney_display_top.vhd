-- tb_tourney_display_top.vhd : self-checking testbench for the full time-attack display
-- subsystem (tick gen + countdown + value->string).
--   ghdl -a lib_common/bin_to_bcd.vhd lib_common/value_to_dispstr.vhd \
--          lib_common/tourney_countdown.vhd lib_common/tourney_display_top.vhd \
--          sim/tb_tourney_display_top.vhd
--   ghdl -e tb_tourney_display_top && ghdl -r tb_tourney_display_top
-- Expect: "===== TOURNEY_DISPLAY_TOP TESTS PASSED ====="
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_tourney_display_top is end tb_tourney_display_top;

architecture sim of tb_tourney_display_top is
  constant CP : time := 10 ns;
  signal clk, rst, gr, tm, arm, dead : std_logic := '0';
  signal dstr : string(1 to 7);
  signal val  : unsigned(23 downto 0);
  signal done : boolean := false;
begin
  -- START 50, DECAY 10, tick every 4 clk so the countdown moves fast in sim
  DUT : entity work.tourney_display_top
    generic map ( WIDTH => 24, START_VAL => 50, DECAY => 10, TICK_DIV => 4 )
    port map ( clk => clk, rst => rst, game_running => gr, tournament_mode => tm,
               arm => arm, dstr => dstr, final_value => val, dead => dead );

  clk <= not clk after CP/2 when not done else '0';

  stim : process
    procedure chk(msg : string; ev : integer; es : string) is
    begin
      assert to_integer(val) = ev report "FAIL " & msg & " val=" & integer'image(to_integer(val)) severity failure;
      assert dstr = es           report "FAIL " & msg & " str=[" & dstr & "]" severity failure;
      report "ok " & msg & " -> " & integer'image(ev) & " [" & dstr & "]";
    end procedure;
  begin
    rst <= '1'; wait for 50 ns; wait until rising_edge(clk); rst <= '0';
    wait until rising_edge(clk);
    assert arm = '0' report "FAIL arm should be 0 when idle" severity failure;

    -- start a time-attack game
    gr <= '1'; tm <= '1';
    wait until rising_edge(clk); wait until rising_edge(clk);
    assert arm = '1' report "FAIL arm should be 1 in time-attack game" severity failure;
    chk("loaded", 50, "     50");

    -- let ~5 ticks pass (TICK_DIV=4 -> ~4 clk each); check it has decayed toward 0
    for i in 1 to 30 loop wait until rising_edge(clk); end loop;
    assert to_integer(val) <= 10 report "FAIL did not decay" severity failure;
    report "ok decayed to " & integer'image(to_integer(val)) & " [" & dstr & "]";

    -- run long enough to hit 0 (dead) and clamp
    for i in 1 to 30 loop wait until rising_edge(clk); end loop;
    chk("clamped 0 + dead", 0, "      0");
    assert dead = '1' report "FAIL dead should be 1 at 0" severity failure;

    -- game over: value frozen, arm drops
    gr <= '0';
    wait until rising_edge(clk); wait until rising_edge(clk);
    assert arm = '0' report "FAIL arm should drop at game over" severity failure;

    report "===== TOURNEY_DISPLAY_TOP TESTS PASSED =====";
    done <= true; wait;
  end process;
end architecture;
