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
-- System 80 / 80A / 80B family decode from the DIP game number (lib_common).
-- See the header of gts_family.vhd for the PinMAME cross-check of every range.
use work.gts_family.all;

entity SYS80 is
	generic(
		-- compile-time include the lisyctrl diagnostic bridge (default on).
		-- set false to recover ~522 LEs on a tight device; the shared-bus
		-- muxes then constant-fold back to the stock SD/EEPROM behaviour.
		lisy_enable : boolean := true;
		-- Chemin de chargement du jeu. JP1 coupe sur cette carte => le FPGA n'a
		-- plus acces a la NOR, qui reste a l'ESP. On charge donc depuis la SD
		-- branchee sur P4 (CS_SDcard=P4.15 + le bus MOSI/MISO/CLK). Une seule
		-- branche est elaboree : l'autre ne coute rien. -- Pstore
		use_sd      : boolean := true;   -- true = carte SD (prouve) | false = NOR U6
		-- Banc sans faisceau : les retours DIP flottent -> numero de jeu ET options
		-- aleatoires (game_option(5) inverse la famille 80B !). >= 0 : jeu force,
		-- options neutres (DIP ouvertes). -1 = lecture DIP normale. -- Pstore
		bench_game  : integer := -1;
		-- true : options forcees neutres (FP actif) meme avec bench_game=-1 --
		-- pour isoler des DIP d'option mal reglees sans toucher au choix du jeu. -- Pstore
		bench_opts  : boolean := false;
		esp_sound   : boolean := true;  -- true = ESP/GOSOWAV sound (drop GOSOF80+DFPlayer)
		-- NOSND build 2026-07-09: this 80B machine has its REAL sound board (diag
		-- test drives it via the U6_PA strobe); GOSOF80 (1709 LE + 1 M9K) freed
		-- -> headroom for the AY integration. sound_link/heartbeat kept (GEN_ESP_SND).
		-- HYBRID build (requires esp_sound=false): GOSOF80 synthesises the supported sounds AND
		-- the sound_link UART feeds the ESP, which plays only speech + complex-80B (sndmode=hybrid
		-- on the ESP, per sndroute). Off by default => stock/esp_sound builds are unchanged.
		hybrid      : boolean := false;
		-- ===================================================================
		-- 80B DIAGNOSTIC TEXT DISPLAY (disp80b_diag) -- MEASURED COST, 2026-07-27.
		--
		-- disp80b_diag lets LISYcontrol paint 2x20 ASCII on an 80B alphanumeric
		-- glass while the 6502 is held.  It is the ONLY consumer of lisyctrl's
		-- 40-byte text buffer (o_txt, registers 0x50..0x77), so enabling it
		-- costs BOTH modules:
		--     disp80b_diag       328 LE /  63 registers
		--     lisyctrl txt_b     ~247 LE / 320 registers
		--     -----------------------------------------
		--     total              ~575 LE / 383 registers   -> 366 LABs becomes
		--                                                     392/392 = 100 %.
		--
		-- Until now this was DEAD CODE that nobody noticed: `not80B` was
		-- hard-wired to '1', the segments_80B branch of the display mux was
		-- unreachable, and Quartus quietly pruned the whole chain.  Making
		-- not80B family-dependent woke it up and instantly filled the device.
		--
		-- So it is now an EXPLICIT switch, defaulting OFF -- which is exactly
		-- the behaviour of every bitstream burned so far, i.e. no regression.
		-- The 80B GAME display path (segments_80B driven by the CPU's own RIOT
		-- writes) is unaffected and stays live for all three families; only the
		-- diag-mode TEXT driver is left out.  Turn this on as part of the 80B
		-- display back-end task, which will have to find the ~26 LABs first
		-- (candidates: the ta_overlay/boot_message duplication, the 3 spare
		-- SPI_Master copies inside EEprom).
		-- ===================================================================
		disp80b_diag_enable : boolean := false
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
		NOR_CS_FPGA	: 	buffer 	std_logic;   -- /CS de U6 (NOR des jeux), P35 via JP1 -- Pstore
		CS_EEprom	: 	buffer 	std_logic;
		MOSI			: 	inout 	std_logic;  -- lisyctrl: inout for shared-bus slave mode
		MISO			: 	inout 	std_logic;
		CLK			: 	inout 	std_logic;
		
		-- DIp Switch Game selectOptions
		DIP_Strobe	:	out 	std_logic_vector(3 downto 0);
		DIP_Return	:	in 	std_logic_vector(3 downto 0);
		myTest		: 	in 	std_logic;
		
		-- Sound
		Audio_RX			: 	in 	std_logic;   -- ESP -> FPGA display-inject UART RX (PIN_2)
		Sound 			: 	buffer 	std_logic;

		-- debug
		Debug			:	out 	std_logic
		
		);
end SYS80;


architecture rtl of SYS80 is

signal cpu_clk		: std_logic; -- 895 kHz CPU clock
signal reset_l	 	: std_logic := '0';
signal reset_sw_stable	:	std_logic; 

-- CPU 6502
signal cpu_addr		: std_logic_vector(15 downto 0);
-- cpu_addr = les 16 bits utiles du port A du T65 (24 bits, reste inutilise)
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
signal game_over_relay_v : std_logic_vector(3 downto 0);   -- port entier, cf. portabilite XST
-- PORTABILITE XST : Quartus tolere qu on associe une PARTIE des bits d un port
-- vectoriel, XST le REFUSE (ERROR:HDLCompiler:1346).  On associe donc le port
-- entier a un signal, et on en extrait le ou les bits utiles juste apres.
signal cpu_addr_full : std_logic_vector(23 downto 0);
signal q_snd80_v     : std_logic_vector(3 downto 0);
signal q_snd80b_v    : std_logic_vector(3 downto 0);
signal clk_Z1			: std_logic;
signal clk_Z2			: std_logic;
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
-- Tournament time-attack display injection (Pstore) -- OFF until tournament_mode='1' (no change).
-- Driven by lisyctrl's o_tournament (see the LISY_CTRL port map); powers up '0'
-- and, with lisy_enable=false, stays '0' -- i.e. stock behaviour either way.
-- Its only consumer is TBLOCK (tourney_block), which is a no-op placeholder
-- today: BLOCK_CODE = NOOP_CODE = "1111", so nothing is actually masked.
signal tournament_mode	: std_logic := '0';
signal ta_arm			: std_logic;
signal ta_dstr			: string(1 to 7);
signal bm_disp1			: string(1 to 7);
signal bm_show			: std_logic;
signal u6pa_masked		: std_logic_vector(7 downto 0);
-- ---------------------------------------------------------------------------
-- TIME-ATTACK OVERLAY v3 (2026-07-27): paint the countdown on an UNUSED display
-- instead of taking the whole glass.  See the "TIME-ATTACK DISPLAY INJECTION"
-- block further down for the strobe-map proof and the ctrl-bit table.
-- ---------------------------------------------------------------------------
signal ta_sel			: std_logic_vector(2 downto 0); -- which display to paint (dinj_ctrl(6 downto 4))
signal ta_full			: std_logic;            -- '1' = legacy behaviour: overlay owns the WHOLE glass
signal ta_part			: std_logic;            -- '1' = paint ONE display, ROM keeps the rest
signal ta_hit_a			: std_logic;            -- '1' = replace segment group A for the current strobe
signal ta_hit_b			: std_logic;            -- '1' = replace segment group B
signal ta_hit_c			: std_logic;            -- '1' = replace segment group C
signal ta_seg			: std_logic_vector(1 to 8);     -- the pattern to put there
signal segments_inj		: std_logic_vector(1 to 24);    -- segments_80 with the countdown merged in

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
signal dip_gs_raw      : std_logic_vector(5 downto 0);  -- sorties brutes de RDIPS -- Pstore
signal dip_go_raw      : std_logic_vector(1 to 6);
signal sb_option		: 	std_logic_vector(1 to 4);

-- ===========================================================================
-- SYSTEM 80 / 80A / 80B FAMILY DECODE  (2026-07-27)
--
-- gnum is the TRUE game number: game_select is INVERTED in this design (a
-- closed DIP reads '0'), which is why every other consumer already applies
-- `not game_select` -- nor_flash `selection`, GOSOF80 `game_sel`, the EEprom
-- `selection`, and the boot banner via byte_to_ascii's internal `not mybyte`.
--
-- WHY THE FLAGS MAY BE USED BEFORE THE 6502 RUNS (checked in the source):
-- read_the_dips only drops `readingdips` in its Idle state, i.e. after all
-- four strobe/return reads have completed.  nor_flash is held in reset by
-- `i_Rst_L => not readingdips`, loads the whole 16 KByte image, and only then
-- asserts `cpu_reset_l` (-> reset_l -> cpu_res_n).  So the DIPs are complete
-- long before the CPU fetches its reset vector, and a family bit derived from
-- them is valid for the ROM decode and the display back-end from the first
-- instruction onwards.
--
-- The flags are nevertheless REGISTERED on the falling edge of readingdips:
-- read_the_dips loads game_select(3 downto 0) in Read1 and (5 downto 4) in
-- Read2, so a purely combinational decode would glitch for one CPU clock
-- while the number is half-updated.  Power-on values = System 80 (is_80='1',
-- everything else '0'), i.e. exactly today's proven hard-wired behaviour, so
-- nothing changes on the glass until the flags latch.
--
-- MANUAL OVERRIDE -- game_option(5)  ("S1 option switch 5", read by
-- read_the_dips in state Read3 from returns(2), strobe "1011").
-- VERIFIED UNUSED: a grep of SYS80.vhd + lib_common shows game_option(5) is
-- referenced in exactly one place, the CONVO byte_to_ascii instance that
-- paints the option digits on the boot banner.  Only (1)..(4) drive real
-- options (freeplay / init nvram / slam fix open / slam fix close); (5) and
-- (6) were display-only.  (6) is left free for the next family one-liner.
-- ENCODING (same polarity as every other option: DIP CLOSED = '0' = active):
--   game_option(5) = '1' (switch OPEN, factory default)  -> family from the
--       game number, as decoded above.  Unchanged behaviour.
--   game_option(5) = '0' (switch CLOSED)                 -> INVERT the 80B
--       decision: an 80-family number is treated as 80B and vice versa.
-- One bit cannot select among three families, so the override flips the only
-- axis that actually changes hardware behaviour (numeric vs alphanumeric
-- display back-end + the sound-S16 source).  It is the escape hatch for a
-- mis-set game DIP, a machine with a swapped display, or a game number this
-- table gets wrong -- "if the glass is the wrong type, close S1-5".
-- ===========================================================================
signal gnum				: std_logic_vector(5 downto 0);   -- TRUE game number = not game_select
signal fam_ovr			: std_logic;                      -- '1' = invert the 80B decision
signal rdips_d			: std_logic := '1';               -- readingdips delayed (falling-edge detect)
signal is_80			: std_logic := '1';               -- power-up = System 80 (today's behaviour)
signal is_80A			: std_logic := '0';
signal is_80B			: std_logic := '0';               -- already includes the manual override
signal has_7digit		: std_logic := '0';               -- 80A = 7-digit score displays
		
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
signal 	Sound_S16_80	: std_logic;   -- 80/80A: lamp latch DS3, bit 1
signal 	Sound_S16_80B	: std_logic;   -- 80B   : lamp latch DS2, bit 0
-- SOUND BUS EVENTS (SOUND_WIRE.md).  The 5-bit code above is combinational on the
-- RIOT PA latch PLUS a lamp latch, so it moves for reasons that are not a sound
-- command; these three signals are the strobe-qualified EVENT stream that the
-- sound_link UART reports instead.  See lib_common/snd_bus.vhd.
signal 	u6_pa_wr			: std_logic;   -- U6 RIOT: the CPU has just written ORA (port A)
signal 	snd_sel			: std_logic;   -- '1' = a sound code is selected on the bus
signal 	snd_stb			: std_logic;   -- one clk_50 pulse per sound-bus event
signal 	snd_rel			: std_logic;   -- with snd_stb: '1' = the bus was RELEASED
signal 	fam_code			: std_logic_vector(1 downto 0);  -- 00=80 01=80A 10=80B -> 0xF4|fam

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
-- ESP bus grant: the companion pulls the board reset line (S8.2) low to take the
-- shared SPI bus (NOR/SD/EEPROM programming). Needed because outside diag the FPGA
-- always drives MOSI/CLK, so holding reset alone never freed the bus.
signal esp_bus     : std_logic := '0';
signal lisy_sclk, lisy_mosi, lisy_miso : std_logic;
signal lisy_u4pb, lisy_u6pa, lisy_u6pb : std_logic_vector(7 downto 0);
  signal lisy_u5pa : std_logic_vector(3 downto 0);
  signal lisy_segments : std_logic_vector(1 to 24);
  signal lisy_txt  : std_logic_vector(319 downto 0) := (others => '0');
  signal bm_disp2, bm_disp3, bm_disp4 : string(1 to 7);
  -- 80B diag display writer (10941 latch protocol) -> RIOT-level U5 lines
  signal d80_pa : std_logic_vector(5 downto 4);
  signal d80_pb : std_logic_vector(6 downto 0);
  signal u5pa_disp4, u5pa_disp5 : std_logic;
  signal u5pb_disp : std_logic_vector(6 downto 0);
signal u6pa_src, u6pb_src, u4_pb_cpu   : std_logic_vector(7 downto 0);
signal sd_cs_n, ee_cs_n, cpu_res_n     : std_logic;
signal nor_cs_n                        : std_logic;   -- /CS pilote par nor_flash -- Pstore
signal lisy_trig : std_logic;   -- long-press of the Gottlieb door test switch
signal dinj_ctrl2 : std_logic_vector(6 downto 0);  -- CONTROL2 0xFD flags from the ESP
signal lisy_by_esp : std_logic := '0';             -- diag mode was entered by the ESP, not by the door switch
signal lisy_sound5     : std_logic_vector(4 downto 0);  -- lisyctrl sound code -> gosof80
signal lisy_sound_trig : std_logic;                     -- lisyctrl sound trigger -> gosof80
signal sl_tx           : std_logic;                     -- sound_link UART (ESP sound mode)
signal ball_val        : std_logic_vector(3 downto 0) := "0000";  -- snooped $0072 = GAME IN PROGRESS (0=attract, 1=game); powers up 0 = attract
-- RAM-snapshot streamer (ram_snoop -> sound_link injection port). Diagnostic only:
-- mirrors CPU writes to the three RIOT RAMs *and* to the 5101 CMOS RAM, and streams
-- the 640-value image to the ESP ~1x/s so the ball-in-play address can be found by
-- correlation instead of guessed ($0072 from PinMAME was disproven on real hardware,
-- and no RIOT byte behaved like a ball counter -> the 5101 is the remaining candidate).
signal snap_riot_wr    : std_logic;                     -- any RIOT RAM write
signal snap_5101_wr    : std_logic;                     -- 5101 (Z5) write
signal snap_wr_en      : std_logic;                     -- either of the above
signal snap_wr_addr    : std_logic_vector(9 downto 0);  -- shadow index (see ram_snoop header)
signal snap_wr_data    : std_logic_vector(7 downto 0);  -- mirrored data byte
signal snap_data_s     : std_logic_vector(7 downto 0);  -- byte offered to sound_link
signal snap_req_s      : std_logic;
signal snap_ack_s      : std_logic;
-- lisyctrl registers TA_START / TA_DECAY.  NOT consumed on the FPGA side any
-- more: the countdown moved to the ESP when the tourney_display_top chain was
-- dropped, so these two only reach an unread signal and Quartus prunes them.
-- Deliberately left wired rather than tied to `open`: they are part of the
-- lisyctrl register map the ESP already writes, and rewiring a port of a
-- hardware-proven module to save nothing is not worth the risk.  Re-point them
-- at whatever consumes the start/decay values next.
signal ta_cfg_start    : std_logic_vector(23 downto 0);
signal ta_cfg_decay    : std_logic_vector(23 downto 0);

-- ===========================================================================
-- ESP -> FPGA CONTROL LINK (disp_inject).  One wire, ESP GPIO9 -> Audio_RX /
-- PIN_2, 8N1 115200, RX only; the reverse direction is the existing sound_link
-- UART on the Debug pin.  Two frame types (see lib_common/disp_inject.vhd):
--   0xFF + 7 ASCII  = the string to overlay on the glass  -> dinj_str/dinj_valid
--   0xFE + 1 flags  = b0 auto-restart, b1 display overlay, b2 kill (edge),
--                     b3 long kill (optional)             -> dinj_ctrl/dinj_kill
-- disp_inject clears b0/b1 by itself after 2 s without a valid control frame, so
-- a dead or unplugged ESP cannot leave the machine restarting games or holding
-- the glass.  Everything below therefore powers up OFF.
-- ===========================================================================
signal dinj_str        : string(1 to 7);                -- last complete display frame
signal dinj_valid      : std_logic;                     -- '1' while display frames keep arriving
signal dinj_ctrl       : std_logic_vector(6 downto 0);  -- latched control flags (fail-safed)
signal dinj_kill       : std_logic;                     -- 1-clk one-shot, rising edge of flags b2
-- ESP -> FPGA link telemetry (2026-07-27).  The FPGA->ESP UART was always
-- observable; this direction was not, so a dead overlay could not be told from a
-- dead wire.  dinj_rxc counts every byte disp_inject DEFRAMES (mod 15, see
-- disp_inject's rx_cnt comment); both it and {dvalid,ctrl(2..0)} are shipped to
-- the ESP as sound_link level tokens 0xB0|rxc and 0xE0|dinj.
signal dinj_rxc        : std_logic_vector(3 downto 0);  -- deframed-byte counter, 0..14

-- ===========================================================================
-- TIME-ATTACK part 1: AUTO-RESTART by synthetic switch-matrix closures
-- ---------------------------------------------------------------------------
-- Rationale (Pstore 2026-07-25).  Freezing the ball counter ($0109, proven on HW
-- to BE the ball-in-play byte) did NOT stop game-over: the System 80 ROM decides
-- game-over from something else.  Address hunting abandoned.  Instead we use the
-- machine's own controls: the FPGA *is* the switch matrix, so it can press the
-- coin and the credit/start button for the player.
--
-- Injection point: the U4 RIOT port-A returns.  bontango's free-play feature
-- already proves this works -- `SW_Freeplay` ORs a '1' onto return 7 while
-- strobe 1 is high and the ROM books a coin.  Polarity (SYS80.vhd comment at the
-- credit detector): "due to inverters on the board a switch is active when both
-- strobe and return are HIGH", i.e. drive U4_pa_in(7)='1' while U4_PB(n)='1'.
--   strobe 1 / return 7 = LEFT COIN     (from the Freeplay process)
--   strobe 4 / return 7 = CREDIT/START  (from the commented reference line and
--                                        from detect_credit_sw* below)
-- NOTE we deliberately do NOT gate on U5_pb_out(7) (the DIP-read phase).  The
-- proven Freeplay injection does not gate on it either, and this machine was
-- measured parking that line in the DIP-read state during attract, which is
-- exactly what broke the earlier *detector*; gating here could mean the closure
-- is never presented at all.  Cost: for <=150 ms one DIP bit may read back as a
-- '1'; the ROM re-reads the DIPs continuously, so it self-corrects.
--
-- Injection is invisible to the FPGA's own detect_sw* blocks (they watch the raw
-- pin vector U4_pa_in, we OR in one stage later, at the RIOT port) -- so an
-- injected press can never re-trigger sim_coin or the NVRAM credit trigger.
-- ===========================================================================
signal auto_restart_en : std_logic;                     -- master enable for the sequencer
signal sw_inject       : std_logic_vector(7 downto 0);  -- synthetic returns, ORed into U4 PA
signal inj_coin        : std_logic := '0';              -- press LEFT COIN    (strobe 1 / return 7)
signal inj_credit      : std_logic := '0';              -- press CREDIT/START (strobe 4 / return 7)

-- ---------------------------------------------------------------------------
-- game-over / attract detection -- v2, retargeted 2026-07-25 after HW test.
--
-- REJECTED, do not go back to these:
--   * game_running: count_to_zero latches d_out='1' after 255 CPU IRQ edges and
--     never clears it again except on reset_l='0'.  It is a "CPU booted" flag --
--     that is why /link reported running:true while the machine sat in attract.
--   * game_over_relay (lamp latch DS1 b0): tried in build #1 with a self-learning
--     polarity detector.  Tested on the real Volcano: the indicator never moved at
--     game over -> DS1 b0 is NOT the game-over signal on this machine.  It stays
--     wired to the EEprom NVRAM save trigger (unchanged), just not used here.
--
-- USED: CPU $0072 (RIOT U4 RAM) = GAME IN PROGRESS.  0 in attract, 1 during a
-- game, back to 0 at game over.  Proven on hardware twice and independently:
-- live $0072 telemetry across a full 3-ball game (0 -> 1 -> 0), and the RAM
-- snapshots (attract=0, 5/5 in-game samples=1, immediately post-game=0).
-- The value is already available as `ball_val`, latched by the BALL_SNOOP
-- process on every CPU write to $0072; it powers up at 0 = attract, which is
-- also the correct safe state before the ROM has written anything.
-- (The real ball counter is $0109, 0-based -- but freezing it does not stop
--  game-over, which is why we inject buttons instead.)
signal ar_raw_attract  : std_logic;                     -- undebounced: '1' when $0072 = 0
signal in_attract      : std_logic := '1';              -- debounced: '1' = no game in progress
signal hb_cnt          : unsigned(25 downto 0) := (others => '0');  -- temoin de vie 6502 -- Pstore
signal irq_stretch     : unsigned(22 downto 0) := (others => '0');  -- etireur d'impulsion IRQ -- Pstore
signal irq_d           : std_logic := '1';
signal ar_db_cnt       : unsigned(21 downto 0) := (others => '0');  -- debounce timer (~84 ms max)
signal ar_gamecnt      : unsigned(27 downto 0) := (others => '0');  -- "game has really run" timer
signal game_qual       : std_logic := '0';              -- '1' once a game ran >= AR_T_GAME

type AR_STATE_T is (AR_IDLE, AR_SETTLE, AR_COIN_ON, AR_COIN_OFF, AR_CRED_ON, AR_VERIFY, AR_DONE);
signal ar_state        : AR_STATE_T := AR_IDLE;
signal ar_cnt          : unsigned(27 downto 0) := (others => '0');
signal ar_tries        : unsigned(1 downto 0)  := (others => '0');

-- ===========================================================================
-- TIME-ATTACK part 2: END-ON-DEMAND (slam).
-- ---------------------------------------------------------------------------
-- INVESTIGATION 2026-07-25 -- "does GottFA's slam DIP disable this?"  NO.  Trace:
--
--   opt_slam_fix_open  <= not game_option(3);        -- ~line 404
--   opt_slam_fix_close <= not game_option(4);        -- ~line 405
--   slam <= '0'      when opt_slam_fix_open  = '1'   -- ~line 511
--        else '1'    when opt_slam_fix_close = '1'
--        else U5_PA_7;                               -- the real slam pin (PIN_91)
--   slam_to_cpu <= slam xor kill_pulse;              -- ~line 927  <-- AFTER the mux
--   U5_IO: pa_in => slam_to_cpu & "0000000";         -- ~line 1256 -> 6502 reads it
--
-- The two DIP options only choose the RESTING level of the line; the XOR that
-- makes the kill pulse sits one stage further down, between that mux and the
-- R6532.  So in all three configurations -- forced open, forced closed, or the
-- real switch -- the level the 6502 sees still moves for the whole pulse.  Only a
-- kill implemented as "force slam to a FIXED level" would have been masked by the
-- DIPs, and that is deliberately not how this is built.
--
-- Polarity does not have to be known either, and that is the second half of the
-- argument: whatever level the machine currently rests at is provably the
-- NOT-slammed level for this ROM, because the machine plays normally.  XOR moves
-- it to the complementary level, which is therefore the slammed one.  This is why
-- slam was chosen over the tilt switch or the outhole: tilt/outhole positions in
-- the switch matrix are game-specific (and tilt only ends the BALL), whereas the
-- slam input is one dedicated pin at a fixed place in the System-80 architecture.
-- A CPU reset would also be game-agnostic but was rejected as unsafe: the R6532s
-- are not reset with the CPU, so a solenoid that happened to be energised would
-- stay latched on -> coil burn.  Nothing here touches a solenoid driver.
--
-- What this does NOT prove is what the game ROM then decides to do; that needs the
-- machine.  Hence the optional long closure below: if 100 ms turns out not to be
-- enough for this ROM's slam debounce, control-frame bit3 stretches it to 500 ms
-- without re-flashing the FPGA.
-- ===========================================================================
signal game_kill       : std_logic;                     -- pulse '1' -> end the game now
signal kill_pulse      : std_logic := '0';
signal kill_d          : std_logic := '0';
signal kill_cnt        : unsigned(24 downto 0) := (others => '0');  -- 25 bit: must hold AR_T_SLAM_L
signal kill_len        : natural range 0 to 500 * 50000;            -- selected closure length
signal slam_to_cpu     : std_logic;                     -- what U5 PA7 shows the 6502

-- timing constants (clk_50 ticks)
constant AR_MS         : natural := 50000;              -- 1 ms at 50 MHz
constant AR_T_DB       : natural :=    50 * AR_MS;      -- $0072 must hold a new value 50 ms to count
constant AR_T_GAME     : natural :=  3000 * AR_MS;      -- 3 s out of attract = a game really ran
constant AR_T_SETTLE   : natural :=  2000 * AR_MS;      -- 2 s after game over before pressing anything
constant AR_T_PRESS    : natural :=   150 * AR_MS;      -- closure length of an injected button press
constant AR_T_GAP      : natural :=   400 * AR_MS;      -- release time between coin and credit
constant AR_T_VERIFY   : natural :=  3000 * AR_MS;      -- how long we wait to see the game start
constant AR_T_SLAM     : natural :=   100 * AR_MS;      -- slam closure length (default)
-- Optional longer closure, selected by control-frame bit3.  Only a fallback for the
-- field: if this ROM's slam handler needs more than ~100 consecutive IRQ samples,
-- the ESP can stretch the closure without a re-flash.  Kept at 500 ms rather than
-- seconds so the ROM cannot read it as a STUCK slam switch.
constant AR_T_SLAM_L   : natural :=   500 * AR_MS;      -- slam closure length (ctrl bit3 = 1)
constant AR_TRIES_MAX  : natural := 2;                  -- => 3 attempts total, then give up
-- '1' = drop a coin (strobe 1) before pressing start, so auto-restart also works
-- on a machine with zero credits banked.  Set to '0' if the coin audit must stay clean.
constant AR_INJECT_COIN : std_logic := '1';

begin
cpu_addr <= cpu_addr_full(15 downto 0);

-- LEDs GottFA80
-- [AUTO-RESTART DIAG] LED_Int used to show `not game_running`, which is useless:
-- game_running latches HIGH ~255 IRQs after reset and never falls again (see
-- count_to_zero), so the LED was static after boot.  Show the game-over/attract
-- detector instead so the auto-restart trigger can be watched on the board:
-- LED_Int follows in_attract ('1' = attract / no game, '0' = a game is running).
-- It must therefore CHANGE STATE when a game starts and change back at game over
-- -- that is the first thing to check on hardware.
-- Revert with:  LED_Int <= not game_running;
LED_Int <= not reset_l;   -- banc : allumee = 6502 relache -- Pstore (etait: in_attract)
LED_SDcard <= SDcard_error;
-- LED_ON: '0' exactly as upstream (GottFA80_PLuS Cyclone IV, `LED_ON <= '0'; --RTH`).
-- 2026-07-30: this pin used to be driven by an XOR-reduction of `ay_audio`, a
-- keep-alive for the AY-3-8910 fit experiment.  The experiment was dropped on
-- 2026-07-09 and `ay_audio` has been tied to all-zeros ever since, so the XOR
-- chain evaluated to a constant '0' -- identical behaviour, stated indirectly.
-- Both the vector and the chain are gone; lib_common/ay_3_8910.vhd is kept in
-- the tree for the real AY integration.
-- Temoin de vie du 6502 (banc, 31/08) : game_running ne monte qu'apres 255
-- fronts d'IRQ du CPU -- il ne peut pas monter sur du code mort. LED active
-- a l'etat bas sur la porteuse : CLIGNOTE (~1,4 s) = 6502 vivant, ETEINTE =
-- CPU jamais demarre. Amont : LED_ON <= '0'; (toujours allumee). -- Pstore
-- TEMOINS POSITIFS de banc (31/08) -- Pstore
-- LED_ON  (active bas) : ALLUMEE = des IRQ battent (chaque front etire 165 ms ;
--          a ~300 Hz elle parait fixe). ETEINTE = aucune IRQ.
-- LED_Int (active bas) : ALLUMEE = reset_l relache (le 6502 est libre).
HB: process(clk_50) begin
  if rising_edge(clk_50) then
    hb_cnt <= hb_cnt + 1;
    irq_d <= cpu_irq_n;
    if cpu_irq_n = '0' and irq_d = '1' then
      irq_stretch <= (others => '1');
    elsif irq_stretch /= 0 then
      irq_stretch <= irq_stretch - 1;
    end if;
  end if;
end process;
LED_ON <= '0' when irq_stretch /= 0 else '1';


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
-- [AY FIT TEST] TADISP (tournament display chain ~463 LE) DROPPED to free room.
-- 2026-07-25: the overlay is back, but the countdown now lives on the ESP -- it
-- formats the 7 characters itself and streams them over the one-wire UART, which
-- costs the FPGA only the receiver (disp_inject) instead of the whole bin_to_bcd /
-- value_to_dispstr / tourney_countdown chain.
-- ta_arm needs BOTH the enable flag AND live frames: dinj_valid self-clears ~1 s
-- after the last display frame, so if the ESP stops mid-game the glass returns to
-- the game by itself even if ctrl(1) were somehow stuck high.
ta_arm   <= dinj_ctrl(1) and dinj_valid;
ta_dstr  <= dinj_str;
-- ===========================================================================
-- TIME-ATTACK DISPLAY INJECTION -- v3, 2026-07-27.
--
-- THE FLAW BEING FIXED.  v2 armed boot_message for the whole glass: the digit
-- strobes came from bm_digit_strobe and all 24 segment lines from bm_segments,
-- and bm_disp2/3/4 were blanked.  Result: while a time-attack game was being
-- PLAYED the player watched a countdown and could not see their score.
--
-- THE MAPPING (this is the load-bearing claim -- reasoning, then the test).
-- U5 PA0..PA3 is a 4-bit digit strobe; an external 1-of-16 decoder (74154, Z33
-- on the stock MPU) turns it into 16 digit-enable lines that are common to every
-- display in the backbox.  The three 8-bit segment groups on J2 carry the DATA:
--     group A = disp_segments(1..8)   player 1 + player 2
--     group B = disp_segments(9..16)  player 3 + player 4
--     group C = disp_segments(17..24) status (credits / ball in play)
-- Which physical digit lights is therefore (segment group) x (strobe value), and
-- that relation is BACKBOX WIRING -- it does not depend on who drives the bus.
-- The game ROM and boot_message are two drivers of the same map, so the map that
-- boot_message uses is the map the ROM uses.  boot_message (lib_common) is the
-- proven reference, because its banner lands on the right displays on this very
-- machine; reading its refresh cycle out gives, for group A:
--     strobe 0,1,2,3,4,5  -> display1 chars 7,6,5,4,3,2   (player 1, units first)
--     strobe 15           -> display1 char 1              (7th digit slot)
--     strobe 6,7,8,9,A,B  -> display2 chars 7,6,5,4,3,2   (player 2, units first)
--     strobe 12           -> display2 char 1              (7th digit slot)
-- and the identical pattern on group B for display3 / display4.  Group C is
-- written only at strobes 12..15 = the four status digits.
--   CORRECTION 2026-07-27, and it only bites on 80A: the strobe-15 / strobe-12
--   slots above are the SEVENTH digit of a 7-digit (80A) glass, and PinMAME's
--   reorder[] table (src/wpc/gts80.c) puts that digit at the RIGHT-HAND, units
--   end -- segment index 8 of the 2..8 run in dispNumeric3 -- not at the left.
--   boot_message puts char 1 (the most significant) there, which is wrong for a
--   7-digit glass but invisible on a 6-digit one, where nothing is wired to
--   strobe 15 at all.  ta_overlay now takes `has7` and follows the hardware:
--   6-digit -> strobes 15/12 are not ours; 7-digit -> strobe 15 is the units
--   digit and strobes 0..5 shift up to tens..millions.  The status window was
--   also reversed (it read 4,5,6,7 for strobes C..F where both references say
--   7,6,5,4) and is fixed in the same change.  boot_message's own 7-digit
--   mapping is left as it is: correcting it needs a family input threaded into
--   the module, and it has never been exercised -- this machine is 6-digit.
--   => THE PLAYER-2 DISPLAY IS SEGMENT GROUP A DURING STROBES 6..12, AND NOTHING
--      ELSE ON THE GLASS IS.  Overriding group A only in that window therefore
--      cannot touch player 1's score (strobes 0..5,15) nor the status display
--      (group C).  Verified by simulation: sim/tb_ta_overlay.vhd sweeps all 16
--      strobes for every sel value and asserts that exactly one segment group is
--      claimed, only inside the intended window, with the expected glyph.
--   NOT proven from code: whether the player-2 digits read left-to-right in the
--      same order as player 1 (they must -- identical modules on a shared bus --
--      but only the glass can confirm), and whether a 6-digit System-80 glass has
--      anything at all wired to strobes 12..15 on groups A/B.  ta_sel 101/110
--      exist to answer that second question on the real machine.
--
-- WHERE THE STRING GOES: dinj_ctrl(6 downto 4), reserved-and-sent-as-0 by the
-- current ESP firmware, so the default needs no ESP change:
--     000  PLAYER 2   (default -- free in a one-player game)   <-- the fix
--     001  PLAYER 1   (same place as the old overlay; sanity check)
--     010  PLAYER 4
--     011  PLAYER 3
--     100  STATUS / credit display
--     101  PROBE: group A on strobes 12..15 (positions a 6-digit ROM never writes)
--     110  PROBE: group B on strobes 12..15
--     111  FULL OVERLAY = exactly the v2 behaviour, kept as an escape hatch
--
-- FALLBACK: when no game is in progress the ROM's multiplex is showing attract,
-- there is no score to protect, and the countdown should be as big as possible --
-- so ta_full is forced whenever in_attract='1' (the $0072 detector, proven twice
-- on this machine) or before the CPU has booted (game_running='0').  Both failure
-- modes of that detector are benign: stuck '1' = today's behaviour, stuck '0' =
-- countdown on player 2 with the score intact.
--
-- TWO-PLAYER RISK: in a 2-player game the ROM owns display 2 as well, and the
-- countdown would fight the second player's score.  That is exactly what ta_sel
-- is for -- 010 moves the string to player 4 (free in 1..3-player games).  There
-- is no player display that is free in a 4-player game; only the strobe-12..15
-- probe positions could be, which is why 101/110 exist.
-- ===========================================================================
ta_sel   <= dinj_ctrl(6 downto 4);
-- full glass takeover: no game running, or the ESP explicitly asked for it
ta_full  <= ta_arm and (in_attract or (not game_running) or
                        (ta_sel(2) and ta_sel(1) and ta_sel(0)));
-- one display only: a game IS in progress, the ROM keeps its own multiplex
ta_part  <= ta_arm and (not ta_full);

TAOVL : entity work.ta_overlay
port map(
	clk    => clk_50,
	strobe => U5_pa_out(3 downto 0),   -- the strobe the ROM is driving RIGHT NOW
	sel    => ta_sel,
	-- 80A = 7-digit score glass.  The 7th digit is the RIGHTMOST one and it is
	-- addressed by strobe 15 (low window) / 12 (high window), so on 80A the whole
	-- six-digit map shifts one place left; on 80 / 80B strobes 15 and 12 carry no
	-- score digit at all and the overlay must keep its hands off them.  See the
	-- WHICH DIGIT IS THE 7TH block in lib_common/ta_overlay.vhd for the two
	-- independent references (boot_message + PinMAME gts80.c reorder[]).
	has7   => has_7digit,
	dstr   => ta_dstr,
	hit_a  => ta_hit_a,
	hit_b  => ta_hit_b,
	hit_c  => ta_hit_c,
	seg    => ta_seg
	);
-- [AY FIT TEST] dropped 2026-07-09: freed ~2 LABs for the disp80b_diag FSM
-- (design hit 394/392 LABs). It was a fit-headroom placeholder only (output
-- went to LED_ON, which is now simply '0').  lib_common/ay_3_8910.vhd is still
-- in the tree; re-instantiate it when the real AY integration lands.
-- boot_message paints the WHOLE glass in one refresh cycle: display1/display2 are
-- the two halves of segment group A (player 1 / player 2), display3/display4 the
-- two halves of group B (player 3 / player 4), status_d is group C.  So when the
-- overlay is armed every other field must be blanked, otherwise the injected string
-- would sit in the middle of the boot banner (SW version / game# / build date /
-- option digits).  status_d is already all blanks.
-- v3 NOTE: boot_message now only ever reaches the pins in the FULL-overlay case
-- (ta_full: attract / pre-boot / ta_sel="111").  While a game is running the
-- countdown comes from TAOVL instead and boot_message's output is unused, so the
-- ta_arm condition below is left as it was -- it costs nothing and keeps the
-- banner instantly ready the moment ta_full goes high again at game over.
bm_disp1 <= ta_dstr when ta_arm = '1' else "    611";               -- injected string when armed, else SW version
bm_disp2 <= "       " when ta_arm = '1' else "    " & game_dig2 & game_dig1 & game_dig0;
bm_disp3 <= "       " when ta_arm = '1' else " 050963";
bm_disp4 <= "       " when ta_arm = '1' else " " & g_opt_dig1 & g_opt_dig0 & "  " & sb_opt_dig1 & sb_opt_dig0;
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
	display2	=> bm_disp2,
	display3	=> bm_disp3,
	display4	=> bm_disp4,
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
	game_select	=> dip_gs_raw,
	game_option	=> dip_go_raw,
	sb_option => sb_option,
	-- strobes
	strobes => DIP_Strobe,
	-- returns
	returns => DIP_Return
	);

----------------------
-- System 80 / 80A / 80B family decode (see the signal block above)
----------------------
GEN_DIPS_REELLES: if bench_game < 0 generate
	game_select <= dip_gs_raw;
end generate GEN_DIPS_REELLES;
GEN_OPTS_REELLES: if (bench_game < 0) and (not bench_opts) generate
	game_option <= dip_go_raw;
end generate GEN_OPTS_REELLES;
GEN_OPTS_FORCE: if (bench_game < 0) and bench_opts generate
	game_option <= (1 => '0', others => '1');   -- FP actif, fam_ovr neutre, defauts
end generate GEN_OPTS_FORCE;
GEN_JEU_FORCE: if bench_game >= 0 generate
	game_select <= not std_logic_vector(to_unsigned(bench_game, 6));
	-- Option 1 FERMEE = free-play actif (opt_freeplay <= not game_option(1)) :
	-- le banc et la machine de Valere jouent sans monnayeur. Bit 5 OUVERT :
	-- fam_ovr='0', la famille 80B n'est pas inversee. -- Pstore
	game_option <= (1 => '0', others => '1');
end generate GEN_JEU_FORCE;

gnum    <= not game_select;          -- game_select is inverted; this is the real number
fam_ovr <= not game_option(5);       -- DIP CLOSED ('0') = invert the 80B decision

FAMILY: process(cpu_clk)
begin
	if rising_edge(cpu_clk) then
		rdips_d <= readingdips;
		if rdips_d = '1' and readingdips = '0' then   -- the DIP scan has just finished
			is_80      <= f_is_80(gnum);
			is_80A     <= f_is_80A(gnum);
			is_80B     <= f_is_80B(gnum) xor fam_ovr;
			has_7digit <= f_has_7digit(gnum);
		end if;
	end if;
end process;

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
esp_bus <= '1' when reset_sw_stable = '0' else '0';   -- ESP (or S8) asserts reset => bus is the ESP's
MOSI <= 'Z' when (lisy_active = '1' or esp_bus = '1') else SDcard_MOSI when reset_l = '0' else EEprom_MOSI;
CLK  <= 'Z' when (lisy_active = '1' or esp_bus = '1') else SDcard_CLK  when reset_l = '0' else EEprom_CLK;
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
CS_SDcard <= 'Z' when esp_bus = '1' else '1' when lisy_active = '1' else sd_cs_n;
CS_EEprom <= '1' when (esp_bus = '1' or lisy_active = '1') else ee_cs_n;  -- v2: KEEP the M95256 deselected during the ESP grant (no board pull-up -> a floating CS could let it fight the NOR on MISO)
-- Le /CS de la NOR des jeux (U6) est sur NOR_CS_FPGA/P35, PAS sur CS_SDcard/P56 :
-- cette derniere ne compte que deux pastilles et n'atteint aucun composant. On la
-- laisse desactivee. NOR_CS_FPGA se tait des que le bus ne nous appartient plus,
-- sinon l'ESP ne pourrait jamais ecrire les jeux (contention muette). -- Pstore
-- P35 reste en haute impedance tant que le FPGA ne pilote pas la NOR : c'est
-- plus sur que le pulldown applique aux broches inutilisees, qui tirerait le
-- /CS de la NOR contre son rappel. -- Pstore
NOR_CS_FPGA <= 'Z' when (use_sd or esp_bus = '1' or lisy_active = '1' or reset_l = '1') else nor_cs_n;
cpu_res_n <= '0' when lisy_active = '1' else reset_l;
u6pa_src  <= lisy_u6pa when lisy_active = '1' else U6_pa_out;
-- Tournament: neutralise a free-game solenoid (knocker) when armed. Placeholder code = no block. -- Pstore
TBLOCK: entity work.tourney_block
	generic map ( SEL_HI => 3, SEL_LO => 0, BLOCK_CODE => "1111", NOOP_CODE => "1111" )
	port map ( port_in => u6pa_src, sol_active => '1', tournament_mode => tournament_mode, port_out => u6pa_masked );
u6pb_src  <= lisy_u6pb when lisy_active = '1' else U6_pb_out;
U4_PB     <= lisy_u4pb when lisy_active = '1' else u4_pb_cpu;
-- mode entry, two independent ways in:
--   1. a LONG-PRESS of the Gottlieb door test switch (lisy_trig) -- STICKY, exactly
--      as before: only a reset/reboot leaves diag mode.  Unchanged contract.
--   2. the ESP raising CONTROL2 bit0 (dinj_ctrl2(0)) -- a LEVEL, so LISY CONNECT
--      enters and DISCONNECT leaves, and disp_inject's own 5 s fail-safe drops it
--      if the ESP dies.  A hung ESP can therefore never strand the machine with a
--      frozen CPU.
-- lisy_by_esp remembers which door was used, so an ESP that goes quiet cannot
-- cancel a diag session the operator started at the door switch.
GEN_LISY: if lisy_enable generate
LISY_MODE: process begin
	wait until rising_edge(clk_50);
	if reset_l = '0' then
		lisy_active <= '0';
		lisy_by_esp <= '0';
	elsif lisy_trig = '1' then
		lisy_active <= '1';
		lisy_by_esp <= '0';
	elsif dinj_ctrl2(0) = '1' then
		lisy_active <= '1';
		lisy_by_esp <= '1';
	elsif lisy_by_esp = '1' then
		lisy_active <= '0';
		lisy_by_esp <= '0';
	end if;
end process;
LISY_CTRL: entity work.lisyctrl
port map(
	clk => clk_50, active => lisy_active,
	sclk => lisy_sclk, mosi => lisy_mosi, miso => lisy_miso,
	o_U4_PB => lisy_u4pb, i_U4_PA => U4_pa_in,
	o_U5_PA => lisy_u5pa, o_U5_PB7 => open,
	o_U6_PA => lisy_u6pa, o_U6_PB => lisy_u6pb, o_segments => lisy_segments,
	o_sound => lisy_sound5, o_sound_trig => lisy_sound_trig,
	o_txt => lisy_txt,
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
	-- PORTABILITE (2026-08-13) : associer le port ENTIER.  N associer que
	-- Qn(0) est accepte par Quartus mais REFUSE par XST (Xilinx) :
	--   ERROR:HDLCompiler:1346 - Not all partial formals of qn have actual
	-- Comportement identique : on n utilise toujours que le bit 0.
	Qn => game_over_relay_v
);
game_over_relay <= game_over_relay_v(0);

 
---------------------
-- SD card stuff
----------------------
-- Deux chemins de chargement, choisis par le generic use_sd. SD_Card et
-- nor_flash ont exactement les 12 memes ports : l'un remplace l'autre.
-- Une seule branche est elaboree. -- Pstore
GEN_SD: if use_sd generate
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
nor_cs_n <= '1';
end generate GEN_SD;

GEN_NOR: if not use_sd generate
NOR_ROM: entity work.nor_flash
generic map( spi_hz => 2000000 )   -- valeur d'origine, et celle de norprog.cpp
port map(
	--no_of_sectors => x"20", -- 32 sectors per rom
	--
	i_clk		=> clk_50,	
	-- Control/Data Signals,
   i_Rst_L  => not (readingdips or esp_bus),  -- + esp_bus : ne pas cadencer un bus rendu a l'ESP -- Pstore
	-- PMOD SPI Interface
   o_SPI_Clk  => SDcard_CLK,
   i_SPI_MISO => MISO,
   o_SPI_MOSI => SDcard_MOSI,
   o_SPI_CS_n => nor_cs_n,
	-- selection
	selection => "0" & opt_freeplay & not game_select,   -- comme l'amont : FP = slot+64.
	-- (le masque du 31/08 reposait sur un calcul faux : 128 slots = 2 Mo, la W25Q32 en a 4)
	-- data
	address_sd_card => address_sd_card,
	data_sd_card => data_sd_card,
	wr_rom => wr_rom,
	-- control CPU
	cpu_reset_l => reset_l,
	-- feedback
	SDcard_error => SDcard_error
	);
sd_cs_n <= '1';
end generate GEN_NOR;	
	
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
-- FIXED 2026-07-27.  The old test was `game_select(5 downto 3) = "000"`, i.e.
-- true game numbers 56..63 -- it wrongly included 62 (Amazon Hunt II) and the
-- non-game 63, and mapping a bank that the ROM never asks for costs nothing but
-- is still wrong.  PinMAME ground truth: the banked variant is
-- GTS80B_4K_ROMSTART ("8K & 4K game PROM"), whose second 2K lands at
-- $9000-$97FF -- exactly what game_rom2_cs below decodes.  In gts80games.c that
-- macro is used by EXACTLY six parent sets: excaliba, badgirls, bighouse,
-- hotshots, bonebstr, nmoves = gamelist 56..61.  Amazon Hunt II (62) uses
-- GTS80B_8K_ROMSTART (one 8K PROM, no bank).  See lib_common/gts_family.vhd.
late80B <= f_late_80B(gnum);   -- true game numbers 56..61
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

--------------------------------------------------------------------------------
-- ESP -> FPGA CONTROL LINK  (one wire, ESP GPIO9 -> Audio_RX / PIN_2)
--------------------------------------------------------------------------------
-- Instantiated unconditionally: PIN_2 is a plain input in BOTH sound builds now
-- (GEN_FPGA_SND passes DFP_tx => open, GEN_ESP_SND never used the pin), so the
-- link works whichever way esp_sound is set.
-- Reset: `not reset_l`, the same active-high reset the sound_link and ram_snoop
-- blocks use.  Consequence, and it is the wanted one: everything the ESP controls
-- powers up OFF and stays off until the companion actually asks for it.
DINJ : entity work.disp_inject
generic map (
	clk_hz     => 50000000,
	baud       => 115200,
	hold_ms    => 1000,     -- display overlay expires 1 s after the last 0xFF frame
	ctrl_to_ms => 2000,     -- fail-safe: ctrl b0/b1 cleared after 2 s of ESP silence
	ctrl2_to_ms => 5000     -- fail-safe: diag mode released after 5 s of ESP silence
)
port map (
	clk            => clk_50,
	rst            => not reset_l,
	rx             => Audio_RX,
	dstr           => dinj_str,
	dvalid         => dinj_valid,
	ctrl           => dinj_ctrl,
	ctrl2          => dinj_ctrl2,
	kill_pulse_req => dinj_kill,
	rx_cnt         => dinj_rxc          -- telemetry: bytes deframed on PIN_2 (mod 15)
);

--------------------------------------------------------------------------------
-- TIME-ATTACK / AUTO-RESTART  (Pstore 2026-07-25)
--------------------------------------------------------------------------------
-- Armed by the ESP: CONTROL frame bit0.  This REPLACES the hardwired '1' used for
-- the 2026-07-25 hardware validation of the FSM -- the sequencer itself is byte
-- for byte the one that was proven on the Volcano, only its enable moved.
-- disp_inject clears bit0 on its own after 2 s without a control frame, so a
-- crashed or unplugged ESP cannot leave the machine restarting games forever.
auto_restart_en <= dinj_ctrl(0);

-- END-ON-DEMAND: CONTROL frame bit2, rising edge -> a one-clock one-shot from
-- disp_inject, which GAME_KILL_P stretches into the slam closure below.
game_kill <= dinj_kill;

-- The synthetic closure.  Combinational on the live strobe, exactly like the
-- proven Freeplay coin sim.  Never active in diag (there lisyctrl owns U4_PB and
-- the 6502 is held in reset anyway).
sw_inject(7) <= ( (inj_coin and U4_PB(1)) or (inj_credit and U4_PB(4)) ) and not lisy_active;
sw_inject(6 downto 0) <= "0000000";

-- '1' = no game in progress.  $0072 (= ball_val, latched by BALL_SNOOP) is 0 in
-- attract and 1 during a game -- proven on hardware, see the header block.
ar_raw_attract <= '1' when ball_val = "0000" else '0';

AUTO_RESTART: process(clk_50)
begin
  if rising_edge(clk_50) then

    ---------------------------------------------------------------------------
    -- 1) debounce the game-in-progress flag.
    --    $0072 only changes when the 6502 writes it, so it is intrinsically
    --    clean at the ROM level; a 6502 read-modify-write cannot even produce a
    --    false 0 during a game (its dummy write replays the OLD value, which is
    --    1 while a game runs).  The debounce is there for the FPGA side: the
    --    BALL_SNOOP latch re-samples cpu_dout on EVERY clk_50 edge for which the
    --    write condition holds (~56 edges per CPU cycle), so it can capture the
    --    bus before cpu_dout has settled.  That never mattered while ball_val
    --    was telemetry only; now that it arms a game restart, require the new
    --    value to hold for AR_T_DB (50 ms) before it is believed.
    ---------------------------------------------------------------------------
    if reset_l = '0' then
      in_attract <= '1';                    -- power-up / reset = attract
      ar_db_cnt  <= (others => '0');
    elsif ar_raw_attract = in_attract then
      ar_db_cnt <= (others => '0');         -- agrees: nothing to do
    elsif ar_db_cnt >= AR_T_DB then
      in_attract <= ar_raw_attract;         -- new value held long enough: accept
      ar_db_cnt  <= (others => '0');
    else
      ar_db_cnt <= ar_db_cnt + 1;
    end if;

    ---------------------------------------------------------------------------
    -- 2) qualifier: only a game that really ran (>= AR_T_GAME out of attract)
    --    may arm an auto-restart.  Belt-and-braces on top of the debounce: no
    --    transient on $0072 can ever look like a whole game.
    ---------------------------------------------------------------------------
    if reset_l = '0' then
      ar_gamecnt <= (others => '0');
      game_qual  <= '0';
    else
      if in_attract = '1' then
        ar_gamecnt <= (others => '0');
      elsif ar_gamecnt < AR_T_GAME then
        ar_gamecnt <= ar_gamecnt + 1;
      end if;
      if ar_gamecnt >= AR_T_GAME then
        game_qual <= '1';
      end if;
    end if;

    ---------------------------------------------------------------------------
    -- 3) the sequencer: game over -> settle -> [coin] -> credit -> verify,
    --    bounded to AR_TRIES_MAX+1 attempts, then latched off until a game runs
    --    again.  It can therefore never free-run.
    ---------------------------------------------------------------------------
    if reset_l = '0' or lisy_active = '1' or auto_restart_en = '0' then
      ar_state   <= AR_IDLE;
      ar_cnt     <= (others => '0');
      ar_tries   <= (others => '0');
      inj_coin   <= '0';
      inj_credit <= '0';
    else
      case ar_state is

        when AR_IDLE =>
          inj_coin   <= '0';
          inj_credit <= '0';
          ar_cnt     <= (others => '0');
          ar_tries   <= (others => '0');
          if game_qual = '1' and in_attract = '1' then
            game_qual <= '0';                 -- consume it (this wins over the set above)
            ar_state  <= AR_SETTLE;
          end if;

        -- let the ROM finish its game-over sequence and settle into attract.
        when AR_SETTLE =>
          if in_attract = '0' then            -- a game started meanwhile -> stand down
            ar_state <= AR_IDLE;
          elsif ar_cnt >= AR_T_SETTLE then
            ar_cnt   <= (others => '0');
            ar_state <= AR_COIN_ON;
          else
            ar_cnt <= ar_cnt + 1;
          end if;

        -- book a coin so a credit exists to start on.
        when AR_COIN_ON =>
          inj_coin <= AR_INJECT_COIN;
          if ar_cnt >= AR_T_PRESS then
            inj_coin <= '0';
            ar_cnt   <= (others => '0');
            ar_state <= AR_COIN_OFF;
          else
            ar_cnt <= ar_cnt + 1;
          end if;

        when AR_COIN_OFF =>
          inj_coin <= '0';
          if ar_cnt >= AR_T_GAP then
            ar_cnt   <= (others => '0');
            ar_state <= AR_CRED_ON;
          else
            ar_cnt <= ar_cnt + 1;
          end if;

        -- press the credit / start button.
        when AR_CRED_ON =>
          inj_credit <= '1';
          if ar_cnt >= AR_T_PRESS then
            inj_credit <= '0';
            ar_cnt     <= (others => '0');
            ar_state   <= AR_VERIFY;
          else
            ar_cnt <= ar_cnt + 1;
          end if;

        when AR_VERIFY =>
          inj_credit <= '0';
          if in_attract = '0' then            -- a game is running: done
            ar_state <= AR_IDLE;
          elsif ar_cnt >= AR_T_VERIFY then
            ar_cnt <= (others => '0');
            if ar_tries >= AR_TRIES_MAX then
              ar_state <= AR_DONE;
            else
              ar_tries <= ar_tries + 1;
              ar_state <= AR_COIN_ON;
            end if;
          else
            ar_cnt <= ar_cnt + 1;
          end if;

        -- gave up.  Nothing more happens until a game runs again (by any means).
        when AR_DONE =>
          inj_coin   <= '0';
          inj_credit <= '0';
          if in_attract = '0' then
            ar_state <= AR_IDLE;
          end if;

      end case;
    end if;
  end if;
end process;

--------------------------------------------------------------------------------
-- END-ON-DEMAND: pulse the slam line for kill_len on a rising edge of game_kill.
-- Polarity-free: we XOR, i.e. we move the line AWAY from its resting level, which
-- is what a real slam does whether the switch idles open or closed -- and, crucially,
-- the XOR is applied AFTER the opt_slam_fix_open/close mux, so the GottFA DIP options
-- cannot mask it (see the INVESTIGATION block in the declarations).
-- Now actually exercised: game_kill = the ESP control-frame bit2 one-shot.
--------------------------------------------------------------------------------
slam_to_cpu <= slam xor kill_pulse;

-- 100 ms by default (protocol contract); 500 ms if the ESP sets control bit3.
kill_len <= AR_T_SLAM_L when dinj_ctrl(3) = '1' else AR_T_SLAM;

GAME_KILL_P: process(clk_50)
begin
  if rising_edge(clk_50) then
    kill_d <= game_kill;
    if reset_l = '0' then
      kill_pulse <= '0';
      kill_cnt   <= (others => '0');
    elsif kill_pulse = '0' then
      if game_kill = '1' and kill_d = '0' then
        kill_pulse <= '1';
        kill_cnt   <= (others => '0');
      end if;
    else
      if kill_cnt >= kill_len then
        kill_pulse <= '0';
      else
        kill_cnt <= kill_cnt + 1;
      end if;
    end if;
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
	sw_enable => '0',
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
--
-- HISTORY.  Upstream auto-detected the family by counting 16 edges on
-- U5_pa_out(1) (COUNT_STROBES): if the strobes never moved the design latched
-- "this must be 80B".  That is unsound in three separate ways -- it concludes
-- 80B from the ABSENCE of evidence (a dead RIOT, a held CPU or a slow ROM boot
-- all look like 80B), it is a ONE-WAY latch (it can never come back), and it
-- powers up in the WRONG state (not80B='0' = 80B format) so a numeric glass is
-- black for as long as the detector takes.  It was disabled for the
-- System-80/Volcano build and replaced by the hard-wired `not80B <= '1'`,
-- which of course made the bitstream System-80-only.
--
-- NOW: the family comes from the DIP game number (lib_common/gts_family.vhd),
-- registered when the DIP scan finishes -- i.e. it is known BEFORE the 6502
-- executes its first instruction, from positive evidence, and it is stable.
-- For every System 80 and 80A number (0..39) is_80B='0' -> not80B='1', which
-- is bit-identical to the hard-wired line it replaces, so the proven Volcano
-- (game 12/13) behaviour is unchanged.
not80B <= not is_80B;

--------------------------------------------------
-- 80B display routines	
--------------------------------------------------
-- 80B diag display: in diag the disp80b_diag FSM replaces the (held) 6502's
-- RIOT lines so LISYcontrol can write the alphanumeric glass through the very
-- same latch plumbing the game uses.
-- Gated by the disp80b_diag_enable generic -- see the entity header for the
-- measured cost (~575 LE / 383 registers, 366 -> 392/392 LABs).  OFF = the
-- CPU's own RIOT lines always drive the 80B display path, which is what every
-- bitstream burned so far did (the whole chain used to be pruned because
-- not80B was hard-wired to '1').
GEN_D80DIAG: if disp80b_diag_enable generate
u5pa_disp4 <= d80_pa(4) when lisy_active = '1' else U5_pa_out(4);
u5pa_disp5 <= d80_pa(5) when lisy_active = '1' else U5_pa_out(5);
u5pb_disp  <= d80_pb    when lisy_active = '1' else U5_pb_out(6 downto 0);
DISP80B: entity work.disp80b_diag
port map( clk => clk_50, active => lisy_active, txt => lisy_txt,
          o_pa => d80_pa, o_pb => d80_pb );
end generate GEN_D80DIAG;

GEN_NO_D80DIAG: if not disp80b_diag_enable generate
u5pa_disp4 <= U5_pa_out(4);
u5pa_disp5 <= U5_pa_out(5);
u5pb_disp  <= U5_pb_out(6 downto 0);
d80_pa     <= (others => '0');
d80_pb     <= (others => '0');
end generate GEN_NO_D80DIAG;
segments_80B(8) <= not u5pb_disp(4); --LD1
segments_80B(16) <= not u5pb_disp(5); --LD2
segments_80B(24) <= not u5pb_disp(6); --Reset
-- D0 ... D4
sn74175_80B_1: entity work.sn74175 
port map(   
   Clock => clk_50,
	clk => u5pa_disp4,
	clear	=> reset_l,
	D => not u5pb_disp(3 downto 0),
	Q => open,
	Qn(0) => segments_80B(2),
	Qn(1) => segments_80B(6),
	Qn(2) => segments_80B(7),
	Qn(3) => segments_80B(1)
);
sn74175_80B_2: entity work.sn74175 
port map(   
   Clock => clk_50,
	clk => u5pa_disp5,
	clear	=> reset_l,
	D => not u5pb_disp(3 downto 0),
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
-- v3: the strobes are taken away from the ROM ONLY for a full-glass takeover
-- (ta_full).  In the normal time-attack case (ta_part) the ROM keeps driving its
-- own multiplex and TAOVL just replaces one segment group inside one strobe
-- window -- see the TIME-ATTACK DISPLAY INJECTION block above.
-- 80B note: PA(3 downto 0) still carries bm_digit_strobe before the CPU runs,
-- exactly as upstream did.  That is harmless on 80B because the alphanumeric
-- path is clocked by U5_pa_out(4)/(5) and U5_pb_out only -- PA(3 downto 0)
-- cannot latch anything into it -- and with the 80B gate on disp_segments below
-- the data lines no longer carry banner patterns either.
U5_PA(3 downto 0) <= lisy_u5pa when (lisy_active='1' and not80B='1') else U5_pa_out(3 downto 0) when (game_running='1' and ta_full='0') else bm_digit_strobe;  -- only a FULL overlay steals the strobes

-- merge the injected character into the ROM's own segment stream: exactly one
-- group, exactly during the digit strobes that address the chosen display.
-- ta_seg bit 8 is the Gottlieb comma line and is '0' for every glyph, so the
-- injected digits carry no comma -- same as the boot banner does today.
segments_inj(1 to 8)   <= ta_seg when (ta_part = '1' and ta_hit_a = '1') else segments_80(1 to 8);
segments_inj(9 to 16)  <= ta_seg when (ta_part = '1' and ta_hit_b = '1') else segments_80(9 to 16);
segments_inj(17 to 24) <= ta_seg when (ta_part = '1' and ta_hit_c = '1') else segments_80(17 to 24);

-- assign display segments dependent on display type
--
-- 80B GATE, added 2026-07-27.  The bm_segments branch used to be tested BEFORE
-- not80B, so on an 80B machine the numeric BCD boot banner (and the time-attack
-- full-glass overlay, and the SD/NOR error banner) was pushed straight into the
-- alphanumeric latch path: 24 lines of 7-segment patterns interpreted as 80B
-- display data = garbage on the glass at every single power-up.  boot_message
-- speaks 6-digit BCD only; there is no 80B banner engine yet (that is the
-- separate 80B display back-end task).  So on 80B all three of those branches
-- are simply suppressed and the mux falls through to segments_80B, which is the
-- stock 80B path: while the CPU is in reset the two sn74175 latches are held
-- cleared, no valid latch traffic reaches the display board, and the glass
-- stays unwritten (blank) until the game ROM starts its own refresh.
--
-- ERROR BANNER ON 80B: the `SDcard_error = '0'` branch is the ROM-load failure
-- banner.  In THIS build it is unreachable on every family -- the game image
-- comes from lib_common/nor_flash.vhd, which hard-wires `SDcard_error <= '1'`
-- and has no failure path (a bad NOR simply never releases cpu_reset_l).  If
-- SD_Card.vhd is ever swapped back in, an 80B user would get a blank glass
-- instead of the numeric error banner; the error is still reported on the
-- LED_SDcard pin (LED_SDcard <= SDcard_error) and, in the ESP builds, the
-- machine simply never leaves reset -- which is the same "no game" symptom the
-- banner was there to explain.
disp_segments <=
	lisy_segments when (lisy_active = '1' and not80B = '1') else  -- numeric System-80 diag display test
	bm_segments when not80B = '1' and (( ta_full = '1' ) or ( game_running = '0' and U5_pb_out(6) = '1') or SDcard_error = '0') else
	segments_inj when not80B = '1' else   -- = segments_80, countdown merged in when ta_part='1'
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
	A			=> cpu_addr_full,        -- port ENTIER (24 bits), cf. portabilite XST       
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
-- $0072 snoop.  Originally added as "ball in play" telemetry from the PinMAME
-- correlation; hardware disproved that reading (the ball counter is $0109) and
-- proved instead that $0072 is a GAME-IN-PROGRESS flag: 0 in attract, 1 during a
-- game, 0 again at game over (live 0->1->0 trace over a full 3-ball game, and
-- confirmed by the RAM snapshots).  Still read-only on the CPU bus -- no gameplay
-- effect -- and still fed to sound_link, which emits 0xA0|value on change.
-- `ball_val` is now ALSO the auto-restart game-over detector (see AUTO_RESTART).
BALL_SNOOP: process(clk_50) begin
  if rising_edge(clk_50) then
    if U4_RAM_cs = '1' and cpu_wr_n = '0' and cpu_addr(6 downto 0) = "1110010" then
      ball_val <= cpu_dout(3 downto 0);
    end if;
  end if;
end process;

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
		
	-- sw_inject = auto-restart synthetic coin/credit closures (see TIME-ATTACK block).
	-- ORed here, one stage AFTER U4_pa_in, so the FPGA's own detect_sw* blocks cannot
	-- see our injected press -> no feedback into sim_coin / the NVRAM credit trigger.
	pa_in	 => U4_pa_in or SW_Freeplay or sw_inject,
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
			
	-- slam_to_cpu = slam XOR kill_pulse (END-ON-DEMAND); identical to `slam` while
	-- game_kill='0', so this build behaves exactly as before.
	pa_in	 => slam_to_cpu & "0000000",
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
	-- ORA write strobe: high for the phi2-low phase in which pa_out takes the
	-- value the CPU just wrote.  This is the qualification PinMAME applies
	-- (riot6532_2a_w runs only on a port-A write) and is what turns the
	-- combinational sound vector into an EVENT -- see snd_bus.vhd below.
   pa_wr  => u6_pa_wr,
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
-- Sound command bit 4 (S16) is NOT on the U6 PA sound nibble -- it is stolen
-- from the LAMP latch, and 80/80A and 80B steal it from DIFFERENT places.
-- PinMAME ground truth, src/wpc/gts80.c riot6532_2a_w:
--
--   if (soundBoard == SNDBRD_GTS80B)
--        if (data&0x10) sndCmd((lampMatrix[0] & 0x10) | (data & 0x0f));
--   else sndCmd(((lampMatrix[1] & 0x02) ? 0x10 : 0) | ((data&0x10) ? data&0x0f : 0));
--
-- and riot6532_2b_w maps the latch: `column = ((data & 0xf0)>>4) - 1`, even
-- columns into the low nibble of lampMatrix[column/2], odd columns into the
-- high nibble.  Unrolling both:
--   80 / 80A : lampMatrix[1] & 0x02 = column 2, data bit 1
--              column 2  <=> (pb>>4)-1 = 2 <=> pb(7 downto 4) = "0011" = DS3
--              -> DS3, bit 1        (this is the latch that was already here)
--   80B      : lampMatrix[0] & 0x10 = column 1 (HIGH nibble of [0]), data bit 0
--              column 1  <=> (pb>>4)-1 = 1 <=> pb(7 downto 4) = "0010" = DS2
--              -> DS2, bit 0        (this latch is new)
-- Both latches always run; is_80B picks which one reaches Sound_Meta(4) and
-- the sound_link 0x80|cmd token.  ~1 FF + a 4-bit compare; the unused bits of
-- each sn74175 are left open and get pruned.
clk_Z3 <= '1' when U6_pb_out(7 downto 4) = "0011" else '0'; --DS3 (80/80A)
clk_Z2 <= '1' when U6_pb_out(7 downto 4) = "0010" else '0'; --DS2 (80B)

sn74175_Sound16: entity work.sn74175
port map(
   Clock => clk_50,
	clk => clk_Z3,
	clear	=> '1',
	D => U6_pb_out(3 downto 0),
	Q => q_snd80_v                  -- port ENTIER, cf. portabilite XST
);
Sound_S16_80 <= q_snd80_v(1);

sn74175_Sound16B: entity work.sn74175
port map(
   Clock => clk_50,
	clk => clk_Z2,
	clear	=> '1',
	D => U6_pb_out(3 downto 0),
	Q => q_snd80b_v                 -- port ENTIER, cf. portabilite XST
);
Sound_S16_80B <= q_snd80b_v(0);

Sound_S16 <= Sound_S16_80B when is_80B = '1' else Sound_S16_80;

---------------------
-- SOUND BUS EVENTS -> the ESP (SOUND_WIRE.md)
----------------------
-- The five signals above are what the SOUND BOARD sees: a level, combinational
-- on the RIOT port-A latch and on a lamp latch.  GOSOF80 consumes them as such
-- and is untouched.  The sound_link UART, however, must report EVENTS -- what
-- the 6502 actually put on the bus, in order, without coalescing -- so it is
-- fed from snd_bus instead, which qualifies with the real port-A write strobe:
--   * a LAMP write can no longer inject a phantom cue (S16 moving on its own
--     is not an event);
--   * a bus RELEASE becomes 0x30, not "command 0" -- or, when the S16 lamp bit
--     happens to be latched high, not the phantom "command 16" that the Arena
--     notes have been calling a constant background hum all along.
-- `snd_sel` folds in the test button exactly as the sound vector does: with
-- myTest asserted the vector is forced to code 3, i.e. a code IS selected.
snd_sel <= (not U6_pa_out(4)) when myTest = '1' else '1';

SND_BUS : entity work.snd_bus
port map(
	clk => clk_50, rst => not reset_l,
	pa_wr => u6_pa_wr,
	sel   => snd_sel,
	stb   => snd_stb,
	rel   => snd_rel
);

-- Machine family for the 0xF4|fam link token.  is_80B already carries the DIP
-- S1-6 manual override, so it is tested first; the three flags are otherwise
-- mutually exclusive by construction (gts_family.vhd).
fam_code <= "10" when is_80B = '1' else "01" when is_80A = '1' else "00";


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
		DFP_tx	=> open,   -- PIN_2 repurposed as the display-inject RX
		
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
-- Shadow the whole RIOT scratch RAM *and* the 5101 CMOS RAM, and stream both to
-- the ESP once a second.  Read-only snoop: no gameplay effect, nothing is driven
-- back onto the CPU bus.
--   RIOT: the three chip selects decode cpu_addr(13 downto 7), which pins both
--   a(8) and a(7), so cpu_addr(8 downto 0) is already the wire-format index with
--   no remapping: U4 ($0000-$007F) -> 0..127, U5 ($0080-$00FF) -> 128..255,
--   U6 ($0100-$017F) -> 256..383.  Prefixed with '0' -> shadow 0..511.
--   5101: r5101_cs covers $1800-$1FFF, Z5 latches cpu_addr(7 downto 0) with only
--   cpu_dout(3 downto 0) (Gottlieb uses the low nibble), so mirror
--   "0000" & cpu_dout(3 downto 0) at shadow "10" & cpu_addr(7 downto 0) -> 512..767.
-- The two selects are mutually exclusive by construction (RIOT needs
-- cpu_addr(13 downto 11)="000", the 5101 needs "011"), so the mux below can never
-- drop a write; the RIOT branch takes priority only as a defensive default.
snap_riot_wr <= (U4_RAM_cs or U5_RAM_cs or U6_RAM_cs) and not cpu_wr_n;
snap_5101_wr <= r5101_cs and not cpu_wr_n;
snap_wr_en   <= snap_riot_wr or snap_5101_wr;
snap_wr_addr <= '0' & cpu_addr(8 downto 0) when snap_riot_wr = '1'
                else "10" & cpu_addr(7 downto 0);
snap_wr_data <= cpu_dout when snap_riot_wr = '1'
                else "0000" & cpu_dout(3 downto 0);

RAM_SNAP : entity work.ram_snoop
generic map( clk_hz => 50000000, period_ms => 1000, n_bytes => 640 )
port map(
	clk => clk_50, rst => not reset_l,
	wr_addr => snap_wr_addr,
	wr_data => snap_wr_data,
	wr_en   => snap_wr_en,
	snap_data => snap_data_s,
	snap_req  => snap_req_s,
	snap_ack  => snap_ack_s
);

SND_LINK : entity work.sound_link
port map(
	clk => clk_50, rst => not reset_l,
	diag => lisy_active,
	-- sound is now an EVENT stream: the code is sampled on snd_stb only.
	sound => Sound_S16 & Sound_S8 & Sound_S4 & Sound_S2 & Sound_S1,
	snd_stb => snd_stb,
	snd_rel => snd_rel,
	fam  => fam_code,                                 -- 0xF4 | fam (00=80 01=80A 10=80B)
	-- FIXED 2026-07-27: this was RAW `game_select`, i.e. the INVERTED DIP value,
	-- while every other consumer of the game number (nor_flash `selection`,
	-- GOSOF80 `game_sel`, EEprom `selection`, and the boot banner via
	-- byte_to_ascii's internal `not mybyte`) applies `not game_select`.  The
	-- 0x40|game token therefore named a different game than the ROM that was
	-- actually loaded -- e.g. Volcano (12) was announced as 51 (Arena).  The ESP
	-- expects the true gamelist index here: see gottfa-esp32/src/wavplayer.cpp
	-- ("No = GottFA80_PLuS gamelist index (manual Appendix A), as sent on the
	-- link (0x40|No)") and fpgalink.cpp's `(b & 0xC0) == 0x40` handler.
	game => gnum,
	game_running => game_running,                     -- tournament auto-timer (0xF2/0xF3 to ESP)
	ball => ball_val,                                 -- ball-in-play telemetry (0xA0|ball)
	-- ESP -> FPGA link telemetry: is disp_inject hearing the ESP at all?
	dinj => dinj_valid & dinj_ctrl(2 downto 0),       -- 0xE0 | {dvalid, kill, overlay, autorestart}
	rxc  => dinj_rxc,                                 -- 0xB0 | deframed-byte count (0xB0..0xBE)
	snap_data => snap_data_s,                         -- RAM snapshot frame (0xBF + 1280 nibble bytes)
	snap_req  => snap_req_s,
	snap_ack  => snap_ack_s,
	tx => sl_tx
);
Debug    <= sl_tx;
-- Audio_RX/PIN_2 is now an INPUT (ESP GPIO9 display-inject UART TX is wired to it).
Sound    <= '0';
end generate GEN_ESP_SND;

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
	snd_stb => snd_stb,                               -- EVENT stream, see SND_LINK above
	snd_rel => snd_rel,
	fam  => fam_code,
	game => gnum,                                     -- true game number, see SND_LINK above
	game_running => game_running,                     -- tournament auto-timer (0xF2/0xF3 to ESP)
	tx => sl_tx
);
Debug <= sl_tx;
end generate GEN_HYB_LINK;
 	
	
	
end rtl;
		