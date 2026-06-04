--
-- nor_flash.vhd
-- Drop-in replacement for SD_Card.vhd that reads the 16 KByte game image from a
-- standard SPI NOR flash (e.g. W25Q32) instead of an SD card.
-- Same entity interface as SD_Card -> swap the instance in SYS80.vhd.
-- for GottFA80 (GPL-3.0)
--
-- NOR read: CS low, send 0x03 (READ DATA) + 24-bit address, then clock out N
-- bytes. Address = gamenumber*0x4000 + base_addr (16 KByte per game). No SD init
-- handshake. Reuses SPI_Master (8-bit). The ESP programs the NOR over the same
-- SPI pins while the FPGA is held in reset (see project notes).

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity nor_flash is
  generic (
    clk_hz       : integer := 50000000;
    spi_hz       : integer := 8000000;
    base_addr    : integer := 0;        -- byte offset of game 0 in the NOR
    last_addr    : integer := 16#3FFF#; -- last image byte (0x3FFF = 16 KByte)
    startup_clks : integer := 50000     -- power/CS settle before first access
  );
  port (
    i_Clk           : in  std_logic := '1';
    i_Rst_L         : in  std_logic;                       -- FPGA reset (active low)
    o_SPI_Clk       : out std_logic;
    i_SPI_MISO      : in  std_logic;
    o_SPI_MOSI      : out std_logic;
    o_SPI_CS_n      : out std_logic;
    selection       : in  std_logic_vector(7 downto 0);    -- game number
    address_sd_card : buffer std_logic_vector(13 downto 0);
    data_sd_card    : out std_logic_vector(7 downto 0);
    wr_rom          : out std_logic;
    cpu_reset_l     : out std_logic;                       -- start CPU when high
    SDcard_error    : out std_logic                        -- active low (kept '1')
  );
end nor_flash;

architecture rtl of nor_flash is
  type state_t is (st_reset, st_delay, st_cmd, st_xfer_start, st_xfer_wait,
                   st_xfer_post, st_data_write, st_data_inc, st_done);
  signal state : state_t := st_reset;

  -- SPI master (8-bit); CS is driven by this module directly (cs signal)
  signal tx_data  : std_logic_vector(7 downto 0) := x"FF";
  signal rx_data  : std_logic_vector(7 downto 0);
  signal tx_start : std_logic := '0';
  signal tx_done  : std_logic;
  signal m_mosi   : std_logic;
  signal m_sclk   : std_logic;

  signal cs       : std_logic := '1';
  signal phase    : integer range 0 to 4 := 0;   -- 0..3 = cmd+addr, 4 = data
  signal nor_addr : unsigned(23 downto 0) := (others => '0');
  signal rxb      : std_logic_vector(7 downto 0) := (others => '0');
  signal dcount   : integer range 0 to startup_clks := 0;
begin

  o_SPI_CS_n <= cs;
  o_SPI_MOSI <= m_mosi when cs = '0' else '0';
  o_SPI_Clk  <= m_sclk when cs = '0' else '0';
  SDcard_error <= '1';

  SPI : entity work.SPI_Master
    generic map ( Quarz_Taktfrequenz => clk_hz, SPI_Taktfrequenz => spi_hz, Laenge => 8 )
    port map (
      TX_Data => tx_data, RX_Data => rx_data, MOSI => m_mosi, MISO => i_SPI_MISO,
      SCLK => m_sclk, SS => open, TX_Start => tx_start, TX_Done => tx_done,
      clk => i_Clk, do_not_disable_SS => '1', do_not_enable_SS => '1'
    );

  process (i_Clk, i_Rst_L)
    variable g : integer;
  begin
    if rising_edge(i_Clk) then
      if i_Rst_L = '0' then
        state <= st_reset; cs <= '1'; tx_start <= '0'; wr_rom <= '0';
        cpu_reset_l <= '0'; address_sd_card <= (others => '0'); phase <= 0; dcount <= 0;
      else
        case state is
          when st_reset =>
            cpu_reset_l <= '0'; wr_rom <= '0'; cs <= '1';
            address_sd_card <= (others => '0'); phase <= 0; dcount <= 0;
            g := to_integer(unsigned(selection));
            nor_addr <= to_unsigned(g * 16384 + base_addr, 24);
            state <= st_delay;

          when st_delay =>                          -- NOR power/CS settle, then assert CS
            if dcount = startup_clks then cs <= '0'; state <= st_cmd;
            else dcount <= dcount + 1; end if;

          when st_cmd =>                            -- present the byte for this phase
            case phase is
              when 0 => tx_data <= x"03";
              when 1 => tx_data <= std_logic_vector(nor_addr(23 downto 16));
              when 2 => tx_data <= std_logic_vector(nor_addr(15 downto 8));
              when 3 => tx_data <= std_logic_vector(nor_addr(7 downto 0));
              when others => tx_data <= x"FF";       -- data dummy
            end case;
            state <= st_xfer_start;

          when st_xfer_start =>
            tx_start <= '1';
            state <= st_xfer_wait;

          when st_xfer_wait =>
            if tx_done = '1' then
              tx_start <= '0';
              rxb <= rx_data;
              state <= st_xfer_post;
            end if;

          when st_xfer_post =>
            if tx_done = '0' then
              if phase < 4 then
                phase <= phase + 1;                  -- next cmd/addr byte (or enter data)
                state <= st_cmd;
              else
                data_sd_card <= rxb;                 -- a data byte
                state <= st_data_write;
              end if;
            end if;

          when st_data_write =>
            wr_rom <= '1';                           -- write current byte to RAM/ROM
            state  <= st_data_inc;

          when st_data_inc =>
            wr_rom <= '0';
            if to_integer(unsigned(address_sd_card)) = last_addr then
              cs <= '1'; cpu_reset_l <= '1';         -- done -> release CPU
              state <= st_done;
            else
              address_sd_card <= std_logic_vector(unsigned(address_sd_card) + 1);
              state <= st_cmd;                       -- phase stays 4 -> next data byte
            end if;

          when st_done =>
            null;
        end case;
      end if;
    end if;
  end process;
end rtl;
