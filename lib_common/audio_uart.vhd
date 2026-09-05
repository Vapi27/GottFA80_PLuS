-- audio_uart.vhd — les voix de l'ESP sortent par l'etage audio de la porteuse.
--
-- POURQUOI. Le module Smart FA n'a AUCUN etage audio : ni DAC, ni ampli, aucun net
-- I2S dans les six feuilles du schema (verifie le 2026-09-04). Le firmware ESP
-- emettait donc son I2S sur GPIO17/18, qui sont en realite `ESP32_TX`/`ESP32_RX`
-- vers le FPGA -- dont l'une est une SORTIE du FPGA. Deux pilotes sur un fil, et
-- un son « ultra faible » qui n'etait que de la fuite.
--
-- Or l'etage audio existe deja, de l'autre cote : la broche `Sound` (P44) porte le
-- flux delta-sigma de GOSOF80 vers le filtre RC 3k3/4n7 de la porteuse puis le
-- TDA7267. En mode `esp_sound=true` GOSOF80 est retire et cette broche est
-- simplement mise a '0' -- elle est libre. Ce module la reprend et y joue ce que
-- l'ESP envoie.
--
-- LE FIL. ESP GPIO17 -> FPGA P143, deja cable sur la carte (gottfa-hw/ETAT.md:856,
-- net `ESP32_TX`) et jusqu'ici CONTRAINT NULLE PART dans le .ucf. Aucun ajout
-- materiel : c'est un fil qui existait et ne servait a rien.
--
-- ⚠️ NI FIFO, NI HORLOGE D'ECHANTILLONNAGE, ET C'EST VOULU.
--    Chaque octet recu devient immediatement l'echantillon courant ; le
--    delta-sigma tourne en continu sur la derniere valeur. La frequence
--    d'echantillonnage est donc EXACTEMENT le debit d'octets de l'UART -- fixe par
--    le quartz de l'ESP seul. Il n'y a aucune horloge locale a comparer, donc
--    aucune derive a rattraper, donc aucun controle de flux, aucun FIFO, aucun
--    compteur de tick. C'est ce qui rend le module assez petit pour les ~145 LUT
--    qui restent sur le XC6SLX9 (mesure : le build actuel occupe 97 % des LUT et
--    99 % des slices).
--    A 8N1, debit d'echantillons = BAUD / 10. Pour 22 050 Hz : 220 500 bauds.
--
-- ⚠️ LE RETOUR AU REPOS N'EST PAS UN CONFORT. Tenir le dernier echantillon apres
--    la fin d'une phrase, c'est envoyer une tension CONTINUE dans un ampli de
--    puissance branche sur un haut-parleur de caisse. On revient donc a mi-echelle
--    (0x80 = silence) apres SILENCE_MS sans le moindre octet.
--
-- (C) 2026 Valere Pillet / Pstore. Original implementation.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity audio_uart is
  generic (
    CLK_HZ     : integer := 50000000;
    BAUD       : integer := 220500;   -- 22 050 echantillons/s en 8N1
    SILENCE_MS : integer := 50        -- sans octet au-dela : retour a mi-echelle
  );
  port (
    clk     : in  std_logic;
    reset_n : in  std_logic;
    rx      : in  std_logic;          -- ESP GPIO17 -> P143
    audio_o : out std_logic;          -- vers la broche Sound (P44) -> RC -> TDA7267
    active  : out std_logic           -- '1' tant que des octets arrivent (diagnostic)
  );
end audio_uart;

architecture rtl of audio_uart is
  constant DIV      : integer := CLK_HZ / BAUD;              -- cycles par bit
  constant DEMI     : integer := DIV / 2;
  constant REPOS_N  : integer := (CLK_HZ / 1000) * SILENCE_MS;

  type etat_t is (ATTENTE, DEMARRAGE, BITS, ARRET);
  signal etat   : etat_t := ATTENTE;
  signal cpt    : integer range 0 to DIV := 0;
  signal nbit   : integer range 0 to 7 := 0;
  signal sr     : std_logic_vector(7 downto 0) := (others => '0');
  signal ech    : std_logic_vector(7 downto 0) := x"80";     -- mi-echelle = silence
  signal muet   : integer range 0 to REPOS_N := REPOS_N;
  -- Deux bascules avant tout usage : `rx` vient d'une autre carte, sur un fil qui
  -- n'est pas synchrone de notre horloge. Sans ca, un front qui arrive juste au
  -- mauvais moment fait echantillonner un etat metastable, et l'octet est faux
  -- sans que rien ne le signale.
  signal rx_s   : std_logic_vector(2 downto 0) := (others => '1');
begin

  audio_o_dac : entity work.dac
    generic map (msbi_g => 7)
    port map (clk_i => clk, res_n_i => reset_n, dac_i => ech, dac_o => audio_o);

  active <= '0' when muet = REPOS_N else '1';

  process (clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        etat <= ATTENTE; cpt <= 0; nbit <= 0;
        ech <= x"80"; muet <= REPOS_N; rx_s <= (others => '1');
      else
        rx_s <= rx_s(1 downto 0) & rx;

        -- Retour au silence : un ampli ne doit pas rester sur une tension continue.
        if muet < REPOS_N then muet <= muet + 1; end if;
        if muet = REPOS_N - 1 then ech <= x"80"; end if;

        case etat is
          when ATTENTE =>
            -- front descendant = bit de depart
            if rx_s(2) = '1' and rx_s(1) = '0' then
              cpt <= 0; etat <= DEMARRAGE;
            end if;

          when DEMARRAGE =>
            -- On revient au MILIEU du bit de depart pour verifier qu'il est bien
            -- la : un parasite sur la ligne produirait sinon un octet fantome.
            if cpt = DEMI then
              if rx_s(1) = '0' then cpt <= 0; nbit <= 0; etat <= BITS;
              else                  etat <= ATTENTE;
              end if;
            else
              cpt <= cpt + 1;
            end if;

          when BITS =>
            if cpt = DIV - 1 then
              cpt <= 0;
              sr  <= rx_s(1) & sr(7 downto 1);       -- 8N1 : bit de poids faible d'abord
              if nbit = 7 then etat <= ARRET; else nbit <= nbit + 1; end if;
            else
              cpt <= cpt + 1;
            end if;

          when ARRET =>
            if cpt = DIV - 1 then
              cpt <= 0; etat <= ATTENTE;
              -- On n'accepte l'octet QUE si le bit d'arret est bien a '1'. Un
              -- cadrage perdu produirait sinon des echantillons au hasard, c'est-
              -- a-dire du bruit blanc pleine echelle dans le haut-parleur.
              if rx_s(1) = '1' then
                ech  <= sr;
                muet <= 0;
              end if;
            else
              cpt <= cpt + 1;
            end if;
        end case;
      end if;
    end if;
  end process;

end rtl;
