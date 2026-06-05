-- sound_link.vhd : 1-wire 8N1 UART link FPGA -> ESP companion. In the ESP-sound
-- build it drives the Debug pin (PIN_11 / K2), carrying everything the ESP needs
-- from the FPGA on a single wire next to the FPGA:
--   1 0 0 s s s s s   (0x80 | sound[4:0])  -- a sound command (Sound_Meta)  [gameplay]
--   0 1 g g g g g g   (0x40 | game[5:0])   -- the selected game number       [gameplay]
--   1 1 1 1 0 0 0 d   (0xF0 | diag)        -- diag-mode token (d=1 on, 0 normal)
-- The three ranges (0x80..0x9F / 0x40..0x7F / 0xF0..0xF1) never overlap.
--
-- diag and gameplay sound never happen at once (in diag the 6502 is held, so no
-- sound is generated) -> one wire safely carries both. The diag token is sent on
-- every change of `diag` AND periodically (heartbeat, hb_ms) so the ESP re-syncs
-- if it ever misses a transition. Idle line = high. Part of GottFA80 (GPL-3.0).
--
-- ESP RX decode (check in this order): (b & 0xFE)==0xF0 -> diag = b&1;
--   else (b & 0xE0)==0x80 -> play sound (b & 0x1F); else (b & 0xC0)==0x40 ->
--   set theme (b & 0x3F).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sound_link is
  generic (
    clk_hz : integer := 50000000;
    baud   : integer := 115200;
    hb_ms  : integer := 50                       -- diag-token heartbeat period (ms)
  );
  port (
    clk   : in  std_logic;
    rst   : in  std_logic;                       -- active-high reset (e.g. not reset_l)
    diag  : in  std_logic := '0';                -- diag/lisyctrl mode active (lisy_active)
    sound : in  std_logic_vector(4 downto 0);    -- Sound_Meta {S16,S8,S4,S2,S1}
    game  : in  std_logic_vector(5 downto 0);    -- game_select
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
  signal snd_pend  : std_logic := '0';
  signal game_pend : std_logic := '0';
  signal mode_pend : std_logic := '1';           -- announce the mode once at start
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

  process(clk)
    variable nb : std_logic_vector(7 downto 0);
  begin
    if rising_edge(clk) then
      if rst = '1' then
        st <= IDLE; tx <= '1'; snd_pend <= '0'; game_pend <= '0'; mode_pend <= '1';
        sound_r <= sound; game_r <= game; diag_r <= diag; bitn <= 0; hb_cnt <= 0;
      else
        -- latch changes promptly (every clk); keep the latest value
        if sound /= sound_r then sound_r <= sound; snd_pend  <= '1'; end if;
        if game  /= game_r  then game_r  <= game;  game_pend <= '1'; end if;
        if diag  /= diag_r  then diag_r  <= diag;  mode_pend <= '1'; end if;
        -- diag-token heartbeat (re-announce the current mode periodically)
        if hb_cnt = HB-1 then hb_cnt <= 0; mode_pend <= '1';
        else hb_cnt <= hb_cnt + 1; end if;

        if baud_tick = '1' then
          case st is
            when IDLE =>
              tx <= '1';
              if mode_pend = '1' then                          -- mode token = highest priority
                nb := "1111000" & diag_r;  shifter <= nb; mode_pend <= '0'; st <= START;
              elsif game_pend = '1' then
                nb := "01" & game_r;       shifter <= nb; game_pend <= '0'; st <= START;
              elsif snd_pend = '1' then
                nb := "100" & sound_r;     shifter <= nb; snd_pend  <= '0'; st <= START;
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
