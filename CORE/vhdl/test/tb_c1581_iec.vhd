----------------------------------------------------------------------------------
-- Talk to the C1581 over a simulated IEC bus, the way a C64 does.
--
-- tb_c1581_wrapper checks addressing and that the drive acknowledges ATN. That
-- is not enough: a drive can answer ATN and still never return a byte, which is
-- exactly what "SEARCHING FOR $" then a hung C64 looks like. This testbench
-- goes the whole way, using Gideon's own IEC bus-functional model as the
-- controller:
--
--   1. read the drive's error channel (device 9, channel 15). That needs no
--      disk access at all, so it separates "the drive does not talk" from "the
--      drive cannot read the disk".
--   2. open "$" on channel 0 and read it back - a real directory load, which
--      exercises seek, read sector and the HyperRAM DMA.
--
-- Needs a real 1581 DOS dump and a *.d81, which are copyrighted and not in this
-- repository, so it is driven by generics and skipped when they are absent.
--
-- done in 2026, licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library c1581_lib;
use c1581_lib.iec_bus_bfm_pkg.all;

entity tb_c1581_iec is
   generic (
      G_ROM_FILE : string  := "";
      G_D81_FILE : string  := "";
      -- How long to let the DOS settle before talking to it, in milliseconds.
      G_BOOT_MS  : natural := 60;
      -- Text expected somewhere in the directory, normally the disk name.
      G_EXPECT   : string  := ""
   );
end entity tb_c1581_iec;

architecture sim of tb_c1581_iec is

   constant C_CLK_PERIOD : time := 31.7 ns;              -- 31.528 MHz
   constant C_MEM_BASE   : std_logic_vector(31 downto 0) := X"0032_0000";
   constant C_IMG_BASE   : std_logic_vector(25 downto 0) :=
                           std_logic_vector(to_unsigned(16#010000#, 26));

   signal clk            : std_logic := '0';
   signal rst            : std_logic := '1';
   signal img_mounted    : std_logic := '0';
   signal running        : boolean   := true;

   -- The bus itself: open collector, so every driver contributes '0' or 'Z'
   -- and a weak 'H' stands in for the pull-up.
   signal iec_atn        : std_logic;
   signal iec_clk        : std_logic;
   signal iec_data       : std_logic;
   signal iec_srq        : std_logic;

   signal drv_atn_o      : std_logic;
   signal drv_clk_o      : std_logic;
   signal drv_data_o     : std_logic;
   signal drv_srq_o      : std_logic;

   signal avm_write      : std_logic;
   signal avm_read       : std_logic;
   signal avm_address    : std_logic_vector(31 downto 0);
   signal avm_writedata  : std_logic_vector(15 downto 0);
   signal avm_byteenable : std_logic_vector( 1 downto 0);
   signal avm_burstcount : std_logic_vector( 7 downto 0);
   signal avm_readdata   : std_logic_vector(15 downto 0) := (others => '0');
   signal avm_rdvalid    : std_logic := '0';
   signal avm_waitreq    : std_logic := '0';

   signal n_img_access   : natural := 0;

begin

   p_clk : process
   begin
      while running loop
         clk <= '0'; wait for C_CLK_PERIOD / 2;
         clk <= '1'; wait for C_CLK_PERIOD / 2;
      end loop;
      wait;
   end process p_clk;

   -- pull-ups
   iec_atn  <= 'H';
   iec_clk  <= 'H';
   iec_data <= 'H';
   iec_srq  <= 'H';

   -- the drive, open drain
   iec_atn  <= '0' when drv_atn_o  = '0' else 'Z';
   iec_clk  <= '0' when drv_clk_o  = '0' else 'Z';
   iec_data <= '0' when drv_data_o = '0' else 'Z';
   iec_srq  <= '0' when drv_srq_o  = '0' else 'Z';

   i_iec_bfm : entity c1581_lib.iec_bus_bfm
      generic map (g_given_name => "iec_bfm")
      port map (
         iec_clock => iec_clk,
         iec_data  => iec_data,
         iec_atn   => iec_atn,
         iec_srq   => iec_srq
      );

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
         drive_addr_i        => "01",            -- device 9
         iec_atn_i           => to_x01(iec_atn),
         iec_clk_i           => to_x01(iec_clk),
         iec_data_i          => to_x01(iec_data),
         iec_srq_i           => to_x01(iec_srq),
         iec_atn_o           => drv_atn_o,
         iec_clk_o           => drv_clk_o,
         iec_data_o          => drv_data_o,
         iec_srq_o           => drv_srq_o,
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
   -- HyperRAM, one byte per 16-bit word, preloaded from the real files
   ------------------------------------------------------------------------------
   p_hyperram : process (clk)
      constant C_MEM_WORDS : natural := 16#10000# + 819200;
      type t_mem is array (0 to C_MEM_WORDS - 1) of std_logic_vector(7 downto 0);
      type t_byte_file is file of character;

      variable v_mem    : t_mem := (others => X"EA");
      variable v_pipe   : std_logic_vector(1 downto 0) := "00";
      variable v_addr_q : natural := 0;
      variable v_init   : boolean := false;
      variable v_idx    : natural;

      procedure load (fname : string; offset : natural; what : string) is
         file     f  : t_byte_file;
         variable st : file_open_status;
         variable ch : character;
         variable n  : natural := 0;
      begin
         if fname = "" then
            return;
         end if;
         file_open(st, f, fname, read_mode);
         if st /= open_ok then
            report "could not open " & what & " " & fname severity warning;
            return;
         end if;
         while not endfile(f) and offset + n < C_MEM_WORDS loop
            read(f, ch);
            v_mem(offset + n) := std_logic_vector(
                                    to_unsigned(character'pos(ch), 8));
            n := n + 1;
         end loop;
         file_close(f);
         report what & ": " & integer'image(n) & " bytes";
      end procedure;
   begin
      if rising_edge(clk) then
         if not v_init then
            load(G_ROM_FILE, 16#8000#,  "DOS ROM");
            load(G_D81_FILE, 16#10000#, "disk image");
            v_init := true;
         end if;

         avm_rdvalid <= v_pipe(1);
         if v_pipe(1) = '1' then
            avm_readdata <= X"00" & v_mem(v_addr_q);
         end if;

         if avm_read = '1' or avm_write = '1' then
            v_idx := to_integer(unsigned(avm_address) - unsigned(C_MEM_BASE));
            if v_idx < C_MEM_WORDS then
               v_addr_q := v_idx;
               if v_idx >= 16#10000# then
                  n_img_access <= n_img_access + 1;
               end if;
               if avm_write = '1' and avm_byteenable(0) = '1' then
                  v_mem(v_idx) := avm_writedata(7 downto 0);
               end if;
            end if;
         end if;
         v_pipe := v_pipe(0) & avm_read;
      end if;
   end process p_hyperram;

   ------------------------------------------------------------------------------
   -- The C64's side of the conversation
   ------------------------------------------------------------------------------
   p_test : process
      variable bfm   : p_iec_bus_bfm_object;
      variable msg   : t_iec_message;
      variable bad   : natural := 0;

      -- Is `needle` anywhere in the bytes the drive sent back?
      impure function contains (needle : string) return boolean is
         variable hit : boolean;
      begin
         if needle = "" or msg.len < needle'length then
            return false;
         end if;
         for i in 0 to msg.len - needle'length loop
            hit := true;
            for j in needle'range loop
               if msg.data(i + j - needle'low)
                  /= std_logic_vector(to_unsigned(character'pos(needle(j)), 8))
               then
                  hit := false;
                  exit;
               end if;
            end loop;
            if hit then
               return true;
            end if;
         end loop;
         return false;
      end function;
   begin
      wait for 1 ns;
      bind_iec_bus_bfm("iec_bfm", bfm);

      report "== C1581 over IEC ==";
      if G_ROM_FILE = "" then
         report "no G_ROM_FILE given - nothing to talk to, skipping";
         report "RESULT: skipped";
         running <= false;
         wait;
      end if;

      rst <= '1';
      wait for 20 * C_CLK_PERIOD;
      rst <= '0';
      img_mounted <= '1';
      wait for G_BOOT_MS * 1 ms;
      report "DOS has had " & integer'image(G_BOOT_MS) & " ms to come up";

      ------------------------------------------------------------------------
      -- 1. the error channel. No disk access, so this isolates "does the
      --    drive talk at all" from "can it read the disk".
      ------------------------------------------------------------------------
      report "bus idle state: atn=" & std_logic'image(iec_atn)
             & " clk=" & std_logic'image(iec_clk)
             & " data=" & std_logic'image(iec_data);

      -- Before any protocol: does the drive acknowledge ATN at all? Every
      -- device on the bus must pull DATA low when ATN goes active, so this
      -- separates "the drive is not there" from "the handshake went wrong".
      report "checking the ATN acknowledge";
      iec_listen(bfm);
      wait for 1 ms;
      report "with the controller listening: clk=" & std_logic'image(iec_clk)
             & " data=" & std_logic'image(iec_data)
             & "  (drive drives clk=" & std_logic'image(drv_clk_o)
             & " data=" & std_logic'image(drv_data_o) & ")";

      report "reading the error channel: TALK 9, channel 15";
      iec_send_atn(bfm, X"49");          -- TALK device 9
      report "  sent TALK 9, bfm status = " & t_iec_status'image(bfm.status);
      iec_send_atn(bfm, X"6F");          -- secondary: channel 15
      report "  sent channel 15, bfm status = " & t_iec_status'image(bfm.status);
      iec_turnaround(bfm);
      report "  turnaround done, bfm status = " & t_iec_status'image(bfm.status);
      iec_get_message(bfm, msg);
      report "  get_message done, bfm status = " & t_iec_status'image(bfm.status);
      iec_print_message(msg);
      iec_send_atn(bfm, X"5F", true);    -- UNTALK
      if msg.len <= 0 then
         report "FAIL: the drive returned nothing on its error channel - it is "
                & "not answering on the IEC bus at all" severity error;
         bad := bad + 1;
      else
         report "the drive answered with " & integer'image(msg.len) & " byte(s)";
         if contains("1581") then
            report "and it identifies itself as a 1581";
         end if;
      end if;

      ------------------------------------------------------------------------
      -- 2. the directory. This is the part that needs seek, read sector and
      --    the HyperRAM DMA all working.
      ------------------------------------------------------------------------
      wait for 10 ms;
      report "loading the directory: OPEN 9,0,""$"" then read channel 0";
      iec_send_atn(bfm, X"29");          -- LISTEN device 9
      iec_send_atn(bfm, X"F0");          -- secondary: OPEN channel 0
      iec_send_message(bfm, "$");
      iec_send_atn(bfm, X"3F", true);    -- UNLISTEN

      wait for 50 ms;                    -- let it seek and read

      iec_send_atn(bfm, X"49");          -- TALK device 9
      iec_send_atn(bfm, X"60");          -- secondary: DATA channel 0
      iec_turnaround(bfm);
      iec_get_message(bfm, msg);
      iec_print_message(msg);
      iec_send_atn(bfm, X"5F", true);    -- UNTALK

      report "disk image accesses: " & integer'image(n_img_access);

      if msg.len <= 0 then
         report "FAIL: the directory came back empty - the drive accepted the "
                & "command and then returned no data" severity error;
         bad := bad + 1;
      else
         report "directory: " & integer'image(msg.len) & " byte(s)";
      end if;

      if n_img_access = 0 then
         report "FAIL: the drive never read the disk image, so it cannot have "
                & "produced a real directory" severity error;
         bad := bad + 1;
      end if;

      if G_EXPECT /= "" then
         if contains(G_EXPECT) then
            report "found " & G_EXPECT & " in the directory";
         else
            report "FAIL: " & G_EXPECT & " is not in what came back - the drive "
                   & "is reading the wrong part of the image" severity error;
            bad := bad + 1;
         end if;
      end if;

      report "";
      if bad = 0 then
         report "RESULT: the C1581 answers over IEC";
      else
         report "RESULT: " & integer'image(bad) & " failure(s)" severity failure;
      end if;

      running <= false;
      wait;
   end process p_test;

end architecture sim;
