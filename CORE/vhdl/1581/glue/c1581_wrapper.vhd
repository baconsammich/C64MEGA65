----------------------------------------------------------------------------------
-- Commodore 64 for MEGA65
--
-- Wrapper around the vendored 1541 Ultimate C1581 (CORE/vhdl/1581).
--
-- Ties together three things, all in the core clock domain:
--
--   c1581_drive        Gideon Zweijtzer's VHDL 1581, including its WD177x
--                      floppy controller and its own 6502
--   c1581_disk_server  services the controller's command FIFO, which on the
--                      1541 Ultimate is done by host software
--   c1581_mem_bridge   turns the drive's memory-bus requests into HyperRAM
--                      accesses
--
-- The drive needs memory for two different things, so the window handed to it
-- is split:
--
--   G_MEM_BASE + 0x000000   the drive's own ROM and RAM (g_ram_base below)
--   G_IMG_BASE              the mounted *.d81 image, 819200 bytes
--
-- QNICE loads both over its own path and tells us where the image is; those
-- control signals arrive already synchronised into this clock domain by the
-- caller, since they only change on a mount.
--
-- done by MJoergen and sy2002 in 2023 and licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.io_bus_pkg.all;
use work.mem_bus_pkg.all;

entity c1581_wrapper is
   generic (
      -- Core clock frequency, used to derive the drive's timing ticks
      G_CLK_FREQ_HZ  : natural := 31_527_778;
      -- HyperRAM window for the drive's own ROM/RAM, as a 16-bit word address
      G_MEM_BASE     : std_logic_vector(31 downto 0) := X"0030_0000"
   );
   port (
      clk_i            : in  std_logic;
      rst_i            : in  std_logic;

      -- Mount control, already in this clock domain
      img_base_i       : in  std_logic_vector(25 downto 0);  -- byte address of the *.d81
      img_mounted_i    : in  std_logic;
      img_readonly_i   : in  std_logic;
      drive_addr_i     : in  std_logic_vector( 1 downto 0);

      -- IEC bus, open drain: '0' pulls the line low
      iec_atn_i        : in  std_logic;
      iec_clk_i        : in  std_logic;
      iec_data_i       : in  std_logic;
      iec_srq_i        : in  std_logic;
      iec_atn_o        : out std_logic;
      iec_clk_o        : out std_logic;
      iec_data_o       : out std_logic;
      iec_srq_o        : out std_logic;

      c64_reset_n_i    : in  std_logic;

      -- Status
      act_led_o        : out std_logic;
      busy_o           : out std_logic;
      err_o            : out std_logic;

      -- HyperRAM master, core clock domain
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
end entity c1581_wrapper;

architecture synthesis of c1581_wrapper is

   -- Timing ticks the drive expects. 4 MHz is not an integer divisor of the
   -- core clock, so the nearest division is used: 31.5278/8 = 3.94 MHz, which
   -- is 1.5 % slow. That only affects head-step timing and the index pulse
   -- rate, not data integrity, because sector data is moved by DMA rather than
   -- being clocked off a simulated surface.
   constant C_DIV_4MHZ : natural := 8;
   constant C_DIV_1KHZ : natural := G_CLK_FREQ_HZ / 1_000;

   signal cnt_4mhz    : natural range 0 to C_DIV_4MHZ - 1 := 0;
   signal cnt_1khz    : natural range 0 to C_DIV_1KHZ - 1 := 0;
   signal tick_4mhz   : std_logic := '0';
   signal tick_1khz   : std_logic := '0';

   signal io_req      : t_io_req;
   signal io_resp     : t_io_resp;
   signal mem_req     : t_mem_req_32;
   signal mem_resp    : t_mem_resp_32;

   signal act_led_n   : std_logic;
   signal power_led_n : std_logic;
   signal motor_led_n : std_logic;

   -- Held in reset until an image is mounted. The drive's 6502 fetches
   -- continuously once running, and every fetch is a HyperRAM access shared
   -- with the video scaler, so there is no reason to let it run when there is
   -- no disk. It also means a user who never touches *.d81 cannot be affected
   -- by this at all. The cost is that the drive does not answer on the IEC bus
   -- to report "no disk" before one is inserted.
   signal drive_rst   : std_logic;

begin

   drive_rst <= rst_i or not img_mounted_i;

   ------------------------------------------------------------------------------
   -- Timing ticks
   ------------------------------------------------------------------------------
   p_ticks : process (clk_i)
   begin
      if rising_edge(clk_i) then
         tick_4mhz <= '0';
         tick_1khz <= '0';

         if cnt_4mhz = C_DIV_4MHZ - 1 then
            cnt_4mhz  <= 0;
            tick_4mhz <= '1';
         else
            cnt_4mhz <= cnt_4mhz + 1;
         end if;

         if cnt_1khz = C_DIV_1KHZ - 1 then
            cnt_1khz  <= 0;
            tick_1khz <= '1';
         else
            cnt_1khz <= cnt_1khz + 1;
         end if;

         if rst_i = '1' then
            cnt_4mhz <= 0;
            cnt_1khz <= 0;
         end if;
      end if;
   end process p_ticks;

   ------------------------------------------------------------------------------
   -- The drive itself
   ------------------------------------------------------------------------------
   i_c1581_drive : entity work.c1581_drive
      generic map (
         g_big_endian => false,
         g_audio      => false,            -- no drive sound for now
         g_ram_base   => X"0000000"
      )
      port map (
         clock        => clk_i,
         reset        => drive_rst,
         drive_stop   => '0',
         tick_4MHz    => tick_4mhz,
         tick_1KHz    => tick_1khz,
         io_req       => io_req,
         io_resp      => io_resp,
         io_irq       => open,
         mem_req      => mem_req,
         mem_resp     => mem_resp,
         atn_o        => iec_atn_o,
         atn_i        => iec_atn_i,
         clk_o        => iec_clk_o,
         clk_i        => iec_clk_i,
         data_o       => iec_data_o,
         data_i       => iec_data_i,
         fast_clk_o   => iec_srq_o,
         fast_clk_i   => iec_srq_i,
         iec_reset_n  => c64_reset_n_i,
         c64_reset_n  => c64_reset_n_i,
         act_led_n    => act_led_n,
         power_led_n  => power_led_n,
         motor_led_n  => motor_led_n,
         audio_sample => open
      ); -- i_c1581_drive

   act_led_o <= not act_led_n;

   ------------------------------------------------------------------------------
   -- Host-side command servicing
   ------------------------------------------------------------------------------
   i_disk_server : entity work.c1581_disk_server
      port map (
         clk_i          => clk_i,
         rst_i          => drive_rst,
         io_req_o       => io_req,
         io_resp_i      => io_resp,
         img_base_i     => img_base_i,
         img_mounted_i  => img_mounted_i,
         img_readonly_i => img_readonly_i,
         drive_addr_i   => drive_addr_i,
         busy_o         => busy_o,
         err_o          => err_o
      ); -- i_disk_server

   ------------------------------------------------------------------------------
   -- Memory bus to HyperRAM
   ------------------------------------------------------------------------------
   i_mem_bridge : entity work.c1581_mem_bridge
      generic map (
         G_BASE_ADDRESS => G_MEM_BASE
      )
      port map (
         clk_i               => clk_i,
         rst_i               => drive_rst,
         mem_req_i           => mem_req,
         mem_resp_o          => mem_resp,
         avm_write_o         => avm_write_o,
         avm_read_o          => avm_read_o,
         avm_address_o       => avm_address_o,
         avm_writedata_o     => avm_writedata_o,
         avm_byteenable_o    => avm_byteenable_o,
         avm_burstcount_o    => avm_burstcount_o,
         avm_readdata_i      => avm_readdata_i,
         avm_readdatavalid_i => avm_readdatavalid_i,
         avm_waitrequest_i   => avm_waitrequest_i
      ); -- i_mem_bridge

end architecture synthesis;
