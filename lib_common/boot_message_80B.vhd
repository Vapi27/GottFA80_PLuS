-- boot message on Gottlieb Display
-- 80B Version
-- part of  GottFA80
-- bontango 01.2026
--
-- v 1.0 initial version
-- 895KHz input clock

LIBRARY ieee;
USE ieee.std_logic_1164.all;

LIBRARY ieee;
USE ieee.std_logic_1164.all;

    entity boot_message_80B is        
        port(
            clk_in  : in std_logic;               						
			show		: in std_logic;     
			SD_error : in std_logic;     
			--output (display control)
			data	: out std_logic_vector(7 downto 0);
			LD1 : out std_logic;     
			LD2 : out std_logic;     
			D_Reset : out std_logic;     
			-- input (display data)
			row1 : in  string(1 to 20);
			row2 : in  string(1 to 20);
			error_row2 : in  string(1 to 20)
            );
    end boot_message_80B;
    ---------------------------------------------------
    architecture Behavioral of boot_message_80B is
	 signal tx_index : integer range 0 to 20 := 0;
		signal count : integer range 0 to 17000 := 0;

		type STATE_T is ( get_opcode, get_parameter, Execute_op_code, Execute_parameter,
						wait_finish_rx, Send_byte, Check_byte, check_char, send_char, send_string,
						Finish_byte, Finish_char); 
signal state : STATE_T;        --State

	begin
		
	
	boot_message_80B: process (clk_in, show, row1, row2, error_row2)
    begin
			if show = '0' then --Reset condidition (reset_l)    	
				LD1 <= '0';
				LD2 <= '0';
				D_Reset <= '0';
				data <= (others => '0');
				count <= 0;
			elsif rising_edge(clk_in) then	--8KHz input we have a clk each 120 us
    case state is
		when Send_string =>
		   if tx_index < string_length then			 
			 uart_data_tx <=   std_logic_vector(to_unsigned(character'pos(string_to_send(tx_index + 1)), 8));
		    -- next index
			 tx_index <= tx_index + 1;
			 state <= Send_char;
			else
			 state <= get_opcode;
			end if;


				end case; --state machine
		end if;	
		end process;
    end Behavioral;
	 
	 
--//push a byte to display controller Rockwell 10941
--//row is 1 or 2
--//use row==3 for pushing to row 1 and 2
--void push_data_to_10941(uint8_t value, uint8_t row)
--{
--    union both8 {
--    unsigned char byte;
--    struct {
--    unsigned b0:1, b1:1, b2:1, b3:1, b4:1, b5:1, b6:1, b7:1;    
--        } bitv;
--    } myvalue;
--    
--    myvalue.byte = value;
--    
--    // LD1 and LD2 on zero
--    LD1 = LD2 = 0;    
--
--    D0 = myvalue.bitv.b0;
--    D1 = myvalue.bitv.b1;        
--    D2 = myvalue.bitv.b2;
--    D3 = myvalue.bitv.b3;                       
--    D4 = myvalue.bitv.b4;
--    D5 = myvalue.bitv.b5;    
--    D6 = myvalue.bitv.b6;
--    D7 = myvalue.bitv.b7;                       
--    
--    //now push the byte to the rigth row by pulse the LD    
--    if ((row == LS80D_B_TOROW1)|(row == LS80D_B_TOROW12))
--     {
--      
--      //set LD1 = 1
--      LD1 = 1;
--      //wait a bit
--      __delay_us(10);      
--      //and set back to 0 again
--      LD1 = 0;
--      //K42 is too fast, add delay
--      __delay_us(3);   
--     }
--    if ((row == LS80D_B_TOROW2)|(row == LS80D_B_TOROW12))
--     {
--      
--      //set LD2 = 1
--      LD2 = 1;
--      //wait a bit
--      __delay_us(10);      
--      //and set back to 0 again      
--      LD2 = 0;
--      //K42 is too fast, add delay
--      __delay_us(3);   
--     }     
--          //K42 is too fast, add delay
--      __delay_us(10);   
--
--}
--
--// init display, show LISY80B and Version
--void init_10941(void)
--{    
--  uint8_t dip;  
--  //read the dip settings
--  dip = get_dip_setting();
--  
--  //do a reset first
--  reset_10941();
--  
--  //Digit Counter = 20, both rows
--  push_data_to_10941(1, LS80D_B_TOROW12);  
--  push_data_to_10941(0x94, LS80D_B_TOROW12);  
--  //Digit time 32 cycle per Grid
--  push_data_to_10941(1, LS80D_B_TOROW12);
--  push_data_to_10941(6, LS80D_B_TOROW12);
--  
--  //Duty cicle 26/6
--  push_data_to_10941(1, LS80D_B_TOROW12);
--  push_data_to_10941(0x5c, LS80D_B_TOROW12);  
--
--  //start display refresh
--  push_data_to_10941(1, LS80D_B_TOROW1);
--  push_data_to_10941(0x0E, LS80D_B_TOROW1);  
--    
--  //Show Initial Message by using lisy80_char which is not in use for 80B
--  sprintf(lisy80_char,"LISY80B GAME NO %02d  ",dip);
--  show_string_80B( lisy80_char,1); 
--  sprintf(lisy80_char,"WAIT FOR PI          ");
--  show_string_80B( lisy80_char,2);
--   
--}
--
--void reset_10941(void)
--{
--    int i;
--    
--    // /RESET on low
--    DISP_RESET = 0;        
--    
--    //put both LDs on zero
--    LD1 = LD2 = 0;
--    
--    //wait for Display to be ready
--    //__delay_ms(100); //new compiler -> too large?
--    for(i=0; i<10; i++) __delay_ms(10);
--    //and put /RESET to High
--    DISP_RESET = 1;
--    //toggle D7 to let the display know we are in parallel mode
--    D7 =1;
--    __delay_ms(1);
--    D7= 0;
--    
--}
--	 