-- R5101 -- RAM double port a largeurs mixtes.  REECRITURE PORTABLE, VERSION SCINDEE.
-- ============================================================================
-- 2026-08-13, branche spartan6-feasibility.
--
-- POURQUOI CETTE VERSION.  La premiere reecriture stockait un seul tableau de
-- 256 quartets, adresse en quartets par le port A et en octets par le port B.
-- Equivalence prouvee en simulation (2 773 comparaisons, 0 divergence) MAIS
-- Quartus ne savait pas l inferer en memoire bloc : elle partait en logique et
-- le design ne rentrait plus (7 162 noeuds combinatoires pour 6 272).
-- L attribut `ramstyle => "M9K"` n y changeait rien -- verifie en build --clean.
--
-- IDEE.  Scinder en DEUX memoires de MEME largeur, 128 x 4 chacune :
--   ram_even(i) = le quartet vu par le port A a l adresse PAIRE  2*i
--   ram_odd (i) = le quartet vu par le port A a l adresse IMPAIRE 2*i+1
-- Le port A choisit l une des deux par address_a(0) ; le port B lit ou ecrit
-- les deux EN PARALLELE a l index address_b.  Les deux memoires deviennent
-- ainsi de simples doubles ports a largeur uniforme -- la structure la plus
-- banale qui soit, reconnue par tous les synthetiseurs.
--
-- Convention des quartets CONFIRMEE en simulation contre l original :
--   octet B = quartet impair (poids fort) & quartet pair (poids faible)
--
-- Semantique conservee : outdata_reg = UNREGISTERED sur les deux ports -> 1
-- cycle de latence ; read_during_write = NEW_DATA -> ecriture prioritaire ;
-- mixed_ports = DONT_CARE -> aucun comportement garanti si les deux ports
-- ecrivent au meme endroit au meme instant, donc rien a reproduire la-dessus.
-- ============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity R5101 is
	port (
		address_a : in  std_logic_vector(7 downto 0);
		address_b : in  std_logic_vector(6 downto 0);
		clock     : in  std_logic := '1';
		data_a    : in  std_logic_vector(3 downto 0);
		data_b    : in  std_logic_vector(7 downto 0);
		wren_a    : in  std_logic := '0';
		wren_b    : in  std_logic := '0';
		q_a       : out std_logic_vector(3 downto 0);
		q_b       : out std_logic_vector(7 downto 0)
	);
end R5101;

architecture inferred of R5101 is
	type nib_t is array (0 to 127) of std_logic_vector(3 downto 0);
	signal ram_even : nib_t;    -- quartets d adresse A paire
	signal ram_odd  : nib_t;    -- quartets d adresse A impaire

	attribute ramstyle  : string;            -- Intel/Altera
	attribute ram_style : string;            -- Xilinx et autres
	attribute ramstyle  of ram_even : signal is "M9K";
	attribute ramstyle  of ram_odd  : signal is "M9K";
	attribute ram_style of ram_even : signal is "block";
	attribute ram_style of ram_odd  : signal is "block";

	signal q_a_r : std_logic_vector(3 downto 0) := (others => '0');
	signal q_b_r : std_logic_vector(7 downto 0) := (others => '0');
begin
	process (clock)
		variable ia  : integer range 0 to 127;
		variable sel : std_logic;
		variable ib  : integer range 0 to 127;
	begin
		if rising_edge(clock) then
			ia  := to_integer(unsigned(address_a(7 downto 1)));
			sel := address_a(0);
			ib  := to_integer(unsigned(address_b));

			-- ---- ecritures ----------------------------------------------
			if wren_a = '1' then
				if sel = '0' then ram_even(ia) <= data_a;
				else              ram_odd(ia)  <= data_a;
				end if;
			end if;
			if wren_b = '1' then
				ram_even(ib) <= data_b(3 downto 0);
				ram_odd(ib)  <= data_b(7 downto 4);
			end if;

			-- ---- lectures, ecriture prioritaire par port -----------------
			if wren_a = '1' then
				q_a_r <= data_a;
			elsif sel = '0' then
				q_a_r <= ram_even(ia);
			else
				q_a_r <= ram_odd(ia);
			end if;

			if wren_b = '1' then
				q_b_r <= data_b;
			else
				q_b_r <= ram_odd(ib) & ram_even(ib);
			end if;
		end if;
	end process;

	q_a <= q_a_r;
	q_b <= q_b_r;
end inferred;
