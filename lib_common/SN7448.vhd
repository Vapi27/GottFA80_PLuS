---------------------------------------------------------------
-- SN7448 7 segment decoder, simple version
---------------------------------------------------------------

LIBRARY ieee;
USE ieee.std_logic_1164.all;

	entity sn7448 is
		port(                			
				 Din		  : in std_logic_vector (3 downto 0);
				 Dout		  : out std_logic_vector (1 to 7)
            );
    end sn7448;


  architecture Behavioral of sn7448 is
    begin
		process (Din)
			begin
		    case Din is 
				 when "0000"=>Dout<="1111110"; 
				 when "0001"=>Dout<="0110000"; 
				 when "0010"=>Dout<="1101101"; 
				 when "0011"=>Dout<="1111001"; 
				 when "0100"=>Dout<="0110011"; 
				 when "0101"=>Dout<="1011011"; 
				 when "0110"=>Dout<="0011111"; 
				 when "0111"=>Dout<="1110000"; 
				 when "1000"=>Dout<="1111111"; 
				 when "1001"=>Dout<="1110011"; 
				 when "1010"=>Dout<="0001101"; 
				 when "1011"=>Dout<="0011001"; 
				 when "1100"=>Dout<="0100011"; 
				 when "1101"=>Dout<="1001011"; 
				 when "1110"=>Dout<="0001111"; 
				 when "1111"=>Dout<="0000000"; 
				 when others=>Dout<="0000000"; 
			end case;	 
		end process;
   end Behavioral;					