--
-- EEprom.vhd 
-- read/write eeprom content to and from ram
-- for BallyFA
-- bontango 09.2020
--
-- eeprom content is red into ram at start of routine ( reset going low)
-- we use a dual port ram in main, with 4bit and 8bit outputs
--
-- code is specific for SPI EEPROM M95640-R  <-- EN-TETE PERIME, cf. ci-dessous
-- 2026-09-08 : la puce REELLEMENT montee sur la carte porteuse est une
-- M95256-WMN (256 Kbit = 32 Ko, adresse sur 15 bits), marquage releve sur le
-- boitier. Le module Smart FA lui-meme n'en porte aucune : CS_EEprom sort sur
-- P4.21 vers la porteuse. Cette taille N'EST PAS UN DETAIL : le second banc
-- ci-dessous vit a 0x2000, un bit d'adresse qui n'existerait pas sur une
-- M95640 de 8 Ko -- il retomberait sur le premier banc et ECRASERAIT la copie
-- saine. Verifier le marquage avant de porter ce fichier sur une autre carte.
-- fix SPI mode : C remains at 0 for (CPOL=0, CPHA=0)
-- to save memory we do 16 rounds a 8 Byte, even the eeprom has a 32byte page size
--
-- v 0.1
-- v 0.2 selection 6bit version for GottFA
-- v 0.3 added second delay for trigger 
-- v 0.3a with init set we do an initial write at beginning
-- v 0.4 aded do_not_enable_SS
--
-- v 0.5 (Pstore, 2026-09-08) DEUX EMPLACEMENTS ALTERNES.
--
-- LE DEFAUT CORRIGE. La sauvegarde parcourait les 128 octets un par un, EN PLACE,
-- sans somme de controle ni marqueur de validite. Une coupure d'alimentation en
-- cours de route -- une demi-seconde de fenetre, a chaque fin de partie et a
-- chaque front des boutons test et credit -- laissait un bloc a moitie neuf, que
-- le demarrage suivant relisait comme s'il etait bon. Symptome observe sur un
-- Volcano : l'attract du PLATEAU reste noir alors que la partie se lance et que
-- les lampes marchent en jeu. Intermittent, donc regulierement impute au
-- bitstream fraichement grave.
--
-- LA CORRECTION. Deux bancs de 128 octets par jeu, plus UN octet de pointeur :
--     banc 0    : 0x0000 + selection*128     (la ou vivaient les donnees : les
--                                             anciennes EEPROM restent lisibles)
--     banc 1    : 0x2000 + selection*128
--     pointeur  : 0x4000 + selection*128     0xA0 = banc 0, 0xA1 = banc 1
-- On ecrit toujours dans le banc INACTIF, puis on bascule le pointeur en DERNIER.
-- Une coupure pendant les donnees laisse le pointeur sur l'ancien banc, intact.
-- Une coupure pendant le pointeur ne peut donner que l'ancienne valeur, la
-- nouvelle, ou une valeur batarde -- et les deux premieres designent un banc
-- COMPLET, la troisieme fait repartir de zero. Aucune issue ne rend du contenu
-- a moitie ecrit. La fenetre dangereuse passe de 128 octets a UN.
-- Cout : 24 Ko des 32 Ko de la M95256, contre 8 Ko avant.
--
-- ⚠️ Un pointeur absent (EEPROM jamais ecrite par cette version, donc 0xFF) est
--    traite comme invalide : le PREMIER demarrage apres cette mise a jour repart
--    donc sur des reglages d'usine, une fois.
--
-- SECOND DEFAUT CORRIGE ICI. L'effacement demande par le DIP d'option sautait de
-- Check_dip directement a send_write_request, SANS passer par Write_enable : la
-- M95256 exige un 0x06 avant chaque 0x02, elle ignorait donc purement et
-- simplement cette ecriture. L'effacement ne survivait pas au redemarrage.
-- Il ecrit desormais un pointeur INVALIDE -- un seul octet, et c'est tout ce
-- qu'il faut pour que le demarrage suivant reparte de zero.

library IEEE;
use IEEE.std_logic_1164.all;
--use IEEE.std_logic_arith.all;
--use IEEE.std_logic_unsigned.all;
use IEEE.numeric_std.all;

	entity EEprom is
		port(		
		i_Clk	: in std_logic;
		-- sd card
		address_eeprom	: buffer  std_logic_vector(6 downto 0); -- 128 words a 8 bit (dual port ram)
		data_eeprom	: out std_logic_vector(7 downto 0);
		q_ram	: in std_logic_vector(7 downto 0);
		wr_ram :  out std_logic;				
		-- Control/Data Signals,
		i_Rst_L : in std_logic;     -- FPGA Reset		
		-- PMOD SPI Interface
		o_SPI_Clk  : out std_logic;
		i_SPI_MISO : in std_logic;
		o_SPI_MOSI : out std_logic;
		o_SPI_CS_n : out std_logic;
		-- selection
		selection : in std_logic_vector(5 downto 0);		
		--trigger for writing ram into eeprom
		w_trigger : STD_LOGIC_VECTOR (3 DOWNTO 0);		
		-- 0 if Dip is set -> no EEprom read
		i_init_Flag : in std_logic;
			-- signal to outside
		is_active : out std_logic
		);
    end EEprom;
	 
   architecture Behavioral of EEprom is
		type STATE_T is ( Check_dip, send_read_request, wait_for_read, wait_for_Master,
								Delay, Delay2, Idle, Write_enable, wait_for_Cmd_done, wait_for_Master_I, 
								send_write_request, wait_for_Write_done,  wait_for_Master_II, 
								get_status_reg, wait_for_get_status_reg, wait_for_Master_III, 
								check_WP_bit, next_write ); 
				
		signal state : STATE_T;       
		
								
		-- SPI stuff				
		signal TX_Data_W : std_LOGIC_VECTOR ( 31 downto 0); -- 4 Bytes ( 3 cmd plus 1 Data) 32bits
		signal RX_Data_W : std_LOGIC_VECTOR ( 31 downto 0);
		signal TX_Start_W : std_LOGIC;
		signal TX_Done_W : std_LOGIC;
		signal MOSI_W : std_LOGIC;
		signal SS_W :  std_LOGIC;
		signal SPI_Clk_W :  std_LOGIC;

		signal TX_Data_R : std_LOGIC_VECTOR ( 31 downto 0); -- 4 Bytes ( 3 cmd plus 1 Data) 32bits
		signal RX_Data_R : std_LOGIC_VECTOR ( 31 downto 0);
		signal TX_Start_R : std_LOGIC;
		signal TX_Done_R : std_LOGIC;
		signal MOSI_R : std_LOGIC;
		signal SS_R :  std_LOGIC;
		signal SPI_Clk_R :  std_LOGIC;
		
		signal TX_Data_Stat : std_LOGIC_VECTOR ( 15 downto 0); -- 2 Bytes ( 1 cmd plus 1 status)
		signal RX_Data_Stat : std_LOGIC_VECTOR ( 15 downto 0);
		signal TX_Start_Stat : std_LOGIC;
		signal TX_Done_Stat : std_LOGIC;
		signal MOSI_Stat : std_LOGIC;
		signal SS_Stat :  std_LOGIC;
		signal SPI_Clk_Stat :  std_LOGIC;

		signal TX_Data_Cmd : std_LOGIC_VECTOR ( 7 downto 0); -- 1 Byte data
		signal RX_Data_Cmd : std_LOGIC_VECTOR ( 7 downto 0);
		signal TX_Start_Cmd : std_LOGIC;
		signal TX_Done_Cmd : std_LOGIC;
		signal MOSI_Cmd : std_LOGIC;
		signal SS_Cmd :  std_LOGIC;
		signal SPI_Clk_Cmd :  std_LOGIC;
					
		signal WIP_bit :  std_LOGIC; -- write in progress
		-- we react to edges of triggers, so we need to remember
		signal old_w_trigger : std_LOGIC_VECTOR ( 3 downto 0);
		
		signal c_count : integer range 0 to 500000000;

		-- DEUX EMPLACEMENTS ALTERNES (voir l'en-tete)
		constant PTR_A : std_logic_vector(7 downto 0) := x"A0"; -- banc 0 valide
		constant PTR_B : std_logic_vector(7 downto 0) := x"A1"; -- banc 1 valide
		signal bank_cur : std_logic;                     -- banc a LIRE
		signal bank_wr  : std_logic;                     -- banc a ECRIRE (l'autre)
		signal rd_ptr   : std_logic;                     -- la lecture en cours est celle du pointeur
		signal wr_ptr   : std_logic;                     -- l'ecriture en cours est celle du pointeur
		signal boot_wr  : std_logic;                     -- l'ecriture vient de l'effacement au demarrage
		signal wr_zero  : std_logic;                     -- ecrire des ZEROS et non le contenu de la RAM
		signal ptr_seen : std_logic_vector(7 downto 0);  -- pointeur relu
		signal ptr_new  : std_logic_vector(7 downto 0);  -- pointeur a ecrire
		
	begin		
	
		
	-- signals for the four SPI Master
	o_SPI_MOSI <=	
	MOSI_R when TX_Start_R = '1' else
	MOSI_W when TX_Start_W = '1' else
	MOSI_Stat when TX_Start_Stat = '1' else
	MOSI_Cmd when TX_Start_Cmd = '1' else
	'0';

	o_SPI_Clk <=
	SPI_Clk_R when TX_Start_R = '1' else
	SPI_Clk_W when TX_Start_W = '1' else
	SPI_Clk_Stat when TX_Start_Stat = '1' else
	SPI_Clk_Cmd when TX_Start_Cmd = '1' else
	'0';

	o_SPI_CS_n <=
	SS_R when TX_Start_R = '1' else
	SS_W when TX_Start_W = '1' else
	SS_Stat when TX_Start_Stat = '1' else
	SS_Cmd when TX_Start_Cmd = '1' else
	'1';


EEPROM_WRITE: entity work.SPI_Master
    generic map (      
      Laenge => 32)
    port map (
			  TX_Data  => TX_Data_W,
           RX_Data  => RX_Data_W,
           MOSI     => MOSI_W,
           MISO     => i_SPI_MISO,
           SCLK     => SPI_Clk_W,
           SS       => SS_W,
           TX_Start => TX_Start_W,
           TX_Done  => TX_Done_W,
           clk      => i_Clk,
			  do_not_disable_SS => '0',
			  do_not_enable_SS => '0'
      );
		
EEPROM_READ: entity work.SPI_Master
    generic map (      
      Laenge => 32)
    port map (
			  TX_Data  => TX_Data_R,
           RX_Data  => RX_Data_R,
           MOSI     => MOSI_R,
           MISO     => i_SPI_MISO,
           SCLK     => SPI_Clk_R,
           SS       => SS_R,
           TX_Start => TX_Start_R,
           TX_Done  => TX_Done_R,
           clk      => i_Clk,
			  do_not_disable_SS => '0',
			  do_not_enable_SS => '0'
      );

EEPROM_STAT: entity work.SPI_Master
    generic map (      
      Laenge => 16)
    port map (
			  TX_Data  => TX_Data_Stat,
           RX_Data  => RX_Data_Stat,
           MOSI     => MOSI_Stat,
           MISO     => i_SPI_MISO,
           SCLK     => SPI_Clk_Stat,
           SS       => SS_Stat,
           TX_Start => TX_Start_Stat,
           TX_Done  => TX_Done_Stat,
           clk      => i_Clk,
			  do_not_disable_SS => '0',
			  do_not_enable_SS => '0'			  
      );

EEPROM_CMD: entity work.SPI_Master
    generic map (      
      Laenge => 8)
    port map (
			  TX_Data  => TX_Data_Cmd,
           RX_Data  => RX_Data_Cmd,
           MOSI     => MOSI_Cmd,
           MISO     => i_SPI_MISO,
           SCLK     => SPI_Clk_Cmd,
           SS       => SS_Cmd,
           TX_Start => TX_Start_Cmd,
           TX_Done  => TX_Done_Cmd,
           clk      => i_Clk,
			  do_not_disable_SS => '0',
			  do_not_enable_SS => '0'			  
      );
		
EEPROM: process (i_Clk, w_trigger, i_Rst_L)
			begin
			if i_Rst_L = '0' then --Reset condidition (reset_l)    
				TX_Start_R <= '0';				
				TX_Start_W <= '0';				
				TX_Start_Cmd <= '0';				
				TX_Start_Stat <= '0';				
				address_eeprom <= "0000000";
				wr_ram <= '0';				
				c_count <= 0;
				is_active <= '0';
				bank_cur <= '0'; bank_wr <= '1';
				rd_ptr <= '0'; wr_ptr <= '0'; boot_wr <= '0'; wr_zero <= '0';
				ptr_seen <= (others => '0'); ptr_new <= (others => '0');
				state <= Check_dip;    				
			elsif rising_edge(i_Clk) then
				case state is
				-- STATE MASCHINE ----------------
				when Check_dip => -- check dip switch if we need to read eeprom
				   if i_init_Flag = '1' then
						-- On lit d'abord le POINTEUR, il dit quel banc est complet.
						rd_ptr <= '1';
						address_eeprom <= "0000000";
						state <= send_read_request;
					else
						-- EFFACEMENT DEMANDE PAR LE DIP D'OPTION.
						-- On n'ecrit pas 128 octets de zeros : on rend le POINTEUR
						-- invalide, un seul octet, et le demarrage suivant ne lira
						-- aucun banc. L'ancien code sautait ici a send_write_request
						-- SANS write-enable, donc la M95256 ignorait l'ecriture et
						-- l'effacement ne survivait pas au redemarrage.
						-- 🔴 UNE PREMIERE VERSION N'ECRIVAIT QU'UN POINTEUR INVALIDE, en
						-- comptant sur une RAM deja a zero. C'est FAUX : la RAM n'est a
						-- zero qu'apres une RECONFIGURATION du FPGA. Sur un simple appui
						-- reset elle garde son contenu, et comme le code ne lit rien il ne
						-- l'ecrase pas non plus : l'effacement ne faisait alors RIEN.
						-- Defaut introduit puis corrige le 2026-09-08 -- il a coute une
						-- soiree, parce qu'on ne pouvait plus reinitialiser la machine
						-- entre deux essais et que tout paraissait definitivement casse.
						-- NE JAMAIS faire dependre un effacement de l'etat SUPPOSE d'une RAM.
						boot_wr <= '1'; wr_ptr <= '0'; wr_zero <= '1';
						bank_wr <= '0';
						address_eeprom <= "0000000";
						state <= Write_enable;
					end if;
					
				when send_read_request =>	
					TX_Data_R(31 downto 24) <= "00000011"; -- cmd read from memory array
					-- Adresse 16 bits = 0 & region & banc & selection(6) & offset(7) :
					--   b22 = region pointeur (0x4000), b21 = numero de banc (0x2000)
					TX_Data_R(23) <= '0';
					TX_Data_R(22) <= rd_ptr;
					TX_Data_R(21) <= bank_cur and not rd_ptr;
					TX_Data_R(20 downto 15) <= selection;
					-- last 7 bits is address
				   TX_Data_R(14 downto 8) <= address_eeprom;
					TX_Start_R <= '1'; -- set flag for sending byte		
					state <= wait_for_read;					
										
				when wait_for_read =>											
						if (TX_Done_R = '1') then -- Master sets TX_Done when TX is done ;-)
							TX_Start_R <= '0'; -- reset flag 		
							if rd_ptr = '1' then
								ptr_seen <= RX_Data_R(7 downto 0);
							else
								--put red data into ram
								data_eeprom <= RX_Data_R(7 downto 0);
								wr_ram <= '1';
							end if;
							state <= wait_for_Master;							
						end if;
						
				when wait_for_Master =>							
						if (TX_Done_R = '0') then -- Master sets back TX_Done when ready again
							-- set back write flag for ram
							wr_ram <= '0';
							if rd_ptr = '1' then
								-- LE POINTEUR VIENT D'ARRIVER : il designe le banc complet.
								rd_ptr <= '0';
								address_eeprom <= "0000000";
								if ptr_seen = PTR_A then
									bank_cur <= '0'; bank_wr <= '1';
									state <= send_read_request;
								elsif ptr_seen = PTR_B then
									bank_cur <= '1'; bank_wr <= '0';
									state <= send_read_request;
								else
									-- Pointeur absent (0xFF sur une EEPROM jamais ecrite par
									-- cette version) ou batard : AUCUN banc n'est sur. On ne
									-- lit rien, la RAM reste a zero -- exactement l'effet d'un
									-- effacement, plutot que de servir du contenu douteux.
									bank_cur <= '0'; bank_wr <= '1';
									state <= Delay;
								end if;
							else
							   -- increment address
							   address_eeprom <= std_logic_vector( unsigned(address_eeprom) + 1 );							
								if address_eeprom = "1111111" then 
								  state <= Delay; -- read done, goto (possible) write
								else
								  state <= send_read_request; -- next round 
								end if;
							end if;
						end if;							

				 when Delay => -- wait 10 seconds before react to first trigger
					if c_count < 500000000 then
						c_count <= c_count +1;
					else	
						c_count <= 0;						
						old_w_trigger <= w_trigger;
						state <= Idle;
					end if;
					
				 when Idle => 							 
					if w_trigger /= old_w_trigger then					
							old_w_trigger <= w_trigger;
							address_eeprom <= "0000000";									
							wr_ptr <= '0';   -- les DONNEES d'abord, le pointeur en dernier
							state <= Delay2;				
					else
							is_active <= '0';				
					end if;	

				when Delay2 => -- wait 100us then check status of trigger again (glitch?)
					if c_count < 5000 then
						c_count <= c_count +1;
					else	
						c_count <= 0;
						if w_trigger = old_w_trigger then -- trigger stable
							is_active <= '1';
							state <= Write_enable;
						else
							old_w_trigger <= w_trigger; -- trigger NOT stable
							state <= Idle;
						end if;
					end if;															
					
				when Write_enable => -- enable writing					
					TX_Data_Cmd <= "00000110"; -- write enable					
					TX_Start_Cmd <= '1'; -- set flag for sending byte											
					state <= wait_for_Cmd_done;					
					
				when wait_for_Cmd_done =>													
					if (TX_Done_Cmd = '1') then				
						TX_Start_Cmd <= '0'; -- reset flag 
						state <= wait_for_Master_I;														
					end if;											 
					
				when wait_for_Master_I =>													
					if (TX_Done_Cmd = '0') then										
						state <= send_write_request;														
					end if;											 
										
				when send_write_request =>
				   --header is write command plus address to write
					TX_Data_W(31 downto 24) <= "00000010"; -- cmd write memory array address 
					-- Meme decoupage qu'en lecture : b22 = region pointeur, b21 = banc.
					-- On ecrit TOUJOURS dans le banc inactif (bank_wr), jamais celui que
					-- le pointeur designe -- c'est toute la protection.
					TX_Data_W(23) <= '0';
					TX_Data_W(22) <= wr_ptr;
					TX_Data_W(21) <= bank_wr and not wr_ptr;
					TX_Data_W(20 downto 15) <= selection;
					-- last 7 bits is address
				   TX_Data_W(14 downto 8) <= address_eeprom;
					-- data from ram, ou la valeur du pointeur
					if wr_ptr = '1' then
						TX_Data_W ( 7 downto 0 ) <= ptr_new;
					elsif wr_zero = '1' then
						TX_Data_W ( 7 downto 0 ) <= x"00";   -- effacement : des ZEROS reels
					else
						TX_Data_W ( 7 downto 0 ) <= q_ram;
					end if;
					TX_Start_W <= '1'; -- set flag for sending byte				
					state <= wait_for_Write_done;					
		
				when wait_for_Write_done =>							
						if (TX_Done_W = '1') then							
							TX_Start_W <= '0'; -- reset flag 														
							state <= wait_for_Master_II;														
						end if;							
						
				when wait_for_Master_II =>													
					if (TX_Done_W = '0') then										
						state <= get_status_reg;														
					end if;											 
						
				when get_status_reg =>		
						-- write should now be in now in progress, check when done ( appr. 5ms according to datasheet)				
						TX_Data_Stat <= "0000010100000000"; -- read status reg (second 8 bit to ignore)
						TX_Start_Stat <= '1'; -- set flag for sending byte						
						state <= wait_for_get_status_reg;					
					
				when wait_for_get_status_reg =>
						if (TX_Done_Stat = '1') then
							TX_Start_Stat <= '0'; -- reset flag 
							state <= wait_for_Master_III;								
						end if;
						
				when wait_for_Master_III =>													
					if (TX_Done_Stat = '0') then			
							-- bit0 of status reg is WIP (write in progress) 
							WIP_bit <= RX_Data_Stat(0);
							state <= check_WP_bit;					
				   end if;
		
				when check_WP_bit =>													
							if WIP_bit = '0' then 
							   -- 0 means write is complete. lets see if we need another round
								state <= next_write;	
							else
								-- not finished yet, get status register again
								state <= get_status_reg;	
							end if;						
				
				when next_write =>			
						if wr_ptr = '1' then
							-- LE POINTEUR EST ECRIT : la bascule est faite. Quelle que
							-- soit l'issue d'une coupure pendant cet unique octet, le
							-- pointeur relu designera un banc COMPLET, ou rien.
							-- Le banc ecrit devient le banc courant, effacement compris :
							-- il contient 128 zeros VALIDES, pas du vide.
							bank_cur <= bank_wr;
							bank_wr  <= not bank_wr;
							wr_ptr <= '0';
							wr_zero <= '0';
							if boot_wr = '1' then
								boot_wr <= '0';
								state <= Delay;  -- effacement au demarrage : armer les declencheurs
							else
								state <= Idle;
							end if;
						elsif address_eeprom = "1111111" then
							-- Les 128 octets sont dans le banc inactif. On bascule
							-- maintenant le pointeur : UN SEUL octet, donc une fenetre
							-- de quelques millisecondes au lieu d'une demi-seconde.
							wr_ptr <= '1';
							if bank_wr = '0' then
								ptr_new <= PTR_A;
							else
								ptr_new <= PTR_B;
							end if;
							address_eeprom <= "0000000";
							state <= Write_enable;
						else
							-- increment address
						   address_eeprom <= std_logic_vector( unsigned(address_eeprom) + 1 );							
							state <= Write_enable; -- next round 
						end if;																		
				end case;	
			end if; --rising edge				
		end process;
						
    end Behavioral;				