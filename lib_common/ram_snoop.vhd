-- ram_snoop.vhd : shadow copy of the Gottlieb System 80 RIOT scratch RAM +
-- the 5101 CMOS RAM, with a periodic snapshot streamer for the ESP companion
-- (GottFA80_PLuS).
--
-- WHY: the ball-in-play counter address is unknown ($0072 from PinMAME was
-- DISPROVEN on a real Volcano). Instead of guessing one address we mirror every
-- CPU write to the game RAMs into a shadow block RAM and stream the whole image
-- to the ESP about once a second, so the host can correlate the full RAM against
-- observed gameplay events.  The RIOT scratch RAM alone (384 bytes) showed NO
-- byte behaving like a ball counter, hence the 5101 at $1800-$1FFF -- the CMOS
-- chip that holds the persistent game state -- is now mirrored too.
--
-- ADDRESS MAPPING (verified against the SYS80 chip-select decode):
--   U4_RAM_cs <= cpu_addr(13 downto 7) = "0000000"  -> $0000-$007F
--   U5_RAM_cs <= cpu_addr(13 downto 7) = "0000001"  -> $0080-$00FF
--   U6_RAM_cs <= cpu_addr(13 downto 7) = "0000010"  -> $0100-$017F
--   r5101_cs  <= cpu_addr(13 downto 11) = "011"     -> $1800-$1FFF (Z5, 256 x 4bit,
--                addressed with cpu_addr(7 downto 0), data = cpu_dout(3 downto 0))
--
-- SHADOW LAYOUT (1024 x 8, one M9K; chosen so that NO adder is needed on the
-- write path -- the shadow address is pure bit concatenation):
--   RIOT write -> shadow addr =  '0' & cpu_addr(8 downto 0)  =>   0..511
--                 (the three RIOT decodes pin a(8) and a(7), so cpu_addr(8..0)
--                  is already the wire index: U4 0..127, U5 128..255, U6 256..383;
--                  384..511 exist but are never written and never scanned)
--   5101 write -> shadow addr = "10" & cpu_addr(7 downto 0)  => 512..767
--                 wr_data = "0000" & cpu_dout(3 downto 0)  (low nibble only)
--   768..1023 unused.
-- The two write sources can never collide: r5101_cs requires cpu_addr(13..11)="011"
-- while every RIOT decode requires cpu_addr(13..11)="000", so the selects are
-- mutually exclusive by construction and the SYS80-side mux is safe.
--
-- WIRE FORMAT emitted through sound_link's injection port (lowest priority, so
-- gameplay tokens are never starved):
--   1 marker byte 0xBF, then 640 values x 2 bytes each:
--       0xC0 | (value >> 4)     high nibble
--       0xD0 | (value and 0x0F) low nibble
--   => 1281 bytes/frame, ~111 ms at 115200 baud, ~11% duty at 1 Hz.
--   index   0..383 = RIOT RAM,  CPU $0000..$017F        (shadow    0..383)
--   index 384..639 = 5101 nibble n, CPU $1800+n, value 0..15, high nibble 0
--                                                        (shadow  512..767)
--   The scanner therefore reads shadow[i] for i<384 and shadow[i+128] for
--   i>=384 (384+128 = 512): one 10-bit add in a path that changes once per
--   transmitted byte (~11 kHz), i.e. utterly non-critical.
-- Payload bytes stay inside 0xC0..0xDF, which collides with no existing token
-- range (0x40..0x7F game, 0x80..0x9F sound, 0xA0..0xAF ball, 0xF0..0xF3 state),
-- so a higher-priority token may interleave harmlessly and a lost byte
-- self-heals at the next 0xBF marker.
--
-- Part of GottFA80 (GPL-3.0).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ram_snoop is
  generic (
    clk_hz    : integer := 50000000;  -- clk frequency
    period_ms : integer := 1000;      -- snapshot period (~1 s)
    n_bytes   : integer := 640        -- values/frame (3 x 128 RIOT + 256 x 5101)
  );
  port (
    clk       : in  std_logic;
    rst       : in  std_logic;                       -- active high
    -- CPU write snoop (mirrors the RIOT_RAM and 5101 write ports; the caller
    -- muxes the two sources -- they are mutually exclusive by address decode)
    wr_addr   : in  std_logic_vector(9 downto 0);    -- shadow index, see header
    wr_data   : in  std_logic_vector(7 downto 0);    -- cpu_dout (5101: low nibble)
    wr_en     : in  std_logic;                       -- (U4|U5|U6)_RAM_cs or r5101_cs, and not cpu_wr_n
    -- byte injection into sound_link
    snap_data : out std_logic_vector(7 downto 0);
    snap_req  : out std_logic;
    snap_ack  : in  std_logic
  );
end ram_snoop;

architecture rtl of ram_snoop is

  constant TICK_MAX : integer := (clk_hz / 1000) * period_ms - 1;

  -- 1024 x 8 shadow RAM. Written from the CPU side, read by the scanner:
  -- classic simple-dual-port template -> Quartus infers one M9K block
  -- (8192 memory bits = exactly one M9K), NOT logic elements.
  type ram_t is array (0 to 1023) of std_logic_vector(7 downto 0);
  signal shadow : ram_t;
  signal ram_q  : std_logic_vector(7 downto 0) := (others => '0');
  signal rd_addr: std_logic_vector(9 downto 0) := (others => '0');

  signal tick_cnt : integer range 0 to TICK_MAX := 0;
  signal tick     : std_logic := '0';

  -- scanner FSM: S_IDLE waits for the 1 Hz tick; S_RD covers the registered
  -- RAM read latency; S_SEND presents a byte; S_ACK/S_REL do the full
  -- request/acknowledge handshake (wait for ack high, then for ack low) so a
  -- single multi-cycle ack pulse can never be mistaken for two accepts.
  type t_st is (S_IDLE, S_RD, S_SEND, S_ACK, S_REL);
  signal st  : t_st := S_IDLE;

  constant PH_MARK : integer := 0;
  constant PH_HI   : integer := 1;
  constant PH_LO   : integer := 2;
  signal ph  : integer range 0 to 2 := PH_MARK;

  -- frame index 0..n_bytes-1 (10 bits now that n_bytes = 640)
  signal idx : unsigned(9 downto 0) := (others => '0');
  signal req : std_logic := '0';
  signal dat : std_logic_vector(7 downto 0) := (others => '0');

  -- first frame index that belongs to the 5101 block, and the constant gap
  -- between the frame index and the shadow address for that block
  -- (shadow 512 - index 384 = 128).
  constant IDX_5101 : integer := 384;
  constant OFF_5101 : integer := 128;

begin

  snap_req  <= req;
  snap_data <= dat;

  -- Frame index -> shadow address. Purely combinational so that the value read
  -- during S_RD is already the one for the freshly incremented idx.
  rd_addr <= std_logic_vector(idx + to_unsigned(OFF_5101, idx'length))
               when idx >= to_unsigned(IDX_5101, idx'length)
               else std_logic_vector(idx);

  ---------------------------------------------------------------------------
  -- Shadow RAM: mirror every CPU write, registered read for the scanner.
  -- No reset and no read-enable -> stays inferrable as block RAM.
  ---------------------------------------------------------------------------
  SHADOW_RAM: process(clk) begin
    if rising_edge(clk) then
      if wr_en = '1' then
        shadow(to_integer(unsigned(wr_addr))) <= wr_data;
      end if;
      ram_q <= shadow(to_integer(unsigned(rd_addr)));
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- 1 Hz frame trigger
  ---------------------------------------------------------------------------
  TICKGEN: process(clk) begin
    if rising_edge(clk) then
      if rst = '1' then
        tick_cnt <= 0; tick <= '0';
      elsif tick_cnt = TICK_MAX then
        tick_cnt <= 0; tick <= '1';
      else
        tick_cnt <= tick_cnt + 1; tick <= '0';
      end if;
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- Frame scanner / byte sequencer
  ---------------------------------------------------------------------------
  SCANNER: process(clk) begin
    if rising_edge(clk) then
      if rst = '1' then
        st <= S_IDLE; ph <= PH_MARK; idx <= (others => '0');
        req <= '0'; dat <= (others => '0');
      else
        case st is

          when S_IDLE =>
            req <= '0';
            if tick = '1' then
              idx <= (others => '0');
              ph  <= PH_MARK;
              st  <= S_SEND;          -- marker needs no RAM read
            end if;

          when S_RD =>
            st <= S_SEND;             -- one clk for the registered RAM read

          when S_SEND =>
            if ph = PH_MARK then
              dat <= x"BF";
            elsif ph = PH_HI then
              dat <= x"C" & ram_q(7 downto 4);
            else
              dat <= x"D" & ram_q(3 downto 0);
            end if;
            req <= '1';
            st  <= S_ACK;

          when S_ACK =>
            if snap_ack = '1' then
              req <= '0';
              st  <= S_REL;
            end if;

          when S_REL =>
            if snap_ack = '0' then    -- ack released: byte is fully consumed
              if ph = PH_MARK then
                ph <= PH_HI;
                st <= S_RD;           -- fetch value at index 0
              elsif ph = PH_HI then
                ph <= PH_LO;
                st <= S_SEND;         -- low nibble of the same ram_q
              else
                if idx = to_unsigned(n_bytes - 1, idx'length) then
                  st <= S_IDLE;       -- frame complete
                else
                  idx <= idx + 1;
                  ph  <= PH_HI;
                  st  <= S_RD;
                end if;
              end if;
            end if;

        end case;
      end if;
    end if;
  end process;

end rtl;
