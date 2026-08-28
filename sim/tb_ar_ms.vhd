--------------------------------------------------------------------------
-- tb_ar_ms : AR_MS = 50000 vaut-il bien 1 ms a 50 MHz ?
-- On mesure le temps ecoule entre deux impulsions "fire" successives du
-- meme idiome de compteur que AUTO_RESTART, pour plusieurs limites.
--------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use std.textio.all;

entity tb_ar_ms is
end tb_ar_ms;

architecture sim of tb_ar_ms is
  constant TCLK50 : time := 20 ns;
  constant AR_MS  : natural := 50000;

  signal clk_50  : std_logic := '0';
  signal reset_l : std_logic := '0';
  signal done    : boolean := false;

  signal fire_1ms   : std_logic;   -- AR_MS
  signal fire_10ms  : std_logic;   -- 10 * AR_MS
  signal fire_50ms  : std_logic;   -- AR_T_DB
begin
  clk_gen : process
  begin
    while not done loop
      clk_50 <= '0'; wait for TCLK50/2;
      clk_50 <= '1'; wait for TCLK50/2;
    end loop;
    wait;
  end process;

  T1  : entity work.ar_timer generic map (LIMIT =>      AR_MS) port map (clk_50, reset_l, fire_1ms);
  T10 : entity work.ar_timer generic map (LIMIT => 10 * AR_MS) port map (clk_50, reset_l, fire_10ms);
  T50 : entity work.ar_timer generic map (LIMIT => 50 * AR_MS) port map (clk_50, reset_l, fire_50ms);

  stim : process
  begin
    reset_l <= '0';
    wait for 200 ns;
    reset_l <= '1';
    wait;
  end process;

  chk : process
    variable t0, t1 : time;
    variable L : line;
    variable n_cmp, n_bad : integer := 0;
    variable per : time;
    variable min_p, max_p : time;

    procedure mesure(signal f : in std_logic;
                     nom : in string; nominal : in time; n : in integer) is
      variable a, b : time;
      variable p : time;
      variable mn, mx : time;
    begin
      wait until rising_edge(f);      -- premiere impulsion, on la jette
      wait until rising_edge(f);
      a := now; mn := 1 sec; mx := 0 ns;
      for k in 1 to n loop
        wait until rising_edge(f);
        p := now - a;
        a := now;
        n_cmp := n_cmp + 1;
        if p /= nominal then n_bad := n_bad + 1; end if;
        if p < mn then mn := p; end if;
        if p > mx then mx := p; end if;
      end loop;
      write(L, string'("  ")); write(L, nom);
      write(L, string'(" : periode min=")); write(L, mn);
      write(L, string'(" max=")); write(L, mx);
      write(L, string'("  attendu(=LIMIT+1 cycles)=")); write(L, nominal);
      writeline(output, L);
    end procedure;
  begin
    write(L, string'("==== tb_ar_ms : AR_MS = 50000, clk_50 = 20 ns ====")); writeline(output, L);
    -- l'idiome consomme LIMIT increments PUIS un cycle de plus pour la branche >=
    -- => periode reelle = (LIMIT + 1) * TCLK50 ; c'est ce qu'on verifie.
    mesure(fire_1ms,  "AR_MS      (1 ms vise)", (AR_MS + 1) * TCLK50,  20);
    mesure(fire_10ms, "10*AR_MS   (10 ms vise)", (10*AR_MS + 1) * TCLK50, 5);
    mesure(fire_50ms, "AR_T_DB=50*AR_MS (50 ms)", (50*AR_MS + 1) * TCLK50, 3);

    writeline(output, L);
    write(L, string'("valeur ideale 1 ms         : ")); write(L, 1 ms); writeline(output, L);
    write(L, string'("AR_MS * 20 ns              : ")); write(L, AR_MS * TCLK50); writeline(output, L);
    write(L, string'("COMPARAISONS               : ")); write(L, n_cmp); writeline(output, L);
    write(L, string'("ECHECS                     : ")); write(L, n_bad); writeline(output, L);
    assert n_cmp > 0 report "FAUX VERT : aucune comparaison" severity failure;
    assert n_bad = 0 report "DIVERGENCE" severity failure;
    write(L, string'("RESULTAT : PASS")); writeline(output, L);
    done <= true;
    wait;
  end process;
end sim;
