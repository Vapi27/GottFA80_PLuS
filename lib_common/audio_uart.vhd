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
--    A 8N1 un octet coute 10 bits, et un echantillon fait DEUX octets (14 bits) :
--    debit d'echantillons = BAUD / 20. Pour 22 050 Hz : 441 000 bauds.
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
    BAUD       : integer := 441000;   -- 22 050 ech/s x 2 octets, en 8N1
    SILENCE_MS : integer := 50        -- sans octet au-dela : retour a mi-echelle
  );
  port (
    clk     : in  std_logic;
    reset_n : in  std_logic;
    rx      : in  std_logic;          -- ESP GPIO17 -> P143
    audio_o : out std_logic;          -- vers la broche Sound (P44) -> RC -> TDA7267
    -- Le MEME echantillon, AVANT le modulateur. En mode hybride il faut le SOMMER
    -- avec celui de GOSOF80 avant un unique modulateur : la carte n'a qu'un seul
    -- etage audio, donc deux modulateurs ne peuvent pas partager la broche.
    pcm_o   : out std_logic_vector(13 downto 0);
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
  -- ECHANTILLON 14 BITS, transmis en DEUX octets auto-cadres :
  --     octet A : 0 & ech(13 downto 7)      (bit de poids fort = marqueur)
  --     octet B : 1 & ech(6 downto 0)
  -- Le marqueur suffit a savoir qui est qui, meme apres un octet perdu : aucun
  -- protocole de trame, aucune resynchronisation a prevoir.
  -- POURQUOI 14 BITS. En 8 bits le plancher de bruit est a ~50 dB, et le dither
  -- necessaire pour eviter la distorsion s'entend alors comme un SOUFFLE CONSTANT
  -- (rapporte a l'ecoute le 2026-09-05). A 14 bits il tombe vers 86 dB, sous le
  -- seuil d'audibilite de cette chaine. Le modulateur, lui, n'a jamais ete le
  -- facteur limitant : a 50 MHz pour 22 050 Hz il suroechantillonne 2268 fois.
  constant MI_ECHELLE : std_logic_vector(13 downto 0) := "10" & x"000";  -- 0x2000
  signal ech    : std_logic_vector(13 downto 0) := MI_ECHELLE;
  signal haut   : std_logic_vector(6 downto 0) := (others => '0');
  signal a_haut : std_logic := '0';           -- l'octet de poids fort est en attente
  signal muet   : integer range 0 to REPOS_N := REPOS_N;
  -- Deux bascules avant tout usage : `rx` vient d'une autre carte, sur un fil qui
  -- n'est pas synchrone de notre horloge. Sans ca, un front qui arrive juste au
  -- mauvais moment fait echantillonner un etat metastable, et l'octet est faux
  -- sans que rien ne le signale.
  signal rx_s   : std_logic_vector(2 downto 0) := (others => '1');
begin

  pcm_o <= ech;

  audio_o_dac : entity work.dac
    generic map (msbi_g => 13)
    port map (clk_i => clk, res_n_i => reset_n, dac_i => ech, dac_o => audio_o);

  active <= '0' when muet = REPOS_N else '1';

  process (clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        etat <= ATTENTE; cpt <= 0; nbit <= 0;
        ech <= MI_ECHELLE; muet <= REPOS_N; rx_s <= (others => '1'); a_haut <= '0';
      else
        rx_s <= rx_s(1 downto 0) & rx;

        -- Retour au silence : un ampli ne doit pas rester sur une tension continue.
        if muet < REPOS_N then muet <= muet + 1; end if;
        if muet = REPOS_N - 1 then ech <= MI_ECHELLE; a_haut <= '0'; end if;

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
                muet <= 0;
                if sr(7) = '0' then
                  haut   <= sr(6 downto 0);      -- octet de poids fort, on attend l'autre
                  a_haut <= '1';
                elsif a_haut = '1' then
                  ech    <= haut & sr(6 downto 0);
                  a_haut <= '0';
                end if;
                -- Un octet de poids faible sans son poids fort est IGNORE : c'est
                -- ainsi que le cadrage se rattrape tout seul apres une perte.
              end if;
            else
              cpt <= cpt + 1;
            end if;
        end case;
      end if;
    end if;
  end process;

end rtl;
