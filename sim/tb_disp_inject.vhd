-- tb_disp_inject.vhd : self-checking testbench for disp_inject (ESP->FPGA display UART).
--   ghdl -a lib_common/disp_inject.vhd sim/tb_disp_inject.vhd
--   ghdl -e tb_disp_inject && ghdl -r tb_disp_inject
-- Expect: "===== DISP_INJECT TESTS PASSED ====="
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_disp_inject is end tb_disp_inject;

architecture sim of tb_disp_inject is
  constant CP   : time := 10 ns;
  constant BITC : integer := 10;            -- BIT_CLKS in the DUT (CLK_HZ/BAUD = 10000/1000)
  signal clk  : std_logic := '0';
  signal rst  : std_logic := '1';
  signal rx   : std_logic := '1';           -- UART idle = high
  signal arm  : std_logic;
  signal dstr : string(1 to 7);
  signal done : boolean := false;
begin
  DUT : entity work.disp_inject
    generic map ( CLK_HZ => 10000, BAUD => 1000, TIMEOUT_MS => 200 )   -- TO_CLKS = 2000
    port map ( clk => clk, rst => rst, rx => rx, arm => arm, dstr => dstr );

  clk <= not clk after CP/2 when not done else '0';

  stim : process
    procedure ticks(n : integer) is
    begin for j in 1 to n loop wait until rising_edge(clk); end loop; end procedure;
    procedure send_byte(v : std_logic_vector(7 downto 0)) is
    begin
      rx <= '0'; ticks(BITC);                                  -- start bit
      for i in 0 to 7 loop rx <= v(i); ticks(BITC); end loop;  -- 8 data bits, LSB first
      rx <= '1'; ticks(BITC);                                  -- stop bit
    end procedure;
    procedure send_char(c : character) is
    begin send_byte(std_logic_vector(to_unsigned(character'pos(c), 8))); end procedure;
  begin
    rx <= '1';
    wait for 50 ns; wait until rising_edge(clk); rst <= '0';
    ticks(5);
    assert arm = '0' report "FAIL: arm should be 0 at idle" severity failure;

    -- frame 1: SYNC 0xFF + "1000000"
    send_byte(x"FF");
    send_char('1'); send_char('0'); send_char('0'); send_char('0');
    send_char('0'); send_char('0'); send_char('0');
    ticks(5);
    assert arm = '1' report "FAIL: arm should be 1 after a frame" severity failure;
    assert dstr = "1000000" report "FAIL: dstr=[" & dstr & "] expected 1000000" severity failure;
    report "ok frame -> arm=1 dstr=[" & dstr & "]";

    -- frame 2: updates the displayed value (leading blanks kept)
    send_byte(x"FF");
    send_char(' '); send_char(' '); send_char('9'); send_char('9');
    send_char('0'); send_char('0'); send_char('0');
    ticks(5);
    assert dstr = "  99000" report "FAIL: dstr=[" & dstr & "] expected '  99000'" severity failure;
    assert arm = '1' report "FAIL: arm should stay 1" severity failure;
    report "ok update -> dstr=[" & dstr & "]";

    -- stop sending -> receive timeout -> arm drops (TO_CLKS=2000)
    rx <= '1';
    ticks(2100);
    assert arm = '0' report "FAIL: arm should drop on timeout" severity failure;
    report "ok timeout -> arm=0";

    report "===== DISP_INJECT TESTS PASSED =====";
    done <= true; wait;
  end process;
end architecture;
