-- read the dips on GottFA
-- part of  GottFA80_PLuS
-- bontango 07.2022
--
-- v 1.0
-- 895KHz input clock

LIBRARY ieee;
USE ieee.std_logic_1164.all;

LIBRARY ieee;
USE ieee.std_logic_1164.all;

    entity read_the_dips is        
        port(
            clk_in  : in std_logic;               						
				i_Rst_L : in std_logic;     -- FPGA Reset		
			   readingdips		: out std_logic;        -- set to 0 when read finished
				--output 
				game_select	:	out std_logic_vector(5 downto 0);
				game_option	:	out std_logic_vector(1 to 4);
				-- strobes
			   dipstrobe1		: out std_logic;
				dipstrobe2		: out std_logic;
				-- input
				return1			: in std_logic;
				return2			: in std_logic;
				return3			: in std_logic;
				return4			: in std_logic;
				return5			: in std_logic
				
            );
    end read_the_dips;
    ---------------------------------------------------
    architecture Behavioral of read_the_dips is
	 	type STATE_T is ( Start, Idle, Read1, Read2 ); 
		signal state : STATE_T := Start;       		
	begin
	
	
	 read_the_dips: process (clk_in, return1, return2, return3)
    begin
		if rising_edge(clk_in) then			
			if i_Rst_L = '0' then --Reset condidition (reset_l)    
			  state <= Start;
			  readingdips <= '1';
			else
				case state is
					when Start =>
					   readingdips <= '1';
						dipstrobe1 <= '0';
						dipstrobe2 <= '1';						
						state <= Read1;						
					when Read1 =>
						game_select(0) <= return1;
						game_select(1) <= return2;
						game_select(2) <= return3;
						game_select(3) <= return4;
						game_select(4) <= return5;
						dipstrobe1 <= '1';
						dipstrobe2 <= '0';
						state <= Read2;
					when  Read2 =>
						game_select(5) <= return1;
						game_option(1) <= return2;
						game_option(2) <= return3;
						game_option(3) <= return4;
						game_option(4) <= return5;
						dipstrobe1 <= '1';
						dipstrobe2 <= '1';
						state <= Idle;
					when  Idle =>
						readingdips <= '0';
						--do nothing				
				end case;
			end if; --reset				
		end if;	--rising edge		
		end process;
    end Behavioral;