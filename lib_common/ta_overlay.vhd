-- ta_overlay.vhd : paint ONE injected 7-character string onto ONE display of a
-- Gottlieb System-80 numeric glass WITHOUT taking the glass away from the game.
-- Part of GottFA80_PLuS (GPL-3.0).  Pstore 2026-07-27.
--
-- WHY THIS EXISTS
-- ---------------
-- The first time-attack overlay switched the WHOLE display subsystem over to
-- boot_message: SYS80 drove the digit strobes from bm_digit_strobe and the whole
-- 24-bit segment bus from bm_segments.  The countdown was visible but the player
-- lost the score, which is the point of playing.  In a one-player game the ROM
-- only ever writes the player-1 display, so displays 2/3/4 are dark and free.
--
-- HOW THE SYSTEM-80 GLASS IS ADDRESSED (see the mapping proof in SYS80.vhd)
-- ------------------------------------------------------------------------
-- U5 PA0..PA3 is a digit strobe that an external 1-of-16 decoder (74154, Z33)
-- turns into 16 digit-enable lines shared by every display in the backbox.  The
-- three 8-bit segment groups on J2 are the DATA:
--     group A = disp_segments(1..8)   player 1 + player 2
--     group B = disp_segments(9..16)  player 3 + player 4
--     group C = disp_segments(17..24) status / credit + ball
-- Which physical digit lights is therefore (segment group) x (strobe), and that
-- relation lives in the backbox wiring -- it is the SAME whether the game ROM or
-- the FPGA drives the bus.  Three strobe windows exist:
--
--   window L (low  half of a group) : strobe 0..5  = the six score digits,
--                                     rightmost/units digit first,
--                                     strobe 15    = the 7th digit (80A glass)
--   window H (high half of a group) : strobe 6..11 = the six score digits,
--                                     strobe 12    = the 7th digit (80A glass)
--   window S (status)               : strobe 12..15 = the four status digits
--
-- The character index inside the 7-char string runs 7 (units) .. 1 (millions),
-- exactly as lib_common/boot_message.vhd does it -- this module is a strobe-slaved
-- re-implementation of that same table, so anything boot_message renders correctly
-- on display 1 this module renders identically on the display it is pointed at.
--
-- WHY NOT REUSE boot_message
-- --------------------------
-- boot_message owns a free-running counter (0..16000 @ 895 kHz) that generates
-- BOTH the strobe and the data.  Its phase is unrelated to the ROM's multiplex, so
-- letting it drive the segments while the ROM drives the strobes would smear each
-- character across whatever digit the ROM happened to be lighting.  This module has
-- no counter at all: it is a pure function of the strobe the ROM is driving RIGHT
-- NOW, so it cannot fight the ROM's timing.
--
-- OUTPUTS are registered on clk (50 MHz) so no combinational hazard from the 4-bit
-- strobe can reach the segment pins; a 20 ns skew against a ~1 ms digit dwell is
-- irrelevant.
--
-- SECOND / THIRD STRING: this entity is a pure combinational map plus one output
-- register -- instantiate it again with another `dstr` and another `sel` and OR the
-- hit flags in SYS80 (they are mutually exclusive as long as the sel values differ).
-- No shared state, no arbitration.  Only the ESP-side frame type would have to be
-- added in disp_inject.  Deliberately NOT done here: no content to put there yet.

library ieee;
use ieee.std_logic_1164.all;

entity ta_overlay is
  port (
    clk    : in  std_logic;                      -- 50 MHz
    strobe : in  std_logic_vector(3 downto 0);   -- the ROM's LIVE digit strobe = U5_pa_out(3..0)
    sel    : in  std_logic_vector(2 downto 0);   -- where to paint, see table below
    dstr   : in  string(1 to 7);                 -- the injected string, right justified
    -- '1' => SYS80 must replace this segment group for the current strobe
    hit_a  : out std_logic;                      -- group A  disp_segments(1..8)
    hit_b  : out std_logic;                      -- group B  disp_segments(9..16)
    hit_c  : out std_logic;                      -- group C  disp_segments(17..24)
    seg    : out std_logic_vector(1 to 8)        -- the pattern to put there
  );
end ta_overlay;

architecture rtl of ta_overlay is
  signal ch_r : character := ' ';
  signal ha_r : std_logic := '0';
  signal hb_r : std_logic := '0';
  signal hc_r : std_logic := '0';
begin

  -- same decoder boot_message uses, so the glyphs are bit-identical to the banner
  DEC : entity work.sn7448_gtb
    port map ( Din => ch_r, Dout => seg );

  hit_a <= ha_r;
  hit_b <= hb_r;
  hit_c <= hc_r;

  SELP : process (clk)
    variable i_lo, i_hi, i_st, idx : integer range 0 to 7;
    variable grp             : integer range 0 to 2;   -- 0=A 1=B 2=C
  begin
    if rising_edge(clk) then

      -- window L : low half of a segment group (player 1 on A, player 3 on B)
      case strobe is
        when x"0"   => i_lo := 7;   -- units
        when x"1"   => i_lo := 6;
        when x"2"   => i_lo := 5;
        when x"3"   => i_lo := 4;
        when x"4"   => i_lo := 3;
        when x"5"   => i_lo := 2;
        when x"F"   => i_lo := 1;   -- 7th digit, 80A glass only
        when others => i_lo := 0;   -- 0 = this strobe is not ours
      end case;

      -- window H : high half of a segment group (player 2 on A, player 4 on B)
      case strobe is
        when x"6"   => i_hi := 7;   -- units
        when x"7"   => i_hi := 6;
        when x"8"   => i_hi := 5;
        when x"9"   => i_hi := 4;
        when x"A"   => i_hi := 3;
        when x"B"   => i_hi := 2;
        when x"C"   => i_hi := 1;   -- 7th digit, 80A glass only
        when others => i_hi := 0;
      end case;

      -- window S : the four status-display strobes (also the probe window for the
      -- group A / group B positions the 6-digit ROM never writes)
      case strobe is
        when x"C"   => i_st := 4;
        when x"D"   => i_st := 5;
        when x"E"   => i_st := 6;
        when x"F"   => i_st := 7;
        when others => i_st := 0;
      end case;

      case sel is
        when "000"  => idx := i_hi; grp := 0;  -- PLAYER 2  (default: free in a 1-player game)
        when "001"  => idx := i_lo; grp := 0;  -- PLAYER 1  (sanity check / same place as the old overlay)
        when "010"  => idx := i_hi; grp := 1;  -- PLAYER 4
        when "011"  => idx := i_lo; grp := 1;  -- PLAYER 3
        when "100"  => idx := i_st; grp := 2;  -- STATUS / credit display
        when "101"  => idx := i_st; grp := 0;  -- PROBE: group A on strobes 12..15
        when "110"  => idx := i_st; grp := 1;  -- PROBE: group B on strobes 12..15
        when others => idx := 0;  grp := 0;  -- "111" = full overlay, handled in SYS80
      end case;

      if idx = 0 then
        ch_r <= ' ';
        ha_r <= '0'; hb_r <= '0'; hc_r <= '0';
      else
        ch_r <= dstr(idx);
        if grp = 0 then
          ha_r <= '1'; hb_r <= '0'; hc_r <= '0';
        elsif grp = 1 then
          ha_r <= '0'; hb_r <= '1'; hc_r <= '0';
        else
          ha_r <= '0'; hb_r <= '0'; hc_r <= '1';
        end if;
      end if;

    end if;
  end process;

end rtl;
