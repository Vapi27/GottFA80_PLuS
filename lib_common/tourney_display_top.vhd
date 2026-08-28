-- tourney_display_top.vhd : the complete time-attack display subsystem, in one module.
--
-- Bundles the whole chain so SYS80 needs ONE instantiation + a 2-line display mux:
--   game_running + tournament_mode -> 1 Hz tick -> tourney_countdown (1M, -10K/s, clamp 0)
--   -> value_to_dispstr (-> 7-char string). Feed `dstr` to a boot_message display input and,
--   when `arm`='1', let boot_message's segments/strobes win the display mux during gameplay
--   (today boot_message only runs when game_running='0'). `final_value` = the score at game
--   over (send on the link -> tourney::recordScore). START_VAL/DECAY are the compile-time
--   defaults; the optional cfg_start/cfg_decay ports let the ESP drive them at run time from a
--   lisyctrl register (0 on a cfg port = use the generic default), so the on-display countdown
--   always matches the operator's chosen start/decay in the web UI.
-- (C) 2026 Valere Pillet / Pstore.  Part of GottFA80 (GPL-3.0).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tourney_display_top is
  generic (
    WIDTH     : natural := 24;
    START_VAL : natural := 1000000;
    DECAY     : natural := 10000;
    TICK_DIV  : natural := 50000000     -- clk cycles per "second" (50 MHz -> 1 Hz); small in sim
  );
  port (
    clk             : in  std_logic;
    rst             : in  std_logic;
    game_running    : in  std_logic;
    tournament_mode : in  std_logic;            -- time-attack armed
    cfg_start       : in  unsigned(WIDTH-1 downto 0) := (others => '0');  -- run-time start (0 => generic)
    cfg_decay       : in  unsigned(WIDTH-1 downto 0) := (others => '0');  -- run-time decay (0 => generic)
    arm             : out std_logic;            -- '1' => SYS80 shows our display (mux enable)
    dstr            : out string(1 to 7);       -- countdown as text -> boot_message display input
    final_value     : out unsigned(WIDTH-1 downto 0);
    dead            : out std_logic
  );
end entity;

architecture rtl of tourney_display_top is
  signal run   : std_logic;
  signal tick  : std_logic := '0';
  signal val   : unsigned(WIDTH-1 downto 0);
  signal tickc : integer range 0 to TICK_DIV-1 := 0;
begin
  run <= game_running and tournament_mode;
  arm <= run;

  -- 1 Hz tick from clk
  process (clk, rst)
  begin
    if rst = '1' then
      tickc <= 0; tick <= '0';
    elsif rising_edge(clk) then
      if tickc = TICK_DIV - 1 then tickc <= 0; tick <= '1';
      else                         tickc <= tickc + 1; tick <= '0'; end if;
    end if;
  end process;

  CD : entity work.tourney_countdown
    generic map ( WIDTH => WIDTH, START_VAL => START_VAL, DECAY => DECAY )
    port map ( clk => clk, rst => rst, run => run, tick => tick,
               cfg_start => cfg_start, cfg_decay => cfg_decay, value => val, dead => dead );

  V2S : entity work.value_to_dispstr
    generic map ( IN_W => WIDTH )
    port map ( value => val, dstr => dstr );

  final_value <= val;
end architecture;
