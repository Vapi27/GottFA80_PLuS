-- SB_RAM -- RAM 128 x 8, port unique.  REECRITURE PORTABLE (2026-08-13).
-- ============================================================================
-- Remplace la megafonction Altera `altsyncram` par du VHDL infere, que tout
-- synthetiseur mappe sur sa propre memoire bloc.  Interface IDENTIQUE.
--
-- Semantique reproduite depuis les generiques de l original :
--   operation_mode    = SINGLE_PORT
--   latence           = 2 cycles (outdata_reg_a => CLOCK0)
--   read_during_write = NEW_DATA_NO_NBE_READ -> ecriture PRIORITAIRE
-- Equivalence verifiee par simulation contre l original (sim/tb_*_equiv.vhd).
-- ============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity SB_RAM is
	port (
		address : in  std_logic_vector(6 downto 0);
		clock   : in  std_logic := '1';
		data    : in  std_logic_vector(7 downto 0);
		wren    : in  std_logic;
		q       : out std_logic_vector(7 downto 0)
	);
end SB_RAM;

architecture inferred of SB_RAM is
	type ram_t is array (0 to 127) of std_logic_vector(7 downto 0);
	signal ram : ram_t;

	-- Forcer la memoire BLOC.  Sans cet attribut, Quartus implemente les petites
	-- memoires en bascules (choix d optimisation) : mesure du 13/08, SB_RAM et
	-- R5101 en logique faisaient passer le combinatoire de 4 772 a 7 153 et le
	-- design ne rentrait plus.  Les deux attributs coexistent : chaque outil
	-- ignore celui de l autre.
	attribute ramstyle : string;                 -- Intel/Altera
	attribute ram_style : string;                -- Xilinx / autres
	attribute ramstyle  of ram : signal is "M9K";
	attribute ram_style of ram : signal is "block";
	signal q_r : std_logic_vector(7 downto 0) := (others => '0');
	signal q_out : std_logic_vector(7 downto 0) := (others => '0');
begin
	process (clock)
	begin
		if rising_edge(clock) then
			if wren = '1' then
				ram(to_integer(unsigned(address))) <= data;
				q_r <= data;                        -- ecriture prioritaire
			else
				q_r <= ram(to_integer(unsigned(address)));
			end if;
			q_out <= q_r;                       -- 2e etage (outdata_reg_a)
		end if;
	end process;
	q <= q_out;
end inferred;
