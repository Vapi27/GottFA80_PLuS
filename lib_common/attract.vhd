-- attract mode for speech attract
-- bontango
-- v0.1 15.06.2025


library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

	entity attract is
		port(
                clk     : in std_logic; 
					 clk_uart     : in std_logic; -- clock is uart clock 9600 Hz == 104uS cycle
					 rst 		: in  STD_LOGIC; --reset_l			
					 other_sound :  in  STD_LOGIC; 
					 options  : in std_logic_vector(1 downto 0); -- SB options for attract
					 num_sounds : in integer; -- number of different attract mode sounds
					 soundnumber  : out std_logic_vector(7 downto 0);
                send_flag 		: out std_logic
            );
    end attract;
	 
   architecture Behavioral of attract is
	  type STATE_T is ( Idle, Activate); 
		signal state : STATE_T;        --State	   
	  signal counter : integer range 0 to 2304001:= 0; 
	  signal timeout : integer range 0 to 2304001; -- 10secs/2min/4min
	  signal sound_seen : std_logic;
	  signal reset_flag : std_logic;
	  	  
    begin	 
	 
	 timeout <= 96000 when options = "10" else -- each 10secs DIP3
					1152000 when options = "01" else -- each 2mins DIP4
					2304000 when options = "00" else -- each 4mins DIP3&4
					0; -- DIPS OFF "11"
					
		detect: process (clk, other_sound, reset_flag)
		begin
			if rising_edge(clk)then
				if ( other_sound = '1') then
					sound_seen <= '1';
				end if;	
				if ( reset_flag = '1' ) then
					sound_seen <= '0';
				end if;
			end if;				
		end process;
		
		
		attract: process (clk_uart, rst, options, num_sounds, timeout)
		variable attract_sound : integer := 34;
		begin
			if ( rst = '0' or ( timeout = 0) or ( num_sounds = 0) ) then --Reset condidition (reset_l) or if attract mode not active
				 counter <= 0;
				 reset_flag <='0';
				 state <= Idle;    
			elsif rising_edge(clk_uart)then
				case state is
					when Idle =>
						send_flag <='0';
						if ( sound_seen = '1') then
							counter <= 0; -- reset counter in case other sounds playd
							reset_flag <= '1'; -- we assume game is active in this case
						else	
							reset_flag <= '0';
							counter <= counter +1;
						end if;						
						-- timeout?
						if (counter > timeout)then
						    -- new state
							 counter <= 0;			
							 state <= Activate;
						end if;
							 
					when Activate => 
						send_flag <='1';
						attract_sound := attract_sound +1;
						if ( attract_sound > num_sounds + 34 ) then -- sounds# 35,36,37
							attract_sound := 35;
						end if;							
						soundnumber <= std_logic_vector (to_unsigned( attract_sound, 8));
						state <= Idle;
				end case;
			end if;
		end process;
    end Behavioral;				
