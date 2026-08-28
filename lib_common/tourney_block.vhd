-- tourney_block.vhd : tournament-mode solenoid suppressor for GottFA80_PLuS.
--
-- In tournament mode we want to neutralise a "free-game" / unfair solenoid (typically the
-- KNOCKER that fires on replay/match/special) without patching the game ROM. The FPGA sees
-- the raw MPU solenoid/sound port (SYS80.vhd `u6pa_src`), and the actual 1-of-N solenoid
-- decoding happens on the pinball. So we intercept the SELECT field: when tournament_mode='1'
-- and this cycle drives the blocked solenoid, we remap the select to a NO-OP code the external
-- decoder ignores -> that solenoid never fires; every other solenoid + all sound pass through.
--
-- ISOLATED + OFF BY DEFAULT: tournament_mode='0' (or sol_active='0', or code mismatch) =>
-- EXACT passthrough, so inserting this changes nothing until tournament mode is armed.
-- The per-game BLOCK_CODE (which select pattern = the knocker) comes from the System 80
-- solenoid map / schematic -> verify with Ralf + on hardware before enabling.
-- (C) 2026 Valere Pillet / Pstore.  Part of GottFA80 (GPL-3.0).
library ieee;
use ieee.std_logic_1164.all;

entity tourney_block is
  generic (
    SEL_HI     : natural := 3;                 -- solenoid-select field: high bit
    SEL_LO     : natural := 0;                  --                        low bit
    BLOCK_CODE : std_logic_vector := "1001";   -- select code of the solenoid to suppress (per game)
    NOOP_CODE  : std_logic_vector := "1111"    -- a select code the decoder maps to NO solenoid
  );
  port (
    port_in         : in  std_logic_vector(7 downto 0);  -- raw game solenoid/sound port (u6pa_src)
    sol_active      : in  std_logic;                     -- '1' = this cycle drives a solenoid (not sound)
    tournament_mode : in  std_logic;                     -- '1' = suppress the blocked solenoid
    port_out        : out std_logic_vector(7 downto 0)
  );
end entity;

architecture rtl of tourney_block is
  signal sel : std_logic_vector(SEL_HI - SEL_LO downto 0);
begin
  sel <= port_in(SEL_HI downto SEL_LO);
  process (port_in, sol_active, tournament_mode, sel)
  begin
    port_out <= port_in;                                 -- default: exact passthrough
    if tournament_mode = '1' and sol_active = '1' and sel = BLOCK_CODE then
      port_out(SEL_HI downto SEL_LO) <= NOOP_CODE;       -- remap select -> decoder fires nothing
    end if;
  end process;
end architecture;
