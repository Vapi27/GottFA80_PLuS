-- sound_link.vhd : 1-wire UART link FPGA -> ESP carrying the live sound command
-- and the selected game number, so the ESP WAV player can pick the per-game theme
-- folder and play <theme>/<sound>.wav. Part of GottFA80 (GPL-3.0).
--
-- One self-describing 8N1 byte per event (LSB first), no framing needed:
--   1 0 0 s s s s s   (0x80 | sound[4:0])   -- a sound command (Sound_Meta)
--   0 1 g g g g g g   (0x40 | game[5:0])    -- the selected game number
-- (ranges 0x80..0x9F and 0x40..0x7F never overlap; 0x00..0x3F unused.)
--
-- The ESP runs a plain UART RX: byte & 0x80 -> play sound (byte & 0x1F);
-- else byte & 0x40 -> set theme (byte & 0x3F). Idle line = high.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sound_link is
  generic (
    clk_hz : integer := 50000000;
    baud   : integer := 115200
  );
  port (
    clk   : in  std_logic;
    rst   : in  std_logic;                       -- active-high reset (e.g. not reset_l)
    sound : in  std_logic_vector(4 downto 0);    -- Sound_Meta {S16,S8,S4,S2,S1}
    game  : in  std_logic_vector(5 downto 0);    -- game_select
    tx    : out std_logic                        -- UART TX to the ESP (idle high)
  );
end sound_link;

architecture rtl of sound_link is
  constant DIV : integer := clk_hz / baud;
  signal baud_cnt  : integer range 0 to DIV-1 := 0;
  signal baud_tick : std_logic := '0';
  -- change detection
  signal sound_r   : std_logic_vector(4 downto 0) := (others => '0');
  signal game_r    : std_logic_vector(5 downto 0) := (others => '0');
  signal snd_pend  : std_logic := '0';
  signal game_pend : std_logic := '0';
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
        st <= IDLE; tx <= '1'; snd_pend <= '0'; game_pend <= '0';
        sound_r <= sound; game_r <= game; bitn <= 0;
      else
        -- latch changes promptly (every clk); keep the latest value
        if sound /= sound_r then sound_r <= sound; snd_pend  <= '1'; end if;
        if game  /= game_r  then game_r  <= game;  game_pend <= '1'; end if;

        if baud_tick = '1' then
          case st is
            when IDLE =>
              tx <= '1';
              if game_pend = '1' then
                nb := "01" & game_r;  shifter <= nb; game_pend <= '0'; st <= START;
              elsif snd_pend = '1' then
                nb := "100" & sound_r; shifter <= nb; snd_pend <= '0'; st <= START;
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
