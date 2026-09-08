-- Banc CIBLE : les deux ports ecrivent EN MEME TEMPS a des adresses DIFFERENTES.
-- C'est le cas reel de la machine (restauration EEPROM sur le port B pendant que
-- le 6502 ecrit par le port A), et c'est precisement celui que tb_R5101_equiv ne
-- couvre pas -- sa phase 5 dit "un seul port ecrivant".
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
library orig;
entity tb_croise is end tb_croise;
architecture sim of tb_croise is
  signal clk : std_logic := '0';
  signal address_a : std_logic_vector(7 downto 0) := (others=>'0');
  signal address_b : std_logic_vector(6 downto 0) := (others=>'0');
  signal data_a : std_logic_vector(3 downto 0) := (others=>'0');
  signal data_b : std_logic_vector(7 downto 0) := (others=>'0');
  signal wren_a, wren_b : std_logic := '0';
  signal qa_o, qa_p : std_logic_vector(3 downto 0);
  signal qb_o, qb_p : std_logic_vector(7 downto 0);
  signal running : boolean := true;
  signal diverg, nb : natural := 0;
  signal check : boolean := false;
begin
  clk <= not clk after 10 ns when running else '0';
  D1 : entity orig.R5101 port map(address_a,address_b,clk,data_a,data_b,wren_a,wren_b,qa_o,qb_o);
  D2 : entity work.R5101 port map(address_a,address_b,clk,data_a,data_b,wren_a,wren_b,qa_p,qb_p);

  CMP : process(clk) begin
    if rising_edge(clk) and check then
      nb <= nb + 1;
      if qa_o /= qa_p or qb_o /= qb_p then
        diverg <= diverg + 1;
        if diverg < 6 then
          report "DIVERGENCE  A[" & integer'image(to_integer(unsigned(address_a))) & "]"
               & " orig=" & integer'image(to_integer(unsigned(qa_o)))
               & " port=" & integer'image(to_integer(unsigned(qa_p)))
               & "  B[" & integer'image(to_integer(unsigned(address_b))) & "]"
               & " orig=" & integer'image(to_integer(unsigned(qb_o)))
               & " port=" & integer'image(to_integer(unsigned(qb_p))) severity note;
        end if;
      end if;
    end if;
  end process;

  STIM : process
    procedure tick is begin wait until rising_edge(clk); end procedure;
  begin
    report "phase 1 : le 6502 ecrit par A pendant que l'EEPROM restaure par B";
    -- B balaie 0..63 (restauration EEPROM), A ecrit AILLEURS au meme instant
    for i in 0 to 63 loop
      address_b <= std_logic_vector(to_unsigned(i, 7));
      data_b    <= std_logic_vector(to_unsigned((i*7) mod 256, 8));
      wren_b    <= '1';
      address_a <= std_logic_vector(to_unsigned(200 + (i mod 40), 8)); -- adresse DIFFERENTE
      data_a    <= std_logic_vector(to_unsigned((i mod 16), 4));
      wren_a    <= '1';
      tick;
    end loop;
    wren_a <= '0'; wren_b <= '0'; tick; tick;

    report "phase 2 : relecture par A de ce qu'il croyait avoir ecrit";
    check <= true;
    for i in 0 to 63 loop
      address_a <= std_logic_vector(to_unsigned(200 + (i mod 40), 8));
      address_b <= std_logic_vector(to_unsigned(i, 7));
      tick;
    end loop;
    tick; tick;
    report "R5101 croise : comparaisons=" & integer'image(nb)
         & "  divergences=" & integer'image(diverg);
    if diverg = 0 then report "EQUIVALENTES sur ce cas" severity note;
    else report "LES DEUX VERSIONS DIVERGENT" severity error; end if;
    running <= false; wait;
  end process;
end sim;
