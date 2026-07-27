-- tb_gts_family.vhd -- exhaustive check of the System 80/80A/80B family decode.
-- Walks all 64 game numbers and compares the package functions against the
-- reference ranges taken from PinMAME (see lib_common/gts_family.vhd header):
--   0..17 = System 80, 18..39 = System 80A, 40..62 = System 80B (63 unused),
--   has_7digit = 80A, late_80B = 56..61.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.gts_family.all;

entity tb_gts_family is end tb_gts_family;

architecture sim of tb_gts_family is
  signal errors : integer := 0;
begin
  process
    variable g   : std_logic_vector(5 downto 0);
    variable e80, e80a, e80b, e7, elate : std_logic;
    variable errs : integer := 0;
    -- reference model, written independently of the implementation
    function ref(n : integer; lo : integer; hi : integer) return std_logic is
    begin
      if n >= lo and n <= hi then return '1'; else return '0'; end if;
    end function;
  begin
    for n in 0 to 63 loop
      g := std_logic_vector(to_unsigned(n, 6));
      e80   := ref(n, 0, 17);
      e80a  := ref(n, 18, 39);
      e80b  := ref(n, 40, 63);   -- 63 is not a game; decoding it as 80B is harmless
      e7    := e80a;
      elate := ref(n, 56, 61);

      if f_is_80(g) /= e80 then
        report "is_80 wrong for game " & integer'image(n) severity error; errs := errs + 1;
      end if;
      if f_is_80A(g) /= e80a then
        report "is_80A wrong for game " & integer'image(n) severity error; errs := errs + 1;
      end if;
      if f_is_80B(g) /= e80b then
        report "is_80B wrong for game " & integer'image(n) severity error; errs := errs + 1;
      end if;
      if f_has_7digit(g) /= e7 then
        report "has_7digit wrong for game " & integer'image(n) severity error; errs := errs + 1;
      end if;
      if f_late_80B(g) /= elate then
        report "late_80B wrong for game " & integer'image(n) severity error; errs := errs + 1;
      end if;
      -- exactly one family must be true for every number
      if (f_is_80(g) xor f_is_80A(g) xor f_is_80B(g)) /= '1' then
        report "families not mutually exclusive for game " & integer'image(n) severity error;
        errs := errs + 1;
      end if;
      -- late_80B may only be claimed inside the 80B block
      if f_late_80B(g) = '1' and f_is_80B(g) = '0' then
        report "late_80B outside the 80B block for game " & integer'image(n) severity error;
        errs := errs + 1;
      end if;
    end loop;

    errors <= errs;
    wait for 1 ns;
    if errs = 0 then
      report "GTS_FAMILY TESTS PASSED (64/64 game numbers)" severity note;
    else
      report "GTS_FAMILY TESTS FAILED: " & integer'image(errs) & " mismatches" severity failure;
    end if;
    wait;
  end process;
end sim;
