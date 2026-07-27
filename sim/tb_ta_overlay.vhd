-- tb_ta_overlay.vhd : proves the strobe -> (segment group, character) map of
-- lib_common/ta_overlay.vhd against TWO INDEPENDENT REFERENCES, neither of which
-- is a hand-written expectation table in this file.
--
--   REFERENCE 1 -- lib_common/boot_message.vhd, CO-SIMULATED here.  boot_message
--     drives the whole glass from its own free-running counter and its banner is
--     known to land on the right digits of the owner's real (6-digit, System 80)
--     machine.  This bench runs it, samples segment groups A/B/C at every digit
--     strobe, and asserts ta_overlay reproduces the same table.  The two can
--     therefore no longer drift apart: edit either module and this fails.
--
--   REFERENCE 2 -- PinMAME src/wpc/gts80.c riot6532_1aBCD_w reorder[] plus the
--     display layouts in src/wpc/gts80games.c.  Both are transcribed VERBATIM
--     below and the expected character index is COMPUTED from them, exactly as
--     PinMAME computes it, rather than restated.  This is what covers the two
--     cases boot_message cannot: the 7-digit (System 80A) glass, and the
--     question of whether a strobe is wired at all on a 6-digit glass.
--
-- WHAT THIS CAUGHT (both fixed 2026-07-27)
--   * the status window (sel="100") was reversed: strobes C,D,E,F produced
--     characters 4,5,6,7 where both references say 7,6,5,4.
--   * the 7th digit of an 80A glass was treated as the LEFTMOST digit.  It is
--     the RIGHTMOST: PinMAME maps strobe 15 to segment 8 of the 2..8 run that
--     dispNumeric3 lays out left to right.  And on a 6-digit glass strobes 15
--     and 12 carry no score digit at all, so the overlay must not claim them.
--
-- Run:  ghdl -r tb_ta_overlay --stop-time=200ms

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_ta_overlay is end tb_ta_overlay;

architecture sim of tb_ta_overlay is

  constant TCPU : time := 1117 ns;   -- 895 kHz, what boot_message is written for
  constant T50  : time :=   20 ns;   -- 50 MHz, what ta_overlay is clocked at

  -- probe strings.  Every value boot_message loads consecutively into one group
  -- must DIFFER from the previous one, otherwise "the group was not reloaded at
  -- this strobe" (which happens on group A/B at strobes 13 and 14) cannot be
  -- told from "it was reloaded with the same value".  display1/3 and display2/4
  -- are deliberately different sequences for that reason.
  constant SLO : string(1 to 7) := "1234567";   -- display1, display3, status_d
  constant SHI : string(1 to 7) := "9876543";   -- display2, display4

  constant BLANK : std_logic_vector(1 to 8) := "00000000";

  -- ---------------- boot_message ------------------------------------------
  signal cpuclk  : std_logic := '0';
  signal bm_show : std_logic := '0';
  signal bm_str  : std_logic_vector(3 downto 0);
  signal bm_seg  : std_logic_vector(1 to 24);

  -- ---------------- ta_overlay --------------------------------------------
  signal clk50   : std_logic := '0';
  signal strobe  : std_logic_vector(3 downto 0) := (others => '0');
  signal sel     : std_logic_vector(2 downto 0) := "000";
  signal has7    : std_logic := '0';
  signal dstr    : string(1 to 7) := SLO;
  signal hit_a, hit_b, hit_c : std_logic;
  signal seg     : std_logic_vector(1 to 8);

  signal done    : boolean := false;
  signal bm_done : boolean := false;

  -- sampled boot_message table: value at each strobe, and at the strobe before it
  type g_t is array (0 to 15) of std_logic_vector(1 to 8);
  signal bmA, bmB, bmC    : g_t := (others => BLANK);
  signal bmAp, bmBp, bmCp : g_t := (others => BLANK);

  -- ========================================================================
  -- PinMAME, transcribed verbatim
  -- ========================================================================
  -- src/wpc/gts80.c, riot6532_1aBCD_w():
  --     static const int reorder[] = {8,0,1,15,9,10,11,12,13,14,2,3,4,5,6,7};
  --     int pos = reorder[15 - dispdata];          -- dispdata = 4-bit strobe
  --     segments[pos]         |= seg1;             -- segment group A
  --     segments[20+pos]      |= seg2;             -- segment group B
  --     segments[55-dispdata] |= seg3;             -- segment group C
  type reorder_t is array (0 to 15) of integer;
  constant REORDER : reorder_t := (8,0,1,15,9,10,11,12,13,14,2,3,4,5,6,7);

  -- src/wpc/core.h:226   struct core_dispLayout { top, left, start, length, type }
  --   -> `start` is the segment index of the LEFTMOST digit and the index grows
  --      to the RIGHT (proved by DISP_SEG_CREDIT(40,41,..) = {2,2,40,1},{2,4,41,1}
  --      in core.h:219: segment 40 sits at column 2, segment 41 at column 4).
  -- src/wpc/gts80games.c:
  --   dispNumeric1  "4 x 6 BCD"  {0,0, 2,6}, {0,16, 9,6}   display1 = seg 2..7,  display2 = seg  9..14
  --   dispNumeric3  "4 x 7 BCD"  {0,0, 2,7}, {0,16, 9,7}   display1 = seg 2..8,  display2 = seg  9..15
  --   DISP_SEG_CREDIT(40,41), DISP_SEG_BALLS(42,43)        status   = seg 40..43
  --
  -- The injected string is right justified, char 7 = rightmost = units.
  -- So for a run of N segments starting at `first`, segment p is char (7-N+1)+(p-first).

  function pm_lo6 (s : integer) return integer is         -- display 1, 6-digit glass
    variable pos : integer;
  begin
    pos := REORDER(15 - s);
    if pos < 2 or pos > 7 then return 0; end if;          -- not on this display
    return 2 + (pos - 2);                                 -- seg 2 -> char 2 .. seg 7 -> char 7
  end function;

  function pm_hi6 (s : integer) return integer is         -- display 2, 6-digit glass
    variable pos : integer;
  begin
    pos := REORDER(15 - s);
    if pos < 9 or pos > 14 then return 0; end if;
    return 2 + (pos - 9);
  end function;

  function pm_lo7 (s : integer) return integer is         -- display 1, 7-digit glass
    variable pos : integer;
  begin
    pos := REORDER(15 - s);
    if pos < 2 or pos > 8 then return 0; end if;
    return 1 + (pos - 2);                                 -- seg 2 -> char 1 .. seg 8 -> char 7
  end function;

  function pm_hi7 (s : integer) return integer is         -- display 2, 7-digit glass
    variable pos : integer;
  begin
    pos := REORDER(15 - s);
    if pos < 9 or pos > 15 then return 0; end if;
    return 1 + (pos - 9);
  end function;

  function pm_st (s : integer) return integer is          -- status display, both
    variable segp : integer;
  begin
    segp := 55 - s;
    if segp < 40 or segp > 43 then return 0; end if;
    return 4 + (segp - 40);                               -- seg 40 -> char 4 .. seg 43 -> char 7
  end function;

  -- reference copy of the SN7448_GTB table (independent of the DUT)
  function glyph (c : character) return std_logic_vector is
  begin
    case c is
      when '0' => return "11111100";
      when '1' => return "01100000";
      when '2' => return "11011010";
      when '3' => return "11110010";
      when '4' => return "01100110";
      when '5' => return "10110110";
      when '6' => return "00111110";
      when '7' => return "11100000";
      when '8' => return "11111110";
      when '9' => return "11100110";
      when others => return "00000000";
    end case;
  end function;

  function img (v : std_logic_vector(1 to 8)) return string is
    variable r : string(1 to 8);
  begin
    for i in 1 to 8 loop
      if v(i) = '1' then r(i) := '1'; else r(i) := '0'; end if;
    end loop;
    return r;
  end function;

begin

  cpuclk <= not cpuclk after TCPU/2 when not done else '0';
  clk50  <= not clk50  after T50/2  when not done else '0';

  BM : entity work.boot_message
    port map ( clk_in          => cpuclk,
               show            => bm_show,
               SD_error        => '0',
               bm_digit_strobe => bm_str,
               bm_segments     => bm_seg,
               display1        => SLO,
               display2        => SHI,
               display3        => SLO,
               display4        => SHI,
               error_disp4     => "0000000",
               status_d        => SLO );

  UUT : entity work.ta_overlay
    port map ( clk => clk50, strobe => strobe, sel => sel, has7 => has7,
               dstr => dstr, hit_a => hit_a, hit_b => hit_b, hit_c => hit_c,
               seg => seg );

  -- ------------------------------------------------------------------------
  -- sample boot_message: on every digit-strobe transition, record what each
  -- segment group carries now and what it carried at the previous strobe.
  -- ------------------------------------------------------------------------
  SAMPLE : process
    variable pA, pB, pC : std_logic_vector(1 to 8) := BLANK;
    variable s, n : integer := 0;
  begin
    wait until bm_show = '1';
    n := 0;
    loop
      wait on bm_str;
      wait for 3 * TCPU;                    -- decoders are combinational; settle
      s := to_integer(unsigned(bm_str));
      if n > 18 then                        -- first full cycle: pA/pB/pC not yet valid
        bmA(s)  <= bm_seg(1 to 8);   bmAp(s) <= pA;
        bmB(s)  <= bm_seg(9 to 16);  bmBp(s) <= pB;
        bmC(s)  <= bm_seg(17 to 24); bmCp(s) <= pC;
      end if;
      pA := bm_seg(1 to 8);
      pB := bm_seg(9 to 16);
      pC := bm_seg(17 to 24);
      n := n + 1;
      exit when n >= 40;                    -- ~2.5 refresh cycles
    end loop;
    bm_done <= true;
    wait;
  end process;

  -- ------------------------------------------------------------------------
  STIM : process
    variable err : integer := 0;

    procedure chk (cond : boolean; msg : string) is
    begin
      if not cond then
        report "FAIL: " & msg severity error;
        err := err + 1;
      end if;
    end procedure;

    -- drive ta_overlay and let its output register settle
    procedure drive (sv : std_logic_vector(2 downto 0);
                     s7 : std_logic;
                     st : integer;
                     ds : string) is
    begin
      sel    <= sv;
      has7   <= s7;
      dstr   <= ds;
      strobe <= std_logic_vector(to_unsigned(st, 4));
      wait until rising_edge(clk50);
      wait until rising_edge(clk50);
      wait for 1 ns;
    end procedure;

    variable nhit : integer;
    variable e    : integer;
    variable bmv, bmp : std_logic_vector(1 to 8);
    variable stale    : boolean;
    variable lo_hit, hi_hit : boolean;
    variable lo_seg, hi_seg : std_logic_vector(1 to 8);
  begin
    report "== ta_overlay : boot_message + PinMAME cross-check ==";

    -- ====================================================================
    -- LAYER A : the two references must agree with EACH OTHER.
    -- If this fails, one of the two references moved and every later check
    -- is meaningless -- so it is checked first and reported loudly.
    -- ====================================================================
    bm_show <= '1';
    wait until bm_done;

    for s in 0 to 15 loop
      -- group A
      bmv := bmA(s); bmp := bmAp(s);
      stale := (bmv = bmp) and (bmv /= BLANK);
      e := pm_lo6(s);
      if e /= 0 then
        chk(bmv = glyph(SLO(e)),
            "REF MISMATCH group A strobe " & integer'image(s) &
            " : PinMAME says display1 char " & integer'image(e) & " = " & SLO(e) &
            ", boot_message shows " & img(bmv));
      else
        e := pm_hi6(s);
        if e /= 0 then
          chk(bmv = glyph(SHI(e)),
              "REF MISMATCH group A strobe " & integer'image(s) &
              " : PinMAME says display2 char " & integer'image(e) & " = " & SHI(e) &
              ", boot_message shows " & img(bmv));
        elsif pm_lo7(s) = 0 and pm_hi7(s) = 0 then
          -- neither reference wires anything here on either glass: boot_message
          -- must be blank, or simply not have reloaded the group (strobes 13,14)
          chk(bmv = BLANK or stale,
              "REF MISMATCH group A strobe " & integer'image(s) &
              " : PinMAME wires nothing here but boot_message drives " & img(bmv));
        end if;
        -- pm_lo7/pm_hi7 non-zero and pm_*6 zero  =  the 7th-digit slot.
        -- boot_message writes it unconditionally (char 1); PinMAME says a
        -- 6-digit glass has no digit there and a 7-digit glass has its UNITS
        -- digit there.  This is the one documented divergence -- see LAYER C.
      end if;

      -- group C : the status display, family independent
      bmv := bmC(s);
      e := pm_st(s);
      if e /= 0 then
        chk(bmv = glyph(SLO(e)),
            "REF MISMATCH group C strobe " & integer'image(s) &
            " : PinMAME says status char " & integer'image(e) & " = " & SLO(e) &
            ", boot_message shows " & img(bmv));
      else
        chk(bmv = BLANK,
            "REF MISMATCH group C strobe " & integer'image(s) &
            " : status group must be blank outside strobes 12..15, got " & img(bmv));
      end if;
    end loop;
    report "layer A (boot_message == PinMAME) done, running error count "
           & integer'image(err);

    -- ====================================================================
    -- LAYER B : ta_overlay on a 6-digit glass == boot_message, cell by cell.
    -- Group A is the union of sel="001" (low window = display1) and sel="000"
    -- (high window = display2); group B of sel="011"/"010"; group C is sel="100".
    -- ====================================================================
    for s in 0 to 15 loop
      drive("001", '0', s, SLO); lo_hit := (hit_a = '1'); lo_seg := seg;
      chk(hit_b = '0' and hit_c = '0',
          "sel=001 strobe " & integer'image(s) & " : claimed a group other than A");
      drive("000", '0', s, SHI); hi_hit := (hit_a = '1'); hi_seg := seg;
      chk(hit_b = '0' and hit_c = '0',
          "sel=000 strobe " & integer'image(s) & " : claimed a group other than A");
      chk(not (lo_hit and hi_hit),
          "strobe " & integer'image(s) & " : low and high window both claim group A");

      bmv := bmA(s); bmp := bmAp(s);
      stale := (bmv = bmp) and (bmv /= BLANK);

      if pm_lo7(s) /= 0 and pm_lo6(s) = 0 then
        -- strobe 15 : the 7th-digit slot of the low window
        chk(not lo_hit and not hi_hit,
            "6-digit glass, strobe " & integer'image(s) &
            " is the 7th-digit slot and is NOT wired -- the overlay must not claim it");
      elsif pm_hi7(s) /= 0 and pm_hi6(s) = 0 then
        -- strobe 12 : the 7th-digit slot of the high window
        chk(not lo_hit and not hi_hit,
            "6-digit glass, strobe " & integer'image(s) &
            " is the 7th-digit slot and is NOT wired -- the overlay must not claim it");
      elsif lo_hit then
        chk(lo_seg = bmv,
            "sel=001 strobe " & integer'image(s) & " : glyph " & img(lo_seg) &
            " but boot_message shows " & img(bmv));
      elsif hi_hit then
        chk(hi_seg = bmv,
            "sel=000 strobe " & integer'image(s) & " : glyph " & img(hi_seg) &
            " but boot_message shows " & img(bmv));
      else
        chk(bmv = BLANK or stale,
            "strobe " & integer'image(s) & " : boot_message drives group A with " &
            img(bmv) & " but the overlay claims nothing");
      end if;

      -- group B is the same table on display3 / display4
      drive("011", '0', s, SLO); lo_hit := (hit_b = '1'); lo_seg := seg;
      chk(hit_a = '0' and hit_c = '0',
          "sel=011 strobe " & integer'image(s) & " : claimed a group other than B");
      drive("010", '0', s, SHI); hi_hit := (hit_b = '1'); hi_seg := seg;
      chk(hit_a = '0' and hit_c = '0',
          "sel=010 strobe " & integer'image(s) & " : claimed a group other than B");
      bmv := bmB(s); bmp := bmBp(s);
      stale := (bmv = bmp) and (bmv /= BLANK);
      if (pm_lo7(s) /= 0 and pm_lo6(s) = 0) or (pm_hi7(s) /= 0 and pm_hi6(s) = 0) then
        chk(not lo_hit and not hi_hit,
            "6-digit glass, group B strobe " & integer'image(s) &
            " is the unwired 7th-digit slot");
      elsif lo_hit then
        chk(lo_seg = bmv, "sel=011 strobe " & integer'image(s) & " : glyph " &
            img(lo_seg) & " but boot_message shows " & img(bmv));
      elsif hi_hit then
        chk(hi_seg = bmv, "sel=010 strobe " & integer'image(s) & " : glyph " &
            img(hi_seg) & " but boot_message shows " & img(bmv));
      else
        chk(bmv = BLANK or stale,
            "strobe " & integer'image(s) & " : boot_message drives group B with " &
            img(bmv) & " but the overlay claims nothing");
      end if;

      -- group C : the status display
      drive("100", '0', s, SLO);
      chk(hit_a = '0' and hit_b = '0',
          "sel=100 strobe " & integer'image(s) & " : claimed a group other than C");
      bmv := bmC(s);
      if hit_c = '1' then
        chk(seg = bmv,
            "sel=100 strobe " & integer'image(s) & " : glyph " & img(seg) &
            " but boot_message status shows " & img(bmv));
      else
        chk(bmv = BLANK,
            "sel=100 strobe " & integer'image(s) &
            " : boot_message drives the status group with " & img(bmv) &
            " but the overlay claims nothing");
      end if;
    end loop;
    report "layer B (ta_overlay 6-digit == boot_message) done, running error count "
           & integer'image(err);

    -- ====================================================================
    -- LAYER C : ta_overlay on a 7-digit (80A) glass == PinMAME's own table.
    -- boot_message cannot serve as the reference here: it puts char 1 on the
    -- strobe-15 / strobe-12 slot, i.e. it treats the 7th digit as the leading
    -- one, and PinMAME's dispNumeric3 layout says it is the trailing (units)
    -- one.  boot_message's 7-digit mapping has never driven a 7-digit glass.
    -- ====================================================================
    for s in 0 to 15 loop
      drive("001", '1', s, SLO); lo_hit := (hit_a = '1'); lo_seg := seg;
      drive("000", '1', s, SHI); hi_hit := (hit_a = '1'); hi_seg := seg;
      chk(not (lo_hit and hi_hit),
          "7-digit strobe " & integer'image(s) & " : both windows claim group A");

      e := pm_lo7(s);
      if e /= 0 then
        chk(lo_hit, "7-digit sel=001 strobe " & integer'image(s) &
                    " : PinMAME wires display1 char " & integer'image(e) &
                    " here, the overlay claims nothing");
        if lo_hit then
          chk(lo_seg = glyph(SLO(e)),
              "7-digit sel=001 strobe " & integer'image(s) & " : expected char " &
              integer'image(e) & " = " & SLO(e) & ", got " & img(lo_seg));
        end if;
      else
        chk(not lo_hit, "7-digit sel=001 strobe " & integer'image(s) &
                        " : PinMAME wires nothing on display1 here");
      end if;

      e := pm_hi7(s);
      if e /= 0 then
        chk(hi_hit, "7-digit sel=000 strobe " & integer'image(s) &
                    " : PinMAME wires display2 char " & integer'image(e) &
                    " here, the overlay claims nothing");
        if hi_hit then
          chk(hi_seg = glyph(SHI(e)),
              "7-digit sel=000 strobe " & integer'image(s) & " : expected char " &
              integer'image(e) & " = " & SHI(e) & ", got " & img(hi_seg));
        end if;
      else
        chk(not hi_hit, "7-digit sel=000 strobe " & integer'image(s) &
                        " : PinMAME wires nothing on display2 here");
      end if;

      -- the status window is 4 digits on every family: same table with has7='1'
      drive("100", '1', s, SLO);
      e := pm_st(s);
      if e /= 0 then
        chk(hit_c = '1' and seg = glyph(SLO(e)),
            "7-digit sel=100 strobe " & integer'image(s) & " : expected char " &
            integer'image(e) & " = " & SLO(e) & ", got " & img(seg));
      else
        chk(hit_c = '0', "7-digit sel=100 strobe " & integer'image(s) &
                         " : status group claimed outside strobes 12..15");
      end if;
    end loop;
    report "layer C (ta_overlay 7-digit == PinMAME) done, running error count "
           & integer'image(err);

    -- ====================================================================
    -- LAYER D : structure -- exactly one group ever claimed, and the two probe
    -- selections 101/110 paint the STATUS characters onto groups A/B (that is
    -- their whole purpose: find out whether a 6-digit glass has anything wired
    -- to strobes 12..15 on those groups).  Checked against sel="100", so no
    -- extra table.
    -- ====================================================================
    for s in 0 to 15 loop
      drive("100", '0', s, SLO);
      lo_hit := (hit_c = '1'); lo_seg := seg;

      drive("101", '0', s, SLO);
      nhit := 0;
      if hit_a = '1' then nhit := nhit + 1; end if;
      if hit_b = '1' then nhit := nhit + 1; end if;
      if hit_c = '1' then nhit := nhit + 1; end if;
      chk(nhit <= 1, "sel=101 strobe " & integer'image(s) & " : more than one group");
      if lo_hit then
        chk(hit_a = '1' and seg = lo_seg,
            "probe sel=101 strobe " & integer'image(s) &
            " : must paint the status character onto group A");
      else
        chk(nhit = 0, "probe sel=101 strobe " & integer'image(s) &
                      " : claimed a group outside the status window");
      end if;

      drive("110", '0', s, SLO);
      nhit := 0;
      if hit_a = '1' then nhit := nhit + 1; end if;
      if hit_b = '1' then nhit := nhit + 1; end if;
      if hit_c = '1' then nhit := nhit + 1; end if;
      chk(nhit <= 1, "sel=110 strobe " & integer'image(s) & " : more than one group");
      if lo_hit then
        chk(hit_b = '1' and seg = lo_seg,
            "probe sel=110 strobe " & integer'image(s) &
            " : must paint the status character onto group B");
      else
        chk(nhit = 0, "probe sel=110 strobe " & integer'image(s) &
                      " : claimed a group outside the status window");
      end if;

      -- sel="111" is the full-glass overlay, handled entirely inside SYS80:
      -- this module must stay silent for it.
      drive("111", '0', s, SLO);
      chk(hit_a = '0' and hit_b = '0' and hit_c = '0',
          "sel=111 strobe " & integer'image(s) & " : must claim nothing");
    end loop;
    report "layer D (structure / probe selections) done, running error count "
           & integer'image(err);

    assert err = 0
      report "== ta_overlay: " & integer'image(err) & " FAILURES ==" severity failure;
    report "== ta_overlay: ALL CHECKS PASSED ==" severity note;
    done <= true;
    wait;
  end process;

end sim;
