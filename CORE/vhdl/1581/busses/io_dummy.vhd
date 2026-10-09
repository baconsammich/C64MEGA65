--------------------------------------------------------------------------------
-- Vendored from the 1541 Ultimate project
--   https://github.com/GideonZ/1541ultimate
--   Copyright (C) Gideon Zweijtzer and contributors
--   Licensed under the GNU General Public License v3 (see LICENSE at the root
--   of this repository; GPL v3 is also C64MEGA65's licence).
--
-- Imported unmodified unless noted below. These sources implement a C1581 with
-- a WD177x floppy controller entirely in VHDL and in a single clock domain,
-- taking its disk image over a memory bus rather than a two-clock SD handshake.
-- See doc/cmd_devices.md for why that matters on the MEGA65.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.io_bus_pkg.all;

entity io_dummy is
port (
    clock       : in  std_logic;
    io_req      : in  t_io_req;
    io_resp     : out t_io_resp );
end entity;

architecture dummy of io_dummy is
begin
    io_resp.data <= X"00";

    process(clock)
    begin
        if rising_edge(clock) then
            io_resp.ack <= io_req.read or io_req.write;
        end if;
    end process;
end dummy;

