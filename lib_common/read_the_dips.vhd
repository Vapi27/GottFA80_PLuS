-- read the dips on GottFA
-- part of  GottFA80S
-- bontango 04.2025
--
-- v 1.0
-- 895KHz input clock
-- v1.1 SB_option added

LIBRARY ieee;
USE ieee.std_logic_1164.all;

LIBRARY ieee;
USE ieee.std_logic_1164.all;

    entity read_the_dips is        
        port(
            clk_in  : in std_logic;               						
				i_Rst_L : in std_logic;     -- FPGA Reset		
			   readingdips		: out std_logic;        -- set to 0 when read finished
				--dip selections
				game_select	:	out std_logic_vector(5 downto 0);
				game_option	:	out std_logic_vector(1 to 6);
				sb_option	:	out std_logic_vector(1 to 4);
				-- output
			   strobes		: out std_logic_vector(3 downto 0);
				-- input
			   returns		: in std_logic_vector(3 downto 0)
				
				
            );
    end read_the_dips;
    ---------------------------------------------------
    architecture Behavioral of read_the_dips is
	 	type STATE_T is ( Start, Idle, Read1, Read2, Read3, Read4 ); 
		signal state : STATE_T := Start;       		
	begin
	
	
	 read_the_dips: process (clk_in, returns )
    begin
		if rising_edge(clk_in) then			
			if i_Rst_L = '0' then --Reset condidition (reset_l)    
			  state <= Start;
			  readingdips <= '1';
			else
				case state is
					when Start =>
					   readingdips <= '1';
						strobes <= "1110";
						state <= Read1;						
					when Read1 =>
						game_select(0) <= returns(0);
						game_select(1) <= returns(1);
						game_select(2) <= returns(2);
						game_select(3) <= returns(3);
						strobes <= "1101";
						state <= Read2;
					when Read2 =>
						game_select(4) <= returns(0);
						game_select(5) <= returns(1);
						game_option(1) <= returns(2);
						game_option(2) <= returns(3);
						strobes <= "1011";
						state <= Read3;
					when Read3 =>
						game_option(3) <= returns(0);
						game_option(4) <= returns(1);
						game_option(5) <= returns(2);
						game_option(6) <= returns(3);
						strobes <= "0111";
						state <= Read4;
					when  Read4 =>
						sb_option(1) <= returns(0);
						sb_option(2) <= returns(1);
						sb_option(3) <= returns(2);
						sb_option(4) <= returns(3);
						strobes <= "1111";
						state <= Idle;
					when  Idle =>
						readingdips <= '0';
						--do nothing				
				end case;
			end if; --reset				
		end if;	--rising edge		
		end process;
    end Behavioral;