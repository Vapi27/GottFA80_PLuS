---------------------------------------------------------------
-- SN7448 Gottlieb Version
-- 7 segment decoder plus 'h' Segment
-- Alphanumeric version
---------------------------------------------------------------

LIBRARY ieee;
USE ieee.std_logic_1164.all;

	entity sn7448_gtb is
		port(                			
				 Din		  : in character;
				 Dout		  : out std_logic_vector (1 to 8)
            );
    end sn7448_gtb;


  architecture Behavioral of sn7448_gtb is
    begin
		process (Din)
			begin
		    case Din is 
				 when '0'=>Dout<="11111100"; 
				 when '1'=>Dout<="00000001"; 
				 when '2'=>Dout<="11011010"; 
				 when '3'=>Dout<="11110010"; 
				 when '4'=>Dout<="01100110"; 
				 when '5'=>Dout<="10110110"; 
				 when '6'=>Dout<="00111110"; 
				 when '7'=>Dout<="11100000"; 
				 when '8'=>Dout<="11111110"; 
				 when '9'=>Dout<="11100110"; 
				 when others=>Dout<="00000000"; 
			end case;	 
		end process;
   end Behavioral;					