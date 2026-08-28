library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library orig;

entity tb_GAME_ROM_equiv is
end tb_GAME_ROM_equiv;

architecture sim of tb_GAME_ROM_equiv is
	signal clk : std_logic := '0';
	signal address : std_logic_vector(10 downto 0) := (others => '0');
	signal data    : std_logic_vector(7 downto 0) := (others => '0');
	signal wren    : std_logic := '0';
	signal q_orig, q_port : std_logic_vector(7 downto 0);
	signal running : boolean := true;
	signal cycle, mismatch, compares : natural := 0;
	signal checking : boolean := false;
begin
	clk <= not clk after 10 ns when running else '0';
	D1 : entity orig.GAME_ROM port map (address=>address, clock=>clk, data=>data, wren=>wren, q=>q_orig);
	D2 : entity work.GAME_ROM port map (address=>address, clock=>clk, data=>data, wren=>wren, q=>q_port);

	CMP : process (clk) begin
		if rising_edge(clk) then
			cycle <= cycle + 1;
			if checking then
				compares <= compares + 1;
				if q_orig /= q_port then
					mismatch <= mismatch + 1;
					report "DIVERGENCE cycle=" & integer'image(cycle)
						& " addr=" & integer'image(to_integer(unsigned(address)))
						& " orig=" & integer'image(to_integer(unsigned(q_orig)))
						& " port=" & integer'image(to_integer(unsigned(q_port))) severity error;
				end if;
			end if;
		end if;
	end process;

	STIM : process
		variable seed : unsigned(15 downto 0) := x"ACE1";
		procedure tick is begin wait until rising_edge(clk); end procedure;
	begin
		for i in 0 to 3 loop tick; end loop;
		-- phase 1 : initialiser toute la memoire (comparaison desactivee : avant
		-- ecriture l originale sort des U, absence de valeur et non desaccord)
		for a in 0 to 2047 loop
			address <= std_logic_vector(to_unsigned(a, 11));
			data <= std_logic_vector(to_unsigned(a mod 256, 8) xor x"5A");
			wren <= '1'; tick;
		end loop;
		wren <= '0'; tick; tick;
		checking <= true;
		-- phase 2 : relecture sequentielle
		for a in 0 to 2047 loop
			address <= std_logic_vector(to_unsigned(a, 11)); tick;
		end loop;
		-- phase 3 : lecture pendant ecriture
		for a in 0 to 31 loop
			address <= std_logic_vector(to_unsigned(a, 11));
			data <= std_logic_vector(to_unsigned(a, 8) xor x"F0");
			wren <= '1'; tick; wren <= '0'; tick;
		end loop;
		-- phase 4 : acces pseudo-aleatoires
		for i in 0 to 1999 loop
			seed := seed(14 downto 0) & (seed(15) xor seed(13) xor seed(12) xor seed(10));
			address <= std_logic_vector(resize(seed(10 downto 0), 11));
			data <= std_logic_vector(seed(15 downto 8));
			wren <= seed(3); tick;
		end loop;
		wren <= '0'; for i in 0 to 3 loop tick; end loop;
		checking <= false; wait for 1 ns;
		report "GAME_ROM : comparaisons=" & integer'image(compares) & "  divergences=" & integer'image(mismatch);
		if mismatch = 0 and compares > 1000 then
			report "GAME_ROM : EQUIVALENTES" severity note;
		else
			report "GAME_ROM : ECHEC (divergences ou trop peu de comparaisons)" severity failure;
		end if;
		running <= false; wait;
	end process;
end sim;
