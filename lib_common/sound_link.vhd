-- sound_link.vhd : 1-wire 8N1 UART link FPGA -> ESP companion. In the ESP-sound
-- build it drives the Debug pin (PIN_11 / K2), carrying everything the ESP needs
-- from the FPGA on a single wire next to the FPGA:
--   1 0 0 s s s s s   (0x80 | sound[4:0])  -- a sound command (Sound_Meta)  [gameplay, EVENT]
--   0 1 g g g g g g   (0x40 | game[5:0])   -- the selected game number       [gameplay, LEVEL]
--   1 1 1 1 0 0 0 d   (0xF0 | diag)        -- diag-mode token (d=1 on, 0 normal)   [LEVEL]
--   1 1 1 1 0 0 1 r   (0xF2 | run)         -- game-state (r=1 running, 0 over)     [LEVEL]
--   1 0 1 0 b b b b   (0xA0 | ball[3:0]) -- ball-in-play ($0072), on change        [LEVEL]
--   1 0 1 1 1 1 1 1   (0xBF)             -- RAM-snapshot frame marker      [diagnostic]
--   1 1 0 0 v v v v   (0xC0 | val>>4)    -- snapshot payload, high nibble  [diagnostic]
--   1 1 0 1 v v v v   (0xD0 | val&0x0F)  -- snapshot payload, low nibble   [diagnostic]
--   1 1 1 0 v c c c   (0xE0 | dinj)      -- disp_inject state              [LEVEL]
--                                           bit3 = dvalid, bits2..0 = ctrl(2..0)
--   1 0 1 1 c c c c   (0xB0 | rx_cnt)    -- disp_inject deframed-byte count [LEVEL]
--                                           0xB0..0xBE ONLY, never 0xBF
-- The snapshot bytes are supplied by ram_snoop through snap_data/snap_req/snap_ack.
-- The ranges (0x80..0x9F / 0x40..0x7F / 0xA0..0xAF / 0xF0..0xF1 / 0xF2..0xF3 /
-- 0xE0..0xEF / 0xB0..0xBE) never overlap.
--
-- ---------------------------------------------------------------------------
-- ESP -> FPGA LINK TELEMETRY (added 2026-07-27).
--
-- The FPGA -> ESP direction (this UART) was always observable; the ESP -> FPGA
-- direction (disp_inject on PIN_2) was not, so a dead display overlay could not be
-- told apart from a dead wire.  Two tokens close that hole:
--
--   0xE0 | {dvalid, ctrl2, ctrl1, ctrl0}  -- what disp_inject BELIEVES right now.
--        dvalid = a complete 7-char display frame arrived within the last second;
--        ctrl0 = auto-restart enable, ctrl1 = display overlay enable, ctrl2 = kill.
--        Sent on change AND folded into the heartbeat, so a stuck value is still
--        re-announced every hb_ms and the ESP can never be left guessing.
--
--   0xB0 | rx_cnt   -- disp_inject's free-running count of DEFRAMED bytes, mod 15.
--        Sent on change only.  This is the byte that distinguishes the two failure
--        modes: frozen = nothing is arriving on PIN_2 at all (wire, pin, ESP TX);
--        moving while the 0xEx byte keeps dvalid=0 = bytes ARE arriving but never
--        assemble into a valid frame (baud, framing, protocol, marker bytes).
--
-- ############################################################################
-- # 0xBF COLLISION -- the reason rx_cnt is mod 15 and not mod 16.             #
-- # 0xBF is the RAM-snapshot frame marker.  A plain 4-bit counter would emit  #
-- # 0xB0|15 = 0xBF once every 15 bytes and the ESP would read it as the start #
-- # of a snapshot frame, corrupting the snapshot stream.  disp_inject         #
-- # therefore wraps its counter at 14.  ESP decode order matters: test the    #
-- # exact byte 0xBF FIRST, and only then (b & 0xF0) == 0xB0.                  #
-- ############################################################################
--
-- Both are LEVEL tokens: they carry the current value, so coalescing loses
-- nothing, and they join the lvl_hold group and the starve credit exactly like
-- mode / state / ball / game.  Adding them therefore does NOT increase level-class
-- bandwidth -- the whole group still shares one byte per lvl_gap bit-times -- so
-- they cannot starve the snapshot stream.
--
-- ---------------------------------------------------------------------------
-- ARBITRATION -- rewritten 2026-07-25 after a starvation post-mortem.
--
-- The old arbiter was a pure fixed-priority chain
--     mode > state > ball > game > sound > snapshot
-- with each pending flag re-armed COMBINATORIALLY from its source ("if x /= x_r
-- then x_r <= x; x_pend <= '1'"). That is a starvation trap: any source that
-- changes faster than one byte time (86.8 us at 115200) re-arms its flag before
-- the arbiter comes back round, so it wins EVERY grant and everything below it
-- gets exactly zero link time, for ever. Measured in GHDL on this very code:
-- a `ball` input toggling at 1 MHz produced 31 593 0xAx tokens and 0 snapshot
-- bytes in 3 s; the same test on `game_running` produced 31 652 0xF2/0xF3 and
-- 0 snapshot bytes. Two of the six sources can genuinely do this on hardware:
--   * ball  <- ball_val, whose SYS80 latch re-samples cpu_dout on every clk_50
--             edge the write condition holds (~56 per CPU cycle, documented in
--             SYS80.vhd AUTO_RESTART), so it can bounce on an unsettled bus;
--   * sound <- Sound_Meta, combinational on u6_pa_out, i.e. on the CPU bus.
--
-- Two independent mechanisms now make that impossible, regardless of which
-- source misbehaves:
--
--  (1) LEVEL-TOKEN RATE LIMIT.  mode / state / ball / game are LEVEL reports:
--      the byte carries the current value, so coalescing loses nothing -- the
--      ESP always learns the latest level, just possibly one guard interval
--      later. After any level token is granted, `lvl_hold` blocks the whole
--      level group for LVL_GAP bit-times. Level traffic is therefore capped at
--      1 byte per LVL_GAP bit-times = 6.25 % of the link, whatever the inputs
--      do. `lvl_hold` counts baud ticks (not granted bytes) so an idle link
--      still clears the guard in LVL_GAP bit-times and a real state change is
--      reported within 1.4 ms -- far below the ESP's 300 ms gip debounce.
--      Sound is deliberately NOT rate-limited: it is an EVENT, coalescing it
--      would drop a cue.
--
--  (2) ANTI-STARVATION CREDIT.  `starve` counts consecutive granted bytes that
--      were not snapshot bytes and saturates at STARVE_MAX. Once saturated, a
--      waiting snapshot byte is granted AHEAD of every status class. So at most
--      STARVE_MAX consecutive non-snapshot bytes can be sent while snap_req is
--      asserted: the snapshot stream keeps >= 1/(STARVE_MAX+1) = 25 % of the
--      link even against a source that re-arms every single clock.
--      Worst case: 115200/10/4 = 2880 byte/s -> a 1281-byte frame takes 445 ms,
--      still well inside ram_snoop's 1 s tick, so the snapshot frame period
--      stays 1 s even under a permanent flood (it never slips to 2 s).
--      When nothing else is pending `starve` sits at 0 and the snapshot stream
--      runs at full rate exactly as before -- the fix costs nothing when idle.
--
-- diag and gameplay sound never happen at once (in diag the 6502 is held, so no
-- sound is generated) -> one wire safely carries both. The diag token + game-state
-- are sent on every change AND periodically (heartbeat, hb_ms) so the ESP re-syncs
-- if it ever misses a transition. Idle line = high. Part of GottFA80 (GPL-3.0).
--
-- ESP RX decode (check in this order): (b & 0xFE)==0xF0 -> diag = b&1;
--   else (b & 0xFE)==0xF2 -> game_running = b&1; else (b & 0xE0)==0x80 -> play
--   sound (b & 0x1F); else (b & 0xC0)==0x40 -> set theme (b & 0x3F).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sound_link is
  generic (
    clk_hz : integer := 50000000;
    baud   : integer := 115200;
    hb_ms  : integer := 50;                      -- diag-token heartbeat period (ms)
    -- fairness knobs (see the ARBITRATION block above)
    lvl_gap    : integer := 160;                 -- bit-times a level token holds off its group
    starve_max : integer := 3                    -- max consecutive non-snapshot bytes
  );
  port (
    clk   : in  std_logic;
    rst   : in  std_logic;                       -- active-high reset (e.g. not reset_l)
    diag  : in  std_logic := '0';                -- diag/lisyctrl mode active (lisy_active)
    sound : in  std_logic_vector(4 downto 0);    -- Sound_Meta {S16,S8,S4,S2,S1}
    game  : in  std_logic_vector(5 downto 0);    -- game_select
    game_running : in std_logic := '0';          -- '1' = a game is in play (tournament auto-timer)
    ball  : in  std_logic_vector(3 downto 0) := "0000";  -- ball-in-play ($0072) telemetry
    -- ESP -> FPGA link telemetry (see the header).  Defaulted so instantiations
    -- that do not wire them (SND_LINK_H in the hybrid build) elaborate unchanged.
    dinj  : in  std_logic_vector(3 downto 0) := "0000";  -- {dvalid, ctrl(2 downto 0)} -> 0xE0|dinj
    rxc   : in  std_logic_vector(3 downto 0) := "0000";  -- disp_inject deframed bytes -> 0xB0|rxc
    -- RAM-snapshot byte injection (ram_snoop). All defaulted so instantiations
    -- that do not use it (e.g. SND_LINK_H in the hybrid build) elaborate unchanged.
    snap_data : in  std_logic_vector(7 downto 0) := (others => '0');
    snap_req  : in  std_logic := '0';          -- '1' = snap_data is valid, please send
    snap_ack  : out std_logic := '0';          -- pulsed one baud tick when accepted
    tx    : out std_logic                        -- UART TX to the ESP (idle high)
  );
end sound_link;

architecture rtl of sound_link is
  constant DIV : integer := clk_hz / baud;
  constant HB  : integer := (clk_hz / 1000) * hb_ms;
  signal baud_cnt  : integer range 0 to DIV-1 := 0;
  signal baud_tick : std_logic := '0';
  signal hb_cnt    : integer range 0 to HB-1 := 0;
  -- change detection
  signal sound_r   : std_logic_vector(4 downto 0) := (others => '0');
  signal game_r    : std_logic_vector(5 downto 0) := (others => '0');
  signal diag_r    : std_logic := '0';
  signal gr_r      : std_logic := '0';           -- game_running change detect
  signal ball_r    : std_logic_vector(3 downto 0) := "0000";  -- ball change detect
  signal dinj_r    : std_logic_vector(3 downto 0) := "0000";  -- disp_inject state change detect
  signal rxc_r     : std_logic_vector(3 downto 0) := "0000";  -- deframed-byte count change detect
  signal snd_pend  : std_logic := '0';
  signal game_pend : std_logic := '0';
  signal gr_pend   : std_logic := '0';           -- game-state message pending (0xF2 over / 0xF3 run)
  signal ball_pend : std_logic := '0';           -- ball telemetry pending (0xA0 | ball)
  signal dinj_pend : std_logic := '1';           -- disp_inject state pending (0xE0 | dinj), announce once at start
  signal rxc_pend  : std_logic := '0';           -- deframed-byte count pending (0xB0 | rxc)
  signal mode_pend : std_logic := '1';           -- announce the mode once at start
  -- fairness
  signal lvl_hold  : integer range 0 to lvl_gap := 0;      -- level group held off (baud ticks)
  signal starve    : integer range 0 to starve_max := 0;   -- consecutive non-snapshot bytes
  signal lvl_ok    : std_logic;                            -- '1' = a level token may be granted
  -- UART TX
  type t_state is (IDLE, START, DATA, STOP);
  signal st      : t_state := IDLE;
  signal shifter : std_logic_vector(7 downto 0) := (others => '0');
  signal bitn    : integer range 0 to 7 := 0;
begin

  -- baud-rate tick
  process(clk) begin
    if rising_edge(clk) then
      if baud_cnt = DIV-1 then baud_cnt <= 0; baud_tick <= '1';
      else baud_cnt <= baud_cnt + 1; baud_tick <= '0'; end if;
    end if;
  end process;

  lvl_ok <= '1' when lvl_hold = 0 else '0';

  process(clk)
    variable nb : std_logic_vector(7 downto 0);
  begin
    if rising_edge(clk) then
      if rst = '1' then
        st <= IDLE; tx <= '1'; snd_pend <= '0'; game_pend <= '0'; gr_pend <= '0'; mode_pend <= '1';
        snap_ack <= '0';
        sound_r <= sound; game_r <= game; diag_r <= diag; gr_r <= game_running; bitn <= 0; hb_cnt <= 0;
        ball_pend <= '0'; ball_r <= ball;
        dinj_pend <= '1'; dinj_r <= dinj;      -- announce the link state once out of reset
        rxc_pend  <= '0'; rxc_r  <= rxc;
        lvl_hold <= 0; starve <= 0;
      else
        -- latch changes promptly (every clk); keep the latest value
        if sound /= sound_r then sound_r <= sound; snd_pend  <= '1'; end if;
        if game  /= game_r  then game_r  <= game;  game_pend <= '1'; end if;
        if diag  /= diag_r  then diag_r  <= diag;  mode_pend <= '1'; end if;
        if game_running /= gr_r then gr_r <= game_running; gr_pend <= '1'; end if;
        if ball /= ball_r then ball_r <= ball; ball_pend <= '1'; end if;
        if dinj /= dinj_r then dinj_r <= dinj; dinj_pend <= '1'; end if;
        if rxc  /= rxc_r  then rxc_r  <= rxc;  rxc_pend  <= '1'; end if;
        -- heartbeat: re-announce the current mode + game-state + ESP-link state
        -- periodically (ESP re-syncs, and a STUCK disp_inject state is still
        -- reported instead of going silent and looking like "nothing to say").
        if hb_cnt = HB-1 then hb_cnt <= 0; mode_pend <= '1'; gr_pend <= '1'; dinj_pend <= '1';
        else hb_cnt <= hb_cnt + 1; end if;

        if baud_tick = '1' then
          snap_ack <= '0';                                  -- default: ack is one baud tick wide
          -- level-group guard decays on every byte slot, busy or idle
          if lvl_hold /= 0 then lvl_hold <= lvl_hold - 1; end if;

          case st is
            when IDLE =>
              tx <= '1';
              -- (2) FAIRNESS OVERRIDE: after starve_max consecutive non-snapshot
              -- bytes a waiting snapshot byte jumps the whole priority chain.
              if starve = starve_max and snap_req = '1' then
                shifter <= snap_data;      snap_ack <= '1'; st <= START;
                starve  <= 0;
              -- (1) LEVEL tokens, rate-limited as a group by lvl_hold
              elsif lvl_ok = '1' and mode_pend = '1' then      -- mode token = highest priority
                nb := "1111000" & diag_r;  shifter <= nb; mode_pend <= '0'; st <= START;
                lvl_hold <= lvl_gap; if starve /= starve_max then starve <= starve + 1; end if;
              elsif lvl_ok = '1' and gr_pend = '1' then        -- game-state: 0xF2 over / 0xF3 running
                nb := "1111001" & gr_r;    shifter <= nb; gr_pend  <= '0'; st <= START;
                lvl_hold <= lvl_gap; if starve /= starve_max then starve <= starve + 1; end if;
              elsif lvl_ok = '1' and ball_pend = '1' then      -- ball-in-play telemetry: 0xA0 | ball
                nb := "1010" & ball_r;     shifter <= nb; ball_pend <= '0'; st <= START;
                lvl_hold <= lvl_gap; if starve /= starve_max then starve <= starve + 1; end if;
              elsif lvl_ok = '1' and game_pend = '1' then
                nb := "01" & game_r;       shifter <= nb; game_pend <= '0'; st <= START;
                lvl_hold <= lvl_gap; if starve /= starve_max then starve <= starve + 1; end if;
              elsif lvl_ok = '1' and dinj_pend = '1' then     -- ESP->FPGA link state: 0xE0 | {dvalid,ctrl2..0}
                nb := "1110" & dinj_r;     shifter <= nb; dinj_pend <= '0'; st <= START;
                lvl_hold <= lvl_gap; if starve /= starve_max then starve <= starve + 1; end if;
              elsif lvl_ok = '1' and rxc_pend = '1' then      -- deframed-byte count: 0xB0 | rxc (0xB0..0xBE)
                nb := "1011" & rxc_r;      shifter <= nb; rxc_pend  <= '0'; st <= START;
                lvl_hold <= lvl_gap; if starve /= starve_max then starve <= starve + 1; end if;
              -- EVENT: sound cues are never coalesced and never rate-limited
              elsif snd_pend = '1' then
                nb := "100" & sound_r;     shifter <= nb; snd_pend  <= '0'; st <= START;
                if starve /= starve_max then starve <= starve + 1; end if;
              elsif snap_req = '1' then                      -- RAM snapshot = lowest priority
                shifter <= snap_data;      snap_ack <= '1'; st <= START;
                starve  <= 0;
              end if;
            when START =>
              tx <= '0'; bitn <= 0; st <= DATA;              -- start bit
            when DATA =>
              tx <= shifter(0);                              -- LSB first
              shifter <= '0' & shifter(7 downto 1);
              if bitn = 7 then st <= STOP; else bitn <= bitn + 1; end if;
            when STOP =>
              tx <= '1'; st <= IDLE;                         -- stop bit
          end case;
        end if;
      end if;
    end if;
  end process;

end rtl;
