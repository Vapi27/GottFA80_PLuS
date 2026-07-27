---------------------------------------------------------------
-- SN7448 Gottlieb Version
-- 7 segment decoder plus 'h' Segment
-- Alphanumeric version
---------------------------------------------------------------
-- Bit order is Dout(1..8) = a b c d e f g h, where 'h' (bit 8) is the extra
-- Gottlieb comma / decimal segment.  Cross-checked digit by digit against the
-- plain decoder lib_common/SN7448.vhd, which holds the same table without the
-- 8th segment:  '0' "1111110" -> "11111100",  '4' "0110011" -> "01100110",
-- '6' "0011111" -> "00111110", '9' "1110011" -> "11100110", etc.
-- BUG fixed 2026-07-25: '1' was "00000001" -- every numeric segment off and ONLY
-- the comma lit, so every '1' on the glass rendered as a bare comma.  SN7448.vhd
-- has "0110000" (segments b+c) for the same digit; with the comma off that is
-- "01100000".  It was the only entry that disagreed with SN7448.vhd.
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
				 when '1'=>Dout<="01100000";
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