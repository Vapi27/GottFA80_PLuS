-- tb_detect_sw.vhd : proves that lib_common/detect_sw.vhd releases BOTH of its
-- outputs at the end of the `delay` state.
--
-- THE BUG THIS CATCHES.  The `delay` state wrote "long_push <= '0'" twice and
-- never wrote short_push, so short_push latched HIGH on the first press of
-- >=20 ms and stayed high until the next reset.  In SYS80.vhd that output is
-- `test_sw` (detect_test_sw, the door test switch) and it feeds EEprom
-- w_trigger(2); the EEprom block saves the 5101 NVRAM on any CHANGE of
-- w_trigger, so a latched bit produces exactly ONE save per power-up and the
-- test switch stops committing settings after that.
--
-- The checks are written against the CONTRACT -- "each qualifying press
-- produces one pulse on the matching output, and the pulse ENDS" -- not against
-- the implementation's cycle counts, and they also count rising edges on
-- short_push, which is literally what the EEprom trigger comparator sees.
--
-- NOTE (pre-existing, deliberately NOT changed): the `delay` state leaves
-- check_counter at ~125002 when it returns to Idle, so the 2 s measuring window
-- of the SECOND and later press in a power cycle is ~1.86 s instead of ~2.00 s.
-- Harmless (the long/short thresholds are 200 ms / 20 ms) and it also affects
-- long_push, i.e. the proven diag-entry timing -- which is why this bench waits
-- on the outputs instead of on absolute times.
--
-- Fails on the pre-fix source, passes on the fixed source.  Run:
--   ghdl -a -fsynopsys lib_common/detect_sw.vhd sim/tb_detect_sw.vhd
--   ghdl -e -fsynopsys tb_detect_sw
--   ghdl -r -fsynopsys tb_detect_sw --stop-time=12sec

library ieee;
use ieee.std_logic_1164.all;

entity tb_detect_sw is end tb_detect_sw;

architecture sim of tb_detect_sw is
  -- the real clock is the 895 kHz cpu_clk; the module's counters are sized for it
  constant TCLK : time := 1117 ns;

  signal clk        : std_logic := '0';
  signal sw_strobe  : std_logic := '0';
  signal sw_return  : std_logic := '0';
  signal sw_enable  : std_logic := '0';
  signal rst        : std_logic := '0';   -- active low (SYS80 ties this to game_running)
  signal short_push : std_logic;
  signal long_push  : std_logic;
  signal done       : boolean := false;

  -- what the EEprom w_trigger comparator actually observes
  signal short_rise : integer := 0;
  signal long_rise  : integer := 0;
begin

  clk <= not clk after TCLK/2 when not done else '0';

  UUT : entity work.detect_sw
    port map ( clk        => clk,
               sw_strobe  => sw_strobe,
               sw_return  => sw_return,
               sw_enable  => sw_enable,
               short_push => short_push,
               long_push  => long_push,
               rst        => rst );

  EDGES : process (short_push, long_push)
  begin
    if rising_edge(short_push) then short_rise <= short_rise + 1; end if;
    if rising_edge(long_push)  then long_rise  <= long_rise  + 1; end if;
  end process;

  STIM : process
    variable err  : integer := 0;
    variable t0   : time;
    variable wdth : time;

    procedure chk (cond : boolean; msg : string) is
    begin
      if not cond then
        report "FAIL: " & msg severity error;
        err := err + 1;
      end if;
    end procedure;

    -- close the switch for `dur`, then open it
    procedure press (dur : time) is
    begin
      sw_strobe <= '1';
      sw_return <= '1';
      wait for dur;
      sw_strobe <= '0';
      sw_return <= '0';
    end procedure;

  begin
    report "== detect_sw: pulse contract ==";

    rst <= '0';
    wait for 50 * TCLK;
    chk(short_push = '0', "short_push must be '0' out of reset");
    chk(long_push  = '0', "long_push must be '0' out of reset");
    rst <= '1';
    wait for 50 * TCLK;

    ----------------------------------------------------------------------
    -- PRESS 1 : long (500 ms closed) -> long_push AND short_push
    ----------------------------------------------------------------------
    press(500 ms);
    wait until long_push = '1' for 2500 ms;
    chk(long_push = '1', "long press: long_push never asserted");
    chk(short_push = '1', "long press: short_push must assert too "
                        & "(a long press is also a short press)");
    t0 := now;

    wait until long_push = '0' for 500 ms;
    chk(long_push = '0', "long press: long_push never released");
    chk(short_push = '0',
        "long press: short_push must be released with long_push "
      & "<-- THE BUG: the delay state cleared long_push twice and short_push never");
    wdth := now - t0;
    chk(wdth > 50 ms and wdth < 300 ms,
        "long press: pulse width out of contract, got " & time'image(wdth));

    wait for 100 ms;   -- settle back to Idle with the switch open

    ----------------------------------------------------------------------
    -- PRESS 2 : short (50 ms closed) -> short_push only
    -- On the buggy source short_push is STILL high here, so `wait until
    -- short_push='1'` never sees an edge and the release check below times out.
    ----------------------------------------------------------------------
    press(50 ms);
    wait until short_push = '1' for 2500 ms;
    chk(short_push = '1', "short press: short_push never asserted");
    chk(long_push  = '0', "short press: long_push must stay low");
    t0 := now;

    wait until short_push = '0' for 500 ms;
    chk(short_push = '0', "short press: short_push never released");
    chk(long_push  = '0', "short press: long_push must stay low");
    wdth := now - t0;
    chk(wdth > 50 ms and wdth < 300 ms,
        "short press: pulse width out of contract, got " & time'image(wdth));

    ----------------------------------------------------------------------
    -- what the EEprom write trigger sees: one edge PER PRESS, not one ever
    ----------------------------------------------------------------------
    chk(short_rise = 2,
        "EEprom trigger: expected 2 rising edges on short_push (one per press), got "
      & integer'image(short_rise));
    chk(long_rise = 1,
        "EEprom trigger: expected 1 rising edge on long_push, got "
      & integer'image(long_rise));

    assert err = 0
      report "== detect_sw: " & integer'image(err) & " FAILURES ==" severity failure;
    report "== detect_sw: ALL CHECKS PASSED ==" severity note;
    done <= true;
    wait;
  end process;

end sim;
