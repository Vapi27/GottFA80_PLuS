-- ---------------------------------------------------------------------------
-- tb_R5101_equiv -- equivalence entre la R5101 d origine (altsyncram
-- BIDIR_DUAL_PORT a largeurs mixtes) et la reecriture portable.
--
-- Le point que ce banc doit trancher : la CONVENTION DES QUARTETS.  Le port A
-- voit 256 mots de 4 bits, le port B 128 mots de 8 bits, sur la meme memoire.
-- La reecriture suppose que le mot A d adresse PAIRE occupe les bits de poids
-- FAIBLE de l octet B.  Si l hypothese est fausse, la phase 3 diverge.
--
-- ⚠️ `read_during_write_mode_mixed_ports = DONT_CARE` dans l original : un acces
-- simultane des deux ports a des adresses qui se recouvrent n a AUCUN
-- comportement garanti.  Le banc ne teste donc jamais ce cas -- il n aurait pas
-- de reference contre laquelle comparer.
-- ---------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library orig;

entity tb_R5101_equiv is
end tb_R5101_equiv;

architecture sim of tb_R5101_equiv is
	signal clk       : std_logic := '0';
	signal address_a : std_logic_vector(7 downto 0) := (others => '0');
	signal address_b : std_logic_vector(6 downto 0) := (others => '0');
	signal data_a    : std_logic_vector(3 downto 0) := (others => '0');
	signal data_b    : std_logic_vector(7 downto 0) := (others => '0');
	signal wren_a, wren_b : std_logic := '0';
	signal qa_o, qa_p : std_logic_vector(3 downto 0);
	signal qb_o, qb_p : std_logic_vector(7 downto 0);

	signal running  : boolean := true;
	signal cycle, mismatch, compares : natural := 0;
	signal checking : boolean := false;
begin
	clk <= not clk after 10 ns when running else '0';

	D1 : entity orig.R5101 port map (address_a=>address_a, address_b=>address_b,
		clock=>clk, data_a=>data_a, data_b=>data_b, wren_a=>wren_a, wren_b=>wren_b,
		q_a=>qa_o, q_b=>qb_o);
	D2 : entity work.R5101 port map (address_a=>address_a, address_b=>address_b,
		clock=>clk, data_a=>data_a, data_b=>data_b, wren_a=>wren_a, wren_b=>wren_b,
		q_a=>qa_p, q_b=>qb_p);

	CMP : process (clk) begin
		if rising_edge(clk) then
			cycle <= cycle + 1;
			if checking then
				compares <= compares + 1;
				if qa_o /= qa_p or qb_o /= qb_p then
					mismatch <= mismatch + 1;
					report "DIVERGENCE cycle=" & integer'image(cycle)
						& "  A[" & integer'image(to_integer(unsigned(address_a))) & "]"
						& " orig=" & integer'image(to_integer(unsigned(qa_o)))
						& " port=" & integer'image(to_integer(unsigned(qa_p)))
						& "  |  B[" & integer'image(to_integer(unsigned(address_b))) & "]"
						& " orig=" & integer'image(to_integer(unsigned(qb_o)))
						& " port=" & integer'image(to_integer(unsigned(qb_p)))
						severity error;
				end if;
			end if;
		end if;
	end process;

	STIM : process
		variable seed : unsigned(15 downto 0) := x"BEEF";
		procedure tick is begin wait until rising_edge(clk); end procedure;
	begin
		for i in 0 to 3 loop tick; end loop;

		-- phase 1 : initialiser les 256 quartets par le port A (comparaison off)
		report "phase 1 : initialisation par le port A";
		for a in 0 to 255 loop
			address_a <= std_logic_vector(to_unsigned(a, 8));
			data_a    <= std_logic_vector(to_unsigned(a mod 16, 4));
			wren_a    <= '1';
			tick;
		end loop;
		wren_a <= '0'; tick; tick;
		checking <= true;

		-- phase 2 : relecture par le port A
		report "phase 2 : relecture port A";
		for a in 0 to 255 loop
			address_a <= std_logic_vector(to_unsigned(a, 8)); tick;
		end loop;

		-- phase 3 : LECTURE PAR LE PORT B -- c est ici que la convention des
		-- quartets se verifie : l octet lu doit recomposer les deux quartets
		-- ecrits par le port A, dans le bon ordre.
		report "phase 3 : lecture port B (verifie l ordre des quartets)";
		for b in 0 to 127 loop
			address_b <= std_logic_vector(to_unsigned(b, 7)); tick;
		end loop;

		-- phase 4 : ecriture par le port B, relecture par le port A
		report "phase 4 : ecriture port B puis relecture port A";
		for b in 0 to 127 loop
			address_b <= std_logic_vector(to_unsigned(b, 7));
			data_b    <= std_logic_vector(to_unsigned(b, 8) xor x"3C");
			wren_b    <= '1'; tick;
		end loop;
		wren_b <= '0'; tick;
		for a in 0 to 255 loop
			address_a <= std_logic_vector(to_unsigned(a, 8)); tick;
		end loop;

		-- phase 5 : acces pseudo-aleatoires, UN SEUL port ecrit a la fois
		-- (mixed_ports = DONT_CARE : un recouvrement simultane n a pas de
		-- comportement de reference)
		report "phase 5 : 2000 acces pseudo-aleatoires, un seul port ecrivant";
		for i in 0 to 1999 loop
			seed := seed(14 downto 0) & (seed(15) xor seed(13) xor seed(12) xor seed(10));
			address_a <= std_logic_vector(seed(7 downto 0));
			address_b <= std_logic_vector(seed(14 downto 8));
			data_a    <= std_logic_vector(seed(3 downto 0));
			data_b    <= std_logic_vector(seed(15 downto 8));
			if seed(5) = '1' then
				wren_a <= seed(4); wren_b <= '0';
			else
				wren_a <= '0';     wren_b <= seed(4);
			end if;
			tick;
		end loop;
		wren_a <= '0'; wren_b <= '0';
		for i in 0 to 3 loop tick; end loop;

		checking <= false; wait for 1 ns;
		report "R5101 : comparaisons=" & integer'image(compares)
			& "  divergences=" & integer'image(mismatch);
		if mismatch = 0 and compares > 1000 then
			report "R5101 : EQUIVALENTES -- convention des quartets CONFIRMEE" severity note;
		else
			report "R5101 : ECHEC" severity failure;
		end if;
		running <= false; wait;
	end process;
end sim;
