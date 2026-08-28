-- SYSTEM_ROM -- RAM 8192 x 8, port unique.  REECRITURE PORTABLE (2026-08-13).
-- ============================================================================
-- Remplace la megafonction Altera `altsyncram` par du VHDL infere, que tout
-- synthetiseur mappe sur sa propre memoire bloc.  Interface IDENTIQUE.
--
-- Semantique reproduite depuis les generiques de l original :
--   operation_mode    = SINGLE_PORT
--   latence           = 1 cycle (outdata_reg_a => UNREGISTERED)
--   read_during_write = NEW_DATA_NO_NBE_READ -> ecriture PRIORITAIRE
-- Equivalence verifiee par simulation contre l original (sim/tb_*_equiv.vhd).
-- ============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity SYSTEM_ROM is
	port (
		address : in  std_logic_vector(12 downto 0);
		clock   : in  std_logic := '1';
		data    : in  std_logic_vector(7 downto 0);
		wren    : in  std_logic;
		q       : out std_logic_vector(7 downto 0)
	);
end SYSTEM_ROM;

architecture inferred of SYSTEM_ROM is
	type ram_t is array (0 to 8191) of std_logic_vector(7 downto 0);
	signal ram : ram_t;
	signal q_r : std_logic_vector(7 downto 0) := (others => '0');
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
		end if;
	end process;
	q <= q_r;
end inferred;
