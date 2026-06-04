-- tb_nor_flash.vhd : self-checking testbench for nor_flash (+ a behavioral SPI
-- NOR model). GPL-3.0. Run:
--   ghdl -a lib_common/SPI_Master.vhd lib_common/nor_flash.vhd sim/tb_nor_flash.vhd
--   ghdl -e tb_nor_flash && ghdl -r tb_nor_flash --stop-time=10ms
-- The model returns data byte n = (read_addr + n) mod 256, so the image written
-- to RAM must satisfy data[k] = (selection*0x4000 + k) mod 256.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity tb_nor_flash is end tb_nor_flash;

architecture sim of tb_nor_flash is
  signal clk      : std_logic := '0';
  signal rst_l    : std_logic := '0';
  signal spi_clk  : std_logic;
  signal miso     : std_logic := '0';
  signal mosi     : std_logic;
  signal cs       : std_logic;
  signal seln     : std_logic_vector(7 downto 0) := x"02";  -- game 2 -> 0x8000
  signal address  : std_logic_vector(13 downto 0);
  signal data     : std_logic_vector(7 downto 0);
  signal wr_rom   : std_logic;
  signal cpu_rl   : std_logic;
  signal sderr    : std_logic;

  signal byte_cnt : integer := 0;
  signal fail_cnt : integer := 0;
  signal done     : boolean := false;
  constant LAST   : integer := 15;     -- 16-byte image for a fast run
begin
  clk <= not clk after 10 ns when not done else '0';

  DUT : entity work.nor_flash
    generic map ( clk_hz => 50000000, spi_hz => 10000000, base_addr => 0,
                  last_addr => LAST, startup_clks => 50 )
    port map ( i_Clk => clk, i_Rst_L => rst_l, o_SPI_Clk => spi_clk,
      i_SPI_MISO => miso, o_SPI_MOSI => mosi, o_SPI_CS_n => cs, selection => seln,
      address_sd_card => address, data_sd_card => data, wr_rom => wr_rom,
      cpu_reset_l => cpu_rl, SDcard_error => sderr );

  -- behavioral SPI NOR (mode 0): byte0=cmd, byte1..3=addr, then data = (addr+n) mod 256
  nor_model : process (spi_clk, cs)
    variable bitc  : integer := 0;
    variable bytec : integer := 0;
    variable insh  : std_logic_vector(7 downto 0) := (others => '0');
    variable outsh : std_logic_vector(7 downto 0) := (others => '0');
    variable raddr : unsigned(23 downto 0) := (others => '0');
  begin
    if cs = '1' then
      bitc := 0; bytec := 0; raddr := (others => '0'); miso <= '0';
    elsif rising_edge(spi_clk) then
      insh := insh(6 downto 0) & mosi;
      bitc := bitc + 1;
      if bitc = 8 then
        bitc := 0;
        if    bytec = 1 then raddr(23 downto 16) := unsigned(insh);
        elsif bytec = 2 then raddr(15 downto 8)  := unsigned(insh);
        elsif bytec = 3 then raddr(7 downto 0)   := unsigned(insh);
        end if;
        bytec := bytec + 1;
        if bytec >= 4 then outsh := std_logic_vector(resize(raddr + (bytec - 4), 8)); end if;
      end if;
    elsif falling_edge(spi_clk) then
      miso  <= outsh(7);
      outsh := outsh(6 downto 0) & '0';
    end if;
  end process;

  -- monitor: every wr_rom pulse, expected data = (0x8000 + address) mod 256 = address
  mon : process (clk)
    variable prev : std_logic := '0';
  begin
    if rising_edge(clk) then
      if prev = '0' and wr_rom = '1' then
        if unsigned(data) /= resize(unsigned(address), 8) then
          fail_cnt <= fail_cnt + 1;
          report "MISMATCH addr=" & integer'image(to_integer(unsigned(address)))
               & " data=" & integer'image(to_integer(unsigned(data))) severity warning;
        end if;
        byte_cnt <= byte_cnt + 1;
      end if;
      prev := wr_rom;
    end if;
  end process;

  stim : process
  begin
    rst_l <= '0'; wait for 1 us; rst_l <= '1';
    wait until cpu_rl = '1' for 5 ms;
    wait for 2 us;
    report "bytes=" & integer'image(byte_cnt) & " fails=" & integer'image(fail_cnt) severity note;
    if byte_cnt = LAST + 1 and fail_cnt = 0 and cpu_rl = '1' then
      report "===== NOR TESTS PASSED =====" severity note;
    else
      report "===== NOR TESTS FAILED =====" severity failure;
    end if;
    done <= true; wait;
  end process;
end sim;
