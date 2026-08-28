--------------------------------------------------------------------------
-- ar_timer : transcription LITTERALE de l'idiome de temporisation utilise
-- dans SYS80.vhd AUTO_RESTART (lignes 1219-1223 / 1229-1234 / 1239-1243 ...)
--
--        if <cnt> >= <LIMITE> then
--          <cnt> <= (others => '0');
--          <action>
--        else
--          <cnt> <= <cnt> + 1;
--        end if;
--
-- Seule difference : la limite est un generique et l'action est un pulse
-- observable "fire".  Meme largeur de compteur, meme comparateur >=.
--------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ar_timer is
  generic ( LIMIT : natural );
  port (
    clk_50  : in  std_logic;
    reset_l : in  std_logic;
    fire    : out std_logic
  );
end ar_timer;

architecture rtl of ar_timer is
  signal cnt : unsigned(27 downto 0) := (others => '0');   -- comme ar_cnt
begin
  process(clk_50)
  begin
    if rising_edge(clk_50) then
      fire <= '0';
      if reset_l = '0' then
        cnt <= (others => '0');
      elsif cnt >= LIMIT then
        cnt  <= (others => '0');
        fire <= '1';
      else
        cnt <= cnt + 1;
      end if;
    end if;
  end process;
end rtl;
