-- tb_tourney_block.vhd : self-checking testbench for tourney_block.
--   ghdl -a lib_common/tourney_block.vhd sim/tb_tourney_block.vhd
--   ghdl -e tb_tourney_block && ghdl -r tb_tourney_block
-- Expect: "===== TOURNEY_BLOCK TESTS PASSED ====="
library ieee;
use ieee.std_logic_1164.all;

entity tb_tourney_block is end tb_tourney_block;

architecture sim of tb_tourney_block is
  signal pin, pout : std_logic_vector(7 downto 0) := (others => '0');
  signal sol_act, tmode : std_logic := '0';
begin
  -- block solenoid select "1001" (example knocker code), remap to no-op "1111"
  DUT : entity work.tourney_block
    generic map ( SEL_HI => 3, SEL_LO => 0, BLOCK_CODE => "1001", NOOP_CODE => "1111" )
    port map ( port_in => pin, sol_active => sol_act, tournament_mode => tmode, port_out => pout );

  stim : process
    procedure chk(msg : string; expect : std_logic_vector(7 downto 0)) is
    begin
      wait for 1 ns;
      assert pout = expect report "FAIL " & msg severity failure;
      report "ok " & msg;
    end procedure;
  begin
    -- 1) tournament OFF -> exact passthrough even when the blocked code is driven
    tmode <= '0'; sol_act <= '1'; pin <= "11101001";  -- select = 1001 (blocked code)
    chk("off=passthrough", "11101001");

    -- 2) tournament ON, solenoid cycle, blocked code -> select remapped to 1111 (suppressed)
    tmode <= '1'; sol_act <= '1'; pin <= "11101001";  -- upper bits 1110 kept, select 1001 -> 1111
    chk("on+sol+blocked=suppressed", "11101111");

    -- 3) tournament ON, solenoid cycle, a DIFFERENT solenoid (1000) -> passthrough (it must fire)
    tmode <= '1'; sol_act <= '1'; pin <= "11101000";
    chk("on+sol+other=passthrough", "11101000");

    -- 4) tournament ON, but a SOUND cycle (sol_active=0) with the same code -> passthrough
    tmode <= '1'; sol_act <= '0'; pin <= "11101001";
    chk("on+sound+samecode=passthrough", "11101001");

    -- 5) upper bits (decoder enable / Sol9) are never touched
    tmode <= '1'; sol_act <= '1'; pin <= "00001001";
    chk("upper-bits-preserved", "00001111");

    report "===== TOURNEY_BLOCK TESTS PASSED =====";
    wait;
  end process;
end architecture;
