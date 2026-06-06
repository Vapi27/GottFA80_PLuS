-- lisyctrl.vhd : LISYcontrol-style diagnostic bridge for GottFA80
-- part of GottFA80 (https://github.com/bontango/GottFA80)
--
-- This is free software: you can redistribute it and/or modify it under the
-- terms of the GNU General Public License as published by the Free Software
-- Foundation, either version 3 of the License, or (at your option) any later
-- version. Distributed WITHOUT ANY WARRANTY; see the GNU GPL v3 for details.
--
-- When `active='1'` (lisyctrl mode, 6502 held in reset by the top level), an
-- external SPI master (ESP32) owns the machine I/O through a small register
-- file: it scans the switch matrix, pulses solenoids (gts80 encoding, with a
-- comms watchdog), holds the lamp state (matrix refresh), and drives displays.
-- Outputs are in RIOT-register semantics (U6_pa_out / U6_pb_out / U4_PB strobes)
-- so the SYS80 top level can reuse its EXISTING pin conditioning for both the
-- CPU path and lisyctrl (see LISYCTRL.md) -> no polarity guessing.
--
-- Register map (2-byte SPI frames, see spi_slave.vhd):
--   R 0x00 ID(0x80)  R 0x01 VER(0x01)  R 0x02 STATUS{b0 active,b1 wd,b2 is80B}
--   W 0x03 CTRL{b0 outputs_en, b1 lamp_blink}
--   RW 0x04 CTRL2{b0 tournament_mode} (persists into gameplay)
--   RW 0x05..0x07 TA_START (24-bit LMH, time-attack start points)  RW 0x08..0x0A TA_DECAY (24-bit LMH, pts/sec)
--       0x04..0x0A persist past diag exit (not cleared on active=0) so the on-display countdown survives into the game
--   R 0x10..0x17 SW_ROW[strobe] (bit=return, 1=closed)   R 0x18 DIP/slam
--   W 0x20..0x25 LAMP[0..5] (48 bits)
--   W 0x30 COIL (write coil# 1..9 -> pulse)   W 0x31 PULSE_MS
--   R 0x32 COIL_FAULT {b0 pulse-clamped,b1 refire-blocked,b2 wd-with-coil; b7..4 coil#}; W clears
--   W 0x40..0x42 SEG_A/B/C (display segments)  W 0x43 U5 {b3..0 strobes, b7 sw_enable}
--   W 0x44 SOUND (write System 80 sound code 0..31 -> play via gosof80)

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity lisyctrl is
  generic (
    clk_hz        : integer := 50000000;
    wd_timeout_ms : integer := 120;        -- coil/output comms watchdog
    gap_clocks    : integer := 64;         -- SPI frame gap (passed to spi_slave)
    scan_div      : integer := 5000;       -- clk cycles per switch strobe (~100us)
    max_pulse_ms  : integer := 150;        -- hard ceiling on a coil pulse (thermal guard)
    refire_ms     : integer := 40;         -- min off-time between coil fires (anti machine-gun)
    sound_hold_ms : integer := 60          -- ms to hold the sound trigger high (level send)
  );
  port (
    clk        : in  std_logic;
    active     : in  std_logic;
    -- SPI slave (the top routes the shared bus here when active)
    sclk       : in  std_logic;
    mosi       : in  std_logic;
    miso       : out std_logic;
    -- machine I/O in RIOT-register semantics (top reuses its conditioning)
    o_U4_PB    : out std_logic_vector(7 downto 0);   -- switch strobes (scan)
    i_U4_PA    : in  std_logic_vector(7 downto 0);   -- switch returns
    o_U5_PA    : out std_logic_vector(3 downto 0);   -- display digit strobes
    o_U5_PB7   : out std_logic;                      -- switch enable
    o_U6_PA    : out std_logic_vector(7 downto 0);   -- solenoids + sound
    o_U6_PB    : out std_logic_vector(7 downto 0);   -- lamps (4 data + 4 strobe)
    o_segments : out std_logic_vector(1 to 24);      -- display segments
    o_sound      : out std_logic_vector(4 downto 0); -- System 80 sound code 0..31 -> gosof80
    o_sound_trig : out std_logic;                    -- level: high triggers a sound send
    o_tournament : out std_logic;                    -- CTRL2 (0x04) b0: tournament mode (persists into gameplay)
    o_ta_start   : out std_logic_vector(23 downto 0); -- TA_START (0x05..0x07): time-attack start points (persists)
    o_ta_decay   : out std_logic_vector(23 downto 0); -- TA_DECAY (0x08..0x0A): time-attack decay/sec (persists)
    i_DIP_Ret  : in  std_logic_vector(4 downto 0);
    i_slam     : in  std_logic;
    wd_tripped : out std_logic
  );
end lisyctrl;

architecture rtl of lisyctrl is

  type t_bytes is array (natural range <>) of std_logic_vector(7 downto 0);

  -- SPI slave wires
  signal rx_byte  : std_logic_vector(7 downto 0);
  signal rx_valid : std_logic;
  signal rx_first : std_logic;
  signal tx_byte  : std_logic_vector(7 downto 0);
  signal reg_rd   : std_logic_vector(7 downto 0) := x"00";

  -- command decode
  signal cmd_rw   : std_logic := '0';
  signal cmd_addr : unsigned(6 downto 0) := (others => '0');
  signal cmd_seen : std_logic := '0';

  -- register file
  signal ctrl     : std_logic_vector(7 downto 0) := x"00";  -- b0 outputs_en, b1 blink
  signal tourney_reg : std_logic_vector(7 downto 0) := x"00";  -- CTRL2 0x04 b0 tournament_mode (persists)
  -- time-attack config (persists into gameplay, defaults = the tourney_countdown generics: 1,000,000 / 10,000)
  signal ta_start_reg : std_logic_vector(23 downto 0) := x"0F4240";  -- TA_START 0x05..0x07 = 1,000,000
  signal ta_decay_reg : std_logic_vector(23 downto 0) := x"002710";  -- TA_DECAY 0x08..0x0A = 10,000
  signal pulse_ms : std_logic_vector(7 downto 0) := x"3C";  -- default 60 ms
  signal lamp_b   : t_bytes(0 to 5) := (others => (others => '0'));
  signal seg_b    : t_bytes(0 to 2) := (others => (others => '0'));
  signal u5_reg   : std_logic_vector(7 downto 0) := x"00";
  signal sw_row   : t_bytes(0 to 7) := (others => (others => '0'));

  alias  outputs_en : std_logic is ctrl(0);
  alias  lamp_blink : std_logic is ctrl(1);

  -- timing
  constant MS_MAX : integer := clk_hz/1000 - 1;
  constant WD_MAX : integer := wd_timeout_ms;          -- counted in ms ticks
  signal ms_div   : integer range 0 to MS_MAX := MS_MAX;

  -- coil pulse + protection
  signal coil_n     : integer range 0 to 15 := 0;
  signal pulse_left : integer range 0 to 255 := 0;
  signal refire_cnt : integer range 0 to refire_ms := 0;      -- cooldown after a pulse
  signal coil_fault : std_logic_vector(7 downto 0) := x"00";  -- b0 clamp,b1 refire,b2 wd; b7..4 coil#

  -- sound (System 80 5-bit code -> gosof80, level-triggered)
  signal snd_code   : std_logic_vector(4 downto 0) := "00000";
  signal snd_hold   : integer range 0 to sound_hold_ms := 0;  -- ms left holding the trigger high

  -- watchdog
  signal wd_cnt  : integer range 0 to 65535 := WD_MAX;
  signal wd_trip : std_logic := '0';

  -- switch scan
  signal scan_strobe : integer range 0 to 7 := 0;
  signal scan_cnt    : integer range 0 to scan_div := scan_div;

  -- lamp refresh
  signal lamp_grp  : integer range 0 to 11 := 0;
  signal lamp_cnt  : integer range 0 to 1023 := 0;
  signal blink_div : integer range 0 to clk_hz := 0;
  signal blink_ph  : std_logic := '1';

  -- gts80 solenoid encode: returns the U6_pa_out "data" byte the game ROM would
  -- write to fire solenoid n (1..9). 0x00 = all drivers off (SAFE, enables clear).
  -- Correct by construction: it mimics the ROM, and the top reuses the same path.
  function f_coil(n : integer) return std_logic_vector is
  begin
    if    n >= 1 and n <= 4 then return std_logic_vector(to_unsigned(16#20# + (n-1),    8));
    elsif n >= 5 and n <= 8 then return std_logic_vector(to_unsigned(16#40# + (n-5)*4,  8));
    elsif n = 9             then return x"80";
    else                         return x"00";
    end if;
  end function;

begin

  ----------------------------------------------------------------------------
  SPI : entity work.spi_slave
    generic map ( gap_clocks => gap_clocks )
    port map (
      clk => clk, enable => active, sclk => sclk, mosi => mosi, miso => miso,
      rx_byte => rx_byte, rx_valid => rx_valid, rx_first => rx_first, tx_byte => tx_byte
    );

  -- response byte for reads (byte1 of a read frame), else the ID magic
  tx_byte <= reg_rd when (cmd_seen = '1' and cmd_rw = '0') else x"80";

  ----------------------------------------------------------------------------
  -- registers, command decode, ms tick, coil pulse, watchdog
  ----------------------------------------------------------------------------
  P_REGS : process
    variable a : integer;
    variable ms_now : boolean;
  begin
    wait until rising_edge(clk);
    ms_now := false;

    if active = '0' then
      cmd_seen <= '0'; coil_n <= 0; pulse_left <= 0;
      wd_cnt <= WD_MAX; wd_trip <= '0';
      refire_cnt <= 0; snd_hold <= 0; coil_fault <= x"00";
    else
      -- 1 ms time base
      if ms_div = 0 then ms_div <= MS_MAX; ms_now := true;
      else ms_div <= ms_div - 1; end if;

      -- SPI command / data
      if rx_valid = '1' then
        wd_cnt <= WD_MAX; wd_trip <= '0';           -- any traffic pets the watchdog
        if rx_first = '1' then
          cmd_rw   <= rx_byte(7);
          cmd_addr <= unsigned(rx_byte(6 downto 0));
          cmd_seen <= '1';
        elsif cmd_rw = '1' then                      -- data byte of a write
          a := to_integer(cmd_addr);
          case a is
            when 16#03# => ctrl     <= rx_byte;
            when 16#04# => tourney_reg <= rx_byte;     -- CTRL2: b0 tournament_mode (persists into gameplay)
            when 16#05# => ta_start_reg( 7 downto  0) <= rx_byte;   -- TA_START low
            when 16#06# => ta_start_reg(15 downto  8) <= rx_byte;   -- TA_START mid
            when 16#07# => ta_start_reg(23 downto 16) <= rx_byte;   -- TA_START high
            when 16#08# => ta_decay_reg( 7 downto  0) <= rx_byte;   -- TA_DECAY low
            when 16#09# => ta_decay_reg(15 downto  8) <= rx_byte;   -- TA_DECAY mid
            when 16#0A# => ta_decay_reg(23 downto 16) <= rx_byte;   -- TA_DECAY high
            when 16#31# => pulse_ms <= rx_byte;
            when 16#30# =>                            -- fire a coil (guarded)
              if to_integer(unsigned(rx_byte)) = 0 then
                coil_n <= 0; pulse_left <= 0;          -- explicit off
              elsif refire_cnt /= 0 then
                coil_fault <= rx_byte(3 downto 0) & "0010";   -- b1: re-fire blocked (cooldown)
              else
                coil_n <= to_integer(unsigned(rx_byte));
                if to_integer(unsigned(pulse_ms)) > max_pulse_ms then
                  pulse_left <= max_pulse_ms;
                  coil_fault <= rx_byte(3 downto 0) & "0001";  -- b0: pulse clamped to max
                else
                  pulse_left <= to_integer(unsigned(pulse_ms));
                end if;
              end if;
            when 16#32# => coil_fault <= x"00";        -- write clears coil-fault flags
            when 16#44# => snd_code <= rx_byte(4 downto 0); snd_hold <= sound_hold_ms;  -- play sound
            when 16#20# to 16#25# => lamp_b(a - 16#20#) <= rx_byte;
            when 16#40# to 16#42# => seg_b (a - 16#40#) <= rx_byte;
            when 16#43# => u5_reg <= rx_byte;
            when others => null;
          end case;
        end if;
      end if;

      -- coil pulse timer + cooldown + sound-hold + watchdog (per ms)
      if ms_now then
        if refire_cnt > 0 then refire_cnt <= refire_cnt - 1; end if;
        if snd_hold   > 0 then snd_hold   <= snd_hold   - 1; end if;
        if pulse_left > 0 then
          pulse_left <= pulse_left - 1;
          if pulse_left = 1 then coil_n <= 0; refire_cnt <= refire_ms; end if;  -- arm cooldown
        end if;
        if outputs_en = '1' then
          if wd_cnt > 0 then wd_cnt <= wd_cnt - 1;
          else
            wd_trip <= '1';
            if coil_n /= 0 then coil_fault <= std_logic_vector(to_unsigned(coil_n, 4)) & "0100"; end if;
            coil_n <= 0; pulse_left <= 0;
          end if;
        end if;
      end if;
    end if;
  end process;

  ----------------------------------------------------------------------------
  -- switch matrix scan: drive one strobe high, settle, latch the returns
  ----------------------------------------------------------------------------
  P_SCAN : process
  begin
    wait until rising_edge(clk);
    if active = '1' then
      if scan_cnt = 0 then
        sw_row(scan_strobe) <= i_U4_PA;        -- 1 = closed (strobe high + return high)
        if scan_strobe = 7 then scan_strobe <= 0; else scan_strobe <= scan_strobe + 1; end if;
        scan_cnt <= scan_div;
      else
        scan_cnt <= scan_cnt - 1;
      end if;
    end if;
  end process;

  o_U4_PB <= std_logic_vector(shift_left(to_unsigned(1, 8), scan_strobe)) when active = '1'
             else (others => '0');

  ----------------------------------------------------------------------------
  -- lamp matrix refresh (cycle 12 groups of 4). NOTE: the group->latch (DS)
  -- addressing below is a best-effort and MUST be confirmed against the SYS80
  -- lamp decoders (IC11/IC13) + SN74175 chain before relying on lamp positions.
  ----------------------------------------------------------------------------
  P_LAMP : process
    variable nib : std_logic_vector(3 downto 0);
    variable byte_idx : integer;
  begin
    wait until rising_edge(clk);
    -- ~2 Hz blink phase
    if blink_div = 0 then blink_div <= clk_hz/4; blink_ph <= not blink_ph;
    else blink_div <= blink_div - 1; end if;

    if active = '1' then
      byte_idx := lamp_grp / 2;
      if (lamp_grp mod 2) = 0 then nib := lamp_b(byte_idx)(3 downto 0);
      else                         nib := lamp_b(byte_idx)(7 downto 4); end if;
      -- gate: lamps off when outputs disabled or blink-off phase
      if outputs_en = '0' or (lamp_blink = '1' and blink_ph = '0') then nib := "0000"; end if;
      -- drive: data nibble + group address + strobe enable (pulsed via lamp_cnt)
      o_U6_PB(3 downto 0) <= nib;
      o_U6_PB(6 downto 4) <= std_logic_vector(to_unsigned(lamp_grp mod 8, 3));
      if lamp_cnt < 4 then o_U6_PB(7) <= '1'; else o_U6_PB(7) <= '0'; end if;
      if lamp_cnt = 0 then
        if lamp_grp = 11 then lamp_grp <= 0; else lamp_grp <= lamp_grp + 1; end if;
        lamp_cnt <= 16;
      else
        lamp_cnt <= lamp_cnt - 1;
      end if;
    else
      o_U6_PB <= (others => '0');
    end if;
  end process;

  ----------------------------------------------------------------------------
  -- read-back mux
  ----------------------------------------------------------------------------
  P_RD : process (cmd_addr, ctrl, active, wd_trip, sw_row, i_DIP_Ret, i_slam, pulse_ms,
                  lamp_b, coil_fault, tourney_reg, ta_start_reg, ta_decay_reg)
    variable a : integer;
  begin
    a := to_integer(cmd_addr);
    case a is
      when 16#00# => reg_rd <= x"80";
      when 16#01# => reg_rd <= x"01";
      when 16#02# => reg_rd <= "00000" & '0' & wd_trip & active;   -- b2 is80B (TODO)
      when 16#03# => reg_rd <= ctrl;
      when 16#04# => reg_rd <= tourney_reg;
      when 16#05# => reg_rd <= ta_start_reg( 7 downto  0);
      when 16#06# => reg_rd <= ta_start_reg(15 downto  8);
      when 16#07# => reg_rd <= ta_start_reg(23 downto 16);
      when 16#08# => reg_rd <= ta_decay_reg( 7 downto  0);
      when 16#09# => reg_rd <= ta_decay_reg(15 downto  8);
      when 16#0A# => reg_rd <= ta_decay_reg(23 downto 16);
      when 16#10# to 16#17# => reg_rd <= sw_row(a - 16#10#);
      when 16#18# => reg_rd <= "00" & i_slam & i_DIP_Ret;
      when 16#20# to 16#25# => reg_rd <= lamp_b(a - 16#20#);
      when 16#31# => reg_rd <= pulse_ms;
      when 16#32# => reg_rd <= coil_fault;
      when others => reg_rd <= x"00";
    end case;
  end process;

  ----------------------------------------------------------------------------
  -- solenoid output (gts80 data) — gated + watchdog; 0x00 = SAFE (enables off)
  ----------------------------------------------------------------------------
  o_U6_PA <= f_coil(coil_n) when (outputs_en = '1' and wd_trip = '0' and coil_n /= 0)
             else x"00";

  -- display + U5 passthrough
  o_segments(1 to 8)   <= seg_b(0);
  o_segments(9 to 16)  <= seg_b(1);
  o_segments(17 to 24) <= seg_b(2);
  o_U5_PA   <= u5_reg(3 downto 0);
  o_U5_PB7  <= u5_reg(7);

  -- sound: present the code + a level trigger (held sound_hold_ms) -> gosof80
  o_sound      <= snd_code;
  o_sound_trig <= '1' when snd_hold > 0 else '0';
  o_tournament <= tourney_reg(0);                    -- persists past diag exit (not reset on active=0)
  o_ta_start   <= ta_start_reg;                      -- time-attack start points (persists into gameplay)
  o_ta_decay   <= ta_decay_reg;                      -- time-attack decay/sec (persists into gameplay)

  wd_tripped <= wd_trip;

end rtl;
