-- disp_inject.vhd : ESP32-S3 -> FPGA one-wire command receiver (8N1, 115200).
-- Part of GottFA80_PLuS (GPL-3.0).  Pstore 2026-07-25.
--
-- WIRE: ESP GPIO9 (TX) -> FPGA PIN_2 / Audio_RX.  One direction only; the return
-- path (FPGA -> ESP) is the existing sound_link UART on the Debug pin (PIN_11).
--
-- FRAMING.  Two frame types, told apart by the first byte, which is the ONLY byte
-- allowed to be >= 0xFE.  That invariant is what makes resynchronisation trivial:
-- 0xFF / 0xFE are never consumed as payload, so a marker seen at any point aborts
-- whatever frame was in flight and starts a new one.
--
--   DISPLAY  0xFF, then 7 ASCII chars (0x20..0x7E), right-justified, space padded.
--            -> dstr(1 to 7) + dvalid.  DOUBLE BUFFERED: a half-received frame is
--            never presented, so the glass cannot show a torn string.
--            dvalid self-clears hold_ms (default 1 s) after the LAST display frame,
--            so the overlay disappears by itself if the ESP stops talking.
--
--   CONTROL  0xFE, then ONE flags byte constrained to 0x00..0x7D:
--               bit0 = auto_restart_en   (1 = auto-restart games at game over)
--               bit1 = ta_display_en     (1 = show the injected string on the glass)
--               bit2 = game_kill         (edge 0->1 = end the current game NOW)
--               bit3 = kill_long         (OPTIONAL extension, see below; 0 = contract)
--               bits 4-6 reserved, send 0
--            -> ctrl(6 downto 0) + a ONE-CLOCK kill_pulse_req on the 0->1 edge of
--            bit2.  The ESP repeats the control frame at least every 500 ms.
--
-- FAIL-SAFE (mandatory).  If no VALID control frame arrives for ctrl_to_ms
-- (default 2 s), ctrl(1 downto 0) is cleared by this module on its own -> a
-- crashed, hung or unplugged ESP can never leave the machine restarting games or
-- overlaying its string forever.  bit2 is edge triggered and one-shot, so it needs
-- no timeout and is deliberately NOT cleared (clearing it would arm a spurious
-- edge on the next frame).  The two fail-safes are independent and BOTH must fail
-- for a stuck overlay: ctrl(1) times out at 2 s AND dvalid at 1 s.
--
-- bit3 (kill_long) is an OPTIONAL, strictly backward-compatible extension: this
-- module only reports it, SYS80 uses it to stretch the slam pulse.  Sending 0 --
-- as the protocol contract says to do for reserved bits -- gives exactly the
-- contracted behaviour.  It exists so the slam pulse length can be changed from
-- the ESP, in the field, without re-flashing the FPGA.
--
-- ROBUSTNESS: 3-stage input synchroniser (metastability + the long cable run),
-- mid-bit start-bit re-check (a glitch on the idle line cannot fake a byte) and a
-- stop-bit check ('0' -> byte discarded).  A pin-level WEAK_PULL_UP on Audio_RX
-- (see SYS80.qsf) parks the line idle-high when the ESP is unplugged, so a
-- floating pin cannot synthesise frames.
--
-- COST NOTE: a shared 1 ms time base + two small millisecond counters are used
-- instead of two full-width tick counters (37 FF instead of 53) -- this device
-- (10CL006) is nearly full.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity disp_inject is
  generic (
    clk_hz     : natural := 50000000;  -- clk frequency
    baud       : natural := 115200;    -- must match the ESP
    hold_ms    : natural := 1000;      -- dvalid drops this long after the last display frame
    ctrl_to_ms : natural := 2000       -- fail-safe: clear ctrl(1 downto 0) after this silence
  );
  port (
    clk            : in  std_logic;
    rst            : in  std_logic;                    -- active HIGH, synchronous
    rx             : in  std_logic;                    -- Audio_RX / PIN_2, idle high
    -- display injection
    dstr           : out string(1 to 7);
    dvalid         : out std_logic;
    -- control flags
    ctrl           : out std_logic_vector(6 downto 0);
    kill_pulse_req : out std_logic;                    -- 1 clk pulse on ctrl bit2 rising edge
    -- TELEMETRY (2026-07-27).  Free-running counter of every byte this receiver
    -- has successfully DEFRAMED (valid start bit + 8 data bits + a '1' stop bit),
    -- counted BEFORE the frame parser looks at it -- so it moves for any traffic
    -- on the pin, whatever the protocol layer then makes of it.  That is the whole
    -- point: it separates "nothing at all arrives on PIN_2" (counter frozen) from
    -- "bytes arrive but never form a valid frame" (counter runs, dvalid stays 0).
    -- It counts 0..14 and wraps, NOT 0..15: sound_link ships it as 0xB0|rx_cnt and
    -- 0xBF is already taken by the RAM-snapshot frame marker, so value 15 would be
    -- indistinguishable from the start of a snapshot.  Never let this reach 15.
    rx_cnt         : out std_logic_vector(3 downto 0)
  );
end disp_inject;

architecture rtl of disp_inject is

  constant DIV    : natural := clk_hz / baud;   -- 434 @ 50 MHz / 115200 (0.008 % error)
  constant HALFD  : natural := DIV / 2;         -- mid-bit sample offset
  constant MS_DIV : natural := clk_hz / 1000;   -- 50000

  -- input synchroniser
  signal rx_sync : std_logic_vector(2 downto 0) := "111";
  signal rx_s    : std_logic;

  -- byte receiver
  type   RX_ST is (RX_IDLE, RX_START, RX_DATA, RX_STOP);
  signal rxst  : RX_ST := RX_IDLE;
  signal bcnt  : integer range 0 to DIV-1 := 0;
  signal bidx  : integer range 0 to 7 := 0;
  signal sh    : std_logic_vector(7 downto 0) := (others => '0');
  signal b_val : std_logic := '0';                        -- 1 clk: b_dat is a fresh byte
  signal b_dat : std_logic_vector(7 downto 0) := (others => '0');

  -- frame parser
  type   P_ST is (P_IDLE, P_DISP, P_CTRL);
  signal pst    : P_ST := P_IDLE;
  signal dcnt   : integer range 0 to 6 := 0;
  signal dbuf   : string(1 to 7) := "       ";            -- frame being received
  signal dreg   : string(1 to 7) := "       ";            -- last COMPLETE frame (published)
  signal dval_i : std_logic := '0';
  signal ctrl_r : std_logic_vector(6 downto 0) := (others => '0');
  signal kill_o : std_logic := '0';

  -- telemetry: deframed-byte counter, mod 15 (see the rx_cnt port comment)
  signal rxc_r  : unsigned(3 downto 0) := (others => '0');

  -- timeouts
  signal ms_cnt : integer range 0 to MS_DIV-1 := 0;
  signal d_ms   : integer range 0 to hold_ms := hold_ms;
  signal c_ms   : integer range 0 to ctrl_to_ms := ctrl_to_ms;

begin

  rx_s           <= rx_sync(2);
  dstr           <= dreg;
  dvalid         <= dval_i;
  ctrl           <= ctrl_r;
  kill_pulse_req <= kill_o;
  rx_cnt         <= std_logic_vector(rxc_r);

  RXP : process (clk)
    variable bi : integer range 0 to 255;
    variable c  : character;
  begin
    if rising_edge(clk) then

      -- defaults (overridden below where needed)
      rx_sync <= rx_sync(1 downto 0) & rx;
      b_val   <= '0';
      kill_o  <= '0';

      if rst = '1' then
        rxst   <= RX_IDLE;
        bcnt   <= 0;
        bidx   <= 0;
        pst    <= P_IDLE;
        dcnt   <= 0;
        dbuf   <= "       ";
        dreg   <= "       ";
        dval_i <= '0';
        ctrl_r <= (others => '0');
        rxc_r  <= (others => '0');
        ms_cnt <= 0;
        d_ms   <= hold_ms;
        c_ms   <= ctrl_to_ms;
      else

        ---------------------------------------------------------------------
        -- millisecond time base + the two fail-safes.
        -- Both counters SATURATE at their limit (they never wrap), so the
        -- timed-out state is stable until a new frame re-arms it.
        ---------------------------------------------------------------------
        if ms_cnt = MS_DIV-1 then
          ms_cnt <= 0;
          if d_ms < hold_ms    then d_ms <= d_ms + 1; end if;
          if c_ms < ctrl_to_ms then c_ms <= c_ms + 1; end if;
        else
          ms_cnt <= ms_cnt + 1;
        end if;
        if d_ms >= hold_ms then
          dval_i <= '0';                       -- display overlay expires by itself
        end if;
        if c_ms >= ctrl_to_ms then
          ctrl_r(1 downto 0) <= "00";          -- ESP silent -> auto-restart + overlay OFF
        end if;

        ---------------------------------------------------------------------
        -- 8N1 receiver
        ---------------------------------------------------------------------
        case rxst is

          when RX_IDLE =>
            bcnt <= 0;
            if rx_s = '0' then                 -- falling edge = possible start bit
              rxst <= RX_START;
            end if;

          when RX_START =>                     -- re-check at the MIDDLE of the start bit
            if bcnt = HALFD-1 then
              bcnt <= 0;
              if rx_s = '0' then
                bidx <= 0;
                rxst <= RX_DATA;
              else
                rxst <= RX_IDLE;               -- glitch, not a start bit
              end if;
            else
              bcnt <= bcnt + 1;
            end if;

          when RX_DATA =>                      -- sample each bit at its mid-point, LSB first
            if bcnt = DIV-1 then
              bcnt <= 0;
              sh   <= rx_s & sh(7 downto 1);
              if bidx = 7 then
                rxst <= RX_STOP;
              else
                bidx <= bidx + 1;
              end if;
            else
              bcnt <= bcnt + 1;
            end if;

          when RX_STOP =>
            if bcnt = DIV-1 then
              bcnt <= 0;
              if rx_s = '1' then               -- framing OK -> hand the byte over
                b_dat <= sh;
                b_val <= '1';
                -- TELEMETRY: count every deframed byte, before the parser judges
                -- it.  Wrap at 14 so sound_link's 0xB0|rx_cnt token can never
                -- collide with the 0xBF snapshot marker.
                if rxc_r = 14 then rxc_r <= (others => '0');
                else               rxc_r <= rxc_r + 1; end if;
              end if;
              rxst <= RX_IDLE;
            else
              bcnt <= bcnt + 1;
            end if;

        end case;

        ---------------------------------------------------------------------
        -- frame parser.  0xFF / 0xFE are handled BEFORE the state machine, so
        -- they can never be eaten as payload -> resync is automatic.
        ---------------------------------------------------------------------
        if b_val = '1' then
          bi := to_integer(unsigned(b_dat));

          if bi = 255 then                     -- 0xFF : start of a DISPLAY frame
            pst  <= P_DISP;
            dcnt <= 0;

          elsif bi = 254 then                  -- 0xFE : start of a CONTROL frame
            pst <= P_CTRL;

          else
            case pst is

              when P_DISP =>
                if (bi >= 16#20#) and (bi <= 16#7E#) then
                  c := character'val(bi);
                  if dcnt = 6 then             -- 7th and last char: publish the frame
                    dreg   <= dbuf(2 to 7) & c;
                    dval_i <= '1';
                    d_ms   <= 0;
                    dcnt   <= 0;
                    pst    <= P_IDLE;
                  else
                    dbuf <= dbuf(2 to 7) & c;  -- shift in; first char ends up at dstr(1)
                    dcnt <= dcnt + 1;
                  end if;
                else
                  pst  <= P_IDLE;              -- not printable -> drop the whole frame
                  dcnt <= 0;
                end if;

              when P_CTRL =>
                if bi <= 16#7D# then
                  ctrl_r <= b_dat(6 downto 0);
                  c_ms   <= 0;                 -- re-arm the fail-safe
                  if b_dat(2) = '1' and ctrl_r(2) = '0' then
                    kill_o <= '1';             -- one-shot on the 0->1 edge of bit2
                  end if;
                end if;
                pst <= P_IDLE;

              when others =>
                null;                          -- byte outside any frame: ignore

            end case;
          end if;
        end if;

      end if;  -- rst
    end if;    -- rising_edge
  end process;

end rtl;
