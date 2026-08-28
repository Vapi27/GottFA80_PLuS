-- tb_link_arb.vhd : sound_link + ram_snoop wired exactly as SYS80 does, with every
-- internal cycle count scaled by exactly 1/10 (clk 5 MHz, baud 115200) so that all
-- ratios are identical to the real 50 MHz / 115200 design:
--   DIV = 43 (real 434) -> byte = 430 clk (real 4340)
--   HB  = 250 000 (real 2 500 000)          -> heartbeat every 50 "ms"
--   TICK_MAX = 5 000 000 (real 50 000 000)  -> snapshot every 1 "s"
--   frame 1281 bytes = 550 830 clk = 11.0 % of the period (real 11.1 %)
-- 1 simulated second therefore corresponds 1:1 to 1 second of real machine time.
--
-- ---------------------------------------------------------------------------
-- REWRITTEN 2026-08-13 -- the previous version was a FAUX-VERT.
--
-- What it used to do: decode the TX line, count bytes per class, PRINT the
-- counts, and then end on `assert false report "END-OF-SIM" severity failure`.
-- It contained not one single assert on anything it measured, so it could
-- never pass on its own merit; and run_all.sh launched it with
-- --stop-time=50ms while its only report sat behind `wait for 3 sec`, so the
-- simulation was cut 60x too early, printed nothing, checked nothing, and was
-- scored PASS because ghdl returns 0 when it is stopped by --stop-time.
--
-- What it does now.  Same wiring, same 1:1 time scaling, but:
--   * the shadow RAM of ram_snoop is FILLED with a known pattern before the
--     first snapshot tick, so the snapshot stream carries defined data (the old
--     bench left it at 'U' and drowned the log in NUMERIC_STD metavalue
--     warnings) and can be checked value by value;
--   * every byte that comes off the wire is classified against the COMPLETE
--     byte map of sound_link.vhd, so `other = 0` is a real invariant: no byte
--     outside the documented map may ever appear;
--   * the 0xBF / 0xC0|hi / 0xD0|lo stream is reassembled and each of the 640
--     values of each frame is compared with what was written into the shadow
--     RAM -- that is the actual end-to-end comparison this bench performs, and
--     its count is reported;
--   * the three properties the arbiter exists for are ASSERTED:
--       (1) LEVEL-token rate limit : at most one level token per LVL_GAP
--           bit-times, whatever the inputs do;
--       (2) anti-starvation        : complete snapshot frames still land at the
--           1 Hz ram_snoop rate even when a source re-arms every clock;
--       (3) heartbeat              : one mode token per hb_ms, +/- one byte in
--           flight at each end of the window;
--   * it ends by itself, with rc = 0 when everything holds and a
--     `severity failure` (rc = 1) when it does not.
-- ---------------------------------------------------------------------------
--
-- MODE selects the stimulus:
--   0 = static inputs        (what count_to_zero actually produces after boot)
--   1 = game_running toggling at 1 kHz
--   2 = sound EVENTS (snd_stb pulses) at 1 kHz
--   3 = ball[] toggling at 1 kHz
--   4 = game_running re-armed every 2 clk  (starvation flood)
--   5 = sound EVENTS every 2 clk           (starvation flood)
--   6 = ball[] re-armed every 2 clk        (starvation flood)
-- Modes 4..6 are the ones that matter: they reproduce the source that killed
-- the old fixed-priority arbiter (see the ARBITRATION post-mortem in
-- lib_common/sound_link.vhd).
--
-- Part of GottFA80 (GPL-3.0).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_link_arb is
  generic ( MODE : integer := 0 );
end tb_link_arb;

architecture sim of tb_link_arb is
  constant TCLK   : time    := 200 ns;              -- 5 MHz
  constant BIT_T  : time    := 43 * TCLK;           -- one UART bit = DIV clocks
  constant SIM_T  : time    := 3 sec;               -- observation window
  constant HB_MS  : integer := 50;                  -- sound_link generic hb_ms
  constant LVL_GAP: integer := 160;                 -- sound_link generic lvl_gap
  constant N_SNAP : integer := 640;                 -- ram_snoop generic n_bytes
  constant SNAP_MS: integer := 1000;                -- ram_snoop generic period_ms

  -- Expected number of mode tokens (0xF0/0xF1): the heartbeat re-arms mode_pend
  -- every hb_ms.  One byte may still be in flight at each end of the window.
  constant HB_EXP  : integer := SIM_T / (HB_MS * 1 ms);
  -- Rate-limit cap: after any level token the whole level group is held off for
  -- LVL_GAP bit-times, so the group cannot exceed one token per LVL_GAP
  -- bit-times.  +1 because the first token is not preceded by a hold, +1 for a
  -- byte straddling the end of the window.
  constant LVL_MAX : integer := SIM_T / (LVL_GAP * BIT_T) + 2;
  -- Complete snapshot frames expected in the window: ram_snoop ticks every
  -- SNAP_MS, the frame started at t = SIM_T cannot finish inside the window.
  constant FRAMES_MIN : integer := SIM_T / (SNAP_MS * 1 ms) - 1;

  -- Known pattern written into the ram_snoop shadow RAM.  Every nibble of every
  -- byte varies, so a swapped/stuck nibble in the 0xCx/0xDx split shows up.
  function snap_val(i : integer) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned((i * 7 + 55) mod 256, 8));
  end function;

  -- Frame index -> shadow address (ram_snoop header: 0..383 direct,
  -- 384..639 = 5101 block at shadow 512..767).
  function snap_addr(i : integer) return std_logic_vector is
  begin
    if i < 384 then return std_logic_vector(to_unsigned(i, 10));
    else            return std_logic_vector(to_unsigned(i + 128, 10));
    end if;
  end function;

  signal clk  : std_logic := '0';
  signal rst  : std_logic := '1';
  signal tx   : std_logic;

  signal game_running : std_logic := '1';
  signal diag  : std_logic := '0';
  signal sound : std_logic_vector(4 downto 0) := "00011";
  signal snd_stb : std_logic := '0';
  signal snd_rel : std_logic := '0';
  signal game  : std_logic_vector(5 downto 0) := "010101";
  signal ball  : std_logic_vector(3 downto 0) := "0000";

  signal snap_data : std_logic_vector(7 downto 0);
  signal snap_req  : std_logic;
  signal snap_ack  : std_logic;

  signal wr_addr : std_logic_vector(9 downto 0) := (others => '0');
  signal wr_data : std_logic_vector(7 downto 0) := (others => '0');
  signal wr_en   : std_logic := '0';

  signal running   : boolean   := true;
  signal win_end   : std_logic := '0';   -- end of the observation window
  signal fill_done : std_logic := '0';
begin

  clk <= not clk after TCLK/2 when running else '0';

  DUT_LINK : entity work.sound_link
    generic map ( clk_hz => 5000000, baud => 115200, hb_ms => HB_MS,
                  lvl_gap => LVL_GAP )
    port map (
      clk => clk, rst => rst, diag => diag,
      sound => sound, snd_stb => snd_stb, snd_rel => snd_rel,
      game => game, game_running => game_running, ball => ball,
      snap_data => snap_data, snap_req => snap_req, snap_ack => snap_ack,
      tx => tx );

  DUT_SNOOP : entity work.ram_snoop
    generic map ( clk_hz => 5000000, period_ms => SNAP_MS, n_bytes => N_SNAP )
    port map (
      clk => clk, rst => rst,
      wr_addr => wr_addr, wr_data => wr_data, wr_en => wr_en,
      snap_data => snap_data, snap_req => snap_req, snap_ack => snap_ack );

  STIM : process
  begin
    rst <= '1';
    wait for 20 us;
    rst <= '0';
    wait;
  end process;

  -- Fill the shadow RAM with the known pattern.  640 writes = 128 us, i.e. long
  -- before the first snapshot tick at 1 s.
  FILL : process
  begin
    wr_en <= '0';
    wait until rst = '0';
    wait until rising_edge(clk);
    for i in 0 to N_SNAP - 1 loop
      wr_addr <= snap_addr(i);
      wr_data <= snap_val(i);
      wr_en   <= '1';
      wait until rising_edge(clk);
    end loop;
    wr_en     <= '0';
    fill_done <= '1';
    wait;
  end process;

  TOG : process
    variable p : time;
  begin
    wait until fill_done = '1';
    if MODE >= 4 then p := 400 ns;                        -- 2 clk: re-arm every cycle
    else              p := 500 us; end if;                -- 1 kHz
    while running loop
      wait for p;
      case MODE is
        when 1 | 4 => game_running <= not game_running;
        when 2 | 5 =>                                     -- one sound EVENT
          sound   <= std_logic_vector(unsigned(sound) + 1);
          snd_stb <= '1';
          wait until rising_edge(clk);
          snd_stb <= '0';
        when 3 | 6 => ball  <= not ball;
        when others => null;
      end case;
    end loop;
    wait;
  end process;

  END_WINDOW : process
  begin
    wait for SIM_T;
    win_end <= '1';
    wait;
  end process;

  ---------------------------------------------------------------------------
  -- Receiver, frame checker, statistics and VERDICT.  Everything lives in one
  -- process so the counters are plain variables and cannot be read half-updated.
  ---------------------------------------------------------------------------
  RX : process
    variable b  : std_logic_vector(7 downto 0);
    -- per-class byte counters, one per range of the sound_link byte map
    variable n_bytes  : integer := 0;
    variable n_meta   : integer := 0;   -- 0x30 / 0x31
    variable n_game   : integer := 0;   -- 0x40..0x7F
    variable n_snd    : integer := 0;   -- 0x80..0x9F
    variable n_ball   : integer := 0;   -- 0xA0..0xAF
    variable n_rxc    : integer := 0;   -- 0xB0..0xBE
    variable n_mark   : integer := 0;   -- 0xBF
    variable n_hi     : integer := 0;   -- 0xC0..0xCF
    variable n_lo     : integer := 0;   -- 0xD0..0xDF
    variable n_dinj   : integer := 0;   -- 0xE0..0xEF
    variable n_mode   : integer := 0;   -- 0xF0 / 0xF1
    variable n_state  : integer := 0;   -- 0xF2 / 0xF3
    variable n_f3     : integer := 0;   --   of which 0xF3 (running)
    variable n_fam    : integer := 0;   -- 0xF4..0xF7
    variable n_other  : integer := 0;   -- anything the byte map does not define
    variable n_meta_x : integer := 0;   -- bytes carrying an undefined bit
    -- snapshot frame reassembly
    variable in_frame : boolean := false;
    variable ph_hi    : boolean := true;
    variable f_idx    : integer := 0;
    variable hi_nib   : std_logic_vector(3 downto 0) := (others => '0');
    variable val      : std_logic_vector(7 downto 0);
    variable snap_cmp : integer := 0;   -- values compared against the shadow RAM
    variable snap_bad : integer := 0;   -- of which wrong
    variable seq_bad  : integer := 0;   -- hi/lo out of order inside a frame
    variable fr_start : integer := 0;
    variable fr_done  : integer := 0;
    -- verdict
    variable lvl_tok  : integer := 0;
    variable checks   : integer := 0;
    variable fails    : integer := 0;
    variable l        : line;

    procedure chk(ok : boolean; what : string) is
    begin
      checks := checks + 1;
      if not ok then
        fails := fails + 1;
        report "ECHEC : " & what severity error;
      end if;
    end procedure;
  begin
    loop
      exit when win_end = '1';
      wait until falling_edge(tx) or win_end = '1';
      exit when win_end = '1';
      wait for BIT_T/2;
      next when tx /= '0';                       -- glitch, not a start bit
      for i in 0 to 7 loop
        wait for BIT_T;
        b(i) := tx;
      end loop;
      wait for BIT_T;                            -- stop bit
      n_bytes := n_bytes + 1;
      if Is_X(b) then
        n_meta_x := n_meta_x + 1;
        next;
      end if;

      ---------------------------------------------------------------------
      -- classification against the COMPLETE byte map of sound_link.vhd
      ---------------------------------------------------------------------
      if    b = x"30" or b = x"31"    then n_meta  := n_meta  + 1;
      elsif b(7 downto 6) = "01"      then n_game  := n_game  + 1;
      elsif b(7 downto 5) = "100"     then n_snd   := n_snd   + 1;
      elsif b(7 downto 4) = "1010"    then n_ball  := n_ball  + 1;
      elsif b = x"BF"                 then n_mark  := n_mark  + 1;
      elsif b(7 downto 4) = "1011"    then n_rxc   := n_rxc   + 1;
      elsif b(7 downto 4) = "1100"    then n_hi    := n_hi    + 1;
      elsif b(7 downto 4) = "1101"    then n_lo    := n_lo    + 1;
      elsif b(7 downto 4) = "1110"    then n_dinj  := n_dinj  + 1;
      elsif b(7 downto 1) = "1111000" then n_mode  := n_mode  + 1;
      elsif b(7 downto 1) = "1111001" then n_state := n_state + 1;
        if b(0) = '1' then n_f3 := n_f3 + 1; end if;
      elsif b(7 downto 2) = "111101"  then n_fam   := n_fam   + 1;
      else                                 n_other := n_other + 1;
        report "OCTET HORS CARTE : " & integer'image(to_integer(unsigned(b)))
          severity error;
      end if;

      ---------------------------------------------------------------------
      -- snapshot frame reassembly + value comparison.  Any other token may
      -- interleave harmlessly (documented self-healing), so only 0xBF / 0xCx /
      -- 0xDx touch the frame state.
      ---------------------------------------------------------------------
      if b = x"BF" then
        fr_start := fr_start + 1;
        in_frame := true; ph_hi := true; f_idx := 0;
      elsif b(7 downto 4) = "1100" then
        if in_frame then
          if ph_hi then hi_nib := b(3 downto 0); ph_hi := false;
          else          seq_bad := seq_bad + 1; in_frame := false;
          end if;
        end if;
      elsif b(7 downto 4) = "1101" then
        if in_frame then
          if not ph_hi then
            val      := hi_nib & b(3 downto 0);
            snap_cmp := snap_cmp + 1;
            if val /= snap_val(f_idx) then
              snap_bad := snap_bad + 1;
              report "SNAPSHOT index=" & integer'image(f_idx)
                & " recu=" & integer'image(to_integer(unsigned(val)))
                & " attendu=" & integer'image(to_integer(unsigned(snap_val(f_idx))))
                severity error;
            end if;
            ph_hi := true;
            if f_idx = N_SNAP - 1 then
              fr_done  := fr_done + 1;
              in_frame := false;
            else
              f_idx := f_idx + 1;
            end if;
          else
            seq_bad := seq_bad + 1; in_frame := false;
          end if;
        end if;
      end if;
    end loop;

    -----------------------------------------------------------------------
    -- statistics
    -----------------------------------------------------------------------
    lvl_tok := n_mode + n_state + n_ball + n_game + n_dinj + n_rxc + n_fam;

    write(l, string'("MODE="));              write(l, MODE);
    write(l, string'("  octets="));          write(l, n_bytes);
    write(l, string'("  mode_F0F1="));       write(l, n_mode);
    write(l, string'("  state_F2F3="));      write(l, n_state);
    write(l, string'("  ofwhich_F3="));      write(l, n_f3);
    write(l, string'("  ball_Ax="));         write(l, n_ball);
    write(l, string'("  game_4x="));         write(l, n_game);
    write(l, string'("  snd_8x="));          write(l, n_snd);
    write(l, string'("  meta_30_31="));      write(l, n_meta);
    write(l, string'("  fam_F4="));          write(l, n_fam);
    write(l, string'("  dinj_Ex="));         write(l, n_dinj);
    write(l, string'("  rxc_Bx="));          write(l, n_rxc);
    write(l, string'("  MARK_BF="));         write(l, n_mark);
    write(l, string'("  hi_Cx="));           write(l, n_hi);
    write(l, string'("  lo_Dx="));           write(l, n_lo);
    write(l, string'("  other="));           write(l, n_other);
    writeline(output, l);

    write(l, string'("MODE="));              write(l, MODE);
    write(l, string'("  niveau_total="));    write(l, lvl_tok);
    write(l, string'("/"));                  write(l, LVL_MAX);
    write(l, string'("  trames_debutees=")); write(l, fr_start);
    write(l, string'("  trames_completes="));write(l, fr_done);
    write(l, string'("  comparaisons="));    write(l, snap_cmp);
    write(l, string'("  divergences="));     write(l, snap_bad);
    writeline(output, l);

    -----------------------------------------------------------------------
    -- VERDICT -- every line below is an assert, not a printout
    -----------------------------------------------------------------------
    chk(n_bytes > 0,        "aucun octet decode -- le banc n a rien observe");
    chk(n_meta_x = 0,       "octets contenant un bit indefini : "
                            & integer'image(n_meta_x));
    chk(n_other = 0,        "octets hors de la carte des octets : "
                            & integer'image(n_other));
    -- (3) heartbeat
    chk(n_mode >= HB_EXP - 1 and n_mode <= HB_EXP + 1,
        "battement : " & integer'image(n_mode) & " jetons 0xF0/0xF1, attendu "
        & integer'image(HB_EXP) & " +/-1");
    -- (1) LEVEL-token rate limit
    chk(lvl_tok <= LVL_MAX,
        "limite de debit du groupe NIVEAU depassee : " & integer'image(lvl_tok)
        & " > " & integer'image(LVL_MAX));
    -- (2) anti-starvation : complete frames still arrive at the ram_snoop rate
    chk(fr_done >= FRAMES_MIN,
        "famine : " & integer'image(fr_done) & " trames completes, attendu >= "
        & integer'image(FRAMES_MIN));
    -- snapshot integrity
    chk(seq_bad = 0,        "sequences hi/lo desordonnees : "
                            & integer'image(seq_bad));
    chk(snap_bad = 0,       "valeurs de snapshot fausses : "
                            & integer'image(snap_bad));
    chk(snap_cmp >= fr_done * N_SNAP,
        "comparaisons insuffisantes : " & integer'image(snap_cmp)
        & " pour " & integer'image(fr_done) & " trames completes");
    chk(snap_cmp > 1000,    "trop peu de comparaisons snapshot : "
                            & integer'image(snap_cmp));
    chk(n_hi >= snap_cmp and n_lo >= snap_cmp,
        "quartets hauts/bas incoherents avec les comparaisons");
    chk(n_mark = fr_start,  "marqueurs 0xBF et trames debutees incoherents");
    -- stimulus-specific
    case MODE is
      when 0 =>
        chk(n_snd = 0 and n_meta = 0, "MODE 0 : evenement son fantome");
        chk(n_ball = 0,               "MODE 0 : jeton balle fantome");
        chk(n_game = 0,               "MODE 0 : jeton jeu fantome");
        chk(n_state = n_f3 and n_state > 0,
            "MODE 0 : game_running fige a 1, tous les 0xF2/0xF3 doivent etre 0xF3");
      when 1 | 4 =>
        chk(n_f3 > 0 and n_f3 < n_state,
            "MODE " & integer'image(MODE)
            & " : les deux polarites de game_running doivent apparaitre");
      when 2 =>
        -- 1 kHz = one cue every ~5.8 byte slots: the 8-deep FIFO absorbs it and
        -- every cue must come out as a 0x8x, with no overflow token at all.
        chk(n_snd > 0,  "MODE 2 : aucun evenement son n a atteint le fil");
        chk(n_meta = 0, "MODE 2 : debordement de la FIFO son a 1 kHz, elle doit absorber");
      when 5 =>
        -- Flood: one event every ~2 clk against one byte slot every 11 baud
        -- ticks.  The FIFO is permanently full, so the CONTRACT is not "the cue
        -- passes" -- it cannot -- but "the loss is never silent": 0x31 must
        -- appear.  A run with neither 0x8x nor 0x31 would mean cues vanish
        -- without a trace, which is exactly what SOUND_WIRE.md forbids.
        chk(n_snd + n_meta > 0,
            "MODE 5 : aucune activite de la classe SON n a atteint le fil");
        chk(n_meta > 0,
            "MODE 5 : FIFO son saturee mais 0x31 jamais emis -- perte de cue SILENCIEUSE");
      when 3 | 6 =>
        chk(n_ball > 0, "MODE " & integer'image(MODE)
            & " : aucun jeton balle n a atteint le fil");
      when others => null;
    end case;

    write(l, string'("MODE="));           write(l, MODE);
    write(l, string'("  verifications=")); write(l, checks);
    write(l, string'("  echecs="));        write(l, fails);
    writeline(output, l);

    assert fails = 0
      report "tb_link_arb MODE=" & integer'image(MODE) & " : "
             & integer'image(fails) & " verification(s) en echec"
      severity failure;
    report "tb_link_arb MODE=" & integer'image(MODE) & " : "
           & integer'image(checks) & " verifications OK, "
           & integer'image(snap_cmp) & " valeurs de snapshot comparees"
      severity note;

    running <= false;
    wait;
  end process;

end sim;
