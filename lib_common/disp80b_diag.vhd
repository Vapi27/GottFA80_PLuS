-- disp80b_diag.vhd — 80B alphanumeric display writer for LISYcontrol diag mode.
--
-- In diag the 6502 is held, freezing the RIOT U5 lines that feed the display.
-- This FSM replays the ROM's exact byte choreography (Rockwell 10941-class row
-- controllers behind two 4-bit latches) at RIOT-register level, so the existing
-- CPU-board latch emulation (sn74175 pair + inverters -> segments_80B) is reused
-- unchanged. Protocol ground truth: LISY80 displays.c/lisy80.c, PinMAME gts80.c,
-- prom1.s L2A9B (cross-verified 2026-07-09; timings are the ROM's proven-safe
-- values — true 10941 minimums are unknown, do not go faster).
--
-- Per byte SEND(D, sel):  PB(3:0)=D low nibble, pulse PA4 (latch #1) ->
--   PB(3:0)=D high nibble, pulse PA5 (latch #2) -> pulse the selected LD
--   register bit(s) LOW (PB4=LD1=row1, PB5=LD2=row2, both=broadcast; the board
--   inverts, so register-low = physical strobe). Controllers read the LATCH
--   outputs, not PB. Frame = broadcast 0x01,0xC0 (both buffer pointers to 0)
--   then per column: row1 char via LD1, row2 char via LD2 (ROM-interleaved).
-- The display is initialised by the game at power-on and holds its own refresh;
-- we only stream frames (~10 Hz restream also picks up text changes).
-- (C) 2026 Valere Pilpil / Pstore. Original implementation.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity disp80b_diag is
  generic (
    tick_div : integer := 100          -- 2 us tick @ 50 MHz (all holds in ticks)
  );
  port (
    clk    : in  std_logic;
    active : in  std_logic;                       -- lisy_active (diag mode)
    txt    : in  std_logic_vector(319 downto 0);  -- 40 ASCII bytes: row1[0..19], row2[0..19]
    o_pa   : out std_logic_vector(5 downto 4);    -- U5_PA(4)=CK1, (5)=CK2 latch clocks
    o_pb   : out std_logic_vector(6 downto 0)     -- U5_PB: (3:0) nibble, (4) LD1, (5) LD2, (6) reset
  );
end disp80b_diag;

architecture rtl of disp80b_diag is
  type t_chars is array (0 to 39) of std_logic_vector(7 downto 0);
  signal chars : t_chars;

  type t_bstate is (B_NEXT, B_NIB_LO, B_CK1_HI, B_CK1_LO, B_NIB_HI,
                    B_CK2_HI, B_CK2_LO, B_LD_LO, B_LD_HI, B_GAP);
  signal bst      : t_bstate := B_NEXT;
  signal tick_cnt : integer range 0 to tick_div-1 := 0;
  signal hold     : integer range 0 to 63 := 0;       -- ticks left in the phase
  signal pause    : integer range 0 to 65535 := 0;    -- inter-frame pause (ticks)
  signal step     : integer range 0 to 41 := 0;       -- 0/1 = 0x01/0xC0, 2..41 = col bytes
  signal cur_b    : std_logic_vector(7 downto 0) := x"00";
  signal cur_sel  : std_logic_vector(5 downto 4) := "11";  -- LD bits during strobe (low = active)
  signal pa_r     : std_logic_vector(5 downto 4) := "00";
  signal pb_r     : std_logic_vector(6 downto 0) := "0110000";  -- idle 0x30: LDs high, no reset
begin
  GEN_UNPACK: for i in 0 to 39 generate
    chars(i) <= txt(8*i+7 downto 8*i);
  end generate GEN_UNPACK;

  o_pa <= pa_r;
  o_pb <= pb_r;

  process(clk)
    variable idx : integer range 0 to 39;
  begin
    if rising_edge(clk) then
      if active = '0' then                 -- CPU owns the display; park clean
        bst <= B_NEXT; step <= 0; pause <= 0; hold <= 0; tick_cnt <= 0;
        pa_r <= "00"; pb_r <= "0110000";
      elsif tick_cnt /= tick_div-1 then
        tick_cnt <= tick_cnt + 1;
      else                                 -- one protocol tick (2 us)
        tick_cnt <= 0;
        if hold /= 0 then
          hold <= hold - 1;
        else
          case bst is
            when B_NEXT =>
              if pause /= 0 then
                pause <= pause - 1;
              else
                if step = 0 then                       -- command escape, both rows
                  cur_b <= x"01"; cur_sel <= "00";
                elsif step = 1 then                    -- buffer pointer = 0, both rows
                  cur_b <= x"C0"; cur_sel <= "00";
                else
                  idx := (step - 2) / 2 + 20 * ((step - 2) mod 2);
                  cur_b <= chars(idx);
                  if ((step - 2) mod 2) = 0 then       -- row 1: LD1 low, LD2 high
                    cur_sel <= "10";
                  else                                 -- row 2: LD2 low, LD1 high
                    cur_sel <= "01";
                  end if;
                end if;
                bst <= B_NIB_LO;
              end if;
            when B_NIB_LO => pb_r(3 downto 0) <= cur_b(3 downto 0);
                             hold <= 1;  bst <= B_CK1_HI;   -- 4 us setup
            when B_CK1_HI => pa_r(4) <= '1'; hold <= 3; bst <= B_CK1_LO;  -- 8 us high
            when B_CK1_LO => pa_r(4) <= '0'; hold <= 2; bst <= B_NIB_HI;  -- 6 us gap
            when B_NIB_HI => pb_r(3 downto 0) <= cur_b(7 downto 4);
                             hold <= 1;  bst <= B_CK2_HI;
            when B_CK2_HI => pa_r(5) <= '1'; hold <= 3; bst <= B_CK2_LO;
            when B_CK2_LO => pa_r(5) <= '0'; hold <= 2; bst <= B_LD_LO;
            when B_LD_LO  => pb_r(5 downto 4) <= cur_sel;    -- strobe (ROM: PB3:0 low too)
                             pb_r(3 downto 0) <= "0000";
                             hold <= 5;  bst <= B_LD_HI;     -- 12 us low
            when B_LD_HI  => pb_r(5 downto 4) <= "11";
                             hold <= 55; bst <= B_GAP;       -- ~112 us inter-byte (ROM pace)
            when B_GAP =>
              if step = 41 then
                step <= 0; pause <= 50000;                   -- ~100 ms between frames
              else
                step <= step + 1;
              end if;
              bst <= B_NEXT;
          end case;
        end if;
      end if;
    end if;
  end process;
end rtl;
