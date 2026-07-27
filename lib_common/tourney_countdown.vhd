-- tourney_countdown.vhd : "time attack" score timer for GottFA80_PLuS tournament mode.
--
-- While run='1' (a time-attack game is in play), counts DOWN from START_VAL by DECAY each
-- 'tick' (a ~1 Hz strobe = one per second), clamped at 0. The value is meant to be shown
-- live on the pinball DISPLAY (drawn as BCD the same way boot_message.vhd draws the boot
-- info) so the player sees their score "dying", and it IS the final score reported at
-- game over (so the ESP needs no pinball-score read for this mode). 'dead'='1' at 0.
--
-- run rising edge = new game -> (re)load the start value. run='0' freezes the value (game over:
-- read 'value' for the score). START_VAL/DECAY are the COMPILE-TIME defaults; the optional
-- run-time ports cfg_start/cfg_decay override them when non-zero, so the ESP can set the
-- start points and decay/sec from the web UI via a lisyctrl register (a value of 0 on a cfg
-- port = "use the generic default", which keeps every existing instantiation/testbench that
-- leaves them unconnected behaving exactly as before). Pure, synthesizable, sim-checked.
-- (C) 2026 Valere Pilpil / Pstore.  Part of GottFA80 (GPL-3.0).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tourney_countdown is
  generic (
    WIDTH     : natural := 24;          -- bits (>= 20 for 1,000,000)
    START_VAL : natural := 1000000;     -- default starting points (cfg_start overrides if /= 0)
    DECAY     : natural := 10000         -- default points lost per tick (cfg_decay overrides if /= 0)
  );
  port (
    clk       : in  std_logic;
    rst       : in  std_logic;              -- async reset
    run       : in  std_logic;              -- '1' = time-attack game in progress
    tick      : in  std_logic;              -- 1-cycle strobe, one per "second"
    cfg_start : in  unsigned(WIDTH-1 downto 0) := (others => '0');  -- run-time start (0 => use START_VAL)
    cfg_decay : in  unsigned(WIDTH-1 downto 0) := (others => '0');  -- run-time decay (0 => use DECAY)
    value     : out unsigned(WIDTH-1 downto 0);  -- current countdown (= live score)
    dead      : out std_logic               -- '1' when the score has hit 0
  );
end entity;

architecture rtl of tourney_countdown is
  signal v         : unsigned(WIDTH-1 downto 0) := (others => '0');
  signal run_d     : std_logic := '0';
  -- effective start/decay: the run-time cfg when non-zero, else the generic default
  signal start_eff : unsigned(WIDTH-1 downto 0);
  signal decay_eff : unsigned(WIDTH-1 downto 0);
  -- decay LATCHED at game start (symmetric with the start value) so a whole game uses one rate
  signal decay_l   : unsigned(WIDTH-1 downto 0) := (others => '0');
begin
  start_eff <= cfg_start when cfg_start /= 0 else to_unsigned(START_VAL, WIDTH);
  decay_eff <= cfg_decay when cfg_decay /= 0 else to_unsigned(DECAY, WIDTH);

  process (clk, rst)
  begin
    if rst = '1' then
      v <= (others => '0'); run_d <= '0'; decay_l <= (others => '0');
    elsif rising_edge(clk) then
      run_d <= run;
      if run = '1' and run_d = '0' then                 -- game start -> latch BOTH start value and decay rate
        v       <= start_eff;
        decay_l <= decay_eff;
      elsif run = '1' and tick = '1' then               -- each second -> decay (by the latched rate), clamp at 0
        if v > decay_l then
          v <= v - decay_l;
        else
          v <= (others => '0');
        end if;
      end if;
    end if;
  end process;
  value <= v;
  dead  <= '1' when v = 0 else '0';
end architecture;
