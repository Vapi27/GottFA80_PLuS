--------------------------------------------------------------------------
-- tb_cdc_snoop : combien de fois un process clk_50 re-echantillonne-t-il
-- un bus du domaine cpu_clk ?
-- Reproduit l'idiome BALL_SNOOP de SYS80.vhd (lignes 1642-1650).
-- Le commentaire du source affirme "~56 edges per CPU cycle".  On COMPTE.
-- Tout le comptage se fait DANS le process clk_50 pour eviter toute course
-- de delta entre processes.
--------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_cdc_snoop is
end tb_cdc_snoop;

architecture sim of tb_cdc_snoop is
  constant TCLK50 : time := 20 ns;
  signal clk_50   : std_logic := '0';
  signal cpu_clk  : std_logic;
  signal done     : boolean := false;

  signal src_data : std_logic_vector(3 downto 0) := "0000";
  signal src_cond : std_logic := '0';
  signal cyc      : integer := 0;

  signal latched  : std_logic_vector(3 downto 0) := "0000";

  -- resultats publies par le process clk_50, lus par le rapporteur
  signal r_bursts : integer := 0;   -- nb de rafales (= cycles d'ecriture) terminees
  signal r_min    : integer := 999999;
  signal r_max    : integer := 0;
  signal r_tot    : integer := 0;   -- somme des echantillons
  signal r_mono   : integer := 0;   -- rafales a 1 seul echantillon
  signal r_stale  : integer := 0;   -- rafales dont un echantillon a capture "1111" (parasite)
begin

  clk_gen : process
  begin
    while not done loop
      clk_50 <= '0'; wait for TCLK50/2;
      clk_50 <= '1'; wait for TCLK50/2;
    end loop;
    wait;
  end process;

  dut_clk : entity work.cpu_clk_gen port map (clk_in => clk_50, cpu_clk_out => cpu_clk);

  -- source domaine cpu_clk : un "write" 6502 un cycle sur deux
  src : process(cpu_clk)
  begin
    if rising_edge(cpu_clk) then
      cyc <= cyc + 1;
      if (cyc mod 2) = 0 then
        src_cond <= '1';
        src_data <= std_logic_vector(to_unsigned((cyc/2) mod 16, 4));
      else
        src_cond <= '0';
        src_data <= "1111";                    -- valeur parasite hors write
      end if;
    end if;
  end process;

  -- REPLIQUE de BALL_SNOOP + instrumentation, TOUT dans le meme process clk_50
  snoop : process(clk_50)
    variable cnt   : integer := 0;
    variable prev  : std_logic := '0';
    variable stale : boolean := false;
  begin
    if rising_edge(clk_50) then
      if src_cond = '1' then
        latched <= src_data;                   -- <-- l'idiome BALL_SNOOP
        cnt := cnt + 1;
        if src_data = "1111" then stale := true; end if;
      end if;
      -- fin de rafale : la condition vient de retomber
      if prev = '1' and src_cond = '0' then
        if cnt > 0 then
          r_bursts <= r_bursts + 1;
          r_tot    <= r_tot + cnt;
          if cnt < r_min then r_min <= cnt; end if;
          if cnt > r_max then r_max <= cnt; end if;
          if cnt = 1 then r_mono <= r_mono + 1; end if;
          if stale then r_stale <= r_stale + 1; end if;
        end if;
        cnt := 0; stale := false;
      end if;
      prev := src_cond;
    end if;
  end process;

  chk : process
    variable L : line;
  begin
    wait for 200 us;                            -- ~175 cycles CPU
    write(L, string'("==== tb_cdc_snoop : BALL_SNOOP, process clk_50 lisant le bus cpu_clk ====")); writeline(output, L);
    write(L, string'("rafales (cycles d'ecriture CPU) observees : ")); write(L, r_bursts); writeline(output, L);
    write(L, string'("echantillons par rafale   min            : ")); write(L, r_min); writeline(output, L);
    write(L, string'("echantillons par rafale   max            : ")); write(L, r_max); writeline(output, L);
    write(L, string'("echantillons TOTAUX                      : ")); write(L, r_tot); writeline(output, L);
    write(L, string'("moyenne echantillons/rafale              : "));
    write(L, r_tot / r_bursts); writeline(output, L);
    write(L, string'("(le commentaire de SYS80.vhd annonce ~56)")); writeline(output, L);
    write(L, string'("rafales a 1 seul echantillon             : ")); write(L, r_mono); writeline(output, L);
    write(L, string'("rafales ayant capture la valeur parasite : ")); write(L, r_stale); writeline(output, L);
    write(L, string'("COMPARAISONS (rafales evaluees)          : ")); write(L, r_bursts); writeline(output, L);
    assert r_bursts > 0 report "FAUX VERT : aucune rafale evaluee" severity failure;
    if r_mono = 0 and r_tot / r_bursts > 10 then
      write(L, string'("CONSTAT : multi-echantillonnage CONFIRME par la mesure"));
    else
      write(L, string'("CONSTAT : multi-echantillonnage NON confirme"));
    end if;
    writeline(output, L);
    done <= true;
    wait;
  end process;

end sim;
