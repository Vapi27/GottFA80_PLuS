-- from the datasheet
-- Test to determine if the state of the A/R line is high ( SC01 ready)
-- strob STP to high to strobe in the phoneme code present on lines P0..P5
-- the stb line should the driven low again, after which the A/R line goes low
--until the until the SC-01 is ready for the enxt phoneme
--Tph time of phonem duration (A/R low) is between 47 and 250ms
--Tsw strobe with is 200ns
--
--This is only a simulation of signaling to fool the program that SC01 is there
--
-- bontango
-- Version 0.2 timetable added
-- Version 0.3 timetable adjusted + 20%

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

	entity SC01 is
		port(
                clk     : in std_logic; -- clock is 50MHz, 20ns cycle
					 strobe  : in std_logic; 
					 cpu_data : in std_logic_vector(5 downto 0);
                AR 		: out std_logic;
					 rst 		: in  STD_LOGIC --reset_l
            );
    end SC01;
	 
   architecture Behavioral of SC01 is
	  type STATE_T is ( Idle, Calc, Speech); 
		signal state : STATE_T;        --State	   
		-- timing table
		type t_time_map is array ( 0 to 63) of integer range 0 to 250;
		signal time_map : t_time_map := ( 59, 71,121, 47, 47, 71,103, 90, 71, 55, 80,121,103, 80, 71, 71,
													 71,121, 71,146,121,146,103,185,103, 80, 47, 71, 71,103, 55, 90,
													185, 65, 80, 47,250,103,185,185,185,103, 71, 90,185, 80,185,103,
													 90, 71,103,185, 80,121, 59, 90, 80, 71,146,185,121,250,185, 47);

    begin	 
		SC01: process (clk, rst)
			variable counter : integer range 0 to 16000000 := 0;
			variable duration : integer range 0 to 16000000 := 0;			
		begin
			if rst = '0' then --Reset condidition (reset_l)
				 AR <= '1';
				 counter := 0;
				 state <= Idle;    
			elsif rising_edge(clk)then
				case state is
					when Idle =>
						if strobe = '1' then --check that we have at least 200ns strobe -> 10cycles
							counter := counter +1;
							  if (counter > 10)then
							    -- new state
								 AR <= '0';
								 counter := 0;
								 state <= Calc;
							  end if;
						else -- strobe was going low while counting
							-- reset counter
							counter := 0;
							--keep Idle state
						end if;
				when Calc => -- we have a valid strobe, calculate time for this phonem
					duration := time_map(to_integer(signed(cpu_data))) * 60000;			--add 20%, allophones are longer then from datasheet		
					state <= Speech;						
				when Speech =>
					counter := counter +1;
					if (counter > duration) then 
						counter:=0;
						AR<='1';
						state <= Idle;
					end if;					
				end case;
			end if;
		end process;
    end Behavioral;				
