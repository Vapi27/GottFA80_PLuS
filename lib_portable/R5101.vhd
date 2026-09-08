-- ============================================================================
-- R5101 -- RAM CMOS 5101 du System 80 (256 x 4 bits), vue en DOUBLE PORT VRAI.
--
-- Port A : le 6502, par quartets (address_a(0) choisit pair/impair).
-- Port B : la restauration/sauvegarde EEPROM, par octets (les deux quartets).
--
-- 🔴 DEUX ECRIVAINS, ET C'EST NECESSAIRE. Une version precedente multiplexait les
-- ecritures en donnant la priorite au port B, sur la premisse ecrite noir sur
-- blanc que « les deux ne peuvent pas ecrire en meme temps dans la machine ».
-- CETTE PREMISSE ETAIT FAUSSE, et jamais verifiee. SYS80.vhd cable
-- `wren_b => wr_ram`, et le module EEprom se declenche sur `game_over_relay`,
-- `test_sw` et `credit_sw` : la rafale EEPROM tombe donc EXACTEMENT a la fin de
-- partie, pendant que le 6502 initialise son attract. Toutes ses ecritures vers
-- la CMOS etaient jetees -- y compris a des adresses DIFFERENTES, que l'original
-- appliquait. Symptome sur la machine : l'attract demarre (2-3 lampes) puis
-- s'arrete, alors qu'une partie se deroule parfaitement. Mesure au banc
-- tb_croise : 65 comparaisons, 65 divergences (2026-09-07).
--
-- L'original ne laisse indefini QUE le cas « les deux ecrivent AU MEME endroit »
-- (mixed_ports = DONT_CARE). Pour deux adresses differentes il applique les deux.
--
-- FORME RETENUE : le modele canonique du double port vrai -- une VARIABLE
-- PARTAGEE par tableau, et UN PROCESSUS PAR PORT ET PAR TABLEAU, sans condition
-- sur la cible : `if we then RAM(a) := d; end if;  q <= RAM(a);` et rien d'autre.
-- Ecrire conditionnellement dans l'un OU l'autre tableau depuis un meme processus
-- suffit a faire abandonner XST : mesure du 2026-09-07, 6631 LUT au lieu de 3898,
-- le design ne rentrait plus. Le multiplexage (pair/impair, quartets) est donc
-- SORTI des processus de RAM.
-- C'est ce que XST et Quartus reconnaissent pour mettre le tableau en bloc RAM
-- avec deux ports d'ecriture, et ca rend la semantique de l'original la ou elle
-- est definie. Mon objection d'alors -- « visible un cycle trop tot » -- ne
-- portait que sur le cas meme-adresse, precisement celui qui est DONT_CARE.
--
-- ⚠️ TOUTE MODIFICATION SE REJOUE SUR LES DEUX BANCS :
--      sim/tb_R5101_equiv.vhd  (sequentiel, un seul port ecrivant)
--      tb_croise               (LES DEUX PORTS ECRIVANT -- le cas de la machine)
--    Le premier passait alors que le design etait casse : il ne couvre pas le
--    croisement. Un banc qui passe ne prouve que ce qu'il regarde.
-- ============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity R5101 is
	port(
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
	shared variable ram_even : nib_t;
	shared variable ram_odd  : nib_t;

	signal ia, ib : integer range 0 to 127;
	signal sel    : std_logic;
	signal sel_d  : std_logic := '0';

	signal qae, qao, qbe, qbo : std_logic_vector(3 downto 0) := (others => '0');
begin
	ia  <= to_integer(unsigned(address_a(7 downto 1)));
	sel <= address_a(0);
	ib  <= to_integer(unsigned(address_b));

	-- Quatre blocs STRICTEMENT au modele : une ecriture inconditionnelle en cible,
	-- une lecture rangee. Rien d'autre, sinon l'inference tombe.
	EVEN_A : process (clock) begin
		if rising_edge(clock) then
			if wren_a = '1' and sel = '0' then ram_even(ia) := data_a; end if;
			qae <= ram_even(ia);
		end if;
	end process;

	EVEN_B : process (clock) begin
		if rising_edge(clock) then
			if wren_b = '1' then ram_even(ib) := data_b(3 downto 0); end if;
			qbe <= ram_even(ib);
		end if;
	end process;

	ODD_A : process (clock) begin
		if rising_edge(clock) then
			if wren_a = '1' and sel = '1' then ram_odd(ia) := data_a; end if;
			qao <= ram_odd(ia);
		end if;
	end process;

	ODD_B : process (clock) begin
		if rising_edge(clock) then
			if wren_b = '1' then ram_odd(ib) := data_b(7 downto 4); end if;
			qbo <= ram_odd(ib);
		end if;
	end process;

	-- Le modele est write-first : apres une ecriture, la lecture rend deja la
	-- nouvelle donnee. C'est exactement l'ecriture prioritaire de l'original, sans
	-- avoir a la recreer par un contournement.
	SEL_R : process (clock) begin
		if rising_edge(clock) then sel_d <= sel; end if;
	end process;

	q_a <= qao when sel_d = '1' else qae;
	q_b <= qbo & qbe;
end inferred;
