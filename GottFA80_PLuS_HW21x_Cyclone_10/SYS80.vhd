-- VHDL implementation of a System80/80A/80B Gottlieb MPU
-- (c)2020 bontango
--
-- This is free software: you can redistribute
-- it and/or modify it under the terms of the GNU General
-- Public License as published by the Free Software
-- Foundation, either version 3 of the License, or (at your
-- option) any later version.
--
-- This is distributed in the hope that it will
-- be useful, but WITHOUT ANY WARRANTY; without even the
-- implied warranty of MERCHANTABILITY or FITNESS FOR A
-- PARTICULAR PURPOSE. See the GNU General Public License
-- for more details.
--
-- Changelog:
-- initial release for GottFA80_PLuS v2.0 based on GottFA80S V501
--
-- FPGA v4 changes: shared SPI; no Serial
-- v610 inital version for HW 2.1x 10CL006YE144C8G
-- v611 output ports corrected for sound/audio_rx

library ieee;
use ieee.std_logic_1164.all;
--use ieee.std_logic_unsigned.all;
use IEEE.numeric_std.all;

entity SYS80 is
	generic(
		-- compile-time include the lisyctrl diagnostic bridge (default on).
		-- set false to recover ~522 LEs on a tight device; the shared-bus
		-- muxes then constant-fold back to the stock SD/EEPROM behaviour.
		lisy_enable : boolean := true;
		esp_sound   : boolean := false; -- true = ESP/GOSOWAV sound (drop GOSOF80+DFPlayer)
		-- HYBRID build (requires esp_sound=false): GOSOF80 synthesises the supported sounds AND
		-- the sound_link UART feeds the ESP, which plays only speech + complex-80B (sndmode=hybrid
		-- on the ESP, per sndroute). Off by default => stock/esp_sound builds are unchanged.
		hybrid      : boolean := false
	);
	port(
	   -- the FPGA board
		clk_50	: in std_logic;
		reset_sw	: in std_logic;
		LED_Int 	: out STD_LOGIC;
		LED_SDcard 	: out STD_LOGIC;
		LED_ON 	: out STD_LOGIC;

		-- U4 switchmatrix 8strobe; 8 returns
		U4_PB	:	buffer 	std_logic_vector(7 downto 0);
		U4_PA	:	in 	std_logic_vector(7 downto 0);
		
		-- U5 displays  		
		-- 24 Segments ( seperate because of 80B ) J2 1..24
		-- U5_PB 0..6 & U5_PA 4..6
		disp_segments 	: out 	std_logic_vector(1 to 24);				
		U5_PA				: out std_logic_vector(3 downto 0); -- 16 strobes via decoder
		U5_PA_7			: in std_logic; -- Slam
		U5_PB_7			: out std_logic; -- Switch Enable
		
		-- Solenoids, Lamps & Sound
		U6_PA		: out std_logic_vector(7 downto 0); -- Sols & Sound 8 signals combined			
		U6_PB		: out std_logic_vector(7 downto 0);-- Lamps ( 4 control, 4 latch strobes)		
		
		-- SPI SD card & EEprom
		CS_SDcard	: 	buffer 	std_logic;
		CS_EEprom	: 	buffer 	std_logic;
		MOSI			: 	inout 	std_logic;  -- lisyctrl: inout for shared-bus slave mode
		MISO			: 	inout 	std_logic;
		CLK			: 	inout 	std_logic;
		
		-- DIp Switch Game selectOptions
		DIP_Strobe	:	out 	std_logic_vector(3 downto 0);
		DIP_Return	:	in 	std_logic_vector(3 downto 0);
		myTest		: 	in 	std_logic;
		
		-- Sound
		Audio_RX			: 	inout 	std_logic;  -- DFPlayer TX (stock) OR ESP->FPGA display UART in (hybrid/esp_sound)
		Sound 			: 	buffer 	std_logic;

		-- debug
		Debug			:	out 	std_logic
		
		);
end SYS80;


architecture rtl of SYS80 is

signal cpu_clk		: std_logic; -- 895 kHz CPU clock
signal reset_l	 	: std_logic := '0';
signal reset_sw_stable	:	std_logic; 
signal Counter : integer range 0 to 15 := 0;

-- CPU 6502
signal cpu_addr		: std_logic_vector(15 downto 0);
signal cpu_din			: std_logic_vector(7 downto 0);
signal cpu_dout		: std_logic_vector(7 downto 0);
signal cpu_wr_n		: std_logic := '1';
signal phi2				: std_logic;
signal cpu_irq_n		: std_logic;

--  5101 RAM
signal r5101_dout_4bit 	: std_logic_vector(3 downto 0);	  
signal r5101_dout_8bit 	: std_logic_vector(7 downto 0);	  
signal r5101_cs		: std_logic;

-- ROM
signal game_rom_dout  : std_logic_vector(7 downto 0);
signal game_rom2_dout  : std_logic_vector(7 downto 0);
signal system_rom_dout  : std_logic_vector(7 downto 0);

-- RIOT U4 Switch Matrix
signal U4_RAM_cs  		: std_logic;
signal U4_IO_cs  			: std_logic;
signal U4_RAM_dout		: std_logic_vector(7 downto 0);
signal U4_IO_dout			: std_logic_vector(7 downto 0);
signal U4_pa_in			: std_logic_vector(7 downto 0);
signal SW_Freeplay		: std_logic_vector(7 downto 0):="00000000";
--signal U4_pa_out		: std_logic_vector(7 downto 0);
--signal U4_pb_in			: std_logic_vector(7 downto 0);
--signal U4_pb_out			: std_logic_vector(7 downto 0);
signal U4_irq_n			: std_logic;

-- trigger
signal game_over_relay			: std_logic;
signal clk_Z1			: std_logic;
signal clk_Z3			: std_logic;
signal test_sw			: std_logic;
signal credit_sw			: std_logic;


-- RIOT U5 Display Control
signal U5_RAM_cs  		: std_logic;
signal U5_IO_cs  			: std_logic;
signal U5_RAM_dout		: std_logic_vector(7 downto 0);
signal U5_IO_dout			: std_logic_vector(7 downto 0);
--signal U5_pa_in			: std_logic_vector(7 downto 0):="11111111";
signal U5_pa_out		: std_logic_vector(7 downto 0);
--signal U5_pb_in			: std_logic_vector(7 downto 0);
signal U5_pb_out			: std_logic_vector(7 downto 0);
signal U5_irq_n			: std_logic;
signal not80B				: std_logic:='0'; --default we have 80B system
signal segments_80B 		: std_logic_vector(1 to 24);				
signal segments_80 		: std_logic_vector(1 to 24);			
signal bm_segments 		: std_logic_vector(1 to 24);			
signal Din_Seg_A			: std_logic_vector(3 downto 0);	
signal Din_Seg_B			: std_logic_vector(3 downto 0);	
signal Din_Seg_C			: std_logic_vector(3 downto 0);	
signal bm_digit_strobe	: std_logic_vector(3 downto 0);
-- Tournament time-attack display injection (Pstore) -- OFF until tournament_mode='1' (no change)
signal tournament_mode	: std_logic := '0';   -- TODO: drive from lisyctrl/DIP; '0' = stock behaviour
signal ta_arm			: std_logic;
signal ta_dstr			: string(1 to 7);
signal ta_value			: unsigned(23 downto 0);
signal ta_dead			: std_logic;
signal bm_disp1			: string(1 to 7);
signal bm_show			: std_logic;
signal ta_rst			: std_logic;            -- = not reset_l (active-high reset for tourney_display_top)
signal u6pa_masked		: std_logic_vector(7 downto 0);

-- RIOT U& Solenoid & Lamp Control
signal U6_RAM_cs  		: std_logic;
signal U6_IO_cs  			: std_logic;
signal U6_RAM_dout		: std_logic_vector(7 downto 0);
signal U6_IO_dout			: std_logic_vector(7 downto 0);
--signal U6_pa_in			: std_logic_vector(7 downto 0);
signal U6_pa_out		: std_logic_vector(7 downto 0);
--signal U6_pb_in			: std_logic_vector(7 downto 0);
signal U6_pb_out			: std_logic_vector(7 downto 0);
signal U6_irq_n			: std_logic;

-- address decoding helper
signal game_rom_cs		: std_logic;
signal game_rom2_cs		: std_logic;
signal game_rom_addr	:  std_logic_vector(10 downto 0);
signal game_rom2_addr	:  std_logic_vector(10 downto 0);
signal system_rom_cs		: std_logic;
signal system_rom_addr	:  std_logic_vector(12 downto 0);

-- SD card
signal address_sd_card	:  std_logic_vector(13 downto 0);
signal data_sd_card	:  std_logic_vector(7 downto 0);
signal wr_rom			:  std_logic;
signal wr_game_rom			:  std_logic;
signal wr_game_rom2			:  std_logic;
signal wr_system_rom			:  std_logic;
signal SDcard_MOSI	:	std_logic; 
signal SDcard_CLK		:	std_logic; 
signal SDcard_error	:	std_logic; 

-- EEprom we use 128Bytes
signal address_eeprom	:  std_logic_vector(6 downto 0);
signal data_eeprom	:  std_logic_vector(7 downto 0);
signal wr_ram			:  std_logic;
signal EEprom_MOSI	:	std_logic; 
signal EEprom_CLK		:	std_logic; 
signal EEprom_active	:	std_logic; 

-- init & boot message helper
signal game_running		: 	std_logic:= '0';
signal game_dig0			:  character;
signal game_dig1			:  character;
signal game_dig2			:  character;
signal g_opt_dig0			:  character;
signal g_opt_dig1			:  character;
signal sb_opt_dig0			:  character;
signal sb_opt_dig1			:  character;

-- dip games select and options
signal readingdips	: 	std_logic:= '1';
signal game_select 		:  std_logic_vector(5 downto 0);				
signal game_option		: 	std_logic_vector(1 to 6);
signal sb_option		: 	std_logic_vector(1 to 4);
		
-- diff
signal sim_coin		: 	std_logic:= '0';
signal slam				: 	std_logic;
signal lamp_ds 		:  std_logic_vector(3 downto 0);		
signal late80B			: std_logic:='0'; --default we have not a late 80B system with bigger rom

-- game options
signal opt_freeplay				: 	std_logic;
signal opt_init_nvram				: 	std_logic;
signal opt_slam_fix_open			: 	std_logic;
signal opt_slam_fix_close		: 	std_logic;

-- soundboard
-- ROM
signal soundrom1_dout	:	std_logic_vector(7 downto 0);
signal soundrom2_dout	: 	std_logic_vector(7 downto 0);	
	
signal 	Sound_S1			: std_logic;
signal 	Sound_S2			: std_logic;
signal 	Sound_S4			: std_logic;
signal 	Sound_S8			: std_logic;
signal 	Sound_S16		: std_logic;
	
-- address decoding helper
signal soundrom1_cs		: std_logic;
signal soundrom2_cs		: std_logic;
signal sb_rom1_addr	:  std_logic_vector(10 downto 0);
signal sb_rom2_addr	:  std_logic_vector(10 downto 0);
signal soundrom1_addr	:  std_logic_vector(10 downto 0);
signal soundrom2_addr	:  std_logic_vector(10 downto 0);
signal wr_soundrom1		: std_logic;
signal wr_soundrom2		: std_logic;

-- ===== lisyctrl diagnostic bridge (added) =====
signal lisy_active : std_logic := '0';
signal lisy_sclk, lisy_mosi, lisy_miso : std_logic;
signal lisy_u4pb, lisy_u6pa, lisy_u6pb : std_logic_vector(7 downto 0);
signal u6pa_src, u6pb_src, u4_pb_cpu   : std_logic_vector(7 downto 0);
signal sd_cs_n, ee_cs_n, cpu_res_n     : std_logic;
signal lisy_trig : std_logic;   -- long-press of the Gottlieb door test switch
signal lisy_sound5     : std_logic_vector(4 downto 0);  -- lisyctrl sound code -> gosof80
signal lisy_sound_trig : std_logic;                     -- lisyctrl sound trigger -> gosof80
signal sl_tx           : std_logic;                     -- sound_link UART (ESP sound mode)
signal ta_cfg_start    : std_logic_vector(23 downto 0); -- lisyctrl TA_START -> tourney countdown (0 => generic)
signal ta_cfg_decay    : std_logic_vector(23 downto 0); -- lisyctrl TA_DECAY -> tourney countdown (0 => generic)
signal dfp_tx_sig      : std_logic;                     -- GOSOF80 DFPlayer TX (-> Audio_RX only in a stock build)


begin

-- LEDs GottFA80
LED_Int <= not game_running;
LED_SDcard <= SDcard_error;
LED_ON <= '0'; --RTH 


----------------------
-- assign options
----------------------
opt_freeplay				<= not game_option(1);
opt_init_nvram				<= not game_option(2);
opt_slam_fix_open			<= not game_option(3);
opt_slam_fix_close		<= not game_option(4);


----------------------
-- boot message
----------------------
-- Tournament time-attack: countdown subsystem -> shows on display1 during a time-attack game (Pstore)
ta_rst <= not reset_l;
-- Tournament display = OPTION B: the ESP computes + formats the countdown and streams the 7 chars
-- over Audio_RX (PIN_2); disp_inject shows them on the machine display. Replaces the FPGA-autonomous
-- tourney_display_top chain (frees ~463 LE; the ESP now does the math + the 7-seg/16-seg formatting).
-- Only when an ESP is present (hybrid or esp_sound); a stock build has no companion -> no overlay.
GEN_DISPINJ : if esp_sound or hybrid generate
DISPINJ : entity work.disp_inject
	generic map ( CLK_HZ => 50000000, BAUD => 115200, TIMEOUT_MS => 500 )
	port map ( clk => clk_50, rst => ta_rst, rx => Audio_RX, arm => ta_arm, dstr => ta_dstr );
end generate GEN_DISPINJ;
GEN_NODISP : if (not esp_sound) and (not hybrid) generate
	ta_arm  <= '0';
	ta_dstr <= "    611";
end generate GEN_NODISP;
bm_disp1 <= ta_dstr when ta_arm = '1' else "    611";               -- countdown when armed, else SW version
bm_show  <= '1' when (game_running = '0' or ta_arm = '1') else '0';  -- run at boot OR in a time-attack game

BM: entity work.boot_message
port map(
	clk_in		=> cpu_clk,
	-- Control/Data Signals,
   show  => bm_show,
	SD_error => not SDcard_error,
	-- output
	bm_digit_strobe	=> bm_digit_strobe,
	bm_segments => bm_segments,
	-- input (display data)
	display1	=> bm_disp1,  -- time-attack countdown (when armed) or SW VERSION
	display2	=> "    " & game_dig2 & game_dig1 & game_dig0,	
	display3	=> " 050963",
	display4	=> " " & g_opt_dig1 & g_opt_dig0 & "  " & sb_opt_dig1 & sb_opt_dig0,
	error_disp4 => "0000000",
	status_d	=> "       "	
	);
	
----------------------
-- try anti thunk at boot
----------------------
AT: entity work.anti_thunk
port map(
	clk_in		=> cpu_clk, 	
	-- Control/Data Signals,
   is_active  => not game_running,
	-- output
	lamp_ds => lamp_ds
	);
	
----------------------
-- read the dips
----------------------
RDIPS: entity work.read_the_dips
port map(
	clk_in		=> cpu_clk, 	
	i_Rst_L  => reset_sw_stable,     -- FPGA Reset   
   readingdips	=> readingdips,
	--output 
	game_select	=> game_select,
	game_option	=> game_option,
	sb_option => sb_option,
	-- strobes
	strobes => DIP_Strobe,
	-- returns
	returns => DIP_Return
	);
	

CONVG: entity work.byte_to_ascii
port map(
	clk_in	=> clk_50, 		
	mybyte	=> "1" & not opt_freeplay & game_select,
	dig0_ascii => game_dig0,
	dig1_ascii => game_dig1,
	dig2_ascii => game_dig2
	);
	
CONVO: entity work.byte_to_ascii
port map(
	clk_in	=> clk_50, 		
	mybyte	=> "11" & game_option(6) & game_option(5) & game_option(4) & game_option(3) & game_option(2) & game_option(1),
	dig0_ascii => g_opt_dig0,
	dig1_ascii => g_opt_dig1,
	dig2_ascii => open
	);
	
CONVS: entity work.byte_to_ascii
port map(
	clk_in	=> clk_50, 		
	mybyte	=> "1111" & sb_option(4) & sb_option(3) & sb_option(2) & sb_option(1),
	dig0_ascii => sb_opt_dig0,
	dig1_ascii => sb_opt_dig1,
	dig2_ascii => open
	);
		
-- RIOT IRQ outputs all assert CPU IRQ input
cpu_irq_n <= U4_irq_n and U5_irq_n and U6_irq_n;		
--cpu_irq_n <= '1';

-- general assigments
phi2 <= not cpu_clk;

-- slam
slam <= '0' when opt_slam_fix_open = '1' else --slam open for late 80B games
		  '1' when opt_slam_fix_close = '1' else -- slam fix closed
		  U5_PA_7; --real slam

---------------------
-- shared SPI bus
----------------------
--SD card only at start of game
-- ===== lisyctrl: shared-bus arbitration + I/O mux (diagnostic mode) =====
-- In diag mode the FPGA tri-states the SPI bus and becomes an SPI slave, the
-- 6502 is held in reset, and lisyctrl drives the machine I/O. Default = inactive
-- => behaviour is identical to the original. See LISYCTRL.md.
MOSI <= 'Z' when lisy_active = '1' else SDcard_MOSI when reset_l = '0' else EEprom_MOSI;
CLK  <= 'Z' when lisy_active = '1' else SDcard_CLK  when reset_l = '0' else EEprom_CLK;
MISO <= lisy_miso when lisy_active = '1' else 'Z';
lisy_sclk <= CLK;
lisy_mosi <= MOSI;
-- handshake to the ESP32 companion on the Debug pin: '1' = lisyctrl/diag mode is
-- active => the shared SPI bus is released to the ESP (FPGA is now an SPI slave,
-- 6502 held in reset, SD/EEPROM deselected). The ESP polls this before driving.
-- In the ESP-sound build (and the hybrid build) Debug is instead driven by the sound_link
-- UART (it carries the diag token + sound/game) -- see GEN_ESP_SND / GEN_HYB_LINK. So only
-- drive the level here when neither ESP path is active (stock / PIN-2-sound builds).
GEN_DBG_LVL: if (not esp_sound) and (not hybrid) generate
Debug <= lisy_active;
end generate GEN_DBG_LVL;
CS_SDcard <= '1' when lisy_active = '1' else sd_cs_n;
CS_EEprom <= '1' when lisy_active = '1' else ee_cs_n;
cpu_res_n <= '0' when lisy_active = '1' else reset_l;
u6pa_src  <= lisy_u6pa when lisy_active = '1' else U6_pa_out;
-- Tournament: neutralise a free-game solenoid (knocker) when armed. Placeholder code = no block. -- Pstore
TBLOCK: entity work.tourney_block
	generic map ( SEL_HI => 3, SEL_LO => 0, BLOCK_CODE => "1111", NOOP_CODE => "1111" )
	port map ( port_in => u6pa_src, sol_active => '1', tournament_mode => tournament_mode, port_out => u6pa_masked );
u6pb_src  <= lisy_u6pb when lisy_active = '1' else U6_pb_out;
U4_PB     <= lisy_u4pb when lisy_active = '1' else u4_pb_cpu;
-- mode entry: a LONG-PRESS of the Gottlieb door test switch enters diag mode;
-- any reset/reboot (reset_l='0') exits it. (lisy_trig = detect_test_sw long_push,
-- which is active from attract/idle -- the usual place to run diagnostics.)
GEN_LISY: if lisy_enable generate
LISY_MODE: process begin
	wait until rising_edge(clk_50);
	if reset_l = '0' then
		lisy_active <= '0';
	elsif lisy_trig = '1' then
		lisy_active <= '1';
	end if;
end process;
LISY_CTRL: entity work.lisyctrl
port map(
	clk => clk_50, active => lisy_active,
	sclk => lisy_sclk, mosi => lisy_mosi, miso => lisy_miso,
	o_U4_PB => lisy_u4pb, i_U4_PA => U4_pa_in,
	o_U5_PA => open, o_U5_PB7 => open,
	o_U6_PA => lisy_u6pa, o_U6_PB => lisy_u6pb, o_segments => open,
	o_sound => lisy_sound5, o_sound_trig => lisy_sound_trig,
	o_tournament => tournament_mode,                  -- arms time-attack display + tourney_block (Pstore)
	o_ta_start => ta_cfg_start, o_ta_decay => ta_cfg_decay,  -- time-attack start/decay -> countdown (Pstore)
	i_DIP_Ret => '0' & DIP_Return, i_slam => slam, wd_tripped => open
);
end generate GEN_LISY;

-- lisyctrl excluded: drive the shared signals to constants so the arbitration
-- muxes fold to stock (lisy_active='0' => MISO=Z/input, MOSI/CLK=SD or EEPROM).
GEN_NOLISY: if not lisy_enable generate
	lisy_active <= '0';
	lisy_miso   <= 'Z';
	lisy_u4pb   <= (others => '0');
	lisy_u6pa   <= (others => '0');
	lisy_u6pb   <= (others => '0');
	ta_cfg_start <= (others => '0');   -- no lisyctrl -> 0 => tourney countdown uses its generic defaults
	ta_cfg_decay <= (others => '0');
end generate GEN_NOLISY;

---------------------
-- count ints
-- indicate game running or not
---------------------
COUNT_INTS: entity work.count_to_zero
port map(   
   Clock => clk_50,
	count =>"11111111",
	d_in => cpu_irq_n,
	d_out => game_running,
	clear => reset_l
	);
 
---------------------
-- detection game over relay (Q1)
----------------------
clk_Z1 <= '1' when U6_pb_out(7 downto 4) = "0001" else '0'; --DS1

sn74175_Game_O: entity work.sn74175 
port map(   
   Clock => clk_50,
	clk => clk_Z1,
	clear	=> '1',
	D => U6_pb_out(3 downto 0),
	Q => open,
	Qn(0) => game_over_relay
);

 
---------------------
-- SD card stuff
----------------------
SD_CARD: entity work.SD_Card
port map(
	--no_of_sectors => x"20", -- 32 sectors per rom
	--
	i_clk		=> clk_50,	
	-- Control/Data Signals,
   i_Rst_L  => not readingdips,     -- FPGA Reset & dip read finished
	-- PMOD SPI Interface
   o_SPI_Clk  => SDcard_CLK,
   i_SPI_MISO => MISO,
   o_SPI_MOSI => SDcard_MOSI,
   o_SPI_CS_n => sd_cs_n,
	-- selection
	selection => "0" & opt_freeplay & not game_select,
	-- data
	address_sd_card => address_sd_card,
	data_sd_card => data_sd_card,
	wr_rom => wr_rom,
	-- control CPU
	cpu_reset_l => reset_l,
	-- feedback
	SDcard_error => SDcard_error
	);	
	
------------------
-- ROMs ----------
-- moved to RAM, initial 16KByte read from SD
-- one file of 16Kbyte for all Gottlieb Variants
-- one file of 16Kbyte for all Gottlieb Variants
-- lower half is game rom and need to be copied to 8KByte blocks
-- upper half is system rom
-- need to be mapped to MPU memory  address range
------------------
					
-- address selection	
-- read from SD when wr_rom == 1
-- else map to address room

-- content of game rom is read from first 2K of SD
wr_game_rom <= '1' when ((wr_rom='1') and (address_sd_card(13 downto 11) ="000" )) else '0';
game_rom_addr <=  --2K
	address_sd_card(10 downto 0) when wr_game_rom = '1' else
	cpu_addr(10 downto 0);

-- content of extended game rom (late 80B games) is read from second 2K of SD
wr_game_rom2 <= '1' when ((wr_rom='1') and (address_sd_card(13 downto 11) ="001" )) else '0';
game_rom2_addr <=  --2K
	address_sd_card(10 downto 0) when wr_game_rom2 = '1' else
	cpu_addr(10 downto 0);
		
-- content of sound rom 1 is read from third 2K of SD
wr_soundrom1 <= '1' when ((wr_rom='1') and (address_sd_card(13 downto 11) ="010" )) else '0';
sb_rom1_addr <=  --2K
	address_sd_card(10 downto 0) when wr_soundrom1 = '1' else soundrom1_addr;

-- content of sound rom 2 is read from fourth 2K of SD
wr_soundrom2 <= '1' when ((wr_rom='1') and (address_sd_card(13 downto 11) ="011" )) else '0';
sb_rom2_addr <=  --2K
	address_sd_card(10 downto 0) when wr_soundrom2 = '1' else soundrom2_addr;
	
-- content of system rom is read from second 8K of SD	
wr_system_rom <= '1' when ((wr_rom='1') and (address_sd_card(13) = '1' )) else '0';
system_rom_addr <= --8K
	address_sd_card(12 downto 0) when wr_system_rom = '1' else
	cpu_addr(12 downto 0);

	
-- Address decoding here, 
-- 0x0000-0x07FF	RIOTS RAM and I/O
-- used: A13 | A12 | A11 | A10 | A9 | A8 | A7
--         0x800 blocks  | n.u.|rs_n|  RIOT sel
--
-- U4 Memory (RIOT) - 0x0000 - 0x007F
U4_RAM_cs 	<= '1' when cpu_addr(13 downto 7) ="0000000" else '0';
-- U5 Memory (RIOT) - 0x0080 - 0x00FF
U5_RAM_cs 	<= '1' when cpu_addr(13 downto 7) ="0000001" else '0';
-- U6 Memory (RIOT) - 0x0100 - 0x017F
U6_RAM_cs 	<= '1' when cpu_addr(13 downto 7) ="0000010" else '0';
-- Not Used - 0x0180 - 0x01FF (Test Fixture)
--
-- U4 Registers - 0x0200 - 0x027F
U4_IO_cs 	<= '1' when cpu_addr(13 downto 7) ="0000100" else '0';
-- U5 Registers - 0x0280 - 0x02FF
U5_IO_cs 	<= '1' when cpu_addr(13 downto 7) ="0000101" else '0';
-- U6 Registers - 0x0300 - 0x037F
U6_IO_cs 	<= '1' when cpu_addr(13 downto 7) ="0000110" else '0';
-- 0x0800-0x0FFF	"001" not used
--
-- 0x1000-0x17FF	"010" Game Rom
game_rom_cs	<= '1' when cpu_addr(13 downto 11) ="010" else '0';
-- 0x1800-0x1FFF	"011" Z5 (5101)
r5101_cs <= '1' when cpu_addr(13 downto 11) ="011" else '0';	
-- 0x2000-0x27FF	"100" SYSTEM ROM
-- 0x2800-0x2FFF	"101" SYSTEM ROM
-- 0x3000-0x37FF	"110" SYSTEM ROM
-- 0x3800-0x3FFF	"111" SYSTEM ROM
system_rom_cs <= cpu_addr(13);
-- late 80B games only when selected
late80B <= '1' when game_select(5 downto 3) = "000" else '0'; --all games after Robo War (GAME SELECT IS NEGATED)
game_rom2_cs	<= '1' when cpu_addr(13 downto 11) ="010" and cpu_addr(15) = '1' and late80B='1' else '0';


-- Bus control
cpu_din <= 
	game_rom2_dout when game_rom2_cs='1' else -- late 80B overwrites selection 
	U4_RAM_dout when U4_RAM_cs='1' else
	U5_RAM_dout when U5_RAM_cs='1' else
	U6_RAM_dout when U6_RAM_cs='1' else
	U4_IO_dout when U4_IO_cs='1'  else
	U5_IO_dout when U5_IO_cs='1'  else
	U6_IO_dout when U6_IO_cs='1'  else		
	game_rom_dout when game_rom_cs='1' else
	--"1111" & r5101_dout_4bit when r5101_cs='1' else	
	cpu_dout(7 downto 4) & r5101_dout_4bit when r5101_cs='1' else	
	system_rom_dout when system_rom_cs='1' else
	x"FF";

---------------------
-- U4
-- Switches
----------------------
META2: entity work.Cross_Slow_To_Fast_Clock_Bus
port map(
   i_D => U4_PA,
	o_Q => U4_pa_in,
   i_Fast_Clk => cpu_clk
	);

-- simulate left coin ( strobe 1 / return 7 )
Freeplay: process(sim_coin, U4_PB, opt_freeplay)
 begin 
    if (( sim_coin = '1') and (U4_PB(1) = '1') and (opt_freeplay = '1')) then
		SW_Freeplay(7) <= '1';
	 else	
		SW_Freeplay(7) <= '0';
	end if;	
 end process;  
	
-- detect credit and test_switch for trigger
-- due to iverters on the borad switch is active when both strobe and return are HIGH
-- switch enable for dips need to be low, Gottlieb does check dips when not in game!?
--credit_sw <=   U4_pa_in(7) and U4_PB(4) and not U5_pb_out(7);  -- credit switch is strobe 4 and return 7 and not dip switch active
detect_credit_sw_trigger: entity work.detect_sw_trigger
port map(
	clk    => cpu_clk,
	sw_strobe => U4_PB(4),
	sw_return => U4_pa_in(7),
	sw_enable => U5_pb_out(7),
	trigger => credit_sw,	
	rst 	=> game_running
);

detect_credit_sw: entity work.detect_sw
port map(
	clk    => cpu_clk,
	sw_strobe => U4_PB(4),
	sw_return => U4_pa_in(7),
	sw_enable => U5_pb_out(7),
	short_push => open,
	long_push => sim_coin,
	rst 	=> game_running
);

--test_sw   <= 	U4_pa_in(7) and U4_PB(0) and not U5_pb_out(7); -- test switch is strobe 0 and return 7 and not dip switch active
detect_test_sw: entity work.detect_sw
port map(
	clk    => cpu_clk,
	sw_strobe => U4_PB(0),
	sw_return => U4_pa_in(7),
	sw_enable => U5_pb_out(7),
	short_push => test_sw,
	long_push => lisy_trig,   -- lisyctrl: long-press of the door test switch enters diag
	rst 	=> game_running
);

--------------------------------------------------
-- U5
-- display 
--------------------------------------------------
U5_PB_7 <= not U5_pb_out(7); --switch enable

-- determine if we have a 80B system -> no strobes on U5 PA0 .. PA3
COUNT_STROBES: entity work.count_to_zero
port map(   
   Clock => clk_50,
	count =>"00001111",
	d_in => U5_pa_out(1), --count only one of  signals				   
	d_out => not80B,
	clear => reset_l
	);

--------------------------------------------------
-- 80B display routines	
--------------------------------------------------
segments_80B(8) <= not U5_pb_out(4); --LD1
segments_80B(16) <= not U5_pb_out(5); --LD2
segments_80B(24) <= not U5_pb_out(6); --Reset
-- D0 ... D4
sn74175_80B_1: entity work.sn74175 
port map(   
   Clock => clk_50,
	clk => U5_pa_out(4),
	clear	=> reset_l,
	D => not U5_pb_out(3 downto 0),
	Q => open,
	Qn(0) => segments_80B(2),
	Qn(1) => segments_80B(6),
	Qn(2) => segments_80B(7),
	Qn(3) => segments_80B(1)
);
sn74175_80B_2: entity work.sn74175 
port map(   
   Clock => clk_50,
	clk => U5_pa_out(5),
	clear	=> reset_l,
	D => not U5_pb_out(3 downto 0),
	Q => open,
	Qn(0) => segments_80B(10),
	Qn(1) => segments_80B(14),
	Qn(2) => segments_80B(15),
	Qn(3) => segments_80B(9)
);

--------------------------------------------------
-- 80/80A display routines	
--------------------------------------------------
--digit strobes
U5_PA(3 downto 0) <= U5_pa_out(3 downto 0) when (game_running='1' and ta_arm='0') else bm_digit_strobe;  -- time-attack overlays the strobes

-- assign display segments dependent on display type		
disp_segments <= 
--	segments_80B when not80B = '0' else	
--	bm_segments when game_running = '0' else --and U5_pb_out(6) = '1' else  --RTH
--	segments_80;
	bm_segments when ( ta_arm = '1' ) or ( game_running = '0' and U5_pb_out(6) = '1') or SDcard_error = '0' else  --RTH (ta_arm = time-attack overlay)
	segments_80 when not80B = '1' else
   segments_80B;

	
--segments
sn74175_80_1: entity work.sn74175 
port map(   
	Clock => clk_50,
	clk => U5_pa_out(4),
	clear	=> '1',
	D => not U5_pb_out(3 downto 0),
	Q => open,
	Qn => Din_Seg_A
);
sn74175_80_2: entity work.sn74175 
port map(   
	Clock => clk_50,
	clk => U5_pa_out(5),
	clear	=> '1',
	D => not U5_pb_out(3 downto 0),
	Q => open,
	Qn => Din_Seg_B
);
sn74175_80_3: entity work.sn74175 
port map(   
	Clock => clk_50,
	clk => U5_pa_out(6),
	clear	=> '1',
	D => not U5_pb_out(3 downto 0),
	Q => open,
	Qn => Din_Seg_C
);


sn7448_1: entity work.sn7448
port map(   
	Din 	=> Din_Seg_A,
	Dout  => segments_80(1 to 7)
);
segments_80(8) <= not U5_pb_out(4);

sn7448_2: entity work.sn7448
port map(   
	Din 	=> Din_Seg_B,
	Dout  => segments_80(9 to 15)
);
segments_80(16) <= not U5_pb_out(5);

sn7448_3: entity work.sn7448
port map(   
	Din 	=> Din_Seg_C,
	Dout  => segments_80(17 to 23)
);
segments_80(24) <= not U5_pb_out(6);


--------------------------------------------------
-- solenoids & lamps
--------------------------------------------------
U6_PA(4 downto 0) <= not u6pa_masked(4 downto 0) when (game_running='1' or lisy_active='1') else "00000"; --sound AND Z31 (via tourney_block)
U6_PA(7 downto 5) <= u6pa_masked(7 downto 5) when (game_running='1' or lisy_active='1') else "111"; -- decoder enable and Sol9
U6_PB(3 downto 0) <= not u6pb_src(3 downto 0) when (game_running='1' or lisy_active='1') else "1111"; -- thunk prevention (inverter)
U6_PB(7 downto 4) <= u6pb_src(7 downto 4) when (reset_l='1' or lisy_active='1') else lamp_ds; -- thunk prevention 
	
-- cpu clock 892Khz
clock_gen: entity work.cpu_clk_gen 
port map(   
	clk_in => clk_50,
	cpu_clk_out	=> cpu_clk
);


U1: entity work.T65 -- 6502 
port map(
	Mode    			=> "00",
	Res_n   			=> cpu_res_n,
	Enable  			=> '1',
	Clk     			=> cpu_clk,
	Rdy     			=> '1',
	Abort_n 			=> '1',
	IRQ_n   			=> cpu_irq_n,
	NMI_n   			=> '1',
	SO_n    			=> '1',
	R_W_n 			=> cpu_wr_n,
	A(15 downto 0)	=> cpu_addr,       
	DI     			=> cpu_din,
	DO    			=> cpu_dout
	);
		

	----------------------
-- read eeprom, read/write to ram
----------------------
EEprom: entity work.EEprom
port map(
	i_clk => clk_50,
	address_eeprom	=> address_eeprom,
	data_eeprom	=> data_eeprom,
	wr_ram => wr_ram,
	q_ram => r5101_dout_8bit,
	-- Control/Data Signals,
   --i_Rst_L  => reset_sw_stable,     -- FPGA Reset   
	i_Rst_L  => reset_l,
	-- PMOD SPI Interface
   o_SPI_Clk  => EEprom_CLK,
   i_SPI_MISO => MISO,
   o_SPI_MOSI => EEprom_MOSI,
   o_SPI_CS_n => ee_cs_n,
	-- selection
	selection => not game_select,
	-- write trigger
	w_trigger(3) => game_over_relay,
	w_trigger(2) => test_sw,
	w_trigger(1) => credit_sw,
	w_trigger(0) => not game_option(1), -- as trigger for testing	
	-- init trigger (no read, RAM will be zero)
	i_init_Flag => not opt_init_nvram, -- 0 if Dip is set 
	-- signal to outside
	is_active => EEprom_active
	);	
	
----------------------
-- 5101 ram (dual port)
----------------------
Z5: entity work.R5101 -- 5101 RAM 128Byte (256 * 4bit) 
	port map(
		address_a	=> cpu_addr(7 downto 0),
		address_b   => address_eeprom,
		clock			=> clk_50,
		data_a		=> cpu_dout (3 DOWNTO 0), -- Gottlieb use the lower 4 bits
		data_b		=> data_eeprom, --8bit
		wren_a 		=> r5101_cs and not cpu_wr_n,
		wren_b 		=> wr_ram,
		q_a			=> r5101_dout_4bit,
		q_b			=> r5101_dout_8bit
);
	
	
U4_RAM: entity work.RIOT_RAM
port map(
	address	=> cpu_addr(7 DOWNTO 0),
	clock		=> clk_50, 
	data		=>  cpu_dout (7 DOWNTO 0),
	wren 		=> U4_RAM_cs and not cpu_wr_n,
	q			=> U4_RAM_dout
);	
U4_IO: entity work.R6532  -- Switchmatrx
port map(
	phi2   => phi2,
   rst_n  => reset_l,
   cs     => U4_IO_cs,
   rw_n   => cpu_wr_n,
	irq_n  => U4_irq_n,
	
   add    => cpu_addr(4 downto 0),
   din	 => cpu_dout,
	dout	 => U4_IO_dout,
		
	pa_in	 => U4_pa_in or SW_Freeplay,
   pa_out => open,
   pb_in  => "00000000",
	pb_out => u4_pb_cpu
 );

U5_RAM: entity work.RIOT_RAM
port map(
	address	=> cpu_addr(7 DOWNTO 0),
	clock		=> clk_50, 
	data		=>  cpu_dout (7 DOWNTO 0),
	wren 		=> U5_RAM_cs and not cpu_wr_n,
	q			=> U5_RAM_dout
);  
U5_IO: entity work.R6532  -- Display Control
port map(
	phi2   => phi2,
   rst_n  => reset_l,
   cs     => U5_IO_cs,
   rw_n   => cpu_wr_n,
	irq_n  => U5_irq_n,
	
   add    => cpu_addr(4 downto 0),
   din	 => cpu_dout,
	dout	 => U5_IO_dout,
			
	pa_in	 => slam & "0000000",
   pa_out => U5_pa_out,
   pb_in  => "00000000",
	pb_out => U5_pb_out
 );
  
U6_RAM: entity work.RIOT_RAM
port map(
	address	=> cpu_addr(7 DOWNTO 0),
	clock		=> clk_50, 
	data		=>  cpu_dout (7 DOWNTO 0),
	wren 		=> U6_ram_cs and not cpu_wr_n,
	q			=> U6_RAM_dout
);
U6_IO: entity work.R6532  -- Solenoid & Lamp Control
port map(
	phi2   => phi2,
   rst_n  => reset_l,
   cs     => U6_IO_cs,
   rw_n   => cpu_wr_n,
	irq_n  => U6_irq_n,
	
   add    => cpu_addr(4 downto 0),
   din	 => cpu_dout,
	dout	 => U6_IO_dout,
		
	pa_in	 => "00000000",
   pa_out => U6_pa_out,
   pb_in  => "00000000",
	pb_out => U6_pb_out
 );  

GAME: entity work.GAME_ROM -- Game ROM 2KByte
port map(
	address	=> game_rom_addr,  -- 10 downto 0
	clock		=> clk_50, 
	data => data_sd_card,
	wren => wr_game_rom,	
	q			=> game_rom_dout
	);

GAME2: entity work.GAME_ROM -- extended Game ROM 2KByte or late 80B games
port map(
	address	=> game_rom2_addr,  -- 10 downto 0
	clock		=> clk_50, 
	data => data_sd_card,
	wren => wr_game_rom2,	
	q			=> game_rom2_dout
	);
	
SYSTEM: entity work.SYSTEM_ROM -- System ROM 8KByte
port map(
	address	=> system_rom_addr, -- 12 downto 0
	clock		=> clk_50, 
	data => data_sd_card,
	wren => wr_system_rom,	
	q	=> system_rom_dout
	);
	
-- soundrom1 for MA219/MA309
-- soundrom for MA55 and others	
SOUNDROM1: entity work.GAME_ROM -- ROM 2KByte
port map(
	address	=> sb_rom1_addr,  -- 10 downto 0
	clock		=> clk_50, 
	data 		=> data_sd_card,
	wren 		=> wr_soundrom1,
	q			=> soundrom1_dout
	);

-- soundrom2 for MA219/MA309
-- maskrom (R6530 internal) for MA55 and others	
SOUNDROM2: entity work.GAME_ROM -- ROM 2KByte
port map(
	address	=> sb_rom2_addr,  -- 10 downto 0
	clock		=> clk_50, 
	data 		=> data_sd_card,
	wren 		=> wr_soundrom2,
	q			=> soundrom2_dout
	);
	
	
META1: entity work.Cross_Slow_To_Fast_Clock
port map(
   i_D => reset_sw,
	o_Q => reset_sw_stable,
   i_Fast_Clk => cpu_clk
	); 

	
--integrated soundboard											Sound#3 by pushing test button
Sound_S1 <= ((not u6_pa_out(0) and not u6_pa_out(4))) when mytest='1' else '1';
Sound_S2 <= ((not u6_pa_out(1) and not u6_pa_out(4))) when mytest='1' else '1';
Sound_S4 <= ((not u6_pa_out(2) and not u6_pa_out(4))) when mytest='1' else '0';
Sound_S8 <= ((not u6_pa_out(3) and not u6_pa_out(4))) when mytest='1' else '0';


---------------------
-- detection Sound16 (Q10)
----------------------
clk_Z3 <= '1' when U6_pb_out(7 downto 4) = "0011" else '0'; --DS3

sn74175_Sound16: entity work.sn74175 
port map(   
   Clock => clk_50,
	clk => clk_Z3,
	clear	=> '1',
	D => U6_pb_out(3 downto 0),
	--Q => open,
	Q(1) => Sound_S16
);


GEN_FPGA_SND : if not esp_sound generate
SOUNDBOARD: entity work.gosof80
port map(
		clk_50	=> clk_50,
		cpu_clk  => cpu_clk,
		reset_l	=> reset_l,
		game_running => game_running,
		test	=> '1', --myTest,
		Audio_O	=> sound,
		
		-- Sound input S1,S2,S4,S8,S16
		-- initial low due to 2803A on input of Gosof80
		Sound_Meta(0) => Sound_S1,
		Sound_Meta(1) => Sound_S2,
		Sound_Meta(2) => Sound_S4,
		Sound_Meta(3) => Sound_S8,
		Sound_Meta(4) => Sound_S16,
		-- lisyctrl direct sound inject (diag mode)
		lisy_active => lisy_active,
		lisy_sound  => lisy_sound5,
		lisy_trig   => lisy_sound_trig,
		
		--Soundboard Options S1 DIPs 1..6
		SB_Opt => sb_option(1) & sb_option(2) & sb_option,
		
		--switches	:	
		game_sel	=> not game_select,
		--option   => sb_option,
		
		-- DFPlayer
		DFP_tx	=> dfp_tx_sig,   -- routed to Audio_RX only in a stock build (see GEN_DFP_DRV)
		
		--module
		soundrom1_addr => soundrom1_addr,
		soundrom2_addr => soundrom2_addr,
		soundrom1_dout => soundrom1_dout,
		soundrom2_dout => soundrom2_dout
		
	);
end generate GEN_FPGA_SND;

GEN_ESP_SND : if esp_sound generate
-- ESP/GOSOWAV is the sound source: GOSOF80 + DFPlayer dropped. A single UART on the
-- Debug pin (PIN_11 / K2, right next to the FPGA) carries the diag-mode token + the
-- live sound# + game# to the ESP (diag and gameplay sound never overlap). The audio
-- pins Audio_RX (PIN_2) and Sound (PIN_7) are freed -> tie them off.
SND_LINK : entity work.sound_link
port map(
	clk => clk_50, rst => not reset_l,
	diag => lisy_active,
	sound => Sound_S16 & Sound_S8 & Sound_S4 & Sound_S2 & Sound_S1,
	game => game_select,
	game_running => game_running,                     -- tournament auto-timer (0xF2/0xF3 to ESP)
	tx => sl_tx
);
Debug    <= sl_tx;
Sound    <= '0';
end generate GEN_ESP_SND;

-- Audio_RX/PIN_2 direction: DFPlayer TX in a stock build; an INPUT (ESP -> disp_inject) whenever an
-- ESP is present (hybrid or esp_sound). Exactly one driver per build mode (no conflict).
GEN_DFP_DRV : if (not esp_sound) and (not hybrid) generate Audio_RX <= dfp_tx_sig; end generate GEN_DFP_DRV;
GEN_RX_IN   : if esp_sound or hybrid           generate Audio_RX <= 'Z';        end generate GEN_RX_IN;

-- HYBRID build: GOSOF80 stays the sound source (GEN_FPGA_SND drives Sound/PIN_7 + the unused
-- DFP_tx/PIN_2), and the sound_link UART feeds the ESP on the Debug pin so it can play the
-- speech + complex-80B that GOSOF80 can't. Only the Debug pin is driven here (the audio pins
-- belong to GOSOF80). `and not esp_sound` guards against a both-true misconfig (no double Debug).
GEN_HYB_LINK : if hybrid and not esp_sound generate
SND_LINK_H : entity work.sound_link
port map(
	clk => clk_50, rst => not reset_l,
	diag => lisy_active,
	sound => Sound_S16 & Sound_S8 & Sound_S4 & Sound_S2 & Sound_S1,
	game => game_select,
	game_running => game_running,                     -- tournament auto-timer (0xF2/0xF3 to ESP)
	tx => sl_tx
);
Debug <= sl_tx;
end generate GEN_HYB_LINK;
 	
	
	
end rtl;
		