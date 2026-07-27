-- boot message on Gottlieb Display
-- part of  GottFA80
-- bontango 01.2021
--
-- v 1.1 displays now strings
-- v 1.2 SD error message
-- 895KHz input clock

LIBRARY ieee;
USE ieee.std_logic_1164.all;

LIBRARY ieee;
USE ieee.std_logic_1164.all;

    entity boot_message is        
        port(
            clk_in  : in std_logic;               						
			   show		: in std_logic;     
				SD_error : in std_logic;     
				--output (display control)
				bm_digit_strobe	: out std_logic_vector(3 downto 0);
				bm_segments			: out std_logic_vector(1 to 24) := x"000000";	
				-- input (display data)
			   display1			: in  string(1 to 7);
				display2			: in  string(1 to 7);
				display3			: in  string(1 to 7);
				display4			: in  string(1 to 7);
				error_disp4		: in  string(1 to 7);
				status_d			: in  string(1 to 7)
            );
    end boot_message;
    ---------------------------------------------------
    architecture Behavioral of boot_message is
		signal count : integer range 0 to 17000 := 0;
		signal Din_Seg_A			: character;
		signal Din_Seg_B			: character;
		signal Din_Seg_C			: character;
		signal var_display4		: string(1 to 7);
	begin
	
	sn7448_gtb_1: entity work.sn7448_gtb
	port map(   
		Din 	=> Din_Seg_A,
		Dout  => bm_segments(1 to 8)
	);
	sn7448_gtb_2: entity work.sn7448_gtb
	port map(   
		Din 	=> Din_Seg_B,
		Dout  => bm_segments(9 to 16)
	);	
	-- BUG (fixed 2026-07-25): this third decoder drives the THIRD segment group,
	-- bm_segments(17 to 24) -- the status / credit-ball digits, fed by Din_Seg_C
	-- (see the process below: status_d is loaded into Din_Seg_C at counts 12000,
	-- 13000, 14000 and 15000, and Din_Seg_C is set to ' ' for every other digit
	-- strobe).  It was wired to Din_Seg_B, i.e. the player 3/4 data, so Din_Seg_C
	-- was written but never read and the status digits showed a frozen copy of
	-- display3/display4 instead.
	sn7448_gtb_3: entity work.sn7448_gtb
	port map(
		Din 	=> Din_Seg_C,
		Dout  => bm_segments(17 to 24)
	);
	
	var_display4 <= display4 when SD_error = '0' else error_disp4; 
	
	 boot_message: process (clk_in, show)
    begin
		if rising_edge(clk_in) then	
			if show = '0' then --Reset condidition (reset_l)    				
				bm_digit_strobe <= "0000";
				count <= 0;
			else			
				-- inc count for next round
				count <= count +1;
				case count is 				--895KHz input we have a clk each 1,1us
												-- we do a refresh each 1.1ms
				when 0 => 					-- start refresh cycle		
					Din_Seg_A <= display1(7);
					Din_Seg_B <= display3(7);		
					Din_Seg_C <= ' ';			
					bm_digit_strobe <= x"0";
				when 1000 =>
					Din_Seg_A <= display1(6);
					Din_Seg_B <= display3(6);		
					Din_Seg_C <=  ' ';			
					bm_digit_strobe <= x"1";
				when 2000 =>
					Din_Seg_A <= display1(5);
					Din_Seg_B <= display3(5);		
					Din_Seg_C <= ' ';					
					bm_digit_strobe <= x"2";
				when 3000 =>
					Din_Seg_A <= display1(4);
					Din_Seg_B <= display3(4);										
					Din_Seg_C <= ' ';				
					bm_digit_strobe <= x"3";				
				when 4000 =>
					Din_Seg_A <= display1(3);
					Din_Seg_B <= display3(3);										
					Din_Seg_C <= ' ';					
					bm_digit_strobe <= x"4";
				when 5000 =>
					Din_Seg_A <= display1(2);
					Din_Seg_B <= display3(2);										
					Din_Seg_C <= ' ';			
					bm_digit_strobe <= x"5";
				when 6000 =>
					Din_Seg_A <= display2(7);
					Din_Seg_B <= var_display4(7);										
					Din_Seg_C <= ' ';			
					bm_digit_strobe <= x"6";					
				when 7000 =>
					Din_Seg_A <= display2(6);
					Din_Seg_B <= var_display4(6);										
					Din_Seg_C <= ' ';			
					bm_digit_strobe <= x"7";						
				when 8000 =>
					Din_Seg_A <= display2(5);
					Din_Seg_B <= var_display4(5);										
					Din_Seg_C <= ' ';			
					bm_digit_strobe <= x"8";						
				when 9000 =>
					Din_Seg_A <= display2(4);
					Din_Seg_B <= var_display4(4);										
					Din_Seg_C <= ' ';			
					bm_digit_strobe <= x"9";						
				when 10000 =>
					Din_Seg_A <= display2(3);
					Din_Seg_B <= var_display4(3);										
					Din_Seg_C <= ' ';			
					bm_digit_strobe <= x"A";
				when 11000 =>
					Din_Seg_A <= display2(2);
					Din_Seg_B <= var_display4(2);										
					Din_Seg_C <= ' ';			
					bm_digit_strobe <= x"B";
				when 12000 =>
					Din_Seg_A <= display2(1);
					Din_Seg_B <= var_display4(1);										
					Din_Seg_C <= status_d(7);	
					bm_digit_strobe <= x"C";
				when 13000 =>
					Din_Seg_C <= status_d(6);
					bm_digit_strobe <= x"D";
				when 14000 =>
					Din_Seg_C <= status_d(5);
					bm_digit_strobe <= x"E";
				when 15000 =>
					Din_Seg_A <= display1(1);
					Din_Seg_B <= display3(1);										
					-- BUG (fixed 2026-07-27): this wrote status_d(7) a SECOND time, so the
					-- fourth status digit (strobe 15 = segment 40 in PinMAME's gts80.c map,
					-- i.e. the LEFTMOST status digit) showed a copy of the rightmost one and
					-- status_d(4) was never displayed at all.  The four status strobes
					-- 12,13,14,15 carry chars 7,6,5,4.
					-- No functional change in THIS design: SYS80.vhd passes a constant blank
					-- status_d, so old and new expression are both ' '.  It matters because
					-- sim/tb_ta_overlay.vhd now uses this table as the reference that
					-- lib_common/ta_overlay.vhd must agree with.
					Din_Seg_C <= status_d(4);																											
					bm_digit_strobe <= x"F";						
				when 16000 =>
					count <= 0;
				when OTHERS =>
				end case;
			end if; -- show
		end if;	--rising edge		
		end process;
    end Behavioral;