-- sound_link.vhd : 1-wire 8N1 UART link FPGA -> ESP companion. On the Cyclone
-- board it drove the Debug pin (PIN_11 / K2); on the Smart FA module it drives
-- ESP32_RX (P142 -> ESP GPIO18, see GEN_LINK_* in SYS80.vhd). It carries
-- everything the ESP needs from the FPGA on a single wire:
--   1 0 0 s s s s s   (0x80 | sound[4:0])  -- ONE strobed sound latch        [gameplay, EVENT]
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
--   0 0 1 1 0 0 0 0   (0x30)             -- sound bus RELEASED             [EVENT]
--   0 0 1 1 0 0 0 1   (0x31)             -- sound FIFO overflowed, cue lost[EVENT]
--   1 1 1 1 0 1 f f   (0xF4 | fam[1:0])  -- decoded machine family         [LEVEL]
-- The snapshot bytes are supplied by ram_snoop through snap_data/snap_req/snap_ack.
--
-- ###########################################################################
-- # THE COMPLETE BYTE MAP -- this comment is the single authority.  Anything #
-- # added to this link must be allocated HERE first.                         #
-- #                                                                          #
-- #   0x00 .. 0x2F   FREE, AND MUST STAY A NO-OP FOREVER.  A broken wire, or  #
-- #                  the Debug pin floating while the FPGA reconfigures,      #
-- #                  decodes as 0x00 -- it can never be given a meaning.      #
-- #   0x30 .. 0x3F   SOUND META (SOUND_WIRE.md claims the whole nibble)       #
-- #                    0x30  sound bus released, no code selected   EVENT     #
-- #                    0x31  sound event FIFO overflowed, >=1 cue lost EVENT  #
-- #                    0x32..0x3F reserved for this contract, do NOT allocate #
-- #   0x40 .. 0x7F   game number   0x40 | game[5:0]        LEVEL              #
-- #                  NOTE: the TRUE gamelist number (manual Appendix A),      #
-- #                  i.e. `not game_select` in SYS80.vhd -- see the SND_LINK  #
-- #                  port map there.                                         #
-- #   0x80 .. 0x9F   sound command 0x80 | sound[4:0]       EVENT              #
-- #   0xA0 .. 0xAF   ball in play  0xA0 | ball[3:0]        LEVEL              #
-- #   0xB0 .. 0xBE   disp_inject deframed-byte count       LEVEL  (mod 15!)   #
-- #   0xBF           RAM-snapshot frame marker             diagnostic         #
-- #   0xC0 .. 0xCF   snapshot payload, high nibble         diagnostic         #
-- #   0xD0 .. 0xDF   snapshot payload, low  nibble         diagnostic         #
-- #   0xE0 .. 0xEF   disp_inject state 0xE0 | {dvalid,ctrl2,ctrl1,ctrl0}      #
-- #                  LEVEL.  ALL SIXTEEN codes are used (dvalid=1 gives       #
-- #                  0xE8..0xEF) -- 0xE8..0xEF is NOT free.                   #
-- #   0xF0 .. 0xF1   diag mode      0xF0 | diag            LEVEL              #
-- #   0xF2 .. 0xF3   game state     0xF2 | running         LEVEL              #
-- #   0xF4 .. 0xF7   machine family 0xF4 | fam[1:0]        LEVEL              #
-- #                    00 = System 80, 01 = System 80A, 10 = System 80B,      #
-- #                    11 = reserved.  Decoded from the DIP game number by    #
-- #                    lib_common/gts_family.vhd (incl. the S1-6 override),   #
-- #                    so the ESP can name the machine and cross-check the    #
-- #                    DIPs against the sound map it loaded.                  #
-- #   0xFA           BALISE DE JEU : marqueur, SUIVI DE 3 OCTETS BRUTS.       #
-- #                  C'est la SEULE exception a la carte : les 3 octets qui    #
-- #                  suivent 0xFA sont des valeurs arbitraires (numero de jeu, #
-- #                  drapeaux, somme xor) et ne portent AUCUNE classe. Le      #
-- #                  decodeur de l'ESP DOIT les sauter sans les interpreter -- #
-- #                  sans quoi la somme de controle, qui peut tomber dans      #
-- #                  0x80..0x9F, serait lue comme une commande son et          #
-- #                  declencherait un SON FANTOME. Voir fpgalink.cpp.          #
-- #                  Emise ici, atomiquement, parce qu'il n'y a qu'UN fil vers #
-- #                  l'ESP : cf. game_beacon.vhd (own_uart = false).           #
-- #   0xF8 .. 0xF9   RADIO AUTORISEE  0xF8 | wifi_off        LEVEL             #
-- #                    0xF8 = radio autorisee, 0xF9 = radio coupee par le DIP  #
-- #                    d'option S1-6 (ferme = coupee). L'ESP eteint alors sa    #
-- #                    radio : c'est le seul moyen, en clientele, de supprimer  #
-- #                    le WiFi sans deposer la carte.                           #
-- #   0xFB .. 0xFF   FREE (5 codes)                                             #
-- #                                                                          #
-- # Free space for new tokens: 0x32..0x3F (reserved to SOUND_WIRE) and        #
-- # 0xF8..0xFF.  Do NOT reach into 0xE8..0xEF, which the disp_inject token    #
-- # already owns, nor into 0x00..0x2F, which must stay a no-op.               #
-- ###########################################################################
--
-- ESP decode order matters: test the EXACT byte 0xBF before the (b & 0xF0) ==
-- 0xB0 mask, and test the two 0xFx pairs before any coarser mask.
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
-- SOUND EVENTS -- rewritten 2026-07-27 to the SOUND_WIRE.md contract.
--
-- WHAT WAS WRONG.  Sound used to be reported exactly like a LEVEL: one pending
-- register re-armed combinationally from the bus,
--     if sound /= sound_r then sound_r <= sound; snd_pend <= '1'; end if;
-- with at most one byte per 86.8 us slot.  `sound_r` was OVERWRITTEN by the
-- next bus value while the first one was still queued, so a 6502 at 895 kHz
-- (STA abs = 4 cycles = 4.5 us) collapsed a bank header and its payload into a
-- single byte.  The bank was lost SILENTLY -- the ESP played the wrong sample,
-- or none, and nothing on the wire said a cue had gone missing.
--
-- WHAT IT IS NOW.  Sound is an EVENT stream:
--   * one event per STROBED port-A write, produced by lib_common/snd_bus.vhd
--     (see that file for the PinMAME ground truth and the release semantics).
--     `snd_stb` is a one-clk pulse; `snd_rel` says whether it is a cue or the
--     bus release; `sound` carries the code and is sampled on the pulse.
--     A lamp-latch write no longer produces anything at all.
--   * a FIFO, SND_DEPTH = 2**snd_aw = 8 entries x 6 bits {rel, code[4:0]},
--     drained one entry per granted byte, IN ORDER.  8 entries absorb ~694 us
--     of burst = ~150 CPU instructions -- far more than any header/payload
--     pair, or any beep train, needs.
--   * overflow is NEVER silent: a full FIFO drops the NEW event and sets a
--     sticky flag that sends 0x31 once, AHEAD of the next cue.  A trace that
--     cannot tell "the game sent nothing" from "the link lost it" is not
--     evidence.
--
-- COST NOTE.  The 8x6 FIFO array carries ramstyle="M9K": on this device the
-- binding constraint is LABs (361/392 = 92 % at the last fit) while 13 of the
-- 30 M9K blocks are free, so the storage is deliberately pushed into a block
-- RAM and only the pointers/count stay in logic.  The RAM read is registered,
-- hence snd_rdy is snd_cnt/=0 delayed two clocks -- 40 ns against a 4340-clk
-- byte slot, i.e. free, and it can only ever UNDER-grant, never over-grant.
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
--      WHERE SOUND SITS IN THE CHAIN, and why it was left there.  SOUND_WIRE.md
--      2.2 rule 5 suggests promoting the sound FIFO above the level group.  It
--      is NOT promoted, on purpose: `lvl_hold` already caps the ENTIRE level
--      group at one byte per lvl_gap (160 bit-times = 1.39 ms), so a level
--      token can delay a queued cue by at most one byte slot (86.8 us) and
--      only in the one slot per 1.39 ms where lvl_ok is set -- in every other
--      slot the level branches are gated off and sound already wins. The 50 ms
--      heartbeat arms 3 level tokens at once, i.e. a worst case of 3 x 86.8 us
--      of added cue latency per 50 ms.  Promoting sound would buy that back and
--      in exchange create a NEW starvation mode (a game hammering port A would
--      lock the level group out entirely), against a proven arbiter.  With the
--      FIFO in place nothing is lost either way, so the cheaper, safer order
--      wins.  The overflow token 0x31 DOES sit at the top of the sound class:
--      it must arrive before the cue that follows the gap it reports.
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
--   else (b & 0xFE)==0xF2 -> game_running = b&1; else (b & 0xFC)==0xF4 -> family
--   = b&3; else (b & 0xE0)==0x80 -> play sound (b & 0x1F); else (b & 0xF0)==0x30
--   -> sound meta (0x30 release, 0x31 cue lost); else (b & 0xC0)==0x40 -> set
--   theme (b & 0x3F).  0x3x is unambiguous: 0x3x & 0xC0 = 0x00 matches none of
--   the other masks (0xC0->0x40, 0xE0->0x80, 0xF0->0xA0/0xB0/0xE0) and is
--   outside 0xBF / 0xC0..0xDF.  Implemented in gottfa-esp32/src/fpgalink.cpp.
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
    starve_max : integer := 3;                   -- max consecutive non-snapshot bytes
    -- sound EVENT FIFO: depth = 2**snd_aw.  SOUND_WIRE.md asks for >= 4, 8
    -- recommended.  snd_aw=2 (4 deep) is the LAB-starved fallback.
    snd_aw     : integer := 3
  );
  port (
    clk   : in  std_logic;
    rst   : in  std_logic;                       -- active-high reset (e.g. not reset_l)
    diag  : in  std_logic := '0';                -- diag/lisyctrl mode active (lisy_active)
    sound : in  std_logic_vector(4 downto 0);    -- Sound_Meta {S16,S8,S4,S2,S1}, sampled on snd_stb
    -- SOUND EVENTS (snd_bus.vhd).  Defaulted to '0' so an instantiation that does
    -- not wire them simply never reports sound -- it can never report a phantom.
    snd_stb : in std_logic := '0';               -- one clk pulse = one sound-bus event
    snd_rel : in std_logic := '0';               -- with snd_stb: '1' = bus RELEASE (0x30)
    -- decoded machine family -> 0xF4 | fam (LEVEL).  00=80, 01=80A, 10=80B.
    fam   : in  std_logic_vector(1 downto 0) := "00";
    -- DIP d'option S1-6 : '1' = radio coupee. Defaut '0' pour que toute
    -- instanciation existante garde le comportement actuel (radio autorisee).
    wifi_off : in std_logic := '0';
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
    -- Balise de jeu (game_beacon, own_uart = false) : 4 octets emis ATOMIQUEMENT,
    -- octet 0 en poids faible. Defauts fournis : une instanciation qui ne s'en
    -- sert pas elabore inchangee (SND_LINK_H du build hybride).
    bcn_frame : in  std_logic_vector(31 downto 0) := (others => '0');
    bcn_req   : in  std_logic := '0';          -- '1' = trame valide, a envoyer
    bcn_ack   : out std_logic := '0';          -- pulse un tick baud a l'acceptation
    tx    : out std_logic                        -- UART TX to the ESP (idle high)
  );
end sound_link;

architecture rtl of sound_link is
  constant DIV : integer := clk_hz / baud;
  constant HB  : integer := (clk_hz / 1000) * hb_ms;
  constant SND_DEPTH : integer := 2**snd_aw;
  signal baud_cnt  : integer range 0 to DIV-1 := 0;
  signal baud_tick : std_logic := '0';
  signal hb_cnt    : integer range 0 to HB-1 := 0;
  -- change detection
  signal fam_r     : std_logic_vector(1 downto 0) := "00";
  signal game_r    : std_logic_vector(5 downto 0) := (others => '0');
  signal diag_r    : std_logic := '0';
  signal gr_r      : std_logic := '0';           -- game_running change detect
  signal ball_r    : std_logic_vector(3 downto 0) := "0000";  -- ball change detect
  signal dinj_r    : std_logic_vector(3 downto 0) := "0000";  -- disp_inject state change detect
  signal rxc_r     : std_logic_vector(3 downto 0) := "0000";  -- deframed-byte count change detect
  signal game_pend : std_logic := '0';
  signal fam_pend  : std_logic := '1';           -- announce the family once at start
  signal wof_r     : std_logic := '0';
  signal wof_pend  : std_logic := '1';           -- annoncer l'etat de la radio une fois au demarrage
  signal gr_pend   : std_logic := '0';           -- game-state message pending (0xF2 over / 0xF3 run)
  signal ball_pend : std_logic := '0';           -- ball telemetry pending (0xA0 | ball)
  signal dinj_pend : std_logic := '1';           -- disp_inject state pending (0xE0 | dinj), announce once at start
  signal rxc_pend  : std_logic := '0';           -- deframed-byte count pending (0xB0 | rxc)
  signal mode_pend : std_logic := '1';           -- announce the mode once at start
  -- ---- SOUND EVENT FIFO (see the SOUND EVENTS block above) -----------------
  type snd_mem_t is array(0 to SND_DEPTH-1) of std_logic_vector(5 downto 0);
  signal snd_mem  : snd_mem_t := (others => (others => '0'));
  -- LAB budget is the binding constraint on this device, M9K blocks are not:
  -- keep the 48 bits of FIFO storage out of the logic array.
  attribute ramstyle : string;
  attribute ramstyle of snd_mem : signal is "M9K";
  signal snd_wp   : unsigned(snd_aw-1 downto 0) := (others => '0');
  signal snd_rp   : unsigned(snd_aw-1 downto 0) := (others => '0');
  signal snd_cnt  : unsigned(snd_aw downto 0)   := (others => '0');  -- 0 .. SND_DEPTH
  signal snd_push : std_logic;                   -- combinational: accept this event
  signal snd_din  : std_logic_vector(5 downto 0);-- {rel, code[4:0]}
  signal snd_q    : std_logic_vector(5 downto 0) := (others => '0'); -- registered FIFO head
  signal snd_ne   : std_logic;                   -- FIFO not empty (combinational on snd_cnt)
  signal snd_rdy1 : std_logic := '0';            -- snd_ne delayed 1 clk (RAM read latency)
  signal snd_rdy  : std_logic := '0';            -- snd_ne delayed 2 clk -> snd_q is valid
  signal lost_pend: std_logic := '0';            -- sticky: at least one event was dropped
  -- fairness
  signal lvl_hold  : integer range 0 to lvl_gap := 0;      -- level group held off (baud ticks)
  signal starve    : integer range 0 to starve_max := 0;   -- consecutive non-snapshot bytes
  signal lvl_ok    : std_logic;                            -- '1' = a level token may be granted
  -- UART TX
  type t_state is (IDLE, START, DATA, STOP);
  signal st      : t_state := IDLE;
  signal shifter : std_logic_vector(7 downto 0) := (others => '0');
  signal bitn    : integer range 0 to 7 := 0;
  signal bcn_sr  : std_logic_vector(31 downto 0) := (others => '0'); -- reste de la trame balise
  signal bcn_n   : integer range 0 to 3 := 0;                        -- octets de balise restants
begin

  -- baud-rate tick
  process(clk) begin
    if rising_edge(clk) then
      if baud_cnt = DIV-1 then baud_cnt <= 0; baud_tick <= '1';
      else baud_cnt <= baud_cnt + 1; baud_tick <= '0'; end if;
    end if;
  end process;

  lvl_ok <= '1' when lvl_hold = 0 else '0';

  -- ---- sound event FIFO ----------------------------------------------------
  -- Accept an event unless the FIFO is full; on full the NEW event is dropped
  -- and lost_pend is raised (SOUND_WIRE.md 2.2 rule 4).
  snd_ne   <= '0' when snd_cnt = 0 else '1';
  snd_push <= '1' when (snd_stb = '1' and snd_cnt < SND_DEPTH) else '0';
  snd_din  <= snd_rel & sound;

  -- Storage only.  Kept in its OWN process, with no reset and no read enable,
  -- so Quartus infers a simple dual-port block RAM (see ramstyle above).  The
  -- FIFO is "cleared" on rst by clearing the pointers and the count, which is
  -- what emptiness means -- stale bytes left in the array are unreachable.
  process(clk)
  begin
    if rising_edge(clk) then
      if snd_push = '1' then
        snd_mem(to_integer(snd_wp)) <= snd_din;
      end if;
      snd_q <= snd_mem(to_integer(snd_rp));
    end if;
  end process;

  process(clk)
    variable nb  : std_logic_vector(7 downto 0);
    variable pop : std_logic;                  -- '1' = the arbiter took the FIFO head this clk
  begin
    if rising_edge(clk) then
      if rst = '1' then
        st <= IDLE; tx <= '1'; game_pend <= '0'; gr_pend <= '0'; mode_pend <= '1';
        snap_ack <= '0'; bcn_ack <= '0'; bcn_n <= 0;
        game_r <= game; diag_r <= diag; gr_r <= game_running; bitn <= 0; hb_cnt <= 0;
        ball_pend <= '0'; ball_r <= ball;
        dinj_pend <= '1'; dinj_r <= dinj;      -- announce the link state once out of reset
        rxc_pend  <= '0'; rxc_r  <= rxc;
        fam_pend  <= '1'; fam_r  <= fam;       -- announce the machine family once out of reset
        wof_pend  <= '1'; wof_r  <= wifi_off;  -- ... et l'etat de la radio
        lvl_hold <= 0; starve <= 0;
        -- clear the sound FIFO; no phantom cue is emitted for the power-up bus
        -- state, because nothing is ever queued except on an snd_stb pulse.
        snd_wp <= (others => '0'); snd_rp <= (others => '0'); snd_cnt <= (others => '0');
        snd_rdy1 <= '0'; snd_rdy <= '0'; lost_pend <= '0';
      else
        -- ---- SOUND EVENT INTAKE (EVENT class, never coalesced) -------------
        pop := '0';                            -- set by the arbiter below on a sound grant
        snd_rdy1 <= snd_ne;                    -- 2-stage: covers the registered
        snd_rdy  <= snd_rdy1;                  -- FIFO read (see the header)
        if snd_stb = '1' then
          if snd_cnt < SND_DEPTH then
            snd_wp <= snd_wp + 1;              -- snd_push wrote snd_mem(snd_wp) at this same edge
          else
            lost_pend <= '1';                  -- FIFO full: drop the NEW event, and say so
          end if;
        end if;

        -- latch changes promptly (every clk); keep the latest value
        if fam   /= fam_r   then fam_r   <= fam;   fam_pend  <= '1'; end if;
        if wifi_off /= wof_r then wof_r <= wifi_off; wof_pend <= '1'; end if;
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
                                   wof_pend <= '1';   -- l'ESP peut avoir redemarre
        else hb_cnt <= hb_cnt + 1; end if;

        if baud_tick = '1' then
          snap_ack <= '0'; bcn_ack <= '0';                  -- default: ack is one baud tick wide
          -- level-group guard decays on every byte slot, busy or idle
          if lvl_hold /= 0 then lvl_hold <= lvl_hold - 1; end if;

          case st is
            when IDLE =>
              tx <= '1';
              -- (0) BALISE DE JEU -- 4 OCTETS ATOMIQUES, priorite absolue.
              -- Atomique par CONSTRUCTION : une fois `bcn_n` charge, cette branche
              -- est prise a chaque creneau jusqu'a epuisement et la chaine de
              -- priorite n'est pas reevaluee. C'est indispensable : les octets 1
              -- a 3 sont des valeurs arbitraires, sans classe ; intercaler un
              -- token les rendrait indistinguables cote ESP, et la somme de
              -- controle (0x80..0x9F possible) passerait pour une commande son.
              -- Cout : 4 creneaux, 2 fois par seconde = 348 us -- un son peut donc
              -- etre retarde d'au plus 348 us, inaudible. `starve` n'est PAS
              -- incremente ici, pour que la balise ne puisse pas affamer l'instantane.
              if bcn_n /= 0 then
                shifter <= bcn_sr(7 downto 0);
                bcn_sr  <= x"00" & bcn_sr(31 downto 8);
                bcn_n   <= bcn_n - 1;
                st      <= START;
              elsif bcn_req = '1' then
                shifter <= bcn_frame(7 downto 0);      -- 0xFA part tout de suite
                bcn_sr  <= x"00" & bcn_frame(31 downto 8);
                bcn_n   <= 3;
                bcn_ack <= '1';
                st      <= START;
              -- (1bis) SILENCE PENDANT UNE SESSION LISY.
              -- Le fil vers l'ESP est aussi le canal ou LISY lit ses REPONSES. Tout
              -- flux continu de notre part les noie : mesure du 2026-09-05 sur la
              -- machine, « Control denied (Code 243) » ou 243 = 0xF3 est un de nos
              -- jetons. Ralentir le battement de coeur n'avait pas suffi -- le
              -- probleme n'est pas le debit, c'est le partage.
              -- En diagnostic le 6502 est TENU : il n'y a aucun son a annoncer, donc
              -- se taire ne coute rien. Seule la balise continue (branches ci-dessus),
              -- pour que l'ESP voie toujours le FPGA.
              -- (0bis) JETON DE MODE -- HORS DE LA PORTE, comme la balise.
              -- Il etait a l'interieur : en diagnostic la porte se ferme, donc le seul
              -- octet qui dit « je suis en diagnostic » ne pouvait JAMAIS sortir et
              -- l'ESP lisait 0xF0 a vie. L'instrument etait aveugle a l'etat qu'il
              -- devait detecter (paye le 2026-09-07). Cout de le laisser passer :
              -- 1 octet par changement + 1 par battement (hb_ms = 1 s), soit 23 us de
              -- fil par seconde -- sans commune mesure avec le flux continu qui noyait
              -- les reponses LISY, qui lui reste bien derriere la porte.
              elsif lvl_ok = '1' and mode_pend = '1' then
                nb := "1111000" & diag_r;  shifter <= nb; mode_pend <= '0'; st <= START;
                lvl_hold <= lvl_gap; if starve /= starve_max then starve <= starve + 1; end if;
              elsif diag = '0' then
              if starve = starve_max and snap_req = '1' then
                shifter <= snap_data;      snap_ack <= '1'; st <= START;
                starve  <= 0;
              -- (1) LEVEL tokens, rate-limited as a group by lvl_hold
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
              elsif lvl_ok = '1' and fam_pend = '1' then      -- machine family: 0xF4 | fam
                nb := "111101" & fam_r;    shifter <= nb; fam_pend  <= '0'; st <= START;
                lvl_hold <= lvl_gap; if starve /= starve_max then starve <= starve + 1; end if;
              elsif lvl_ok = '1' and wof_pend = '1' then      -- radio : 0xF8 | wifi_off
                nb := "1111100" & wof_r;   shifter <= nb; wof_pend  <= '0'; st <= START;
                lvl_hold <= lvl_gap; if starve /= starve_max then starve <= starve + 1; end if;
              -- EVENT class: sound is never coalesced and never rate-limited.
              -- 0x31 (a cue was lost) goes FIRST so it always precedes the cue
              -- that follows the gap it reports.
              elsif lost_pend = '1' then
                nb := x"31";               shifter <= nb; lost_pend <= '0'; st <= START;
                if starve /= starve_max then starve <= starve + 1; end if;
              elsif snd_rdy = '1' then                       -- one FIFO entry, in order
                if snd_q(5) = '1' then nb := x"30";          -- bus RELEASE
                else                   nb := "100" & snd_q(4 downto 0); end if;  -- 0x80 | cmd
                shifter <= nb; st <= START;
                snd_rp <= snd_rp + 1; pop := '1';
                if starve /= starve_max then starve <= starve + 1; end if;
              elsif snap_req = '1' then                      -- RAM snapshot = lowest priority
                shifter <= snap_data;      snap_ack <= '1'; st <= START;
                starve  <= 0;
              end if;
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

        -- FIFO occupancy, updated in exactly ONE place so a push and a pop that
        -- land on the same clock edge BOTH take effect (in VHDL the last signal
        -- assignment in a process wins, so splitting this would silently lose
        -- one of them -- which is the very bug this whole change exists to fix).
        if snd_push = '1' and pop = '0' then
          snd_cnt <= snd_cnt + 1;
        elsif snd_push = '0' and pop = '1' then
          snd_cnt <= snd_cnt - 1;
        end if;
      end if;
    end if;
  end process;

end rtl;
