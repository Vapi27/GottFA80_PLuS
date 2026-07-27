-- tb_snd_wire.vhd : the SOUND_WIRE.md acceptance testbench.
--
-- It drives ONE stimulus -- a faithful model of the Gottlieb System 80 sound bus
-- as SYS80.vhd wires it -- into TWO transmitters at once:
--
--   OLD = sim/sound_link_old.vhd, a verbatim copy of lib_common/sound_link.vhd at
--         git 5ea7514 (entity renamed).  This is the code burned into the machine
--         today, not a caricature of it.
--   NEW = lib_common/snd_bus.vhd + lib_common/sound_link.vhd, the contract.
--
-- Both TX lines are decoded back into bytes and every sound-class byte is printed
-- with its timestamp, so the transcript IS the evidence.
--
-- Bus model, identical to SYS80.vhd's "Sound_S1 <= ..." lines with myTest='1':
--     S1..S8 = not pa(n) and not pa(4)      (RIOT U6 port-A latch, combinational)
--     S16    = lamp latch bit               (74175, clocked by a LAMP write)
--     sel    = not pa(4)                    (the strobe PinMAME gates on)
--     pa_wr  = pulse per CPU write to ORA   (the strobe PinMAME triggers on)
-- and the snapshot source is held permanently hungry (snap_req='1') so the
-- arbiter runs under maximum contention throughout -- the worst case for a cue.
--
-- Scaling, exactly as tb_link_arb.vhd: clk 5 MHz with clk_hz=5000000, so DIV=43,
-- one byte = 430 clk = 86.0 us and simulated time == real machine time 1:1.
-- Stimulus times are therefore REAL times (a 6502 STA abs = 4.5 us).
--
-- PHASES
--   A  t=100us  an 80B bank cue: header, release, payload, release, 4.4 us apart.
--               NEW must emit 0x8A 0x30 0x85 0x30.  OLD coalesces them.
--   B  t=1ms    ATTRACT MODE: lamps animating, no CPU write to port A at all.
--               NEW must emit NOTHING.  OLD emits a stream of 0x90/0x80 -- the
--               RTL proof that the "cmd 16 = background hum, ignore it" note on
--               Arena is the idle bus read through a high S16 lamp bit.
--   C  t=25ms   12 cues in 35 us: the 8-deep FIFO overflows.  NEW must emit
--               exactly one 0x31 and must not lose anything silently.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_snd_wire is
end tb_snd_wire;

architecture sim of tb_snd_wire is
  constant TCLK  : time := 200 ns;              -- 5 MHz
  constant BIT_T : time := 43 * TCLK;           -- one UART bit = DIV clocks

  signal clk  : std_logic := '0';
  signal rst  : std_logic := '1';
  signal tx_n : std_logic;                      -- NEW link
  signal tx_o : std_logic;                      -- OLD link
  signal running : boolean := true;

  -- the modelled sound bus
  signal pa    : std_logic_vector(7 downto 0) := (others => '1');  -- U6 port A latch
  signal s16   : std_logic := '0';                                 -- lamp-latch bit
  signal pa_wr : std_logic := '0';                                 -- R6532 ORA write strobe
  signal sound : std_logic_vector(4 downto 0);
  signal sel   : std_logic;
  signal stb   : std_logic;
  signal rel   : std_logic;

  -- recorded sound-class traffic: code, and arrival time in us
  type iarr is array(0 to 255) of integer;
  shared variable nb_seq, nb_us : iarr := (others => -1);   -- NEW
  shared variable ob_seq, ob_us : iarr := (others => -1);   -- OLD
  shared variable nb_n   : integer := 0;
  shared variable ob_n   : integer := 0;
  shared variable nb_lvl : integer := 0;                    -- level/snapshot bytes seen
  shared variable ob_lvl : integer := 0;

  function hx(v : integer) return string is
    constant D : string(1 to 16) := "0123456789ABCDEF";
  begin
    return "0x" & D(((v/16) mod 16)+1) & D((v mod 16)+1);
  end function;
begin

  clk <= not clk after TCLK/2 when running else '0';

  ---------------------------------------------------------------------------
  -- the bus, wired exactly as SYS80.vhd wires it (myTest = '1')
  ---------------------------------------------------------------------------
  sound <= s16 & (not pa(3) and not pa(4)) & (not pa(2) and not pa(4))
                & (not pa(1) and not pa(4)) & (not pa(0) and not pa(4));
  sel   <= not pa(4);

  DUT_BUS : entity work.snd_bus
    port map ( clk => clk, rst => rst, pa_wr => pa_wr, sel => sel,
               stb => stb, rel => rel );

  DUT_NEW : entity work.sound_link
    generic map ( clk_hz => 5000000, baud => 115200, hb_ms => 50 )
    port map (
      clk => clk, rst => rst, diag => '0',
      sound => sound, snd_stb => stb, snd_rel => rel, fam => "10",
      game => "001100", game_running => '1', ball => "0000",
      snap_data => x"C5", snap_req => '1', snap_ack => open,
      tx => tx_n );

  DUT_OLD : entity work.sound_link_old
    generic map ( clk_hz => 5000000, baud => 115200, hb_ms => 50 )
    port map (
      clk => clk, rst => rst, diag => '0',
      sound => sound,
      game => "001100", game_running => '1', ball => "0000",
      snap_data => x"C5", snap_req => '1', snap_ack => open,
      tx => tx_o );

  ---------------------------------------------------------------------------
  -- stimulus
  ---------------------------------------------------------------------------
  STIM : process
    -- one CPU write to U6 ORA: put the value on the port and raise pa_wr for one
    -- phi2-low phase (~0.56 us at 895 kHz), exactly as R6532.vhd does.
    procedure cpu_write_pa(v : std_logic_vector(7 downto 0)) is
    begin
      pa <= v;
      wait for 100 ns;
      pa_wr <= '1';
      wait for 560 ns;
      pa_wr <= '0';
    end procedure;
  begin
    rst <= '1';
    wait for 20 us;
    rst <= '0';

    ------------------------------------------------------------------ PHASE A
    -- 80B bank cue.  pa(7..5) = "111" = solenoids idle.
    wait for 80 us;                                      -- t = 100 us
    cpu_write_pa("11100101");   -- sel=1, S8+S2 -> cmd 0x0A   (bank header)
    wait for 4.4 us;
    cpu_write_pa("11111111");   -- sel=0                      (bus release)
    wait for 4.4 us;
    cpu_write_pa("11101010");   -- sel=1, S4+S1 -> cmd 0x05   (payload)
    wait for 4.4 us;
    cpu_write_pa("11111111");   -- sel=0                      (bus release)

    ------------------------------------------------------------------ PHASE B
    -- attract mode: lamps animate, the CPU never writes port A.
    wait for 1 ms - now;
    for i in 1 to 20 loop
      wait for 1 ms;
      s16 <= not s16;                                    -- a LAMP-latch write
    end loop;
    s16 <= '0';

    ------------------------------------------------------------------ PHASE C
    wait for 25 ms - now;
    for i in 1 to 12 loop
      cpu_write_pa("1110" & not std_logic_vector(to_unsigned(i, 4)));
      wait for 2.3 us;
    end loop;

    wait;
  end process;

  ---------------------------------------------------------------------------
  -- receivers
  ---------------------------------------------------------------------------
  RX_NEW : process
    variable b : std_logic_vector(7 downto 0);
    variable v, t : integer;
    variable l : line;
  begin
    wait until falling_edge(tx_n);
    wait for BIT_T/2;
    if tx_n = '0' then
      for i in 0 to 7 loop wait for BIT_T; b(i) := tx_n; end loop;
      wait for BIT_T;
      v := to_integer(unsigned(b));
      t := now / 1 us;
      if b(7 downto 5) = "100" or v = 16#30# or v = 16#31# then
        nb_seq(nb_n) := v; nb_us(nb_n) := t; nb_n := nb_n + 1;
        write(l, string'("  NEW  t="));  write(l, t);
        write(l, string'("us  "));       write(l, hx(v));
        if    v = 16#30# then write(l, string'("  REL"));
        elsif v = 16#31# then write(l, string'("  LOST"));
        else  write(l, string'("  SND cmd=")); write(l, v - 16#80#); end if;
        writeline(output, l);
      else
        nb_lvl := nb_lvl + 1;
      end if;
    end if;
  end process;

  RX_OLD : process
    variable b : std_logic_vector(7 downto 0);
    variable v, t : integer;
    variable l : line;
  begin
    wait until falling_edge(tx_o);
    wait for BIT_T/2;
    if tx_o = '0' then
      for i in 0 to 7 loop wait for BIT_T; b(i) := tx_o; end loop;
      wait for BIT_T;
      v := to_integer(unsigned(b));
      t := now / 1 us;
      if b(7 downto 5) = "100" then
        ob_seq(ob_n) := v; ob_us(ob_n) := t; ob_n := ob_n + 1;
        write(l, string'("  OLD  t="));  write(l, t);
        write(l, string'("us  "));       write(l, hx(v));
        write(l, string'("  SND cmd=")); write(l, v - 16#80#);
        writeline(output, l);
      else
        ob_lvl := ob_lvl + 1;
      end if;
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- verdict
  ---------------------------------------------------------------------------
  REPORTP : process
    variable l : line;
    variable nA, oA, nB, oB, nC, oC, nLost : integer := 0;
    variable fails : integer := 0;
    procedure check(ok : boolean; what : string) is
      variable ll : line;
    begin
      write(ll, string'("  "));
      if ok then write(ll, string'("PASS  "));
      else       write(ll, string'("FAIL  ")); fails := fails + 1; end if;
      write(ll, what);
      writeline(output, ll);
    end procedure;
  begin
    wait for 28 ms;

    for i in 0 to nb_n-1 loop
      if    nb_us(i) < 1000  then nA := nA + 1;
      elsif nb_us(i) < 24000 then nB := nB + 1;
      else                        nC := nC + 1;
        if nb_seq(i) = 16#31# then nLost := nLost + 1; end if;
      end if;
    end loop;
    for i in 0 to ob_n-1 loop
      if    ob_us(i) < 1000  then oA := oA + 1;
      elsif ob_us(i) < 24000 then oB := oB + 1;
      else                        oC := oC + 1; end if;
    end loop;

    write(l, string'("=== tb_snd_wire ==="));                          writeline(output, l);
    write(l, string'("  sound-class bytes  NEW="));    write(l, nb_n);
    write(l, string'("  OLD="));                       write(l, ob_n);
    write(l, string'("   (other bytes NEW="));         write(l, nb_lvl);
    write(l, string'(" OLD="));                        write(l, ob_lvl);
    write(l, string'(")"));                            writeline(output, l);
    write(l, string'("  A cue header+payload  NEW=")); write(l, nA);
    write(l, string'("  OLD="));                       write(l, oA);  writeline(output, l);
    write(l, string'("  B lamp animation only NEW=")); write(l, nB);
    write(l, string'("  OLD="));                       write(l, oB);  writeline(output, l);
    write(l, string'("  C 12-cue burst        NEW=")); write(l, nC);
    write(l, string'("  ofwhich 0x31="));              write(l, nLost);
    write(l, string'("  OLD="));                       write(l, oC);  writeline(output, l);

    -- (1) the header/payload pair survives, in order, on the NEW link -- and
    --     nA = 4 exactly also proves no phantom byte was emitted for the
    --     power-up state of the bus (SOUND_WIRE.md 2.2 rule 6).
    check(nA = 4,                              "A: NEW emits all 4 bus events, and only those");
    check(nA = 4 and nb_seq(0) = 16#8A#,       "A: NEW[0] = 0x8A  bank header");
    check(nA = 4 and nb_seq(1) = 16#30#,       "A: NEW[1] = 0x30  release");
    check(nA = 4 and nb_seq(2) = 16#85#,       "A: NEW[2] = 0x85  payload");
    check(nA = 4 and nb_seq(3) = 16#30#,       "A: NEW[3] = 0x30  release");
    check(oA < 4,                              "A: OLD coalesces -- cue events LOST (the bug)");
    -- (2) THE ACCEPTANCE TEST: lamps animating, zero sound rows
    check(nB = 0,                              "B: NEW emits ZERO sound bytes for lamp animation");
    check(oB > 0,                              "B: OLD injects phantom cues from lamp animation");
    -- (3) overflow is reported, exactly once, and is never silent
    check(nLost = 1,                           "C: NEW reports the overflow with exactly one 0x31");
    check(nC - nLost >= 8,                     "C: NEW still delivered >= 8 of the 12 cues");

    if fails = 0 then write(l, string'("  RESULT: ALL CHECKS PASS"));
    else              write(l, string'("  RESULT: FAILURES = ")); write(l, fails); end if;
    writeline(output, l);

    running <= false;
    wait for 1 us;
    assert fails = 0 report "tb_snd_wire FAILED" severity failure;
    wait;
  end process;

end sim;
