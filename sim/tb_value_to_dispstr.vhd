-- tb_value_to_dispstr.vhd : self-checking testbench for value_to_dispstr.
--   ghdl -a lib_common/bin_to_bcd.vhd lib_common/value_to_dispstr.vhd sim/tb_value_to_dispstr.vhd
--   ghdl -e tb_value_to_dispstr && ghdl -r tb_value_to_dispstr
-- Expect: "===== VALUE_TO_DISPSTR TESTS PASSED ====="
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_value_to_dispstr is end tb_value_to_dispstr;

architecture sim of tb_value_to_dispstr is
  signal value : unsigned(23 downto 0) := (others => '0');
  signal dstr  : string(1 to 7);
begin
  DUT : entity work.value_to_dispstr
    generic map ( IN_W => 24 )
    port map ( value => value, dstr => dstr );

  stim : process
    procedure chk(v : integer; expect : string) is
    begin
      value <= to_unsigned(v, 24); wait for 1 ns;
      assert dstr = expect report "FAIL " & integer'image(v) & " got [" & dstr & "]" severity failure;
      report "ok " & integer'image(v) & " -> [" & dstr & "]";
    end procedure;
  begin
    chk(1000000, "1000000");      -- time-attack start
    chk(990000,  " 990000");      -- after 1s : leading zero blanked
    chk(10000,   "  10000");
    chk(0,       "      0");       -- all blank but the last 0
    chk(7,       "      7");
    chk(1234567, "1234567");
    report "===== VALUE_TO_DISPSTR TESTS PASSED =====";
    wait;
  end process;
end architecture;
