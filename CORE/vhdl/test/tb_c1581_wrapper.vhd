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
   generic (
      -- Optional, and empty by default: with a real 1581 DOS dump here the
      -- testbench additionally boots the drive for real and reports where it
      -- goes. Those ROMs are copyrighted and are not in this repository, so CI
      -- runs without them and the memory is filled with $EA (6502 NOP)
      -- instead, which still exercises the addressing checks.
      G_ROM_FILE : string := "";
      G_D81_FILE : string := "";
      -- How long to let the drive run after mounting, in milliseconds. The
      -- default is only long enough for the addressing checks; give it a
      -- hundred or more together with a real G_ROM_FILE to watch the DOS
      -- actually initialise and start touching the disk.
      G_RUN_MS   : natural := 2;
      -- Log the first N accesses that fall in the drive's zero page. The DOS
      -- reset handler tests zero page byte by byte before it does anything
      -- else, so this shows whether RAM reads back what was written.
      G_TRACE_ZP : natural := 0;
      -- Log this many drive addresses right after ATN is asserted. Addresses
      -- at or above 0x8000 are ROM, so this shows which code the 6502 is
      -- actually running when the controller calls - the only way to tell an
      -- idle loop that polls ATN from one that does not.
      G_TRACE_ATN : natural := 0;
      -- Cycles between a read being accepted and its data arriving. The
      -- default of 2 is optimistic on purpose - it keeps the addressing checks
      -- quick - but it is NOT what the hardware does. A single random access
      -- to the real HyperRAM, through the arbiter and the clock-domain FIFO,
      -- costs the core clock domain something closer to 16 cycles, and
      -- c1541_timing stalls the drive's CPU through mem_busy for every one of
      -- them. Raise this to see how much slower the drive really is.
      G_HR_LATENCY : natural := 2
   );
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
   -- the *.d81 starts right above the drive's address space
   constant C_IMG_LO     : unsigned(31 downto 0) := C_DRIVE_HI;
   constant C_IMG_HI     : unsigned(31 downto 0) := C_DRIVE_HI + 819200;

   signal clk            : std_logic := '0';
   signal rst            : std_logic := '1';
   signal img_mounted    : std_logic := '0';
   signal drive_en       : std_logic := '0';
   signal running        : boolean   := true;

   -- The IEC lines as the controller drives them: open collector, so '1' is
   -- released and '0' is pulled low.
   signal c64_atn        : std_logic := '1';
   signal c64_clk        : std_logic := '1';
   signal c64_data       : std_logic := '1';
   -- and what the drive drives back
   signal drv_clk_o      : std_logic;
   signal drv_data_o     : std_logic;

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
   signal n_img_access   : natural := 0;     -- reads/writes of the disk image
   signal atn_live        : boolean := false;

   -- The disk server sits in POLL_ST whenever it has nothing to do, so busy_o
   -- rising means the drive asked the WD177x for something. Counting those
   -- separates "the DOS never touches the floppy controller" from "it does and
   -- the transfer goes wrong", which look the same from the memory bus.
   signal drv_busy        : std_logic;
   signal drv_err         : std_logic;
   signal n_cmds          : natural := 0;
   -- How much of its own 64 KB the drive actually touches. A healthy DOS ranges
   -- over its ROM; a crashed 6502 spinning on a handful of bytes does not, and
   -- the two look identical if you only count accesses.
   signal n_pages        : natural := 0;
   signal lo_addr        : unsigned(31 downto 0) := (others => '1');
   signal hi_addr        : unsigned(31 downto 0) := (others => '0');

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
         drive_en_i          => drive_en,
         img_mounted_i       => img_mounted,
         img_readonly_i      => '0',
         drive_addr_i        => "01",
         iec_atn_i           => c64_atn,
         iec_clk_i           => c64_clk,
         iec_data_i          => c64_data,
         iec_srq_i           => '1',
         iec_atn_o           => open,
         iec_clk_o           => drv_clk_o,
         iec_data_o          => drv_data_o,
         iec_srq_o           => open,
         c64_reset_n_i       => '1',
         act_led_o           => open,
         busy_o              => drv_busy,
         err_o               => drv_err,
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
   -- A HyperRAM model: always ready, answers a read two cycles later.
   --
   -- It holds the drive's whole window plus the image, one byte per 16-bit
   -- word in the low half, which is how the Shell's loader writes it - see the
   -- note at the top of c1581_mem_bridge.vhd. Default fill is $EA, a 6502 NOP,
   -- so the CPU keeps fetching even with no ROM supplied.
   ------------------------------------------------------------------------------
   p_hyperram : process (clk)
      -- Drive address space (64 KB) plus the image (819200 B), as words.
      constant C_MEM_WORDS : natural := 16#10000# + 819200;
      type t_mem is array (0 to C_MEM_WORDS - 1) of std_logic_vector(7 downto 0);
      type t_byte_file is file of character;

      variable v_mem    : t_mem := (others => X"EA");
      -- one stage per cycle of latency, so the data comes back G_HR_LATENCY
      -- cycles after the access is accepted
      variable v_pipe   : std_logic_vector(0 to G_HR_LATENCY) := (others => '0');
      variable v_addr_q : natural := 0;
      variable v_init   : boolean := false;
      variable v_idx    : natural;

      -- Read a file into v_mem at a byte offset in the drive's address space.
      procedure load (fname : string; offset : natural; what : string) is
         file     f    : t_byte_file;
         variable st   : file_open_status;
         variable ch   : character;
         variable n    : natural := 0;
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
         report what & ": " & integer'image(n) & " bytes at drive offset 0x"
                & to_hstring(std_logic_vector(to_unsigned(offset, 24)));
      end procedure;
   begin
      if rising_edge(clk) then
         if not v_init then
            -- The DOS ROM sits at CPU $8000, the image just above the 64 KB.
            load(G_ROM_FILE, 16#8000#,  "DOS ROM");
            load(G_D81_FILE, 16#10000#, "disk image");
            v_init := true;
         end if;

         avm_rdvalid <= v_pipe(v_pipe'high);
         if v_pipe(v_pipe'high) = '1' then
            avm_readdata <= X"00" & v_mem(v_addr_q);
         end if;

         if avm_read = '1' or avm_write = '1' then
            v_idx := to_integer(unsigned(avm_address) - unsigned(C_MEM_BASE));
            if v_idx < C_MEM_WORDS then
               v_addr_q := v_idx;
               if avm_write = '1' and avm_byteenable(0) = '1' then
                  v_mem(v_idx) := avm_writedata(7 downto 0);
               end if;
            end if;
         end if;
         v_pipe(1 to v_pipe'high) := v_pipe(0 to v_pipe'high - 1);
         v_pipe(0) := avm_read;
      end if;
   end process p_hyperram;

   ------------------------------------------------------------------------------
   -- Watch the bus
   ------------------------------------------------------------------------------
   p_cmds : process (clk)
      variable v_busy_q : std_logic := '0';
   begin
      if rising_edge(clk) then
         if drv_busy = '1' and v_busy_q = '0' then
            n_cmds <= n_cmds + 1;
         end if;
         v_busy_q := drv_busy;
      end if;
   end process p_cmds;

   p_watch : process (clk)
      -- one flag per 256-byte page of the drive's 64 KB address space
      variable v_seen  : std_logic_vector(0 to 255) := (others => '0');
      variable v_off   : unsigned(31 downto 0);
      variable v_trace     : natural := 0;
      variable v_atn_trace : natural := 0;
      variable v_rd    : boolean := false;
      variable v_raddr : unsigned(31 downto 0) := (others => '0');
   begin
      if rising_edge(clk) then
         -- a read logged here shows the data one cycle late, when it arrives
         if v_rd and avm_rdvalid = '1' then
            report "   zp read  0x" & to_hstring(std_logic_vector(v_raddr(7 downto 0)))
                   & " -> 0x" & to_hstring(avm_readdata(7 downto 0));
            v_rd := false;
         end if;

         if v_trace < G_TRACE_ZP and rst = '0'
            and (avm_read = '1' or avm_write = '1')
            and unsigned(avm_address) >= C_DRIVE_LO
            and unsigned(avm_address) < C_DRIVE_LO + 256 then
            v_trace := v_trace + 1;
            v_off := unsigned(avm_address) - C_DRIVE_LO;
            if avm_write = '1' then
               report "   zp write 0x" & to_hstring(std_logic_vector(v_off(7 downto 0)))
                      & " <- 0x" & to_hstring(avm_writedata(7 downto 0))
                      & "  be=" & to_hstring(avm_byteenable);
            else
               v_rd    := true;
               v_raddr := v_off;
            end if;
         end if;
         if atn_live and v_atn_trace < G_TRACE_ATN
            and (avm_read = '1' or avm_write = '1') then
            v_atn_trace := v_atn_trace + 1;
            v_off := unsigned(avm_address) - C_DRIVE_LO;
            if avm_read = '1' then
               report "   after ATN: rd $"
                      & to_hstring(std_logic_vector(v_off(15 downto 0)));
            else
               report "   after ATN: wr $"
                      & to_hstring(std_logic_vector(v_off(15 downto 0)));
            end if;
         end if;

         if rst = '0' and (avm_read = '1' or avm_write = '1') then
            n_access <= n_access + 1;
            if not got_first then
               first_addr <= unsigned(avm_address);
               got_first  <= true;
            end if;
            if unsigned(avm_address) < lo_addr then
               lo_addr <= unsigned(avm_address);
            end if;
            if unsigned(avm_address) > hi_addr then
               hi_addr <= unsigned(avm_address);
            end if;
            if unsigned(avm_address) >= C_DRIVE_LO
               and unsigned(avm_address) < C_DRIVE_HI then
               v_off := unsigned(avm_address) - C_DRIVE_LO;
               if v_seen(to_integer(v_off(15 downto 8))) = '0' then
                  v_seen(to_integer(v_off(15 downto 8))) := '1';
                  n_pages <= n_pages + 1;
               end if;
            end if;
            if unsigned(avm_address) >= C_IMG_LO
               and unsigned(avm_address) < C_IMG_HI then
               -- the drive reaching into the image means it is doing disk I/O
               n_img_access <= n_img_access + 1;
            elsif unsigned(avm_address) < C_DRIVE_LO
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
      -- 1. no DOS ROM yet: the drive must be completely quiet
      --
      -- This is the safety property. The ROM is an optional auto-load file, so
      -- the core has to boot on a card without it - and with no ROM the
      -- drive's 6502 would fetch its reset vector out of uninitialised
      -- HyperRAM, run away, and starve the video scaler of the bandwidth it
      -- shares. Note it is the ROM, not a mounted disk, that gates this: the
      -- drive is deliberately left running once started, so that its 1.5 s
      -- power-on self test is not repeated on every mount.
      ------------------------------------------------------------------------
      drive_en    <= '0';
      img_mounted <= '0';
      wait for 20000 * C_CLK_PERIOD;        -- ~634 us, far longer than bring-up

      report "no DOS ROM: " & integer'image(n_access) & " HyperRAM access(es)";
      if n_access /= 0 then
         report "FAIL: the drive accessed HyperRAM before its DOS ROM was "
                & "loaded - its 6502 is running on uninitialised memory and "
                & "will starve the video scaler" severity error;
         v_bad := v_bad + 1;
      end if;

      ------------------------------------------------------------------------
      -- 2. released: it must start fetching, from inside its own window
      ------------------------------------------------------------------------
      drive_en    <= '1';
      img_mounted <= '1';
      wait for G_RUN_MS * 1 ms;

      report "running: " & integer'image(n_access) & " HyperRAM access(es)";
      if n_access = 0 then
         report "FAIL: the drive made no HyperRAM access after being released "
                & "- it is not fetching its DOS" severity error;
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

      -- A real DOS issues a handful of commands per operation. Anything in the
      -- thousands means the disk server is servicing an empty command FIFO -
      -- which also means it is clearing the WD177x BUSY status and popping the
      -- FIFO continuously, destroying every real command the DOS issues.
      report "WD177x commands serviced: " & integer'image(n_cmds);
      if G_ROM_FILE /= "" and n_cmds > 1000 then
         report "FAIL: " & integer'image(n_cmds) & " WD177x commands in "
                & integer'image(G_RUN_MS) & " ms is impossible - the disk "
                & "server is servicing phantom commands from an empty FIFO"
                severity error;
         v_bad := v_bad + 1;
      end if;
      report "disk image accesses: " & integer'image(n_img_access);
      report "touched " & integer'image(n_pages) & " of 256 pages of its own "
             & "address space, from 0x" & to_hstring(std_logic_vector(lo_addr))
             & " to 0x" & to_hstring(std_logic_vector(hi_addr));
      if G_ROM_FILE /= "" and n_pages < 16 then
         report "FAIL: the drive only ranged over " & integer'image(n_pages)
                & " page(s) - its 6502 is not running the DOS, it is spinning"
                severity error;
         v_bad := v_bad + 1;
      end if;

      ------------------------------------------------------------------------
      -- 3. the drive has to answer on the IEC bus
      --
      -- Only meaningful with a real DOS: a booted drive must acknowledge ATN
      -- by pulling DATA low, within 1 ms per the IEC timing. This is the check
      -- that catches the drive being wired to the wrong side of the bus - it
      -- boots and runs perfectly either way, it just never hears the computer.
      ------------------------------------------------------------------------
      if G_ROM_FILE /= "" then
         report "asserting ATN; the drive should pull DATA low";
         atn_live <= true;
         c64_atn  <= '0';
         for i in 1 to 1000 loop
            wait for 1 us;
            exit when drv_data_o = '0';
         end loop;
         if drv_data_o = '0' then
            report "the drive acknowledged ATN on DATA";

            -- The acknowledge is pure hardware: cpu_part_1581 holds DATA low
            -- whenever CIA port B bit 4 (atn_ack) is set and ATN is low. To
            -- take part in the transfer the DOS has to notice the ATN
            -- interrupt on the CIA FLAG input and clear that bit, releasing
            -- DATA. Until it does, a controller waiting for "ready for data"
            -- waits for ever - and that is indistinguishable from a dead
            -- drive if you only check the acknowledge.
            report "waiting for the DOS to release DATA";
            for i in 1 to 30000 loop
               wait for 1 us;
               exit when drv_data_o = '1';
            end loop;
            if drv_data_o = '1' then
               report "DATA released - the DOS is servicing the ATN interrupt";
            else
               report "FAIL: DATA still held low 30 ms after the acknowledge. "
                      & "The hardware acknowledged ATN but the DOS never "
                      & "cleared it, so it is not servicing the ATN interrupt"
                      severity error;
               v_bad := v_bad + 1;
            end if;
         else
            report "FAIL: no DATA acknowledge within 1 ms of ATN - the drive "
                   & "is not listening to the controller" severity error;
            v_bad := v_bad + 1;
         end if;
         c64_atn <= '1';
      end if;

      if out_of_window /= 0 then
         report "FAIL: " & integer'image(out_of_window) & " access(es) outside "
                & "both the drive window and the disk image, e.g. 0x"
                & to_hstring(std_logic_vector(worst_addr))
                severity error;
         v_bad := v_bad + 1;
      else
         report "all accesses inside the drive window 0x"
                & to_hstring(std_logic_vector(C_DRIVE_LO)) & "..0x"
                & to_hstring(std_logic_vector(C_DRIVE_HI - 1))
                & " or the image above it";
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
