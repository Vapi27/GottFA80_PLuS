-- bin_to_bcd.vhd : binary -> packed BCD (double-dabble), combinational.
--
-- The missing data-path piece for showing a NUMBER on the pinball display from the FPGA:
--   tourney_countdown.value (binary) -> bin_to_bcd -> per-digit BCD -> SN7448 (the FPGA's
--   existing BCD->7seg) -> display multiplex (boot_message-style). So the time-attack score
--   can be drawn live on the machine. DIGITS nibbles, MSD = top nibble. Pure/synthesizable.
-- (C) 2026 Valere Pilpil / Pstore.  Part of GottFA80 (GPL-3.0).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity bin_to_bcd is
  generic (
    IN_W   : natural := 24;        -- input width (>= 24 covers up to 9,999,999)
    DIGITS : natural := 7          -- BCD digits out
  );
  port (
    bin : in  unsigned(IN_W-1 downto 0);
    bcd : out std_logic_vector(DIGITS*4-1 downto 0)   -- digit k = bcd(k*4+3 downto k*4), 0=LSD
  );
end entity;

architecture comb of bin_to_bcd is
begin
  process (bin)
    variable b : unsigned(IN_W-1 downto 0);
    variable d : unsigned(DIGITS*4-1 downto 0);
  begin
    d := (others => '0'); b := bin;
    for i in 0 to IN_W-1 loop                          -- shift bin in MSB-first
      for k in 0 to DIGITS-1 loop                      -- add 3 to any nibble >= 5
        if d(k*4+3 downto k*4) >= 5 then
          d(k*4+3 downto k*4) := d(k*4+3 downto k*4) + 3;
        end if;
      end loop;
      d := d(DIGITS*4-2 downto 0) & b(IN_W-1);         -- shift d left, bring in next bin bit
      b := b(IN_W-2 downto 0) & '0';
    end loop;
    bcd <= std_logic_vector(d);
  end process;
end architecture;
