---------------------------------------------------------------------------
-- gts_family.vhd -- Gottlieb System 80 / 80A / 80B family decode
-- part of GottFA80_PLuS (GPL-3.0)
--
-- ONE bitstream must serve System 80, 80A and 80B.  Everything that differs
-- between the three is decoded HERE, from the 6-bit game number the operator
-- already sets on DIP S1 -- no auto-detect, no guessing from bus activity.
--
-- ===========================================================================
-- THE MAPPING, AND HOW IT WAS ESTABLISHED (2026-07-27)
-- ===========================================================================
-- The GottFA80_PLuS gamelist (manual Appendix A, No 0..62 = DIP S1) is
-- reproduced verbatim in the ESP companion's web UI
-- (gottfa-esp32/data/index.html, const GAMELIST) and is cross-checked by the
-- sound-board table in lib_common/GOSOF80.vhd, which carves the SAME list into
-- the SAME blocks ("0 to 8 Panthera to ForceII", "16 HH", "17 Eclipse",
-- "18/19 Devils Dare", "38/39 Caveman", "40 to 42 Bounty Hu to Tag Team").
-- Every entry was then looked up in PinMAME (src/wpc/gts80games.c) and the
-- family read off the init macro it uses:
--
--   No  0 .. 17  Panthera .. Eclipse          INIT_S80   -> GEN_GTS80   (System 80)
--   No 18 .. 39  Devil's Dare .. Caveman(fl)  INIT_S80A  -> GEN_GTS80A  (System 80A)
--   No 40 .. 62  Bounty Hunter .. Amazon H II INITGAME(..,GEN_GTS80B,..) (System 80B)
--
-- NOTE, because it is the usual trap: Haunted House (16) and Eclipse (17) are
-- System 80, NOT 80A -- PinMAME has INIT_S80(hh,...) and INIT_S80(eclipse,...).
-- The blocks are CONTIGUOUS, so three magnitude comparators decode the family;
-- no per-game table is needed.
--
-- 7-DIGIT SCORE DISPLAYS.  From the PinMAME display layouts at the top of
-- gts80games.c: every GEN_GTS80 game uses dispNumeric1 = "4 x 6 BCD +
-- Ball,Credit"; every GEN_GTS80A game uses dispNumeric3 = "4 x 7 BCD +
-- Ball,Credit" (or a custom layout that DISP_SEG_IMPORTs dispNumeric3 --
-- dispDevilsdare, dispRocky, dispSpirit, dispKrull, dispGoinNuts all do, and
-- dispStriker spells out four 7-char CORE_SEG98F fields).  So
--     has_7digit = is_80A
-- exactly.  (The "...7" clones -- spiderm7, panther7, ... -- are System 80
-- games retro-fitted with a 7-digit glass and use INIT_S80D7; they have no
-- entry of their own in the GottFA gamelist, so they do not affect the ranges.)
--
-- LATE 80B = BANKED 4K GAME PROM.  PinMAME's GTS80B_4K_ROMSTART (gts80.h) is
-- the "8K & 4K game PROM" variant: it splits the 4K game PROM as
--   ROM_LOAD(n1, 0x1000, 0x0800) ROM_CONTINUE(0x9000, 0x0800)
-- i.e. the second 2K appears at $9000-$97FF -- which is exactly what
-- SYS80.vhd's game_rom2_cs decodes (cpu_addr(13 downto 11)="010" and
-- cpu_addr(15)='1').  Grepping gts80games.c, GTS80B_4K_ROMSTART is used by
-- EXACTLY six parent sets: excaliba, badgirls, bighouse, hotshots, bonebstr,
-- nmoves = gamelist 56, 57, 58, 59, 60, 61.  Amazon Hunt II (62) uses
-- GTS80B_8K_ROMSTART (single 8K PROM, no bank) and 63 is not a game, so
--     late_80B = 56 .. 61,  NOT 56 .. 63.
--
-- ===========================================================================
-- CONVENTION: every function takes the TRUE game number.  In SYS80.vhd the
-- DIP signal `game_select` is INVERTED (a closed switch reads '0'); the true
-- number is `not game_select` -- as used by nor_flash `selection`, GOSOF80
-- `game_sel`, the EEprom `selection` and (via byte_to_ascii's internal `not
-- mybyte`) the boot banner.  Pass `not game_select`, never `game_select`.
--
-- COST: all five functions are pure combinational magnitude tests on 6 bits;
-- the whole package synthesises to a handful of LEs (LAB budget is the binding
-- constraint on this device -- 366/392 LABs before this change).
---------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

package gts_family is
  -- g = TRUE game number (0..62), i.e. `not game_select` in SYS80.vhd
  function f_is_80      (g : std_logic_vector(5 downto 0)) return std_logic;
  function f_is_80A     (g : std_logic_vector(5 downto 0)) return std_logic;
  function f_is_80B     (g : std_logic_vector(5 downto 0)) return std_logic;
  function f_has_7digit (g : std_logic_vector(5 downto 0)) return std_logic;
  function f_late_80B   (g : std_logic_vector(5 downto 0)) return std_logic;
end package gts_family;

package body gts_family is

  -- System 80 : 0 .. 17  ("000000" .. "010001")
  --   g(5)='0'  and ( g(4)='0'  or  g(3 downto 1)="000" )
  --   g(5)=0 -> 0..31; within that, g(4)=0 -> 0..15 (all 80); g(4)=1 -> 16..31,
  --   of which only 16 and 17 are 80, i.e. g(3)=g(2)=g(1)='0'.
  function f_is_80 (g : std_logic_vector(5 downto 0)) return std_logic is
  begin
    return (not g(5)) and ((not g(4)) or (not (g(3) or g(2) or g(1))));
  end function;

  -- System 80B : 40 .. 62 (and the unused 63)
  --   g >= 40 <=> g(5)='1' and (g(4)='1' or g(3)='1')
  --   g(5)=1 -> 32..63; 32..39 are "1 0 0 xxx" -> excluded by (g(4) or g(3)).
  function f_is_80B (g : std_logic_vector(5 downto 0)) return std_logic is
  begin
    return g(5) and (g(4) or g(3));
  end function;

  -- System 80A : everything in between, 18 .. 39
  function f_is_80A (g : std_logic_vector(5 downto 0)) return std_logic is
  begin
    return (not f_is_80(g)) and (not f_is_80B(g));
  end function;

  -- 7-digit score displays: the 80A glass (dispNumeric3), see the header.
  function f_has_7digit (g : std_logic_vector(5 downto 0)) return std_logic is
  begin
    return f_is_80A(g);
  end function;

  -- late 80B with the banked 4K game PROM : 56 .. 61
  --   g(5 downto 3)="111"  and  g(2 downto 0) <= 5  (i.e. not "11x")
  function f_late_80B (g : std_logic_vector(5 downto 0)) return std_logic is
  begin
    return g(5) and g(4) and g(3) and (not (g(2) and g(1)));
  end function;

end package body gts_family;
