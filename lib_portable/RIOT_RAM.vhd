-- RIOT_RAM -- RAM 256 x 8, port unique, sortie registree.
-- ============================================================================
-- REECRITURE PORTABLE (2026-08-13, branche spartan6-feasibility).
-- Remplace la megafonction Altera `altsyncram` par du VHDL infere, que tout
-- synthetiseur (Quartus, ISE, Vivado, Gowin EDA, Yosys) mappe sur sa propre
-- memoire bloc.  Interface IDENTIQUE a l original : aucun changement d appel.
--
-- Semantique reproduite depuis les generiques de l original :
--   operation_mode    = SINGLE_PORT
--   outdata_reg_a     = CLOCK0                -> sortie REGISTREE
--   read_during_write = NEW_DATA_NO_NBE_READ  -> ecriture PRIORITAIRE : une
--     lecture au meme instant et a la meme adresse qu une ecriture rend la
--     donnee NOUVELLE.  D ou l affectation de `data` a la sortie quand wren=1 ;
--     lire la memoire y rendrait l ancienne valeur.
-- ============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity RIOT_RAM is
	port (
		address : in  std_logic_vector(7 downto 0);
		clock   : in  std_logic := '1';
		data    : in  std_logic_vector(7 downto 0);
		wren    : in  std_logic;
		q       : out std_logic_vector(7 downto 0)
	);
end RIOT_RAM;

architecture inferred of RIOT_RAM is
	type ram_t is array (0 to 255) of std_logic_vector(7 downto 0);
	signal ram : ram_t;
	-- DEUX etages : altsyncram avec outdata_reg_a => CLOCK0 en a deux (registre
	-- interne de la memoire + registre de sortie), donc 2 cycles de latence.
	-- Mesure : avec un seul etage, la simulation d equivalence rendait 2540
	-- divergences sur 2580 -- la sortie arrivait un cycle trop tot.
	signal q_r   : std_logic_vector(7 downto 0) := (others => '0');
	signal q_out : std_logic_vector(7 downto 0) := (others => '0');
begin
	process (clock)
	begin
		if rising_edge(clock) then
			if wren = '1' then
				ram(to_integer(unsigned(address))) <= data;
				q_r <= data;                                  -- ecriture prioritaire
			else
				q_r <= ram(to_integer(unsigned(address)));
			end if;
			q_out <= q_r;                                     -- 2e etage
		end if;
	end process;
	q <= q_out;
end inferred;
