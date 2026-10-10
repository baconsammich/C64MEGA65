----------------------------------------------------------------------------------
-- Commodore 64 for MEGA65
--
-- Bridge between the 1541 Ultimate memory bus (t_mem_req_32 / t_mem_resp_32)
-- and the MEGA65's Avalon-style HyperRAM interface.
--
-- The vendored C1581 (CORE/vhdl/1581) is a master on Gideon Zweijtzer's memory
-- bus: it fetches its own ROM and RAM, and DMAs disk sectors, rather than being
-- handed blocks by a host in another clock domain. That is what makes it usable
-- here; see CORE/vhdl/1581/README.md.
--
-- The drive converts its internal 8-bit bus with mem_to_mem32(route_through),
-- which widens a single-byte access to 32 bits with byte_en = "0001" and leaves
-- the address as a byte address. So every request that arrives here is one byte.
--
-- IMPORTANT - one byte per 16-bit HyperRAM word, not two
-- ------------------------------------------------------
-- The obvious mapping is the one reu_mapper.vhd uses: word = base + addr/2,
-- with byteenable picking the half, so two bytes share a word. That is wrong
-- here, and it is wrong because of how the *data gets into* HyperRAM.
--
-- The drive's ROM and its disk image are put there by the Shell, through the
-- C_CRTROMTYPE_HYPERRAM entries in globals.vhd. That loader (_CRMA_4 in
-- M2M/rom/crts-and-roms.asm, and _LI_FREAD_CONT in M2M/rom/shell.asm) writes
-- one file byte per QNICE word:
--
--     MOVE R9, @R5++          -- R9 is a single byte from f32_fread
--
-- and a QNICE word address on the HyperRAM device is passed straight through as
-- the HyperRAM *word* address (qnice_ramrom_address in M2M/vhdl/qnice_wrapper.vhd
-- feeding m_avm_address_o <= s_qnice_address_i in qnice2hyperram.vhd), with
-- byteenable hard-wired to "11". So file byte n lands in the low half of
-- HyperRAM word n, and the high half is zero. A 4k window therefore holds 4096
-- bytes of payload, not 8192.
--
-- Reading it back packed would interleave every other byte with a zero, which
-- is exactly the kind of ROM corruption that sends the drive's 6502 off into
-- the weeds. So the mapping is 1:1 - word address = base + byte address - and
-- only the low byte of each word is used.
--
-- Nothing upstream used C_CRTROMTYPE_HYPERRAM (V5.2 has only
-- C_CRTROMTYPE_DEVICE entries), which is why this convention is not documented
-- anywhere and why that loader still had an unrelated register-mix-up bug in
-- it. Treat the byte-per-word layout as the contract.
--
-- Everything runs in the core clock domain, so there is no clock-domain
-- crossing anywhere in this path.
--
-- done by MJoergen and sy2002 in 2023 and licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.mem_bus_pkg.all;

entity c1581_mem_bridge is
   generic (
      -- Base address of the drive's memory window, as a 16-bit word address
      -- within the HyperRAM. Because of the byte-per-word layout above, the
      -- drive's byte address is added to this directly, so this window has to
      -- be as many words long as the drive has bytes of address space.
      G_BASE_ADDRESS : std_logic_vector(31 downto 0)
   );
   port (
      clk_i               : in  std_logic;
      rst_i               : in  std_logic;

      -- Slave port: the drive is the master here
      mem_req_i           : in  t_mem_req_32;
      mem_resp_o          : out t_mem_resp_32;

      -- Master port towards HyperRAM
      avm_write_o         : out std_logic;
      avm_read_o          : out std_logic;
      avm_address_o       : out std_logic_vector(31 downto 0);
      avm_writedata_o     : out std_logic_vector(15 downto 0);
      avm_byteenable_o    : out std_logic_vector( 1 downto 0);
      avm_burstcount_o    : out std_logic_vector( 7 downto 0);
      avm_readdata_i      : in  std_logic_vector(15 downto 0);
      avm_readdatavalid_i : in  std_logic;
      avm_waitrequest_i   : in  std_logic
   );
end entity c1581_mem_bridge;

architecture synthesis of c1581_mem_bridge is

   type t_state is (IDLE_ST, WAIT_ACCEPT_ST, WAIT_READDATA_ST);
   signal state        : t_state := IDLE_ST;

   -- Latched request, so the drive may drop mem_req_i as soon as it sees rack
   signal req_tag      : std_logic_vector( 7 downto 0) := (others => '0');
   signal req_rwn      : std_logic                     := '1';

   signal avm_write_r  : std_logic := '0';
   signal avm_read_r   : std_logic := '0';
   signal avm_addr_r   : std_logic_vector(31 downto 0) := (others => '0');
   signal avm_wdata_r  : std_logic_vector(15 downto 0) := (others => '0');

   signal resp         : t_mem_resp_32 := c_mem_resp_32_init;

begin

   ------------------------------------------------------------------------------
   -- Address translation: byte address -> word address 1:1, offset by the
   -- window base and masked to the 8 MB (4 M word) HyperRAM. See the note at
   -- the top for why this is not a shift.
   ------------------------------------------------------------------------------
   avm_address_o    <= avm_addr_r;
   avm_writedata_o  <= avm_wdata_r;
   avm_burstcount_o <= X"01";
   -- Only ever the low byte: that is where the Shell's loader puts the data.
   avm_byteenable_o <= "01";
   avm_write_o      <= avm_write_r;
   avm_read_o       <= avm_read_r;

   mem_resp_o       <= resp;

   p_fsm : process (clk_i)
      variable v_word_addr : std_logic_vector(31 downto 0);
   begin
      if rising_edge(clk_i) then

         -- rack and dack are single-cycle strobes
         resp.rack     <= '0';
         resp.rack_tag <= (others => '0');
         resp.dack_tag <= (others => '0');

         case state is

            when IDLE_ST =>
               if mem_req_i.request = '1' then
                  -- byte address -> word address, 1:1, zero-extended to 32 bits
                  v_word_addr := "000000" & std_logic_vector(mem_req_i.address(25 downto 0));
                  avm_addr_r  <= std_logic_vector(unsigned(v_word_addr) + unsigned(G_BASE_ADDRESS))
                                 and X"003FFFFF";

                  -- route_through always presents the byte in the low lane, and
                  -- the low lane is also where it belongs in HyperRAM
                  avm_wdata_r <= X"00" & mem_req_i.data(7 downto 0);

                  req_tag     <= mem_req_i.tag;
                  req_rwn     <= mem_req_i.read_writen;
                  avm_read_r  <=     mem_req_i.read_writen;
                  avm_write_r <= not mem_req_i.read_writen;
                  state       <= WAIT_ACCEPT_ST;
               end if;

            when WAIT_ACCEPT_ST =>
               -- HyperRAM has taken the request once waitrequest drops
               if avm_waitrequest_i = '0' then
                  avm_read_r    <= '0';
                  avm_write_r   <= '0';
                  resp.rack     <= '1';
                  resp.rack_tag <= req_tag;
                  if req_rwn = '1' then
                     state <= WAIT_READDATA_ST;
                  else
                     -- writes complete on acceptance; acknowledge the data too,
                     -- which is what the drive's arbiter waits for
                     resp.dack_tag <= req_tag;
                     state         <= IDLE_ST;
                  end if;
               end if;

            when WAIT_READDATA_ST =>
               if avm_readdatavalid_i = '1' then
                  resp.data <= X"000000" & avm_readdata_i(7 downto 0);
                  resp.dack_tag <= req_tag;
                  state         <= IDLE_ST;
               end if;

         end case;

         if rst_i = '1' then
            state       <= IDLE_ST;
            avm_read_r  <= '0';
            avm_write_r <= '0';
            resp        <= c_mem_resp_32_init;
         end if;
      end if;
   end process p_fsm;

end architecture synthesis;
