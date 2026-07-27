-- detect switch
-- input strobe, return and 'swuitch enable' signal
-- input is cpu clock
-- output
-- shortpush when switch is pushed >=100ms
-- longpush when switch is pushed >=1,8s
-- Gottlieb version
-- bontango 21.01.2021

Library IEEE;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;

entity detect_sw is 
   port(
	   clk     : in std_logic; -- clock is cpuclk 895KHz, 1,1uS cycle
		sw_strobe : in std_logic; -- strobe line of switch (active high)
		sw_return : in std_logic; -- return line of switch (active high)
		sw_enable : in std_logic; -- (dip) sw enable (active high)
		short_push :out  std_logic;    -- will go high if switch is pushed >50ms
		long_push :out  std_logic;    -- will go high if switch is pushed >1500ms		
		rst 		: in  STD_LOGIC --reset_l or game running
   );
end detect_sw;
architecture Behavioral of detect_sw is  
		  type STATE_T is ( Idle, counting, delay); 
		signal state : STATE_T;        --State			
		signal is_closed : std_logic;
		signal check_counter : integer range 0 to 20000000 := 0;
		signal closed_counter : integer range 0 to 20000000 := 0;
begin 

 is_closed <= sw_strobe and sw_return and not sw_enable;
 
 process(clk, rst)
		begin
			if rst = '0' then --Reset condidition (reset_l)
				 short_push <= '0';
				 long_push <= '0';
				 check_counter <= 0;
				 closed_counter <= 0;
				 state <= Idle;    
			elsif rising_edge(clk)then
				case state is
					when Idle =>
						if is_closed = '1' then 
							state <= counting;	-- start counting
						end if;
					----------------------------------	
					-- we count 2 seconds which is 1.790.000 cycles at 895KHz
					when counting => 						
							check_counter <= check_counter +1;
							if ( is_closed = '1') then 								
								closed_counter <= closed_counter +1;
							end if;		
							
							if (check_counter > 1790000) then -- end checking phase
								if ( closed_counter > 179000) then
									long_push <= '1';
								else	
									long_push <= '0';
								end if;		
								
								if ( closed_counter > 17900) then
									short_push <= '1';
								else	
									short_push <= '0';
								end if;		
								
								-- new state			
								check_counter <= 0;
								closed_counter <= 0;
								state <= delay;
							end if;								  
					----------------------------------	
					-- BUG FIX 2026-07-27: short_push was NEVER cleared here -- the line
					-- "long_push <= '0'" was simply written twice.  Consequence: after the
					-- first press of >=20ms the short_push output latched HIGH and stayed
					-- high for the rest of the power cycle, because the only other place
					-- short_push is written is the end of the `counting` state, which can
					-- only ever re-assert it.  On the door test switch (detect_test_sw in
					-- SYS80.vhd) short_push is `test_sw` -> EEprom w_trigger(2), and EEprom
					-- saves the 5101 NVRAM on any CHANGE of w_trigger.  A latched-high
					-- trigger bit produces exactly ONE edge per power-up, so "press the
					-- door test switch to commit the settings" worked once and never
					-- again -- which is precisely when an operator needs it (after
					-- adjusting the book-keeping in the ROM test menu).
					-- long_push (-> lisy_trig, diag entry) was already cleared correctly
					-- and its timing is unchanged by this fix.
					when delay =>
						check_counter <= check_counter +1;
						if (check_counter > 125000) then -- 100ms signals active							
							long_push  <= '0';
							short_push <= '0';
							state <= Idle;				
						end if;
				end case;
			end if;
		end process;
    end Behavioral;				
