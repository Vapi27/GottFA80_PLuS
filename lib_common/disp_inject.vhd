-- disp_inject.vhd : ESP -> FPGA display injection for tournament time-attack (option B).
--
-- The ESP computes the countdown and FORMATS the 7 display chars itself (so it handles the
-- 7-seg 80/80A AND the 16-seg 80B alphanumeric in software), then streams them to the FPGA over
-- a 1-wire 8N1 UART (reusing the freed Audio_RX / PIN_2 in a hybrid build). This module is the
-- FPGA receiver: it decodes frames [0xFF sync][7 ASCII bytes] -> latches `dstr` + raises `arm`
-- (a drop-in for tourney_display_top's arm+dstr outputs, fed to boot_message). `arm` self-clears
-- on a receive TIMEOUT (the ESP stops sending at game over). This replaces the FPGA countdown+BCD
-- chain (~463 LE: tourney_countdown + bin_to_bcd + value_to_dispstr) with a tiny UART RX — the
-- ESP now does the arithmetic + formatting. Pure, synthesizable, sim-checked.
-- (character handling matches value_to_dispstr / boot_message's synthesized style.)
-- (C) 2026 Valere Pilpil / Pstore.  Part of GottFA80 (GPL-3.0).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity disp_inject is
  generic (
    CLK_HZ     : integer := 50000000;
    BAUD       : integer := 115200;
    TIMEOUT_MS : integer := 500            -- arm drops if no full frame arrives within this
  );
  port (
    clk  : in  std_logic;
    rst  : in  std_logic;                  -- async, active high
    rx   : in  std_logic;                  -- UART RX from the ESP (idle high)
    arm  : out std_logic;                  -- '1' => show the injected string (display overlay)
    dstr : out string(1 to 7)              -- dstr(1)=MSD .. dstr(7)=LSD (the ESP-formatted chars)
  );
end entity;

architecture rtl of disp_inject is
  constant BIT_CLKS : integer := CLK_HZ / BAUD;
  constant HALF_BIT : integer := BIT_CLKS / 2;
  constant TO_CLKS  : integer := (CLK_HZ / 1000) * TIMEOUT_MS;
  type rxst_t is (IDLE, START, DATA, STOP);
  signal rxst   : rxst_t := IDLE;
  signal clkcnt : integer range 0 to BIT_CLKS := 0;
  signal bitcnt : integer range 0 to 7 := 0;
  signal shreg  : std_logic_vector(7 downto 0) := (others => '0');
  signal rxs    : std_logic_vector(1 downto 0) := "11";   -- 2-FF synchroniser on rx
  -- frame assembler: 0xFF sync, then 7 chars (first 6 buffered, 7th completes)
  type buf_t is array (0 to 5) of std_logic_vector(7 downto 0);
  signal fbuf  : buf_t := (others => x"20");
  signal idx   : integer range 0 to 7 := 7;               -- 7 = idle; 0..6 = index of the next char
  signal arm_r : std_logic := '0';
  signal tocnt : integer range 0 to TO_CLKS := 0;
  signal s     : string(1 to 7) := "       ";
begin
  process (clk, rst)
    variable bv : std_logic;               -- a byte completed this cycle
    variable b  : std_logic_vector(7 downto 0);
  begin
    if rst = '1' then
      rxst <= IDLE; clkcnt <= 0; bitcnt <= 0; rxs <= "11";
      idx <= 7; arm_r <= '0'; tocnt <= 0; s <= "       "; fbuf <= (others => x"20");
    elsif rising_edge(clk) then
      rxs <= rxs(0) & rx;
      bv := '0'; b := shreg;
      ---- UART RX (sampled line = rxs(1)) ----
      case rxst is
        when IDLE  => if rxs(1) = '0' then rxst <= START; clkcnt <= 0; end if;
        when START =>
          if clkcnt = HALF_BIT then
            if rxs(1) = '0' then clkcnt <= 0; bitcnt <= 0; rxst <= DATA;  -- valid start
            else rxst <= IDLE; end if;                                    -- glitch
          else clkcnt <= clkcnt + 1; end if;
        when DATA  =>
          if clkcnt = BIT_CLKS - 1 then
            clkcnt <= 0; shreg <= rxs(1) & shreg(7 downto 1);             -- LSB first
            if bitcnt = 7 then rxst <= STOP; else bitcnt <= bitcnt + 1; end if;
          else clkcnt <= clkcnt + 1; end if;
        when STOP  =>
          if clkcnt = BIT_CLKS - 1 then rxst <= IDLE; bv := '1';         -- byte ready (= shreg)
          else clkcnt <= clkcnt + 1; end if;
      end case;

      ---- frame assembler + receive timeout ----
      if bv = '1' then
        if b = x"FF" then
          idx <= 0;                                                       -- sync -> expect 7 chars
        elsif idx <= 6 then
          if idx = 6 then                                                 -- 7th char completes a frame
            for i in 0 to 5 loop
              s(i + 1) <= character'val(to_integer(unsigned(fbuf(i))));
            end loop;
            s(7) <= character'val(to_integer(unsigned(b)));
            arm_r <= '1'; tocnt <= 0; idx <= 7;
          else
            fbuf(idx) <= b; idx <= idx + 1;
          end if;
        end if;
      elsif tocnt = TO_CLKS - 1 then
        arm_r <= '0';                                                     -- no frame for TIMEOUT_MS -> overlay off
      else
        tocnt <= tocnt + 1;
      end if;
    end if;
  end process;
  arm  <= arm_r;
  dstr <= s;
end architecture;
