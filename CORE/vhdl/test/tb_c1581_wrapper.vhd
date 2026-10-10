----------------------------------------------------------------------------------
-- Testbench for c1581_wrapper.
--
-- Checks the two properties of the C1581 that cannot be checked by inspection
-- and that nothing else in the tree covers:
--
--   1. While no disk image is mounted, the drive must make NO HyperRAM
--      requests at all. Its 6502 fetches every instruction out of HyperRAM,
--      shared with the video scaler, so a drive that runs when it should not
--      starves the scaler - which presents as the whole machine freezing
--      rather than as anything disk-related.
--
--   2. Once mounted, every address the drive emits has to land inside the
--      window it was given. The drive's own 64 KB maps to
--      G_MEM_BASE .. +0x7FFF, and its first fetch after reset is the 6502
--      reset vector at $FFFC, which has to appear at word G_MEM_BASE+0x7FFE.
--      That is the arithmetic that decides whether the drive finds its DOS at
--      all; getting it wrong let the CPU run away in an earlier build.
--
-- done in 2026, licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library c1581_lib;

entity tb_c1581_wrapper is
end entity tb_c1581_wrapper;

architecture sim of tb_c1581_wrapper is

   constant C_CLK_PERIOD : time := 31.7 ns;              -- 31.528 MHz
   constant C_MEM_BASE   : std_logic_vector(31 downto 0) := X"0032_0000";
   constant C_IMG_BASE   : std_logic_vector(25 downto 0) :=
                           std_logic_vector(to_unsigned(16#010000#, 26));

   -- The drive's own address space, as word addresses on the avm bus. One byte
   -- per word (see c1581_mem_bridge.vhd), so its 64 KB of address space is
   -- 65536 words, not 32768.
   constant C_DRIVE_LO   : unsigned(31 downto 0) := unsigned(C_MEM_BASE);
   constant C_DRIVE_HI   : unsigned(31 downto 0) := unsigned(C_MEM_BASE) + 16#10000#;
   -- where the 6502 reset vector ($FFFC) has to show up
   constant C_RESET_VEC  : unsigned(31 downto 0) := unsigned(C_MEM_BASE) + 16#FFFC#;

   signal clk            : std_logic := '0';
   signal rst            : std_logic := '1';
   signal img_mounted    : std_logic := '0';
   signal running        : boolean   := true;

   signal avm_write      : std_logic;
   signal avm_read       : std_logic;
   signal avm_address    : std_logic_vector(31 downto 0);
   signal avm_writedata  : std_logic_vector(15 downto 0);
   signal avm_byteenable : std_logic_vector( 1 downto 0);
   signal avm_burstcount : std_logic_vector( 7 downto 0);
   signal avm_readdata   : std_logic_vector(15 downto 0) := (others => '0');
   signal avm_rdvalid    : std_logic := '0';
   signal avm_waitreq    : std_logic := '0';

   -- observations
   signal n_access       : natural := 0;
   signal first_addr     : unsigned(31 downto 0) := (others => '0');
   signal got_first      : boolean := false;
   signal out_of_window  : natural := 0;
   signal worst_addr     : unsigned(31 downto 0) := (others => '0');

begin

   p_clk : process
   begin
      while running loop
         clk <= '0'; wait for C_CLK_PERIOD / 2;
         clk <= '1'; wait for C_CLK_PERIOD / 2;
      end loop;
      wait;
   end process p_clk;

   i_dut : entity c1581_lib.c1581_wrapper
      generic map (
         G_CLK_FREQ_HZ => 31_527_778,
         G_MEM_BASE    => C_MEM_BASE
      )
      port map (
         clk_i               => clk,
         rst_i               => rst,
         img_base_i          => C_IMG_BASE,
         img_mounted_i       => img_mounted,
         img_readonly_i      => '0',
         drive_addr_i        => "01",
         iec_atn_i           => '1',
         iec_clk_i           => '1',
         iec_data_i          => '1',
         iec_srq_i           => '1',
         iec_atn_o           => open,
         iec_clk_o           => open,
         iec_data_o          => open,
         iec_srq_o           => open,
         c64_reset_n_i       => '1',
         act_led_o           => open,
         busy_o              => open,
         err_o               => open,
         avm_write_o         => avm_write,
         avm_read_o          => avm_read,
         avm_address_o       => avm_address,
         avm_writedata_o     => avm_writedata,
         avm_byteenable_o    => avm_byteenable,
         avm_burstcount_o    => avm_burstcount,
         avm_readdata_i      => avm_readdata,
         avm_readdatavalid_i => avm_rdvalid,
         avm_waitrequest_i   => avm_waitreq
      );

   ------------------------------------------------------------------------------
   -- A minimal HyperRAM: always ready, answers a read two cycles later with
   -- 0x00EA - a 6502 NOP in the low byte, which is where the Shell's loader
   -- puts data and where the bridge reads it from - so the CPU keeps fetching
   -- instead of stopping. The data barely matters here; the addresses do.
   ------------------------------------------------------------------------------
   p_hyperram : process (clk)
      variable v_pipe : std_logic_vector(1 downto 0) := "00";
   begin
      if rising_edge(clk) then
         avm_rdvalid  <= v_pipe(1);
         avm_readdata <= X"00EA";
         v_pipe       := v_pipe(0) & avm_read;
      end if;
   end process p_hyperram;

   ------------------------------------------------------------------------------
   -- Watch the bus
   ------------------------------------------------------------------------------
   p_watch : process (clk)
   begin
      if rising_edge(clk) then
         if rst = '0' and (avm_read = '1' or avm_write = '1') then
            n_access <= n_access + 1;
            if not got_first then
               first_addr <= unsigned(avm_address);
               got_first  <= true;
            end if;
            if unsigned(avm_address) < C_DRIVE_LO
               or unsigned(avm_address) >= C_DRIVE_HI then
               out_of_window <= out_of_window + 1;
               worst_addr    <= unsigned(avm_address);
            end if;
         end if;
      end if;
   end process p_watch;

   ------------------------------------------------------------------------------
   -- Stimulus
   ------------------------------------------------------------------------------
   p_test : process
      variable v_bad : natural := 0;
   begin
      report "== c1581_wrapper ==";

      rst <= '1';
      wait for 20 * C_CLK_PERIOD;
      rst <= '0';

      ------------------------------------------------------------------------
      -- 1. unmounted: the drive must be completely quiet
      ------------------------------------------------------------------------
      img_mounted <= '0';
      wait for 20000 * C_CLK_PERIOD;        -- ~634 us, far longer than bring-up

      report "unmounted: " & integer'image(n_access) & " HyperRAM access(es)";
      if n_access /= 0 then
         report "FAIL: the drive accessed HyperRAM with no disk mounted - its "
                & "6502 is running and will starve the video scaler"
                severity error;
         v_bad := v_bad + 1;
      end if;

      ------------------------------------------------------------------------
      -- 2. mounted: it must start fetching, from inside its own window
      ------------------------------------------------------------------------
      img_mounted <= '1';
      wait for 60000 * C_CLK_PERIOD;        -- ~1.9 ms

      report "mounted: " & integer'image(n_access) & " HyperRAM access(es)";
      if n_access = 0 then
         report "FAIL: the drive made no HyperRAM access after mounting - it is "
                & "not fetching its DOS" severity error;
         v_bad := v_bad + 1;
      end if;

      if got_first then
         report "first access at word 0x"
                & to_hstring(std_logic_vector(first_addr))
                & ", 6502 reset vector expected at 0x"
                & to_hstring(std_logic_vector(C_RESET_VEC));
         if first_addr /= C_RESET_VEC then
            report "FAIL: the drive's first fetch is not the 6502 reset vector "
                   & "- the DOS ROM window does not line up with the CPU map"
                   severity error;
            v_bad := v_bad + 1;
         end if;
      end if;

      if out_of_window /= 0 then
         report "FAIL: " & integer'image(out_of_window) & " access(es) outside "
                & "the drive's window, e.g. 0x"
                & to_hstring(std_logic_vector(worst_addr))
                severity error;
         v_bad := v_bad + 1;
      else
         report "all accesses inside the drive window 0x"
                & to_hstring(std_logic_vector(C_DRIVE_LO)) & "..0x"
                & to_hstring(std_logic_vector(C_DRIVE_HI - 1));
      end if;

      if v_bad = 0 then
         report "RESULT: c1581_wrapper behaves as expected";
      else
         report "RESULT: " & integer'image(v_bad) & " failure(s)" severity failure;
      end if;

      running <= false;
      wait;
   end process p_test;

end architecture sim;
