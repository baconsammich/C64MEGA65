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
-- the address as a byte address. So every request that arrives here is one byte,
-- which maps onto the 16-bit HyperRAM port the same way reu_mapper.vhd does it:
-- word address = base + addr(25 downto 1), with byteenable selecting the half.
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
      -- within the HyperRAM, i.e. the same convention as reu_mapper's
      -- G_BASE_ADDRESS.
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
   signal req_lowbyte  : std_logic                     := '0';

   signal avm_write_r  : std_logic := '0';
   signal avm_read_r   : std_logic := '0';
   signal avm_addr_r   : std_logic_vector(31 downto 0) := (others => '0');
   signal avm_wdata_r  : std_logic_vector(15 downto 0) := (others => '0');
   signal avm_be_r     : std_logic_vector( 1 downto 0) := (others => '0');

   signal resp         : t_mem_resp_32 := c_mem_resp_32_init;

begin

   ------------------------------------------------------------------------------
   -- Address translation: byte address -> 16-bit word address, offset by the
   -- window base and masked to the 8 MB (4 M word) HyperRAM, as reu_mapper does.
   ------------------------------------------------------------------------------
   avm_address_o    <= avm_addr_r;
   avm_writedata_o  <= avm_wdata_r;
   avm_byteenable_o <= avm_be_r;
   avm_burstcount_o <= X"01";
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
                  -- 25-bit word address, zero-extended to the 32-bit avm address
                  v_word_addr := "0000000" & std_logic_vector(mem_req_i.address(25 downto 1));
                  avm_addr_r  <= std_logic_vector(unsigned(v_word_addr) + unsigned(G_BASE_ADDRESS))
                                 and X"003FFFFF";

                  -- route_through always presents the byte in the low lane
                  avm_wdata_r <= mem_req_i.data(7 downto 0) & mem_req_i.data(7 downto 0);
                  if mem_req_i.address(0) = '0' then
                     avm_be_r    <= "01";
                     req_lowbyte <= '1';
                  else
                     avm_be_r    <= "10";
                     req_lowbyte <= '0';
                  end if;

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
                  if req_lowbyte = '1' then
                     resp.data <= X"000000" & avm_readdata_i( 7 downto 0);
                  else
                     resp.data <= X"000000" & avm_readdata_i(15 downto 8);
                  end if;
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
