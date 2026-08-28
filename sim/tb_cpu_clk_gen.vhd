--------------------------------------------------------------------------
-- tb_cpu_clk_gen : mesure la periode REELLE de cpu_clk_out
-- clk_50 = 20 ns exactement.  On chronometre front-a-front ET on COMPTE les
-- fronts montants de clk_50 entre deux fronts montants de cpu_clk (mesure
-- directe du rapport de division, independante de l'unite de temps).
--------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use std.textio.all;

entity tb_cpu_clk_gen is
end tb_cpu_clk_gen;

architecture sim of tb_cpu_clk_gen is
  constant TCLK50 : time := 20 ns;                  -- 50 MHz exactement
  signal clk_50   : std_logic := '0';
  signal cpu_clk  : std_logic;
  signal done     : boolean := false;

  -- HYPOTHESE lue dans le RTL : compteur 0..56 inclus => 57 cycles clk_50
  constant DIV_EXPECTED : integer := 57;
  constant HI_EXPECTED  : integer := 29;            -- q = 28..56
  constant LO_EXPECTED  : integer := 28;            -- q =  0..27
  constant T_EXPECTED   : time    := DIV_EXPECTED * TCLK50;

  constant N_PERIODS : integer := 500;

  -- compteur libre de fronts montants clk_50, sert d'etalon
  shared variable tick : integer := 0;

  shared variable n_cmp_per : integer := 0;  shared variable n_bad_per : integer := 0;
  shared variable n_cmp_div : integer := 0;  shared variable n_bad_div : integer := 0;
  shared variable n_cmp_hi  : integer := 0;  shared variable n_bad_hi  : integer := 0;
  shared variable n_cmp_lo  : integer := 0;  shared variable n_bad_lo  : integer := 0;
begin

  clk_gen : process
  begin
    while not done loop
      clk_50 <= '0'; wait for TCLK50/2;
      clk_50 <= '1'; wait for TCLK50/2;
    end loop;
    wait;
  end process;

  -- etalon : incremente sur chaque front montant de clk_50
  ticker : process(clk_50)
  begin
    if rising_edge(clk_50) then tick := tick + 1; end if;
  end process;

  dut : entity work.cpu_clk_gen
    port map ( clk_in => clk_50, cpu_clk_out => cpu_clk );

  meas : process
    variable t_prev_r, t_fall, t_now : time;
    variable per_r, w_high, w_low    : time;
    variable k_prev_r, k_fall, k_now : integer;
    variable d_per, d_hi, d_lo       : integer;
    variable first_r, last_r         : time;
    variable min_p, max_p            : time;
    variable sum_hi, sum_lo          : time := 0 ns;
    variable n_hi, n_lo              : integer := 0;
    variable i                       : integer;
    variable L                       : line;
    variable n_cmp_tot, n_bad_tot    : integer;
  begin
    -- on jette les 3 premieres periodes (sortie de reset du compteur)
    for k in 0 to 2 loop wait until rising_edge(cpu_clk); end loop;

    wait until rising_edge(cpu_clk);
    t_prev_r := now; k_prev_r := tick; first_r := now;
    min_p := 1 sec; max_p := 0 ns;

    for i in 1 to N_PERIODS loop
      wait until falling_edge(cpu_clk);
      t_fall := now;  k_fall := tick;
      w_high := t_fall - t_prev_r;  d_hi := k_fall - k_prev_r;
      sum_hi := sum_hi + w_high; n_hi := n_hi + 1;
      n_cmp_hi := n_cmp_hi + 1;
      if d_hi /= HI_EXPECTED then n_bad_hi := n_bad_hi + 1; end if;

      wait until rising_edge(cpu_clk);
      t_now := now;  k_now := tick;
      w_low := t_now - t_fall;  d_lo := k_now - k_fall;
      sum_lo := sum_lo + w_low; n_lo := n_lo + 1;
      n_cmp_lo := n_cmp_lo + 1;
      if d_lo /= LO_EXPECTED then n_bad_lo := n_bad_lo + 1; end if;

      per_r := t_now - t_prev_r;
      d_per := k_now - k_prev_r;

      n_cmp_per := n_cmp_per + 1;
      if per_r /= T_EXPECTED then n_bad_per := n_bad_per + 1; end if;

      n_cmp_div := n_cmp_div + 1;
      if d_per /= DIV_EXPECTED then
        n_bad_div := n_bad_div + 1;
        if n_bad_div < 4 then
          write(L, string'("  [DIVERGENCE] division mesuree = ")); write(L, d_per);
          write(L, string'(" attendue ")); write(L, DIV_EXPECTED); writeline(output, L);
        end if;
      end if;

      if per_r < min_p then min_p := per_r; end if;
      if per_r > max_p then max_p := per_r; end if;
      t_prev_r := t_now; k_prev_r := k_now; last_r := t_now;
    end loop;

    write(L, string'("==== tb_cpu_clk_gen : mesure de cpu_clk ====")); writeline(output, L);
    write(L, string'("periodes mesurees        : ")); write(L, N_PERIODS); writeline(output, L);
    write(L, string'("periode min              : ")); write(L, min_p); writeline(output, L);
    write(L, string'("periode max              : ")); write(L, max_p); writeline(output, L);
    write(L, string'("intervalle total mesure  : ")); write(L, last_r - first_r); writeline(output, L);
    write(L, string'("periode moyenne (ps)     : "));
    write(L, integer((last_r - first_r)/1 ps) / N_PERIODS); writeline(output, L);
    write(L, string'("cycles clk_50 / periode  : "));
    write(L, (integer((last_r - first_r)/1 ps) / N_PERIODS) / 20000); writeline(output, L);
    write(L, string'("largeur HAUT moyenne     : ")); write(L, sum_hi/n_hi); writeline(output, L);
    write(L, string'("largeur BAS  moyenne     : ")); write(L, sum_lo/n_lo); writeline(output, L);
    writeline(output, L);
    write(L, string'("CMP periode=1140ns   : ")); write(L, n_cmp_per);
    write(L, string'("  echecs ")); write(L, n_bad_per); writeline(output, L);
    write(L, string'("CMP division =57     : ")); write(L, n_cmp_div);
    write(L, string'("  echecs ")); write(L, n_bad_div); writeline(output, L);
    write(L, string'("CMP haut     =29 cyc : ")); write(L, n_cmp_hi);
    write(L, string'("  echecs ")); write(L, n_bad_hi); writeline(output, L);
    write(L, string'("CMP bas      =28 cyc : ")); write(L, n_cmp_lo);
    write(L, string'("  echecs ")); write(L, n_bad_lo); writeline(output, L);

    n_cmp_tot := n_cmp_per + n_cmp_div + n_cmp_hi + n_cmp_lo;
    n_bad_tot := n_bad_per + n_bad_div + n_bad_hi + n_bad_lo;
    write(L, string'("COMPARAISONS TOTALES : ")); write(L, n_cmp_tot); writeline(output, L);
    write(L, string'("ECHECS TOTAUX        : ")); write(L, n_bad_tot); writeline(output, L);

    assert n_cmp_tot > 0 report "FAUX VERT : aucune comparaison effectuee" severity failure;
    assert n_bad_tot = 0 report "DIVERGENCE(S) detectee(s)" severity failure;
    write(L, string'("RESULTAT : PASS")); writeline(output, L);

    done <= true;
    wait;
  end process;

end sim;
