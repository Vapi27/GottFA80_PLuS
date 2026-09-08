-- game_beacon : dit a l'ESP ce que le FPGA sait de lui-meme. -- Pstore, 31/08/2026
--
-- Trame de 4 octets a 115200 bauds, repetee 2x/seconde vers l'ESP :
--   [0] 0xFA                    synchro
--   [1] "0" & fp & gnum(5:0)    le VRAI numero de jeu lu des DIP + drapeau free-play
--   [2] flags : b0=game_running (255 IRQ vues), b1=is_80B, b2=is_80A, b3=reset_l
--   [3] octet[1] xor octet[2] xor 0xA5
-- Le bit 7 de l'octet [1] est toujours 0 : aucune donnee ne peut imiter la synchro.
--
-- DEUX MODES DE SORTIE (2026-09-05) -- generic own_uart :
--
--   own_uart = true  : comportement d'origine, la balise possede son propre UART
--                      et pilote `tx` toute seule. Utilise par les builds SANS
--                      sound_link (esp_sound = false), ou elle est seule sur le fil.
--
--   own_uart = false : la balise n'emet plus rien elle-meme ; elle PRESENTE sa
--                      trame (frame/req) et attend `ack`. C'est sound_link qui la
--                      pousse sur le fil, en 4 octets ATOMIQUES.
--
-- POURQUOI. Il n'y a qu'UN fil FPGA -> ESP (P142 -> GPIO18). La balise le tenait
-- seule, donc les commandes son de sound_link n'arrivaient JAMAIS au decodeur : elles
-- partaient sur `Debug` (P46 = P4.11 ET RXD0 de l'ESP, GPIO44 -- pas « nulle part »,
-- correction du 2026-09-07), que fpgalink n'ecoutait pas. Mesure du
-- 2026-09-05 sur la machine : le lien ne portait que 0xFA/0x09, `payload=0`.
--
-- Et on ne peut pas simplement multiplexer deux UART : les octets [1] a [3] sont
-- des valeurs ARBITRAIRES qu'aucune classe de la carte d'octets ne distingue. Si
-- une trame etait coupee en deux, l'octet [3] pourrait tomber dans 0x80..0x9F et
-- l'ESP jouerait un SON FANTOME. D'ou l'atomicite, garantie par un seul emetteur.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity game_beacon is
generic( clk_hz   : integer := 50_000_000;
         baud     : integer := 115_200;
         own_uart : boolean := true );
port(
    clk          : in  std_logic;
    gnum         : in  std_logic_vector(5 downto 0);
    fp           : in  std_logic;
    game_running : in  std_logic;
    is_80B       : in  std_logic;
    is_80A       : in  std_logic;
    reset_l      : in  std_logic;
    diag_esp     : in  std_logic := '0';   -- diagnostic ouvert par l'ESP (et non par Test)
    ctrl_lvl     : in  std_logic := '1';   -- niveau courant de FA_CTRL_REQ (P141), actif bas
    ctrl_low_seen: in  std_logic := '0';   -- COLLANT : la ligne a ete vue basse au moins une fois
    build_tag    : in  std_logic := '0';   -- etiquette de build, alternee a chaque gravure
    tx           : out std_logic := '1';
    -- Remise a un emetteur exterieur (own_uart = false). Defauts fournis pour que
    -- les instanciations qui ne s'en servent pas elaborent sans changement.
    frame        : out std_logic_vector(31 downto 0) := (others => '0');
    req          : out std_logic := '0';
    ack          : in  std_logic := '0'
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
    signal   req_i  : std_logic := '0';
    signal   frm_i  : std_logic_vector(31 downto 0) := (others => '0');
begin
    o1 <= "0" & fp & gnum;
    -- b4 : PAR QUELLE PORTE le diagnostic a ete ouvert. Sans ce bit, une machine
    -- coincee en diagnostic ne dit pas si c'est la ligne de l'ESP (niveau, elle
    -- retombe) ou l'appui long sur Test (COLLANT : seul un reset en sort). Les
    -- deux se ressemblent exactement de l'exterieur, et chercher la mauvaise
    -- coute une soiree (2026-09-07).
    -- b5/b6 : etat BRUT de la ligne de demande. b5 est un niveau, donc soumis a
    -- l'echantillonnage ; b6 est COLLANT et attrape n'importe quel passage bas,
    -- meme d'une microseconde. Sans le collant, une impulsion breve se lit comme
    -- « la ligne n'a jamais bouge » -- l'erreur exacte payee plus tot ce jour.
    -- b7 : ETIQUETTE DE BUILD. Un seul bit, alterne d'une gravure a la suivante.
    -- Il ne dit pas QUELLE version tourne, il dit si c'est LA DERNIERE GRAVEE --
    -- ce qui est la seule question qu'on se pose apres une gravure, et qu'on a
    -- passe la soiree a ne pas pouvoir trancher (2026-09-07). Comparer deux
    -- fichiers .bin ne prouve rien : ca ne dit pas ce que le FPGA a charge.
    o2 <= build_tag & ctrl_low_seen & ctrl_lvl & diag_esp & reset_l & is_80A & is_80B & game_running;

    -- ---------------------------------------------------------------------
    -- Mode historique : la balise est seule sur le fil et l'emet elle-meme.
    -- ---------------------------------------------------------------------
    GEN_UART : if own_uart generate
      req   <= '0';
      frame <= (others => '0');
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
    end generate GEN_UART;

    -- ---------------------------------------------------------------------
    -- Mode remise : sound_link possede le fil, la balise ne fait que proposer.
    -- `req` reste haut jusqu'a l'acquittement -- la trame est donc figee tant
    -- qu'elle n'est pas partie, et le compteur de pause ne repart qu'apres.
    -- ---------------------------------------------------------------------
    GEN_HANDOFF : if not own_uart generate
      tx    <= '1';
      req   <= req_i;
      frame <= frm_i;
      process(clk)
      begin
        if rising_edge(clk) then
          if req_i = '0' then
            if attente = PAUSE then
              attente <= 0;
              frm_i   <= (o1 xor o2 xor x"A5") & o2 & o1 & x"FA";
              req_i   <= '1';
            else
              attente <= attente + 1;
            end if;
          elsif ack = '1' then
            req_i <= '0';
          end if;
        end if;
      end process;
    end generate GEN_HANDOFF;
end rtl;
