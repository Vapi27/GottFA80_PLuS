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
--   window L (low  half of a group) : strobe 0..5  = six score digits,
--                                     strobe 15    = the 7th digit (80A glass)
--   window H (high half of a group) : strobe 6..11 = six score digits,
--                                     strobe 12    = the 7th digit (80A glass)
--   window S (status)               : strobe 12..15 = the four status digits
--
-- The character index inside the 7-char string runs 7 (units) .. 1 (millions).
--
-- ===========================================================================
-- WHICH DIGIT IS THE 7TH -- and which way the status display runs
-- (both fixed 2026-07-27; each was checked against TWO independent references)
-- ===========================================================================
-- REFERENCE 1: lib_common/boot_message.vhd, whose banner lands on the right
-- digits of the owner's real (6-digit, System 80) glass.  Reading its refresh
-- cycle out, for segment group A:
--     strobe 0,1,2,3,4,5 -> display1 chars 7,6,5,4,3,2   (units first)
--     strobe 6..11       -> display2 chars 7,6,5,4,3,2
--     strobe 12          -> display2 char 1     |  the 7th-digit slots; NEVER
--     strobe 15          -> display1 char 1     |  exercised on a 6-digit glass
-- and for group C (status): strobe 12,13,14 -> status_d 7,6,5 (and 15 -> 4,
-- which boot_message got wrong -- it wrote status_d(7) a second time; fixed in
-- the same commit, no functional effect there because SYS80 passes a constant
-- blank status_d).
--
-- REFERENCE 2: PinMAME src/wpc/gts80.c riot6532_1aBCD_w:
--     static const int reorder[] = {8,0,1,15,9,10,11,12,13,14,2,3,4,5,6,7};
--     int pos = reorder[15 - dispdata];      -- dispdata = the 4-bit strobe
--     segments[pos]      = group A     segments[20+pos] = group B
--     segments[55-dispdata] = group C
-- and the layouts in src/wpc/gts80games.c, with core_dispLayout =
-- {top,left,start,length,type} (src/wpc/core.h:226) so `start` is the LEFTMOST
-- digit and the index grows to the RIGHT:
--     6-digit (dispNumeric1) : {0,0, 2,6}  -> display 1 = segments 2..7
--     7-digit (dispNumeric3) : {0,0, 2,7}  -> display 1 = segments 2..8
--     status  : DISP_SEG_CREDIT(40,41) = cols 2,4 ; DISP_SEG_BALLS(42,43) = cols 8,10
--
-- Evaluating reorder: strobe 0..5 -> pos 7,6,5,4,3,2 and strobe 15 -> pos 8.
--   * On the 6-digit glass (segments 2..7) strobe 0 = pos 7 = the RIGHTMOST of
--     the six = units.  Agrees with boot_message.  Strobe 15 = pos 8 = off the
--     end = not wired.  So on System 80 / 80B this module must NOT claim
--     strobe 15 (nor strobe 12 in the high window) at all.
--   * On the 7-digit glass (segments 2..8) pos 8 IS wired and it is the
--     RIGHTMOST digit, i.e. strobe 15 is the UNITS digit and strobes 0..5 are
--     tens .. millions.  The extra digit is at the right-hand end, not the
--     left.  boot_message assumes the opposite (it puts char 1, the most
--     significant, on strobe 15); that mapping has never been exercised on
--     hardware -- the owner's machine is 6-digit -- and is left alone here
--     because changing it needs a family input threaded into boot_message.
--     ta_overlay follows PinMAME, which is the only reference that has ever
--     driven a 7-digit 80A glass.
-- Status window: strobe 12,13,14,15 -> segments 43,42,41,40, i.e. DESCENDING
-- segment index for ASCENDING strobe, so strobe 12 is the rightmost status
-- digit and strobe 15 the leftmost -> chars 7,6,5,4.  This module had it
-- exactly backwards (4,5,6,7).  Both references agree; both say 7,6,5,4.
-- ===========================================================================
--
-- sim/tb_ta_overlay.vhd co-simulates boot_message and asserts that the two
-- multiplex tables agree cell by cell for the 6-digit case, so they cannot
-- drift apart; the 7-digit case is asserted against the reorder[] table above.
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
    -- '1' = 7-digit score glass (System 80A).  lib_common/gts_family.vhd
    -- f_has_7digit(not game_select); SYS80.vhd passes the registered `has_7digit`.
    -- The 7th digit is NOT a leading digit: it sits at the RIGHT-HAND (units) end
    -- and the other six shift one place left, so the whole low/high window map
    -- changes.  See the WHICH DIGIT IS THE 7TH block below.
    has7   : in  std_logic := '0';
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
      if has7 = '1' then
        -- 7-digit glass: strobe 15 is the UNITS digit, the other six shift left
        case strobe is
          when x"F"   => i_lo := 7;   -- units  (the 7th-digit board)
          when x"0"   => i_lo := 6;
          when x"1"   => i_lo := 5;
          when x"2"   => i_lo := 4;
          when x"3"   => i_lo := 3;
          when x"4"   => i_lo := 2;
          when x"5"   => i_lo := 1;
          when others => i_lo := 0;   -- 0 = this strobe is not ours
        end case;
      else
        -- 6-digit glass: strobe 15 is not wired to anything in this group
        case strobe is
          when x"0"   => i_lo := 7;   -- units
          when x"1"   => i_lo := 6;
          when x"2"   => i_lo := 5;
          when x"3"   => i_lo := 4;
          when x"4"   => i_lo := 3;
          when x"5"   => i_lo := 2;
          when others => i_lo := 0;
        end case;
      end if;

      -- window H : high half of a segment group (player 2 on A, player 4 on B)
      if has7 = '1' then
        case strobe is
          when x"C"   => i_hi := 7;   -- units  (the 7th-digit board)
          when x"6"   => i_hi := 6;
          when x"7"   => i_hi := 5;
          when x"8"   => i_hi := 4;
          when x"9"   => i_hi := 3;
          when x"A"   => i_hi := 2;
          when x"B"   => i_hi := 1;
          when others => i_hi := 0;
        end case;
      else
        case strobe is
          when x"6"   => i_hi := 7;   -- units
          when x"7"   => i_hi := 6;
          when x"8"   => i_hi := 5;
          when x"9"   => i_hi := 4;
          when x"A"   => i_hi := 3;
          when x"B"   => i_hi := 2;
          when others => i_hi := 0;
        end case;
      end if;

      -- window S : the four status-display strobes (also the probe window for the
      -- group A / group B positions the 6-digit ROM never writes).
      -- Strobe 12 is the RIGHTMOST status digit, 15 the leftmost -> 7,6,5,4.
      -- This is family independent: the status display is 4 digits on 80 and 80A.
      case strobe is
        when x"C"   => i_st := 7;
        when x"D"   => i_st := 6;
        when x"E"   => i_st := 5;
        when x"F"   => i_st := 4;
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
