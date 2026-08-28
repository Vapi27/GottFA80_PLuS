-- ---------------------------------------------------------------------------
-- tb_riot_ram_equiv -- equivalence entre la RIOT_RAM d origine (megafonction
-- Altera altsyncram) et la reecriture portable en VHDL infere.
--
-- Les deux instances recoivent EXACTEMENT les memes stimuli au meme instant ;
-- toute divergence de sortie est signalee avec le cycle, l adresse et les deux
-- valeurs.  Le test couvre :
--   1. ecriture puis relecture de chaque adresse (motif adresse XOR constante)
--   2. la latence de sortie (sortie registree : la donnee arrive au cycle N+1)
--   3. la lecture-pendant-ecriture a la MEME adresse -> ecriture prioritaire
--   4. une sequence pseudo-aleatoire d acces melant lectures et ecritures
-- ---------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library orig;

entity tb_riot_ram_equiv is
end tb_riot_ram_equiv;

architecture sim of tb_riot_ram_equiv is
	signal clk     : std_logic := '0';
	signal address : std_logic_vector(7 downto 0) := (others => '0');
	signal data    : std_logic_vector(7 downto 0) := (others => '0');
	signal wren    : std_logic := '0';
	signal q_orig  : std_logic_vector(7 downto 0);
	signal q_port  : std_logic_vector(7 downto 0);

	signal running   : boolean := true;
	signal cycle     : natural := 0;
	signal mismatch  : natural := 0;
	signal compares  : natural := 0;
	signal checking  : boolean := false;
begin
	clk <= not clk after 10 ns when running else '0';

	-- L originale, compilee dans la bibliotheque `orig`
	DUT_ORIG : entity orig.RIOT_RAM
		port map (address => address, clock => clk, data => data, wren => wren, q => q_orig);

	-- La portable, dans `work`
	DUT_PORT : entity work.RIOT_RAM
		port map (address => address, clock => clk, data => data, wren => wren, q => q_port);

	-- Comparateur : sur chaque front montant, une fois l amorcage passe
	CMP : process (clk)
	begin
		if rising_edge(clk) then
			cycle <= cycle + 1;
			if checking then
				compares <= compares + 1;
				if q_orig /= q_port then
					mismatch <= mismatch + 1;
					report "DIVERGENCE cycle=" & integer'image(cycle)
						& "  addr=" & integer'image(to_integer(unsigned(address)))
						& "  orig=" & integer'image(to_integer(unsigned(q_orig)))
						& "  port=" & integer'image(to_integer(unsigned(q_port)))
						severity error;
				end if;
			end if;
		end if;
	end process;

	STIM : process
		variable seed : unsigned(15 downto 0) := x"ACE1";
		procedure tick is begin wait until rising_edge(clk); end procedure;
	begin
		wren <= '0'; address <= (others => '0'); data <= (others => '0');
		for i in 0 to 3 loop tick; end loop;

		-- 1) ecrire les 256 adresses  (comparaison DESACTIVEE : avant ecriture la
		--    memoire originale sort des U non initialises, ce qui n est pas un
		--    desaccord de comportement mais une absence de valeur definie)
		report "phase 1 : ecriture des 256 adresses";
		for a in 0 to 255 loop
			address <= std_logic_vector(to_unsigned(a, 8));
			data    <= std_logic_vector(to_unsigned(a, 8) xor x"5A");
			wren    <= '1';
			tick;
		end loop;
		wren <= '0';
		tick; tick;                       -- vider le pipeline a 2 etages
		checking <= true;                 -- a partir d ici toute valeur est definie

		-- 2) relire les 256 adresses (sortie registree : on lit au cycle suivant)
		report "phase 2 : relecture des 256 adresses";
		for a in 0 to 255 loop
			address <= std_logic_vector(to_unsigned(a, 8));
			tick;
		end loop;

		-- 3) lecture-pendant-ecriture a la meme adresse
		report "phase 3 : lecture pendant ecriture (ecriture prioritaire)";
		for a in 0 to 31 loop
			address <= std_logic_vector(to_unsigned(a, 8));
			data    <= std_logic_vector(to_unsigned(a, 8) xor x"F0");
			wren    <= '1';
			tick;
			wren <= '0';
			tick;
		end loop;

		-- 4) sequence pseudo-aleatoire
		report "phase 4 : 2000 acces pseudo-aleatoires";
		for i in 0 to 1999 loop
			-- LFSR 16 bits
			seed := seed(14 downto 0) & (seed(15) xor seed(13) xor seed(12) xor seed(10));
			address <= std_logic_vector(seed(7 downto 0));
			data    <= std_logic_vector(seed(15 downto 8));
			wren    <= seed(3);
			tick;
		end loop;
		wren <= '0';
		for i in 0 to 3 loop tick; end loop;

		checking <= false;
		wait for 1 ns;
		report "=====================================================";
		report "comparaisons : " & integer'image(compares);
		report "divergences  : " & integer'image(mismatch);
		-- Garde alignee sur les 4 autres bancs d equivalence : un banc qui ne
		-- compare RIEN sortirait vert sans la clause `compares > 1000`.
		if mismatch = 0 and compares > 1000 then
			report "RESULTAT : les deux memoires sont EQUIVALENTES" severity note;
		else
			report "RESULTAT : ECHEC (divergences ou trop peu de comparaisons)" severity failure;
		end if;
		report "=====================================================";
		running <= false;
		wait;
	end process;
end sim;
