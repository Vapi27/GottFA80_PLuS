-- ay_3_8910.vhd : AY-3-8910 / AY-3-8912 (YM2149-family) PSG core
-- part of GottFA80 (https://github.com/bontango/GottFA80)
--
-- This is free software: you can redistribute it and/or modify it under the
-- terms of the GNU General Public License as published by the Free Software
-- Foundation, either version 3 of the License, or (at your option) any later
-- version. Distributed WITHOUT ANY WARRANTY; see the GNU GPL v3 for details.
--
-- The "Programmable Sound Generator" used (x2) on the late Gottlieb System 80B
-- and System 3 sound boards. 3 square-wave tone channels + 1 noise generator +
-- 1 envelope generator + per-channel mixer and 4-bit log amplitude DAC.
--
-- Register interface: the board glue decodes the AY BDIR/BC1 bus into a simple
-- {addr, din, wr} latch (addr = R0..R15). dout reads the register file back.
-- `ce` is the AY master clock-enable (e.g. ~1.79 MHz tick from the system clk);
-- the /16 tone prescaler and /256 envelope prescaler are internal. Audio is the
-- summed unsigned level of the 3 channels (feed dac.vhd or a sigma-delta).
--
-- Registers:
--   R0/R1  ch A tone period (12-bit: R1[3:0]:R0)      R6  noise period (5-bit)
--   R2/R3  ch B tone period                            R7  mixer (b0-2 tone dis A/B/C,
--   R4/R5  ch C tone period                                 b3-5 noise dis A/B/C; active high)
--   R8/9/10 ch A/B/C amplitude (b3-0 level, b4 = use envelope)
--   R11/R12 envelope period (16-bit)   R13 envelope shape (b3 cont,b2 att,b1 alt,b0 hold)
--   R14/R15 I/O ports (not used here)

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity ay_3_8910 is
  port (
    clk   : in  std_logic;                          -- system clock
    ce    : in  std_logic;                          -- AY master clock enable (1 = tick)
    rst_n : in  std_logic;                          -- async reset, active low
    -- CPU register interface (board decodes BDIR/BC1 -> these)
    addr  : in  std_logic_vector(3 downto 0);
    din   : in  std_logic_vector(7 downto 0);
    dout  : out std_logic_vector(7 downto 0);
    wr    : in  std_logic;                           -- 1-clk write strobe
    -- audio
    ch_a  : out std_logic_vector(7 downto 0);
    ch_b  : out std_logic_vector(7 downto 0);
    ch_c  : out std_logic_vector(7 downto 0);
    audio : out std_logic_vector(9 downto 0)         -- sum of the 3 channels (0..765)
  );
end ay_3_8910;

architecture rtl of ay_3_8910 is

  type t_regs is array (0 to 15) of std_logic_vector(7 downto 0);
  signal regs : t_regs := (others => (others => '0'));

  -- 16-level logarithmic amplitude DAC (~3 dB/step), normalised to 0..255
  type t_vol is array (0 to 15) of unsigned(7 downto 0);
  constant VOL : t_vol := (
    to_unsigned(0,8),   to_unsigned(1,8),   to_unsigned(2,8),   to_unsigned(3,8),
    to_unsigned(5,8),   to_unsigned(7,8),   to_unsigned(11,8),  to_unsigned(15,8),
    to_unsigned(22,8),  to_unsigned(31,8),  to_unsigned(45,8),  to_unsigned(63,8),
    to_unsigned(90,8),  to_unsigned(127,8), to_unsigned(180,8), to_unsigned(255,8) );

  -- prescaler: tone/noise tick every 16 ce, envelope tick every 256 ce
  signal presc : unsigned(7 downto 0) := (others => '0');

  -- tone generators
  signal tcnt_a, tcnt_b, tcnt_c : unsigned(11 downto 0) := (others => '0');
  signal tone_a, tone_b, tone_c : std_logic := '0';

  -- noise generator
  signal ncnt : unsigned(4 downto 0) := (others => '0');
  signal lfsr : std_logic_vector(16 downto 0) := (others => '1');

  -- envelope generator
  signal ecnt    : unsigned(15 downto 0) := (others => '0');
  signal env_vol : integer range 0 to 15 := 0;
  signal env_inc : integer range -1 to 1 := -1;
  signal env_hold: std_logic := '0';

  -- channel DAC levels (internal so they can also feed the summed audio)
  signal dac_a, dac_b, dac_c : unsigned(7 downto 0) := (others => '0');

  -- helpers
  function tperiod(hi, lo : std_logic_vector(7 downto 0)) return unsigned is
  begin
    return unsigned(hi(3 downto 0)) & unsigned(lo);   -- 12-bit, unsigned concat (no t_regs '&' clash)
  end function;

begin

  ----------------------------------------------------------------------------
  -- register file + tone / noise / envelope generation
  ----------------------------------------------------------------------------
  process(clk, rst_n)
    variable shp : std_logic_vector(3 downto 0);
  begin
    if rst_n = '0' then
      regs    <= (others => (others => '0'));
      presc   <= (others => '0');
      tcnt_a  <= (others => '0'); tcnt_b <= (others => '0'); tcnt_c <= (others => '0');
      tone_a  <= '0'; tone_b <= '0'; tone_c <= '0';
      ncnt    <= (others => '0'); lfsr <= (others => '1');
      ecnt    <= (others => '0'); env_vol <= 0; env_inc <= -1; env_hold <= '0';
    elsif rising_edge(clk) then

      -- CPU register write
      if wr = '1' then
        regs(to_integer(unsigned(addr))) <= din;
        if addr = "1101" then                       -- R13: writing the shape re-triggers
          if din(2) = '1' then env_vol <= 0;  env_inc <= 1;   -- attack -> start low, rising
          else                 env_vol <= 15; env_inc <= -1;  -- start high, falling
          end if;
          env_hold <= '0';
          ecnt     <= (others => '0');
        end if;
      end if;

      if ce = '1' then
        presc <= presc + 1;

        -- tone + noise: every 16 ce
        if presc(3 downto 0) = "1111" then
          -- channel A
          if tcnt_a >= tperiod(regs(1), regs(0)) then
            tcnt_a <= (others => '0'); tone_a <= not tone_a;
          else tcnt_a <= tcnt_a + 1; end if;
          -- channel B
          if tcnt_b >= tperiod(regs(3), regs(2)) then
            tcnt_b <= (others => '0'); tone_b <= not tone_b;
          else tcnt_b <= tcnt_b + 1; end if;
          -- channel C
          if tcnt_c >= tperiod(regs(5), regs(4)) then
            tcnt_c <= (others => '0'); tone_c <= not tone_c;
          else tcnt_c <= tcnt_c + 1; end if;
          -- noise (17-bit LFSR, taps 0 and 3)
          if ncnt >= unsigned(regs(6)(4 downto 0)) then
            ncnt <= (others => '0');
            lfsr <= (lfsr(0) xor lfsr(3)) & lfsr(16 downto 1);
          else ncnt <= ncnt + 1; end if;
        end if;

        -- envelope: every 256 ce
        if presc = "11111111" then
          shp := regs(13)(3 downto 0);
          if env_hold = '0' then
            if env_inc = 1 and env_vol = 15 then
              -- rising ramp finished
              if    shp(3) = '0' then env_vol <= 0;  env_hold <= '1';          -- shapes 0-7: one shot -> 0
              elsif shp(0) = '1' then                                          -- hold
                if shp(1) = '1' then env_vol <= 0;  else env_vol <= 15; end if;
                env_hold <= '1';
              elsif shp(1) = '1' then env_inc <= -1; env_vol <= 15;            -- alternate -> reflect
              else                    env_vol <= 0;                            -- saw -> restart low
              end if;
            elsif env_inc = -1 and env_vol = 0 then
              -- falling ramp finished
              if    shp(3) = '0' then env_vol <= 0;  env_hold <= '1';
              elsif shp(0) = '1' then
                if shp(1) = '1' then env_vol <= 15; else env_vol <= 0;  end if;
                env_hold <= '1';
              elsif shp(1) = '1' then env_inc <= 1;  env_vol <= 0;             -- alternate -> reflect
              else                    env_vol <= 15;                           -- saw -> restart high
              end if;
            else
              env_vol <= env_vol + env_inc;
            end if;
          end if;
        end if;
      end if;
    end if;
  end process;

  dout <= regs(to_integer(unsigned(addr)));

  ----------------------------------------------------------------------------
  -- mixer + amplitude DAC (combinational)
  --   channel passes when (tone OR tone-disabled) AND (noise OR noise-disabled)
  --   level = envelope (R8/9/10 b4=1) else fixed 4-bit
  ----------------------------------------------------------------------------
  P_MIX : process(regs, tone_a, tone_b, tone_c, lfsr, env_vol)
    variable na : std_logic;
    variable la, lb, lc : integer range 0 to 15;
  begin
    na := lfsr(0);
    if regs(8)(4)  = '1' then la := env_vol; else la := to_integer(unsigned(regs(8)(3 downto 0)));  end if;
    if regs(9)(4)  = '1' then lb := env_vol; else lb := to_integer(unsigned(regs(9)(3 downto 0)));  end if;
    if regs(10)(4) = '1' then lc := env_vol; else lc := to_integer(unsigned(regs(10)(3 downto 0))); end if;

    if (tone_a or regs(7)(0)) = '1' and (na or regs(7)(3)) = '1' then dac_a <= VOL(la); else dac_a <= (others => '0'); end if;
    if (tone_b or regs(7)(1)) = '1' and (na or regs(7)(4)) = '1' then dac_b <= VOL(lb); else dac_b <= (others => '0'); end if;
    if (tone_c or regs(7)(2)) = '1' and (na or regs(7)(5)) = '1' then dac_c <= VOL(lc); else dac_c <= (others => '0'); end if;
  end process;

  ch_a  <= std_logic_vector(dac_a);
  ch_b  <= std_logic_vector(dac_b);
  ch_c  <= std_logic_vector(dac_c);
  audio <= std_logic_vector(resize(dac_a, 10) + resize(dac_b, 10) + resize(dac_c, 10));

end rtl;
