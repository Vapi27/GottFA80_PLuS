-- game_beacon : dit a l'ESP ce que le FPGA sait de lui-meme. -- Pstore, 31/08/2026
--
-- Trame de 4 octets a 115200 bauds, repetee 2x/seconde sur le fil P142 -> GPIO18
-- (UART1 RX de FA_Control, cable au PCB depuis toujours mais jamais servi) :
--   [0] 0xFA                    synchro
--   [1] "0" & fp & gnum(5:0)    le VRAI numero de jeu lu des DIP + drapeau free-play
--   [2] flags : b0=game_running (255 IRQ vues), b1=is_80B, b2=is_80A, b3=reset_l
--   [3] octet[1] xor octet[2] xor 0xA5
-- Le bit 7 de l'octet [1] est toujours 0 : aucune donnee ne peut imiter la synchro.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity game_beacon is
generic( clk_hz : integer := 50_000_000; baud : integer := 115_200 );
port(
    clk          : in  std_logic;
    gnum         : in  std_logic_vector(5 downto 0);
    fp           : in  std_logic;
    game_running : in  std_logic;
    is_80B       : in  std_logic;
    is_80A       : in  std_logic;
    reset_l      : in  std_logic;
    tx           : out std_logic
);
end game_beacon;

architecture rtl of game_beacon is
    constant DIV    : integer := clk_hz / baud;               -- 434 a 50 MHz
    constant PAUSE  : integer := clk_hz / 2;                  -- 2 trames/seconde
    signal   bdiv   : integer range 0 to DIV-1 := 0;
    signal   attente: integer range 0 to PAUSE := 0;
    signal   trame  : std_logic_vector(31 downto 0);
    signal   shift  : std_logic_vector(9 downto 0) := (others => '1'); -- start+8+stop
    signal   nbit   : integer range 0 to 10 := 0;
    signal   noct   : integer range 0 to 4  := 4;
    signal   o1, o2 : std_logic_vector(7 downto 0);
begin
    o1 <= "0" & fp & gnum;
    o2 <= "0000" & reset_l & is_80A & is_80B & game_running;

    process(clk)
    begin
        if rising_edge(clk) then
            if noct = 4 then                          -- entre deux trames
                tx <= '1';
                if attente = PAUSE then
                    attente <= 0;
                    -- la trame est fixee ICI, une fois, coherente d'un bloc
                    trame <= (o1 xor o2 xor x"A5") & o2 & o1 & x"FA";
                    noct <= 0; nbit <= 0; bdiv <= 0;
                else
                    attente <= attente + 1;
                end if;
            else
                if nbit = 0 and bdiv = 0 then         -- charger l'octet courant
                    shift <= '1' & trame(7 downto 0) & '0';
                    trame <= x"00" & trame(31 downto 8);
                end if;
                tx <= shift(0);
                if bdiv = DIV-1 then
                    bdiv <= 0;
                    shift <= '1' & shift(9 downto 1);
                    if nbit = 9 then
                        nbit <= 0; noct <= noct + 1;
                    else
                        nbit <= nbit + 1;
                    end if;
                else
                    bdiv <= bdiv + 1;
                end if;
            end if;
        end if;
    end process;
end rtl;
