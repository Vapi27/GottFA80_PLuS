-- tb_bin_to_bcd.vhd : self-checking testbench for bin_to_bcd.
--   ghdl -a lib_common/bin_to_bcd.vhd sim/tb_bin_to_bcd.vhd
--   ghdl -e tb_bin_to_bcd && ghdl -r tb_bin_to_bcd
-- Expect: "===== BIN_TO_BCD TESTS PASSED ====="
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_bin_to_bcd is end tb_bin_to_bcd;

architecture sim of tb_bin_to_bcd is
  signal bin : unsigned(23 downto 0) := (others => '0');
  signal bcd : std_logic_vector(27 downto 0);
begin
  DUT : entity work.bin_to_bcd
    generic map ( IN_W => 24, DIGITS => 7 )
    port map ( bin => bin, bcd => bcd );

  stim : process
    procedure chk(v : integer) is
      variable dig, exp : integer;
    begin
      bin <= to_unsigned(v, 24); wait for 1 ns;
      for k in 0 to 6 loop                                  -- compare each BCD digit to v's digit
        dig := to_integer(unsigned(bcd(k*4+3 downto k*4)));
        exp := (v / (10**k)) mod 10;
        assert dig = exp
          report "FAIL " & integer'image(v) & " digit" & integer'image(k) &
                 " got" & integer'image(dig) & " exp" & integer'image(exp) severity failure;
      end loop;
      report "ok " & integer'image(v);
    end procedure;
  begin
    chk(0);
    chk(7);
    chk(42);
    chk(990000);      -- time-attack: 1M - 10K
    chk(1000000);     -- time-attack start
    chk(1234567);
    chk(9999999);     -- all 9s
    report "===== BIN_TO_BCD TESTS PASSED =====";
    wait;
  end process;
end architecture;
