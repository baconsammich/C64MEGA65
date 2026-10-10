----------------------------------------------------------------------------------
-- Commodore 64 for MEGA65
--
-- Host-side disk server for the vendored C1581 (CORE/vhdl/1581).
--
-- Gideon Zweijtzer's WD177x is deliberately software-assisted: it does not fetch
-- sectors by itself. When the drive's CPU writes the WD command register, the
-- controller latches the command, sets BUSY and pushes the command into a FIFO
-- for the host to service. On the 1541 Ultimate that host is its NIOS/RISC-V
-- running software/drive/c1581.cc. Here there is no such CPU in the core clock
-- domain, so this state machine does the same job in hardware:
--
--   * poll  $1806 bit 7            command pending?
--   * read  $1800 / $1801 / $1802  command, track, sector
--   * read  $0006                  side
--   * compute the byte offset of that sector within the *.d81 image
--   * write $1808..$180A           transfer address (byte address in HyperRAM)
--   * write $180C / $180D          transfer length (512)
--   * write $1807                  DMA mode: 01 = to drive, 10 = from drive
--   * poll  $1807                  until the controller clears DMA mode
--   * write $1804                  clear BUSY
--   * write $1806                  pop the command FIFO
--
-- The address map follows the io_bus_splitter inside c1581_drive, which uses
-- address bits 12:11 to pick one of four slaves: "00" = drive registers,
-- "11" = the WD177x. Hence $0000.. and $1800.. above.
--
-- *.d81 geometry: 80 tracks, 2 sides, 10 sectors of 512 bytes = 819200 bytes.
-- Sectors are numbered from 1.
--
--     offset = (((track * 2) + side) * 10 + (sector - 1)) * 512
--
-- Everything here is in the core clock domain, like the drive itself.
--
-- done by MJoergen and sy2002 in 2023 and licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.io_bus_pkg.all;

entity c1581_disk_server is
   port (
      clk_i            : in  std_logic;
      rst_i            : in  std_logic;

      -- Master port towards the drive's io slave
      io_req_o         : out t_io_req;
      io_resp_i        : in  t_io_resp;

      -- Image placement and state, supplied by QNICE
      img_base_i       : in  std_logic_vector(25 downto 0);  -- byte address of the image
      img_mounted_i    : in  std_logic;
      img_readonly_i   : in  std_logic;
      drive_addr_i     : in  std_logic_vector( 1 downto 0);  -- 0 => device 8, 1 => 9, ...

      -- Status, for the on-screen display and for debugging
      busy_o           : out std_logic;
      err_o            : out std_logic
   );
end entity c1581_disk_server;

architecture synthesis of c1581_disk_server is

   -- io_bus addresses, as decoded by the splitter inside c1581_drive
   constant C_DRV_POWER     : unsigned(23 downto 0) := X"000000";
   constant C_DRV_RESET     : unsigned(23 downto 0) := X"000001";
   constant C_DRV_ADDRESS   : unsigned(23 downto 0) := X"000002";
   constant C_DRV_SENSOR    : unsigned(23 downto 0) := X"000003";
   constant C_DRV_INSERTED  : unsigned(23 downto 0) := X"000004";
   constant C_DRV_SIDE      : unsigned(23 downto 0) := X"000006";
   constant C_DRV_DISKCHNG  : unsigned(23 downto 0) := X"00000C";
   constant C_DRV_DRIVETYPE : unsigned(23 downto 0) := X"00000D";

   constant C_WD_CMD        : unsigned(23 downto 0) := X"001800";
   -- Same address as C_WD_CMD, but on a write: bit 0 enables the index pulse
   -- and bit 1 sets its polarity. wd177x.vhd only feeds the index pulse into
   -- the type I status bit when this is enabled, and it comes out of reset
   -- disabled, so a DOS that waits on INDEX after a seek waits for ever.
   constant C_WD_IDXCTRL    : unsigned(23 downto 0) := X"001800";
   constant C_WD_TRACK      : unsigned(23 downto 0) := X"001801";
   constant C_WD_SECTOR     : unsigned(23 downto 0) := X"001802";
   constant C_WD_STAT_CLR   : unsigned(23 downto 0) := X"001804";
   constant C_WD_STAT_SET   : unsigned(23 downto 0) := X"001805";
   constant C_WD_CMD_FLAGS  : unsigned(23 downto 0) := X"001806";
   constant C_WD_DMA_MODE   : unsigned(23 downto 0) := X"001807";
   constant C_WD_ADDR_0     : unsigned(23 downto 0) := X"001808";
   constant C_WD_ADDR_1     : unsigned(23 downto 0) := X"001809";
   constant C_WD_ADDR_2     : unsigned(23 downto 0) := X"00180A";
   constant C_WD_LEN_0      : unsigned(23 downto 0) := X"00180C";
   constant C_WD_LEN_1      : unsigned(23 downto 0) := X"00180D";
   constant C_WD_DATA       : unsigned(23 downto 0) := X"001803";

   -- The side, awkwardly. drive_registers has a "side" register at $0006, but
   -- c1581_drive.vhd leaves that input unconnected, so it always reads 0.
   -- The side actually arrives through the port it wires to "mode": the status
   -- register reports "not mode", and mode is side_0 - CIA port A bit 0, the
   -- 1581's side-select line. So status bit 1 is the side number. This is what
   -- Gideon's own host model reads (sim/c1581_startup_tc.vhd).
   constant C_DRV_STATUS    : unsigned(23 downto 0) := X"000009";

   -- Status bit 0 is BUSY (see the aliases in wd177x.vhd)
   constant C_ST_BUSY       : std_logic_vector(7 downto 0) := X"01";
   constant C_ST_NOT_FOUND  : std_logic_vector(7 downto 0) := X"10";

   constant C_SECTOR_LEN    : natural := 512;
   constant C_SECTORS_TRACK : natural := 10;
   constant C_TRACKS        : natural := 80;    -- cylinders in a *.d81
   constant C_MAX_TRACK     : natural := 83;    -- what the mechanics allow

   type t_state is (
      RESET_ST, INIT_POWER_ST, INIT_TYPE_ST, INIT_ADDR_ST, INIT_SENSOR_ST,
      INIT_INSERT_ST, INIT_CHNG_ST, INIT_IDX_ST, INIT_RELEASE_ST,
      POLL_ST, MEDIA_INS_ST,
      GET_CMD_ST, GET_SECTOR_ST, GET_SIDE_ST,
      DECODE_ST, GET_SEEKTRK_ST, SET_TRACK_ST,
      SET_ADDR0_ST, SET_ADDR1_ST, SET_ADDR2_ST, SET_LEN0_ST, SET_LEN1_ST,
      SET_DMA_ST, WAIT_DMA_ST,
      SET_ERR_ST, CLEAR_BUSY_ST, POP_ST
   );
   signal state       : t_state := RESET_ST;

   -- One io transaction at a time: hold the request until ack, then advance.
   signal io_req      : t_io_req := c_io_req_init;
   signal pending     : std_logic := '0';
   signal next_state  : t_state := RESET_ST;

   signal wd_cmd      : std_logic_vector(7 downto 0) := (others => '0');
   signal wd_sector   : unsigned(7 downto 0) := (others => '0');
   signal wd_side     : std_logic := '0';

   -- Where the head is. This is the host's job to know, which is the whole
   -- point of the seek and step commands below: the WD1772 track register is
   -- only what the DOS believes, and on real hardware the controller updates
   -- it as it steps. Nothing else here tracks it - the drive's own cur_track
   -- is driven by the mechanics and is not used for addressing.
   signal head_track  : unsigned(7 downto 0) := (others => '0');
   signal step_in     : std_logic := '1';   -- direction of the last step

   -- The drive is released from reset once, when its DOS ROM is in place, and
   -- then left running - see the comment on drive_en_i in c1581_wrapper.vhd. So
   -- the bring-up sequence only ever happens at power-on, and a disk arriving
   -- or being swapped afterwards has to be reported separately. These watch for
   -- that and fold it into the command loop.
   signal mnt_q       : std_logic := '0';
   signal media_dirty : std_logic := '0';
   signal offset      : unsigned(25 downto 0) := (others => '0');
   signal xfer_addr   : unsigned(25 downto 0) := (others => '0');
   signal is_write    : std_logic := '0';

begin

   io_req_o <= io_req;
   busy_o   <= '0' when state = POLL_ST else '1';

   p_fsm : process (clk_i)
      -- helper: start an io read/write and continue at s once acknowledged
      procedure do_read (addr : unsigned(23 downto 0); s : t_state) is
      begin
         io_req.read    <= '1';
         io_req.write   <= '0';
         io_req.address <= addr;
         pending        <= '1';
         next_state     <= s;
      end procedure;

      procedure do_write (addr : unsigned(23 downto 0);
                          dat  : std_logic_vector(7 downto 0);
                          s    : t_state) is
      begin
         io_req.read    <= '0';
         io_req.write   <= '1';
         io_req.address <= addr;
         io_req.data    <= dat;
         pending        <= '1';
         next_state     <= s;
      end procedure;

      variable v_lin : unsigned(25 downto 0);
   begin
      if rising_edge(clk_i) then

         -- Notice a disk being inserted, removed or swapped. Checked every
         -- cycle, independently of whatever transaction is in flight.
         if img_mounted_i /= mnt_q then
            mnt_q       <= img_mounted_i;
            media_dirty <= '1';
         end if;

         ----------------------------------------------------------------------
         -- Outstanding io transaction: wait for ack, then take next_state
         ----------------------------------------------------------------------
         if pending = '1' then
            if io_resp_i.ack = '1' then
               io_req.read  <= '0';
               io_req.write <= '0';
               pending      <= '0';

               -- capture read data for the states that asked for it
               case state is
                  when GET_CMD_ST     => wd_cmd    <= io_resp_i.data;
                  when GET_SECTOR_ST  => wd_sector <= unsigned(io_resp_i.data);
                  -- status bit 1 is the side; see C_DRV_STATUS above
                  when GET_SIDE_ST    => wd_side   <= io_resp_i.data(1);
                  -- a seek takes its target from the WD1772 data register
                  when GET_SEEKTRK_ST => head_track <= unsigned(io_resp_i.data);
                  when POLL_ST       =>
                     -- bit 7 of $1806 is command_fifo_valid
                     if io_resp_i.data(7) = '0' then
                        next_state <= POLL_ST;
                     end if;
                  when WAIT_DMA_ST   =>
                     -- The controller signals completion by changing dma_mode
                     -- itself: "00" after a read, but "11" - "write complete"
                     -- - after a write (see the dma_state machine in
                     -- wd177x.vhd). Waiting only for "00" hangs on every write.
                     if io_resp_i.data(1 downto 0) /= "00"
                        and io_resp_i.data(1 downto 0) /= "11" then
                        next_state <= WAIT_DMA_ST;
                     end if;
                  when others        => null;
               end case;

               state <= next_state;
            end if;

         ----------------------------------------------------------------------
         -- No transaction outstanding: issue the next one
         ----------------------------------------------------------------------
         else
            case state is

               -- Bring the drive up, then release its reset last.
               --
               -- Every one of these registers comes out of reset in a state
               -- the drive cannot work in: unpowered, write-protected, with no
               -- disk inserted and its own reset asserted (see the reset
               -- branch of drive_registers.vhd). So each one has to be written
               -- before the CPU is let go.
               when RESET_ST        => do_write(C_DRV_POWER,     X"01",     INIT_POWER_ST);

               -- Harmless no-op for a 1581: drive_registers only latches the
               -- type when its g_multi_mode generic is set, and nothing in the
               -- 1581 reads drive_type. Written anyway so the sequence matches
               -- what the Ultimate host software does.
               when INIT_POWER_ST   => do_write(C_DRV_DRIVETYPE, X"02",     INIT_TYPE_ST);
               when INIT_TYPE_ST    => do_write(C_DRV_ADDRESS,
                                                "000000" & drive_addr_i,    INIT_ADDR_ST);

               -- The write-protect sensor. drive_registers exports this as
               -- "write_prot_n <= sensor_i" straight into the WD177x, and it
               -- resets to 0, which the controller reads as "protected" - so
               -- without this write every write command fails.
               when INIT_ADDR_ST    => do_write(C_DRV_SENSOR,
                                          "0000000" & (not img_readonly_i),  INIT_SENSOR_ST);
               when INIT_SENSOR_ST  => do_write(C_DRV_INSERTED,
                                                "0000000" & img_mounted_i,  INIT_INSERT_ST);

               -- Flag a disk change so the DOS re-reads the BAM instead of
               -- trusting what it cached for whatever image was there before.
               when INIT_INSERT_ST  => do_write(C_DRV_DISKCHNG,
                                                "0000000" & img_mounted_i,  INIT_CHNG_ST);

               -- Enable the index pulse, active high. Without it the type I
               -- status never reports INDEX and the disk looks stationary.
               when INIT_CHNG_ST    => do_write(C_WD_IDXCTRL,   X"01",      INIT_IDX_ST);
               when INIT_IDX_ST     => do_write(C_DRV_RESET,     X"00",     INIT_RELEASE_ST);
               when INIT_RELEASE_ST => do_read (C_WD_CMD_FLAGS,             POLL_ST);

               -- Wait for the drive to ask for something.
               --
               -- The track is deliberately not read from the WD1772 track
               -- register here. That register is the DOS's belief about where
               -- the head is; on real hardware the controller updates it while
               -- it steps, and emulating the controller is this module's job.
               -- Reading it instead of maintaining the position means every
               -- seek is ignored and every sector comes off whatever track the
               -- DOS last wrote - which looks like a disk that never reads.
               -- Report a media change first, then go back to listening.
               -- floppy_inserted is what drives the drive's ready line, and
               -- the change flag is what makes the DOS re-read the BAM instead
               -- of trusting what it cached for the previous disk.
               when POLL_ST =>
                  if media_dirty = '1' then
                     media_dirty <= '0';
                     do_write(C_DRV_INSERTED,
                              "0000000" & img_mounted_i,            MEDIA_INS_ST);
                  else
                     do_read (C_WD_CMD_FLAGS,                       GET_CMD_ST);
                  end if;

               when MEDIA_INS_ST    => do_write(C_DRV_DISKCHNG, X"01",  POLL_ST);
               when GET_CMD_ST      => do_read (C_WD_CMD,                   GET_SECTOR_ST);
               when GET_SECTOR_ST   => do_read (C_WD_SECTOR,                GET_SIDE_ST);
               when GET_SIDE_ST     => do_read (C_DRV_STATUS,               DECODE_ST);

               -- Work out what was asked for. WD1772 type I commands move the
               -- head and the controller - this module - owns the resulting
               -- position; type II commands transfer a sector.
               --
               --   0000 xxxx  restore, head to track 0
               --   0001 xxxx  seek, target in the data register
               --   001u xxxx  step again in the last direction
               --   010u xxxx  step in  (towards the spindle, track + 1)
               --   011u xxxx  step out (towards track 0, track - 1)
               --   100x xxxx  read sector
               --   101x xxxx  write sector
               --   1101 xxxx  force interrupt
               --
               -- "u" asks for the track register to be updated as well. The
               -- WD1772 datasheet has step in incrementing the track register;
               -- Gideon's host model in sim/c1581_startup_tc.vhd has those two
               -- the other way round, which goes unnoticed there because the
               -- 1581 DOS seeks rather than steps.
               when DECODE_ST =>
                  v_lin := (others => '0');

                  if wd_cmd(7 downto 4) = "0000" then         -- restore
                     head_track <= (others => '0');
                     state      <= SET_TRACK_ST;

                  elsif wd_cmd(7 downto 4) = "0001" then      -- seek
                     -- head_track is captured from the read, then written back
                     state <= GET_SEEKTRK_ST;

                  elsif wd_cmd(7 downto 5) = "001"            -- step
                     or  wd_cmd(7 downto 5) = "010"           -- step in
                     or  wd_cmd(7 downto 5) = "011" then      -- step out
                     if wd_cmd(7 downto 5) = "010" then
                        step_in <= '1';
                     elsif wd_cmd(7 downto 5) = "011" then
                        step_in <= '0';
                     end if;

                     if (wd_cmd(7 downto 5) = "010")
                        or (wd_cmd(7 downto 5) = "001" and step_in = '1') then
                        if head_track < C_MAX_TRACK then
                           head_track <= head_track + 1;
                        end if;
                     else
                        if head_track > 0 then
                           head_track <= head_track - 1;
                        end if;
                     end if;

                     if wd_cmd(4) = '1' then                  -- update flag
                        state <= SET_TRACK_ST;
                     else
                        state <= CLEAR_BUSY_ST;
                     end if;

                  elsif wd_cmd(7 downto 5) = "100"            -- read sector
                     or  wd_cmd(7 downto 5) = "101" then      -- write sector
                     -- Refuse anything that is not actually on the disk rather
                     -- than computing an address outside the image: the head
                     -- can step to 83 but a *.d81 only holds 80 cylinders.
                     if img_mounted_i = '0'
                        or head_track >= C_TRACKS
                        or wd_sector = 0
                        or wd_sector > C_SECTORS_TRACK
                        or (wd_cmd(7 downto 5) = "101" and img_readonly_i = '1')
                     then
                        state <= SET_ERR_ST;
                     else
                        is_write <= wd_cmd(5);
                        state    <= SET_ADDR0_ST;
                     end if;

                     -- offset = (((track*2) + side)*10 + (sector-1)) * 512
                     if wd_sector /= 0 then
                        v_lin := resize((((head_track & '0')
                                          + ("0000000" & wd_side))
                                         * C_SECTORS_TRACK
                                         + (wd_sector - 1)) * C_SECTOR_LEN, 26);
                     end if;

                  else
                     -- force interrupt and anything unrecognised
                     state <= CLEAR_BUSY_ST;
                  end if;

                  offset    <= v_lin;
                  xfer_addr <= unsigned(img_base_i) + v_lin;

               -- Seek: the target track is in the WD1772 data register. The
               -- read lands in head_track, then it is written back to the
               -- track register so the DOS sees the move it asked for.
               when GET_SEEKTRK_ST => do_read (C_WD_DATA,                   SET_TRACK_ST);

               when SET_TRACK_ST   => do_write(C_WD_TRACK,
                                        std_logic_vector(head_track),       CLEAR_BUSY_ST);

               when SET_ADDR0_ST => do_write(C_WD_ADDR_0,
                                       std_logic_vector(xfer_addr( 7 downto  0)), SET_ADDR1_ST);
               when SET_ADDR1_ST => do_write(C_WD_ADDR_1,
                                       std_logic_vector(xfer_addr(15 downto  8)), SET_ADDR2_ST);
               -- The controller's transfer_addr is 24 bits, ample for an 8 MB
               -- HyperRAM, so the top two bits of the 26-bit memory-bus
               -- address are not passed on.
               when SET_ADDR2_ST => do_write(C_WD_ADDR_2,
                                       std_logic_vector(xfer_addr(23 downto 16)), SET_LEN0_ST);
               when SET_LEN0_ST  => do_write(C_WD_LEN_0, X"00",                   SET_LEN1_ST);
               when SET_LEN1_ST  => do_write(C_WD_LEN_1, X"02",                   SET_DMA_ST);

               when SET_DMA_ST =>
                  if is_write = '1' then
                     do_write(C_WD_DMA_MODE, X"02", WAIT_DMA_ST);   -- from drive
                  else
                     do_write(C_WD_DMA_MODE, X"01", WAIT_DMA_ST);   -- to drive
                  end if;

               when WAIT_DMA_ST   => do_read (C_WD_DMA_MODE,                CLEAR_BUSY_ST);

               when SET_ERR_ST    => do_write(C_WD_STAT_SET, C_ST_NOT_FOUND, CLEAR_BUSY_ST);
               when CLEAR_BUSY_ST => do_write(C_WD_STAT_CLR, C_ST_BUSY,      POP_ST);
               when POP_ST        => do_write(C_WD_CMD_FLAGS, X"00",         POLL_ST);

            end case;
         end if;

         ----------------------------------------------------------------------
         if rst_i = '1' then
            mnt_q       <= img_mounted_i;
            media_dirty <= '0';
            state   <= RESET_ST;
            pending <= '0';
            io_req  <= c_io_req_init;
         end if;
      end if;
   end process p_fsm;

   -- Latched sticky error flag for the OSM
   p_err : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if state = SET_ERR_ST then
            err_o <= '1';
         end if;
         if rst_i = '1' then
            err_o <= '0';
         end if;
      end if;
   end process p_err;

end architecture synthesis;
