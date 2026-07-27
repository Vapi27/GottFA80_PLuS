-- value_to_dispstr.vhd : binary value -> 7-char decimal string for the Gottlieb display.
--
-- The last RTL link to show the time-attack countdown on the pinball display: it reuses
-- bin_to_bcd, then renders the 7 digits as a string(1 to 7) (MSD..LSD = boot_message order),
-- BLANKING leading zeros to ' ' (keeping the last digit). Feed `dstr` to boot_message.vhd's
-- display input (e.g. display1) and activate boot_message during gameplay when time-attack
-- is armed -> the score is drawn live on the machine. (character handling matches the style
-- already synthesized by boot_message/sn7448_gtb.)
-- (C) 2026 Valere Pilpil / Pstore.  Part of GottFA80 (GPL-3.0).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity value_to_dispstr is
  generic ( IN_W : natural := 24 );
  port (
    value : in  unsigned(IN_W-1 downto 0);
    dstr  : out string(1 to 7)              -- dstr(1)=MSD ... dstr(7)=LSD
  );
end entity;

architecture rtl of value_to_dispstr is
  signal bcd : std_logic_vector(27 downto 0);
begin
  B2B : entity work.bin_to_bcd
    generic map ( IN_W => IN_W, DIGITS => 7 )
    port map ( bin => value, bcd => bcd );

  process (bcd)
    variable lead : boolean;
    variable nib  : integer;
  begin
    lead := true;
    for k in 6 downto 0 loop                              -- MSD (k=6) .. LSD (k=0)
      nib := to_integer(unsigned(bcd(k*4+3 downto k*4)));
      if nib /= 0 then lead := false; end if;
      if lead and k /= 0 then
        dstr(7 - k) <= ' ';                               -- blank leading zeros, keep last digit
      else
        dstr(7 - k) <= character'val(48 + nib);           -- '0'..'9'
      end if;
    end loop;
  end process;
end architecture;
