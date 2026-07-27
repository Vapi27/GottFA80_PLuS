-- snd_bus.vhd : Gottlieb System 80 sound-bus EVENT generator.
-- part of GottFA80_PLuS (GPL-3.0)
--
-- ===========================================================================
-- WHY THIS EXISTS
-- ===========================================================================
-- The 5-bit sound code {S16,S8,S4,S2,S1} in SYS80.vhd is PURELY COMBINATIONAL:
--   S1..S8 = not U6_pa_out(n) and not U6_pa_out(4)      (RIOT U6 port-A latch)
--   S16    = one bit of a 74175 clocked by a LAMP-latch write (DS3 on 80/80A,
--            DS2 on 80B)
-- so the vector moves for two reasons that are NOT a sound command:
--   * a LAMP write flips the S16 bit          -> a phantom cue, every attract
--     animation frame;
--   * the CPU RELEASES the bus (PA4 high)     -> S1..S8 all drop to 0 while S16
--     keeps whatever the lamp latch holds, so the vector reads 0 *or 16*.
--     ### That is the RTL explanation of the long-standing "cmd 16 = constant
--     ### background hum, ignore it" note on Arena: cmd 16 is the bus RELEASE
--     ### seen through a high S16 lamp bit, not a cue.
--
-- PinMAME models the same board and does neither (src/wpc/gts80.c):
--   static WRITE_HANDLER(riot6532_2a_w) {          <-- runs ONLY on a PA write
--     data = ~data;
--     if (soundBoard == SNDBRD_GTS80B) { if (data & 0x10) sndCmd(...); }
--     else                             { sndCmd( ... (data&0x10) ? data&0x0f : 0 ); }
--   }
-- i.e. the command is re-evaluated only on a port-A write and qualified by
-- `data & 0x10` == `not U6_pa_out(4)`.  This module reproduces exactly that:
-- one EVENT per ORA write, never one per bus change.
--
-- ===========================================================================
-- TIMING (the reason pa_wr comes from R6532 and is not re-decoded here)
-- ===========================================================================
-- R6532 latches ORA on rising_edge(phi2) and updates pa_out on the following
-- falling_edge(phi2); pa_wr is registered on that SAME falling edge, so
-- pa_wr='1' <=> pa_out already carries the freshly written value.  phi2 is
-- `not cpu_clk`, and cpu_clk is a clk_50-registered divider output, so phi2's
-- edges land on clk_50 edges and this two-stage edge detector is a plain
-- synchronous edge detect, not a CDC.  `stb` is emitted 2 clk_50 cycles after
-- pa_out settled -- ample for the combinational sound vector and for the
-- 74175 S16 latch (which is itself clk_50-synchronous and can only move on a
-- DIFFERENT CPU cycle, >= 3 phi2 periods = ~170 clk_50 away).
--
-- ===========================================================================
-- RELEASE DE-DUPLICATION -- deliberate, and why it is not a lost event
-- ===========================================================================
-- U6 port A is shared: PA0..3 = sound code, PA4 = sound strobe, PA5..7 =
-- solenoid selects (PinMAME riot6532_2a_w again).  So the CPU writes PA for
-- every solenoid too, always with the sound strobe inactive.  Emitting one
-- REL per such write would put a few hundred 0x30 bytes/s of pure noise on the
-- link and in /sndtrace.  A release is a TRANSITION ("the bus let go"), so
-- only the first not-selected write after a selected one is an event.  The
-- sequences the ESP cares about are unaffected:
--     header, release, payload      -> SND, REL, SND   (80B bank cue)
--     the same cue fired twice      -> SND, REL, SND   (a release always sits
--                                      between, that is how the latch works)
-- and after reset sel_r starts at '0', so no phantom REL is emitted for the
-- power-up state of the bus (SOUND_WIRE.md 2.2 rule 6).
--
-- The command bits themselves are NOT carried here: sound_link samples its
-- `sound` input on `stb`, and `sound` is stable long before the pulse.
---------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

entity snd_bus is
  port (
    clk   : in  std_logic;                 -- clk_50
    rst   : in  std_logic;                 -- active-high reset (not reset_l)
    pa_wr : in  std_logic;                 -- R6532 U6 ORA-write flag (phi2 domain)
    sel   : in  std_logic;                 -- '1' = a sound code is selected on the bus
                                           --       ( = not U6_pa_out(4), test button folded in )
    stb   : out std_logic := '0';          -- one clk pulse = one sound-bus EVENT
    rel   : out std_logic := '0'           -- valid with stb: '1' = RELEASE, '0' = command
  );
end snd_bus;

architecture rtl of snd_bus is
  signal d1, d2 : std_logic := '0';        -- pa_wr edge detect
  signal sel_r  : std_logic := '0';        -- was a code selected at the previous event?
begin

  process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        d1 <= '0'; d2 <= '0'; sel_r <= '0'; stb <= '0'; rel <= '0';
      else
        d1  <= pa_wr;
        d2  <= d1;
        stb <= '0';
        if d1 = '1' and d2 = '0' then          -- the CPU has just written U6 port A
          if sel = '1' then                    -- a code is on the bus -> a cue
            stb <= '1'; rel <= '0'; sel_r <= '1';
          elsif sel_r = '1' then               -- selected -> idle : ONE release event
            stb <= '1'; rel <= '1'; sel_r <= '0';
          end if;                              -- idle -> idle (solenoid write): nothing
        end if;
      end if;
    end if;
  end process;

end rtl;
