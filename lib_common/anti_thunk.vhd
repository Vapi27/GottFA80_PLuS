-- anti thunk for Gottlieb Display
-- inits driverboard to zero
-- part of  GottFA80
-- bontango 09.2022
--
-- 895KHz input clock

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

    entity anti_thunk is        
        port(
         clk_in  : in std_logic;               						
			is_active	: in std_logic;        
			--output ( count up ds )
			lamp_ds	: out std_logic_vector(3 downto 0)
            );
    end anti_thunk;
    ---------------------------------------------------
    architecture Behavioral of anti_thunk is
		signal count : integer range 0 to 17000 := 0;
		signal count_ds	: std_logic_vector(3 downto 0);
	begin
	
	 anti_thunk: process (clk_in, is_active)
    begin
		if rising_edge(clk_in) then	
			if is_active = '0' then --Reset condidition (reset_l)    				
				count_ds <= "0000"; 
				count <= 0;
			else			
				-- inc count for next round
				count <= count +1;
				lamp_ds <= count_ds;
				if ( count > 1000) then -- next DS
					count <= 0;
					count_ds <= std_LOGIC_VECTOR(unsigned(count_ds) +1);					
				end if;			
			end if; -- is_active
		end if;	--rising edge		
		end process;
    end Behavioral;