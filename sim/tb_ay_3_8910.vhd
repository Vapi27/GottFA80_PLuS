-- tb_ay_3_8910.vhd : self-checking testbench for the AY-3-8910/8912 PSG core
-- GHDL:  ghdl -a lib_common/ay_3_8910.vhd sim/tb_ay_3_8910.vhd
--        ghdl -e tb_ay_3_8910 && ghdl -r tb_ay_3_8910
-- Expect: "===== AY TESTS PASSED ====="
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_ay_3_8910 is end tb_ay_3_8910;

architecture sim of tb_ay_3_8910 is
  signal clk   : std_logic := '0';
  signal ce    : std_logic := '1';                 -- AY master clock = every system clk
  signal rst_n : std_logic := '0';
  signal addr  : std_logic_vector(3 downto 0) := (others => '0');
  signal din   : std_logic_vector(7 downto 0) := (others => '0');
  signal dout  : std_logic_vector(7 downto 0);
  signal wr    : std_logic := '0';
  signal ch_a, ch_b, ch_c : std_logic_vector(7 downto 0);
  signal audio : std_logic_vector(9 downto 0);
  signal done  : boolean := false;
begin
  DUT : entity work.ay_3_8910
    port map ( clk=>clk, ce=>ce, rst_n=>rst_n, addr=>addr, din=>din, dout=>dout, wr=>wr,
               ch_a=>ch_a, ch_b=>ch_b, ch_c=>ch_c, audio=>audio );

  clk <= not clk after 10 ns when not done else '0';
  ce  <= '1';

  stim : process
    variable hi, lo : boolean;
    variable maxv   : integer;
    procedure wreg(a : integer; d : integer) is
    begin
      addr <= std_logic_vector(to_unsigned(a, 4));
      din  <= std_logic_vector(to_unsigned(d, 8));
      wr   <= '1'; wait until rising_edge(clk);
      wr   <= '0'; wait until rising_edge(clk);
    end procedure;
  begin
    rst_n <= '0'; wait for 60 ns; wait until rising_edge(clk); rst_n <= '1';
    wait until rising_edge(clk);

    -- 1) register write/read-back
    wreg(4, 16#5A#);
    addr <= std_logic_vector(to_unsigned(4, 4)); wait for 25 ns;
    assert dout = x"5A" report "FAIL regrw" severity failure;
    report "PASS regrw";

    -- 2) channel A produces a square (tone enabled, full volume)
    wreg(0, 2); wreg(1, 0);          -- tone period A = 2
    wreg(7, 16#3E#);                 -- mixer: enable tone A only (bit0=0), all else disabled
    wreg(8, 16#0F#);                 -- ch A amplitude = 15
    hi := false; lo := false;
    for i in 0 to 4000 loop
      wait until rising_edge(clk);
      if ch_a = x"FF" then hi := true; end if;
      if ch_a = x"00" then lo := true; end if;
    end loop;
    assert hi and lo report "FAIL tone square (no toggling)" severity failure;
    report "PASS tone square";

    -- 3) amplitude DAC: level 8 -> VOL(8)=22
    wreg(8, 16#08#); maxv := 0;
    for i in 0 to 4000 loop
      wait until rising_edge(clk);
      if to_integer(unsigned(ch_a)) > maxv then maxv := to_integer(unsigned(ch_a)); end if;
    end loop;
    assert maxv = 22 report "FAIL vol (got " & integer'image(maxv) & ", want 22)" severity failure;
    report "PASS vol";

    -- 4) amplitude 0 -> silent
    wreg(8, 0);
    for i in 0 to 300 loop
      wait until rising_edge(clk);
      assert ch_a = x"00" report "FAIL silence" severity failure;
    end loop;
    report "PASS silence";

    -- 5) envelope sweeps the amplitude (tone+noise off => DC at the envelope level)
    wreg(7, 16#3F#);                 -- disable tone+noise on A -> channel = DC
    wreg(8, 16#10#);                 -- ch A uses the envelope
    wreg(11, 1); wreg(12, 0);        -- short envelope period
    wreg(13, 16#08#);                -- shape \\\\ (saw down, repeating)
    hi := false; lo := false;
    for i in 0 to 60000 loop
      wait until rising_edge(clk);
      if to_integer(unsigned(ch_a)) >= 90 then hi := true; end if;  -- near top
      if to_integer(unsigned(ch_a)) <= 3  then lo := true; end if;  -- near bottom
    end loop;
    assert hi and lo report "FAIL envelope sweep" severity failure;
    report "PASS envelope";

    report "===== AY TESTS PASSED =====";
    done <= true; wait;
  end process;
end sim;
