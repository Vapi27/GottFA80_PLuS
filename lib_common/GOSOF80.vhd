-- Top level file for a Gottlieb compatible Soundboard
-- by bontango www.lisy.dev
-- 
-- Version for GottFA80S based on GOSOF 3.97 with attract

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity gosof80 is
	port(
		clk_50	: in std_logic;
		cpu_clk	: in std_logic;
		reset_l	: in std_logic;
		game_running	: in std_logic;
		test		: in std_logic := '1';
		Audio_O	: buffer std_logic;
		
		-- Sound input S1,S2,S4,S8,S16
		Sound_Meta :	in 	std_logic_vector(4 downto 0);

		-- lisyctrl direct sound inject (diag mode): play lisy_sound while lisy_trig is high
		lisy_active : in std_logic := '0';
		lisy_sound  : in std_logic_vector(4 downto 0) := "00000";
		lisy_trig   : in std_logic := '0';

		--Soudnboard Options S1 DIPs 1..6
		SB_Opt :	in 	std_logic_vector(1 to 6);
		
		--switches	:	
		game_sel	:	in 	std_logic_vector(5 downto 0);  -- game selection S2		
		--option   :	in 	std_logic_vector(3 downto 0);  -- GOSOF options
		
		-- DFPlayer
		DFP_tx	   : out STD_LOGIC;
		
		-- main
		soundrom1_addr : out std_logic_vector(10 downto 0);
		soundrom2_addr : out std_logic_vector(10 downto 0);
		soundrom1_dout : in std_logic_vector(7 downto 0);
		soundrom2_dout : in std_logic_vector(7 downto 0)
		
		);
end gosof80;

architecture rtl of gosof80 is 

	-- multi SD, type according to game select
	constant is_MA216 : std_logic_vector(2 downto 0):="000";
	constant is_MA309 : std_logic_vector(2 downto 0):="001";
	constant is_MA55 : std_logic_vector(2 downto 0):="010";
	constant is_MA490 : std_logic_vector(2 downto 0):="011";
	constant is_SYS1 : std_logic_vector(2 downto 0):="100";
	constant is_special : std_logic_vector(2 downto 0):="101";

	signal SB_type : 	std_logic_vector(2 downto 0);
	signal game_number : integer  range 0 to 63; 
	
	signal phi2			: 	std_logic; -- CPU clock phase 2
	signal uart_clk	: std_logic; -- 9600 baud clock for uart

	signal cpu_addr	:	std_logic_vector(15 downto 0);
	signal cpu_din		: 	std_logic_vector(7 downto 0);
	signal cpu_dout	:  std_logic_vector(7 downto 0);
	signal n_cpu_nmi	: 	std_logic;
	signal n_cpu_irq	:  std_logic;
	signal cpu_wr_n	:  std_logic;
	
	signal riot_dout	:  std_logic_vector(7 downto 0);
	signal riot_pa_i	:  std_logic_vector(7 downto 0);
	signal riot_pa_o	:  std_logic_vector(7 downto 0);
	signal riot_pb_i	:  std_logic_vector(7 downto 0);
	signal riot_pb_o	:	std_logic_vector(7 downto 0);
	signal riot_cs		:  std_logic;
	signal n_riot_irq : std_logic;
	signal riot_rs_n  : std_logic;	
	signal addr_6532  :	std_logic_vector(4 downto 0);
				
	-- RAM
	signal RAM_dout	: 	std_logic_vector(7 downto 0);
	signal RAM_cs		:  std_logic;
    
	-- sounds
	signal DAC_latch	:  std_logic;
	signal audio_dat_latch	: 	std_logic_vector(7 downto 0);
   signal audio_dat	: 	std_logic_vector(7 downto 0);	
	
	-- speech
	signal DAC_latch_speech	:  std_logic;
	signal sc01_strobe	:  std_logic;
	signal sc01_AR			:  std_logic;
	signal sc01_cs			:  std_logic;
	
	signal send_flag	:  std_logic:='0';
	signal DFcmd_cmd	:  std_logic_vector(7 downto 0);
	signal DFcmd_par1	:  std_logic_vector(7 downto 0);
	signal DFcmd_par2	:  std_logic_vector(7 downto 0);	
		
	signal speech_ctrl :  std_logic_vector(31 downto 0);
				
	-- MA490 only	
	signal ma490_irq_n			: std_logic;
	signal ma490_U11_q			: std_logic;
		
	-- module
	signal soundrom1_cs			: std_logic;
	signal soundrom2_cs			: std_logic;
	
	-- attract mode
	signal attract_sound	:  std_logic_vector(7 downto 0);
	signal attract_send_flag	:  std_logic:='0';	
	signal nu_attr_s : integer;
	
		
begin

game_number <= to_integer(unsigned(game_sel));

-- what type of soundboard do we emulate?
-- speech_ctrl 0 is speech (-> MP3-Player), 1 is 'other'		
--DFcmd_par1 <= is folder number
		process (game_number)
			begin
		    case game_number is 
				 when 0 to  8 => nu_attr_s <=0; SB_type <= is_MA55; speech_ctrl <= "11111111111111111111111111111111"; DFcmd_par1 <= X"00"; --Panthera to ForceII
				 when 		9 => nu_attr_s <=0; SB_type <= is_MA55; speech_ctrl <= "11111111111111111111111111111101"; DFcmd_par1 <= X"00"; --Pink Panther Folder 9?
				 when 	  10 => nu_attr_s <=3; SB_type <= is_MA216; speech_ctrl <= "00000100000000010111100111100111";DFcmd_par1 <= X"0A"; --Mars w. speech
				 when      11 => nu_attr_s <=0; SB_type <= is_MA55; speech_ctrl <= "11111111111111111111111111111111"; DFcmd_par1 <= X"00"; --Mars 'fake'
				 when 	  12 => nu_attr_s <=3; SB_type <= is_MA216; speech_ctrl <= "00010000011000110110001101100111"; DFcmd_par1 <= X"0C"; --Volcano w. speech
				 when      13 => nu_attr_s <=0; SB_type <= is_MA55; speech_ctrl <= "11111111111111111111111111111111"; DFcmd_par1 <= X"00"; --Volcano
				 when 	  14 => nu_attr_s <=2; SB_type <= is_MA216; speech_ctrl <= "00000000001111110101111111110111"; DFcmd_par1 <= X"0E"; --BH w. speech
				 when      15 => nu_attr_s <=0; SB_type <= is_MA55; speech_ctrl <= "11111111111111111111111111111111"; DFcmd_par1 <= X"00"; --BH
				 when      16 => nu_attr_s <=0; SB_type <= is_MA309; speech_ctrl <= "11111111111111111111111111111111"; DFcmd_par1 <= X"00"; --HH
				 when      17 => nu_attr_s <=0; SB_type <= is_MA55; speech_ctrl <= "11111111111111111111111111111111"; DFcmd_par1 <= X"00"; --Eclipse
				 when 	  18 => nu_attr_s <=0; SB_type <= is_MA216; speech_ctrl <= "00111111101001011011111111111111"; DFcmd_par1 <= X"12"; --Devils Dare w. speech
				 when      19 => nu_attr_s <=0; SB_type <= is_MA55; speech_ctrl <= "11111111111111111111111111111111"; DFcmd_par1 <= X"00"; --Devils Dare
				 when 	  20 => nu_attr_s <=0; SB_type <= is_MA216; speech_ctrl <= "00000000000111111111111111111111"; DFcmd_par1 <= X"14"; --Rocky w. speech
				 when 21 to 22 => nu_attr_s <=0; SB_type <= is_MA309; speech_ctrl <= "11111111111111111111111111111111"; DFcmd_par1 <= X"00"; --Spirit & Punk
				 when 	  23 => nu_attr_s <=0; SB_type <= is_MA216; speech_ctrl <= "00000111111110110111111111110111"; DFcmd_par1 <= X"17"; --Striker w. speech
				 when      24 => nu_attr_s <=0; SB_type <= is_MA309; speech_ctrl <= "11111111111111111111111111111111"; DFcmd_par1 <= X"00"; --Krull
				 when 	  25 => nu_attr_s <=0; SB_type <= is_MA216; speech_ctrl <= "11111111111111110000111101110101"; DFcmd_par1 <= X"19"; --Q*Bert's Quest w. speech
				 when 26 to 29 => nu_attr_s <=0; SB_type <= is_MA309; speech_ctrl <= "11111111111111111111111111111111"; DFcmd_par1 <= X"00"; --Sup.Orbit to Amaz Hunt
				 when 30 to 37 => nu_attr_s <=0; SB_type <= is_MA490; speech_ctrl <= "11111111111111111111111111111111"; DFcmd_par1 <= X"00"; --RackEmup o ICE Fever
				 when 38 to 39 => nu_attr_s <=0; SB_type <= is_MA216; speech_ctrl <= "00000111111110111111111111111011";DFcmd_par1 <= X"3F"; --Caveman w. Speech
				 when 40 to 42 => nu_attr_s <=0; SB_type <= is_MA490; speech_ctrl <= "11111111111111111111111111111111"; DFcmd_par1 <= X"00"; --Bounty Hu to Tag Team
				 when others 	=> nu_attr_s <=0; SB_type <= is_special; speech_ctrl <= "11111111111111111111111111111111"; DFcmd_par1 <= X"00";
			end case;	 
		end process;	
	

Attract_S: entity work.attract
port map(   			
         clk => clk_50,
			clk_uart => uart_clk,
         rst => reset_l,
			other_sound => riot_pa_i(7),
			options => SB_Opt(4) & SB_Opt(3),
			num_sounds => nu_attr_s,
			soundnumber => attract_sound,
         send_flag => attract_send_flag
);

	
	
DFP_send: entity work.DFPlayer_Mini_CMD 
port map(   
			DFcmd_cmd => DFcmd_cmd,
			DFcmd_par1 => DFcmd_par1,
			DFcmd_par2 => DFcmd_par2,
         send_flag => send_flag,
         clk => clk_50,
         rst => game_running or lisy_active, --out of reset when the game runs OR in lisy diag mode
         txd => DFP_tx			
);

SC01_Simu: entity work.SC01
port map(   			
         clk => clk_50,
			strobe => sc01_strobe,
			cpu_data => cpu_dout(5 downto 0),
			AR => sc01_AR,
         rst => reset_l
);

-- phase 2 is complement of CPU clock
phi2 <= not(cpu_clk); 

-- IRQ signals ( should be '1')
n_cpu_irq <= n_riot_irq when ( SB_type = is_MA216 or SB_type = is_MA309 ) else
				 ma490_irq_n when ( SB_type = is_MA490 ) else
				 '1';

-- JK flip-flop on the piggyback board triggers CPU IRQ
ma490_U11_q <= not (riot_pb_i(0) or riot_pb_i(1) or riot_pb_i(2) or riot_pb_i(3));
U10: process(ma490_U11_q, riot_pb_o(6))
begin
	if riot_pb_o(6) = '0' then
		ma490_irq_n <= '1';
	elsif falling_edge(ma490_U11_q) then 
		ma490_irq_n <= '0';
	end if;
end process;

-- Address decoding here, cpu address bus 14-12 connect to 74LS138, only a few are used on non-speech board
--'000' riot cs
--'001' dac latch (sound)
--'010' SC01 latch 
--'011' dac latch (speech)
--'111' rom enable
riot_rs_n <= cpu_addr(9); -- ram select for riot RS_N = '0' do select ram
riot_cs 		<= '1' when cpu_addr(14 downto 12) ="000" and riot_rs_n='1' and ( SB_type = is_MA216 or SB_type = is_MA309 ) else
					'1' when cpu_addr(11 downto 10) ="00" and riot_rs_n='1' and ( SB_type = is_MA55 or SB_type = is_MA490 or SB_type = is_SYS1 ) else
					 '0';
ram_cs 		<= '1' when cpu_addr(14 downto 12) ="000" and riot_rs_n='0' and ( SB_type = is_MA216 or SB_type = is_MA309 ) else
					'1' when cpu_addr(11 downto 10) ="00" and
					riot_rs_n='0' and ( SB_type = is_MA55 or SB_type = is_MA490 or SB_type = is_SYS1 ) else
					'0';
soundrom1_cs 		<= '1' when cpu_addr(14 downto 11) ="1110" and ( SB_type = is_MA216 or SB_type = is_MA309 ) else
							'1' when cpu_addr(11 downto 10) ="01" and ( SB_type = is_MA55 or SB_type = is_SYS1 )else -- 0x0400 - 0x07FF & Mirror 0x0800 - 0x0BFF
							'1' when cpu_addr(11 downto 10) ="10" and ( SB_type = is_MA55 or SB_type = is_SYS1 )else -- Mirror 0x0800 - 0x0BFF
							'1' when cpu_addr(11) ='1' and SB_type = is_MA490 else
							'0';
soundrom2_cs 		<= '1' when cpu_addr(14 downto 11) ="1111" and ( SB_type = is_MA216 or SB_type = is_MA309 ) else
							'1' when cpu_addr(11 downto 10) ="11" and ( SB_type = is_MA55 or SB_type = is_SYS1 ) else -- 0x0C00 - 0x0FFF
							'0';
							
-- content of sound rom 1 is read from first 2K of SD
soundrom1_addr <=  --2K
	'0' & cpu_addr(9 downto 0) when (SB_type = is_MA55 or SB_type = is_SYS1) else -- MA55 and SYS1 have only 1K rom
	cpu_addr(10 downto 0);

-- content of sound rom 2 is read from second 2K of SD
soundrom2_addr <=  --2K
	'0' & cpu_addr(9 downto 0) when (SB_type = is_MA55 or SB_type = is_SYS1) else -- MA55 and SYS1 have only 1K rom
	cpu_addr(10 downto 0);
							
							
					
--MA only					
dac_latch 	<= '1' when cpu_addr(14 downto 12) ="001" and cpu_wr_n='0' else '0';
dac_latch_speech 	<= '1' when cpu_addr(14 downto 12) ="011" and cpu_wr_n='0' else '0';
SC01_cs <= '1' when cpu_addr(14 downto 12) ="010" and cpu_wr_n='0' else '0';
-- strobe is an AND of cs for SC-01, phi1 negated and Q1 negate from U2
sc01_strobe 	<= SC01_cs and not cpu_clk;
--sc01_strobe 	<= '1' when cpu_addr(14 downto 12) ="010" and cpu_wr_n='0' else '0';
	
-- Bus control
cpu_din <= 
   ram_dout when ram_cs = '1' else
	riot_dout when riot_cs = '1' else
	soundrom1_dout when soundrom1_cs = '1' else
	soundrom2_dout when soundrom2_cs = '1' else	
	x"FF";
		
-- RIOT_PA
-- input for MA216 & MA309
-- MA55 use PA_out for 1408 DAC
--Sound board inputs through RIOT port A via GOSOF 
-- use not sound for benchtest with 2803A
riot_pa_i(0) <= Sound_meta(0);
riot_pa_i(1) <= Sound_meta(1);
riot_pa_i(2) <= Sound_meta(2);
riot_pa_i(3) <= Sound_meta(3);
riot_pa_i(4) <= Sound_meta(4);
riot_pa_i(5) <= '0'; -- wired, but not used
riot_pa_i(6) <= '0'; -- not wired, not used
-- Strobe signal generates IRQ when one of the inputs S1-S8 go low
-- we do this also for speech as the SB may want to stop current sound
riot_pa_i(7) <= ( Sound_meta(0) or Sound_meta(1) or Sound_meta(2) or Sound_meta(3));

-- RIOT PB
---
-- switches
--dip switch	1	2	3	4	5	6	7	8
--PB				3	J1	5	4	2	1	0	J1
--pin riot		21		18	19	22	23	24	
--
--Test attract mode and speech off for Mars
-- Manual: Switch ON -> 0, Switch OFF -> 1
riot_pb_i(0) <= Sound_meta(0) when ( SB_type = is_MA55 or SB_type = is_MA490 or SB_type = is_SYS1 ) else
				    '1'; -- DIP7 not wired on Gosof PCB
riot_pb_i(1) <= Sound_meta(1) when ( SB_type = is_MA55 or SB_type = is_MA490 or SB_type = is_SYS1 ) else
					 SB_Opt(6); --DIP6
riot_pb_i(2) <= Sound_meta(2) when ( SB_type = is_MA55 or SB_type = is_MA490 or SB_type = is_SYS1 ) else
					 SB_Opt(5); --DIP5
riot_pb_i(3) <= Sound_meta(3) when ( SB_type = is_MA55 or SB_type = is_MA490 or SB_type = is_SYS1 ) else
					 SB_Opt(1); --DIP1
riot_pb_i(4) <= SB_Opt(4) when (SB_type = is_MA216 or SB_type = is_MA309) else --DIP4
					 SB_Opt(2); --MA55 and MA490 -- Attract mode sounds enable (S2 on board)
riot_pb_i(5) <= cpu_addr(10) when ( SB_type = is_MA55 or SB_type = is_SYS1 ) else --CS2 (needed?)
					 SB_Opt(3); --DIP3
riot_pb_i(6) <= '0' when ( SB_type = is_MA55 or SB_type = is_MA490 ) else  -- S16 Spare not used by games with MA-55 and MA490
					  Sound_meta(4) when ( SB_type = is_SYS1 ) else -- 5 inputs with System1 'Multisound'
					  test; -- connected to Testswitch against ground with MA216 & MA390
--for MA216 we have also a wire to A/R of SC01 ( is pB7 a input or a output IO?)
-- jumpered to Vcc in most games, can be strapped to riot PB7 out;
riot_pb_i(7) <= not sc01_AR when SB_type = is_MA216 else
					 SB_Opt(1) when ( SB_type = is_MA55 or SB_type = is_MA490 or SB_type = is_SYS1 ) else --Sound or tones mode (DIP1), many games lack tone support and require this to be high (OFF)
					'1'; -- '1' for MA309 and games with no speech
n_cpu_nmi <=  not sc01_AR when SB_type = is_MA216 else 
				  test when ( SB_type = is_MA55 or SB_type = is_MA490 or SB_type = is_SYS1 ) else 
				  '1'; -- '1' for MA309 and games with no speech
-- DIP8 not wired on Gosof PCB


-- prepare date for MP3 Player	      	  
-- Folder selection wav files
DFcmd_cmd <= X"0F"; -- cmd for folder to playback

-- DFcmd_par1 with game_sel

DFcmd_par2 <=  "000" & lisy_sound when lisy_active = '1'
               else attract_sound when attract_send_flag = '1'
					  else "000" & Sound_meta;

send_flag <= lisy_trig when lisy_active = '1' else
             riot_pa_i(7) when speech_ctrl(to_integer(unsigned(Sound_meta))) = '0' else
				  attract_send_flag;
	
				
				
-- do some signaling 
--LED_1 <= not sc01_AR;
--LED_1 <= '1' when SB_type = is_SYS1 else '0';
--LED_1 <= not audio_O; --signal audio for 093
--LED_2 <= riot_pa_i(7);

-- RAM
RIOT_RAM: entity work.SB_RAM -- RIOT internal RAM 128Byte
port map(
	address	=> cpu_addr(6 downto 0),
	clock		=> clk_50, 
	data		=>  cpu_dout (7 DOWNTO 0),
	wren 		=> ram_cs and not cpu_wr_n,
	q			=> ram_dout
);


-- 6502 CPU
CPU : entity work.T65
port map(
	Enable => '1',
	Mode => "00",
	Res_n => reset_l,
	Clk => cpu_clk,
	Rdy => '1',
	Abort_n => '1',
	IRQ_n => n_Cpu_irq,
	NMI_n => n_Cpu_nmi,
	SO_n => '1',
	R_W_n => cpu_wr_n,
	A(15 downto 0) => cpu_addr,
	DI => cpu_din,
	DO => cpu_dout
);	

-- we use a 6532 also for MA55 and MA490, so we have to adjust the address
addr_6532 <= cpu_addr(4 downto 0) when (SB_type = is_MA216 or SB_type = is_MA309) else
				  '1' & cpu_addr(3 downto 0);
				  
 
 
-- 6532 RAM-IO-Timer	
RIOT : entity work.R6532
port map(
	PHI2 		=> phi2, 	
	RST_N 	=> reset_l, 
	CS			=> riot_cs,
	RW_n 		=> cpu_wr_n,
	IRQ_N		=> n_riot_irq,
	
	ADD			=> addr_6532,
	DIN		=> cpu_dout,
	DOUT		=> riot_dout,
	
   PA_IN		=> riot_pa_i,
	PA_OUT		=> riot_pa_o,
   PB_IN		=> riot_pb_i,
	PB_OUT		=> riot_pb_o	

);

--Latch for pulling DAC data from the CPU data bus
Audio_DAC_Latch: Process(clk_50) is
Begin
	If rising_edge(clk_50) then
		if dac_latch = '1' then
			audio_dat_latch <= cpu_dout;
		end if;		
	end if;
end process;

-- different audio sources for MA216/Ma309 and other soundboards
audio_dat <= audio_dat_latch when ( SB_type = is_MA216 or SB_type = is_MA309) else
				 riot_pa_o;
				 
				 
-- Delta-Sigma audio DAC
Audio_DAC : entity work.dac
generic map(
  msbi_g => 7)
port  map(
   clk_i   => clk_50,
   res_n_i => reset_l,
   dac_i   => audio_dat,
   dac_o   => audio_O
);

-- 9600 baud send clock
uart_gen: entity work.uart_clk_gen 
port map(   
	clk_in => clk_50,
	uart_clk_out	=> uart_clk
);

	
end rtl;