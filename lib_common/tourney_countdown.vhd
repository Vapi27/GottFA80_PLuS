-- tourney_countdown.vhd : "time attack" score timer for GottFA80_PLuS tournament mode.
--
-- While run='1' (a time-attack game is in play), counts DOWN from START_VAL by DECAY each
-- 'tick' (a ~1 Hz strobe = one per second), clamped at 0. The value is meant to be shown
-- live on the pinball DISPLAY (drawn as BCD the same way boot_message.vhd draws the boot
-- info) so the player sees their score "dying", and it IS the final score reported at
-- game over (so the ESP needs no pinball-score read for this mode). 'dead'='1' at 0.
--
-- run rising edge = new game -> (re)load START_VAL. run='0' freezes the value (game over:
-- read 'value' for the score). DECAY/START_VAL are generics (the ESP can also make them
-- run-time via a register feeding a wider design later). Pure, synthesizable, sim-checked.
-- (C) 2026 Valere Pilpil / Pstore.  Part of GottFA80 (GPL-3.0).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tourney_countdown is
  generic (
    WIDTH     : natural := 24;          -- bits (>= 20 for 1,000,000)
    START_VAL : natural := 1000000;     -- starting points
    DECAY     : natural := 10000         -- points lost per tick (per second)
  );
  port (
    clk   : in  std_logic;
    rst   : in  std_logic;              -- async reset
    run   : in  std_logic;              -- '1' = time-attack game in progress
    tick  : in  std_logic;              -- 1-cycle strobe, one per "second"
    value : out unsigned(WIDTH-1 downto 0);  -- current countdown (= live score)
    dead  : out std_logic               -- '1' when the score has hit 0
  );
end entity;

architecture rtl of tourney_countdown is
  signal v     : unsigned(WIDTH-1 downto 0) := (others => '0');
  signal run_d : std_logic := '0';
begin
  process (clk, rst)
  begin
    if rst = '1' then
      v <= (others => '0'); run_d <= '0';
    elsif rising_edge(clk) then
      run_d <= run;
      if run = '1' and run_d = '0' then                 -- game start -> load
        v <= to_unsigned(START_VAL, WIDTH);
      elsif run = '1' and tick = '1' then               -- each second -> decay, clamp at 0
        if v > to_unsigned(DECAY, WIDTH) then
          v <= v - to_unsigned(DECAY, WIDTH);
        else
          v <= (others => '0');
        end if;
      end if;
    end if;
  end process;
  value <= v;
  dead  <= '1' when v = 0 else '0';
end architecture;
