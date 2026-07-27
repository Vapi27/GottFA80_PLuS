-- Behavioural testbench for lib_common/disp_inject.vhd
-- Short timeouts (hold_ms=5 / ctrl_to_ms=10) so the fail-safes are reachable in
-- simulation; the logic under test is identical to the synthesised instance.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_disp_inject is
end tb_disp_inject;

architecture sim of tb_disp_inject is
  constant CLKP  : time := 20 ns;              -- 50 MHz
  constant BITT  : time := 8680 ns;            -- 1/115200
  signal clk     : std_logic := '0';
  signal rst     : std_logic := '1';
  signal rx      : std_logic := '1';
  signal dstr    : string(1 to 7);
  signal dvalid  : std_logic;
  signal ctrl    : std_logic_vector(6 downto 0);
  signal kreq    : std_logic;
  signal running : boolean := true;
  signal kcount  : integer := 0;               -- counts kill_pulse_req cycles
  signal errors  : integer := 0;

  procedure chk(cond : boolean; msg : string; signal e : inout integer) is
  begin
    if not cond then
      report "FAIL: " & msg severity error;
      e <= e + 1;
    else
      report "ok  : " & msg severity note;
    end if;
  end procedure;

begin

  clk <= not clk after CLKP/2 when running else '0';

  DUT : entity work.disp_inject
    generic map (clk_hz => 50000000, baud => 115200, hold_ms => 5, ctrl_to_ms => 10)
    port map (clk => clk, rst => rst, rx => rx,
              dstr => dstr, dvalid => dvalid, ctrl => ctrl, kill_pulse_req => kreq);

  -- count how many clock cycles kill_pulse_req is high (must be exactly 1 per edge)
  KC : process (clk)
  begin
    if rising_edge(clk) then
      if kreq = '1' then kcount <= kcount + 1; end if;
    end if;
  end process;

  STIM : process
    -- send one 8N1 byte
    procedure send(b : integer) is
      variable v : std_logic_vector(7 downto 0);
    begin
      v := std_logic_vector(to_unsigned(b, 8));
      rx <= '0'; wait for BITT;                       -- start
      for i in 0 to 7 loop
        rx <= v(i); wait for BITT;                    -- LSB first
      end loop;
      rx <= '1'; wait for BITT;                       -- stop
    end procedure;
    procedure send_str(s : string) is
    begin
      for i in s'range loop
        send(character'pos(s(i)));
      end loop;
    end procedure;
    variable k0 : integer;
  begin
    wait for 1 us;
    rst <= '0';
    wait for 10 us;

    ------------------------------------------------------------------
    report "--- T1: display frame ---";
    send(16#FF#); send_str("  12345");
    wait for 20 us;
    chk(dstr = "  12345", "T1 dstr = '  12345' (got '" & dstr & "')", errors);
    chk(dvalid = '1',     "T1 dvalid high after a complete frame", errors);

    ------------------------------------------------------------------
    report "--- T2: control frame b0+b1 ---";
    send(16#FE#); send(16#03#);
    wait for 20 us;
    chk(ctrl = "0000011", "T2 ctrl = 0000011", errors);
    chk(kcount = 0,       "T2 no kill pulse yet", errors);

    ------------------------------------------------------------------
    report "--- T3: kill edge 0->1 gives exactly ONE cycle ---";
    send(16#FE#); send(16#07#);
    wait for 20 us;
    chk(kcount = 1,       "T3 kill_pulse_req high for exactly 1 clk", errors);
    chk(ctrl(2) = '1',    "T3 ctrl(2) latched", errors);

    report "--- T4: repeated b2=1 must NOT re-fire ---";
    send(16#FE#); send(16#07#);
    send(16#FE#); send(16#07#);
    wait for 20 us;
    chk(kcount = 1,       "T4 still exactly 1 kill pulse", errors);

    report "--- T5: b2 back to 0 then 1 -> a second pulse ---";
    send(16#FE#); send(16#03#);
    send(16#FE#); send(16#07#);
    wait for 20 us;
    chk(kcount = 2,       "T5 second kill pulse", errors);

    ------------------------------------------------------------------
    report "--- T6: resync -- truncated display frame then a good one ---";
    send(16#FF#); send_str("XYZ");            -- aborted mid-frame
    send(16#FF#); send_str("   4321");        -- new marker resyncs
    wait for 20 us;
    chk(dstr = "   4321", "T6 resynced frame (got '" & dstr & "')", errors);

    report "--- T7: 0xFE inside a display frame switches to CONTROL ---";
    send(16#FF#); send_str("99");
    send(16#FE#); send(16#01#);
    wait for 20 us;
    chk(ctrl = "0000001", "T7 control frame parsed after abort", errors);
    chk(dstr = "   4321", "T7 display string untouched by the aborted frame", errors);

    report "--- T8: line glitch must not fake a byte ---";
    k0 := kcount;
    rx <= '0'; wait for 1 us; rx <= '1';       -- 1 us low = 1/8 of a bit
    wait for 200 us;
    chk(kcount = k0,      "T8 glitch produced no control byte", errors);
    chk(ctrl = "0000001", "T8 ctrl unchanged by the glitch", errors);

    ------------------------------------------------------------------
    report "--- T9: FAIL-SAFES on ESP silence ---";
    send(16#FF#); send_str("  99999");         -- refresh both timers
    send(16#FE#); send(16#07#);
    wait for 20 us;
    chk(dvalid = '1', "T9 dvalid high before the silence", errors);
    chk(ctrl(1 downto 0) = "11", "T9 ctrl b0/b1 set before the silence", errors);

    wait for 6 ms;                             -- > hold_ms (5), < ctrl_to_ms (10)
    chk(dvalid = '0', "T9 dvalid self-cleared after hold_ms", errors);
    chk(ctrl(1 downto 0) = "11", "T9 ctrl still set before ctrl_to_ms", errors);

    wait for 6 ms;                             -- now past ctrl_to_ms
    chk(ctrl(1 downto 0) = "00", "T9 FAIL-SAFE cleared ctrl b0/b1", errors);
    chk(ctrl(2) = '1', "T9 fail-safe left b2 alone (no phantom kill edge)", errors);
    chk(kcount = 3, "T9 no extra kill pulse from the fail-safe", errors);

    report "--- T10: link comes back ---";
    send(16#FE#); send(16#03#);
    wait for 20 us;
    chk(ctrl(1 downto 0) = "11", "T10 ctrl re-armed", errors);

    ------------------------------------------------------------------
    if errors = 0 then
      report "=========== ALL TESTS PASSED ===========" severity note;
    else
      report "=========== FAILURES: " & integer'image(errors) & " ===========" severity failure;
    end if;
    running <= false;
    wait;
  end process;

end sim;
