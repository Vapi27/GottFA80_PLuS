-- tb_ta_overlay.vhd : proves the strobe -> (segment group, character) map of
-- lib_common/ta_overlay.vhd.  The load-bearing check is sel="000": the module must
-- touch ONLY segment group A and ONLY during strobes 6..12 (the player-2 window),
-- leaving every other strobe -- i.e. the whole player-1 score and the status
-- display -- to the game ROM.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_ta_overlay is end tb_ta_overlay;

architecture sim of tb_ta_overlay is
  signal clk    : std_logic := '0';
  signal strobe : std_logic_vector(3 downto 0) := (others => '0');
  signal sel    : std_logic_vector(2 downto 0) := "000";
  signal dstr   : string(1 to 7) := "1234567";
  signal hit_a, hit_b, hit_c : std_logic;
  signal seg    : std_logic_vector(1 to 8);
  signal done   : boolean := false;

  -- reference copy of the SN7448_GTB table (independent of the DUT)
  function glyph(c : character) return std_logic_vector is
  begin
    case c is
      when '0' => return "11111100";
      when '1' => return "01100000";
      when '2' => return "11011010";
      when '3' => return "11110010";
      when '4' => return "01100110";
      when '5' => return "10110110";
      when '6' => return "00111110";
      when '7' => return "11100000";
      when '8' => return "11111110";
      when '9' => return "11100110";
      when others => return "00000000";
    end case;
  end function;
begin
  clk <= not clk after 10 ns when not done else '0';

  UUT : entity work.ta_overlay
    port map ( clk => clk, strobe => strobe, sel => sel, dstr => dstr,
               hit_a => hit_a, hit_b => hit_b, hit_c => hit_c, seg => seg );

  STIM : process
    type idx_t is array (0 to 15) of integer;
    -- expected character index per strobe (0 = module must not touch this strobe)
    constant EXP_H : idx_t := (0,0,0,0,0,0, 7,6,5,4,3,2,1, 0,0,0);  -- player 2 / player 4
    constant EXP_L : idx_t := (7,6,5,4,3,2, 0,0,0,0,0,0,0, 0,0,1);  -- player 1 / player 3
    constant EXP_S : idx_t := (0,0,0,0,0,0, 0,0,0,0,0,0, 4,5,6,7);  -- status window
    variable e      : integer;
    variable hits   : integer;
    variable errors : integer := 0;
    variable selv   : std_logic_vector(2 downto 0);
  begin
    report "== ta_overlay strobe map ==";
    for sv in 0 to 6 loop
      selv := std_logic_vector(to_unsigned(sv, 3));
      sel  <= selv;
      for s in 0 to 15 loop
        strobe <= std_logic_vector(to_unsigned(s, 4));
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        wait for 1 ns;

        case sv is
          when 0 | 2  => e := EXP_H(s);
          when 1 | 3  => e := EXP_L(s);
          when others => e := EXP_S(s);
        end case;

        hits := 0;
        if hit_a = '1' then hits := hits + 1; end if;
        if hit_b = '1' then hits := hits + 1; end if;
        if hit_c = '1' then hits := hits + 1; end if;

        if e = 0 then
          if hits /= 0 then
            report "FAIL sel=" & integer'image(sv) & " strobe=" & integer'image(s)
                   & " : expected NO override" severity error;
            errors := errors + 1;
          end if;
        else
          if hits /= 1 then
            report "FAIL sel=" & integer'image(sv) & " strobe=" & integer'image(s)
                   & " : expected exactly one group, got " & integer'image(hits) severity error;
            errors := errors + 1;
          end if;
          case sv is
            when 0 | 1 | 5 =>
              if hit_a /= '1' then
                report "FAIL sel=" & integer'image(sv) & " strobe=" & integer'image(s)
                       & " : group A expected" severity error;
                errors := errors + 1;
              end if;
            when 2 | 3 | 6 =>
              if hit_b /= '1' then
                report "FAIL sel=" & integer'image(sv) & " strobe=" & integer'image(s)
                       & " : group B expected" severity error;
                errors := errors + 1;
              end if;
            when others =>
              if hit_c /= '1' then
                report "FAIL sel=" & integer'image(sv) & " strobe=" & integer'image(s)
                       & " : group C expected" severity error;
                errors := errors + 1;
              end if;
          end case;
          if seg /= glyph(dstr(e)) then
            report "FAIL sel=" & integer'image(sv) & " strobe=" & integer'image(s)
                   & " : wrong glyph, expected char index " & integer'image(e)
                   & " = " & dstr(e) severity error;
            errors := errors + 1;
          end if;
        end if;
      end loop;
      report "sel=" & integer'image(sv) & " swept, running error count " & integer'image(errors);
    end loop;

    assert errors = 0
      report "== ta_overlay: " & integer'image(errors) & " FAILURES ==" severity failure;
    report "== ta_overlay: ALL CHECKS PASSED ==" severity note;
    done <= true;
    wait;
  end process;
end sim;
