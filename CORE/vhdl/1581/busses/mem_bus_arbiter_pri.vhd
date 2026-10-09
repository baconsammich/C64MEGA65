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

library work;
use work.mem_bus_pkg.all;

entity mem_bus_arbiter_pri is
generic (
    g_registered: boolean := true;
    g_ports     : positive := 3 );
port (
    clock       : in  std_logic;
    reset       : in  std_logic;
    
    reqs        : in  t_mem_req_array(0 to g_ports-1);
    resps       : out t_mem_resp_array(0 to g_ports-1);
    
    req         : out t_mem_req;
    resp        : in  t_mem_resp );
end entity;

architecture rtl of mem_bus_arbiter_pri is
    signal req_i    : t_mem_req;
    signal req_c    : t_mem_req;
begin
    -- prioritize the first request found onto output
    process(reqs)
    begin
        req_i <= c_mem_req_init;
        for i in reqs'range loop
            if reqs(i).request='1' then
                req_i <= reqs(i);
                exit;
            end if;
        end loop;
    end process;

    -- send the reply to everyone (including tag)
    process(resp)
    begin
        for i in resps'range loop
            resps(i) <= resp;
        end loop;
    end process;
    
    -- output register (will be eliminated when not used)
    process(clock)
    begin
        if rising_edge(clock) then
            req_c  <= req_i;
            if resp.rack = '1' and (resp.rack_tag = req_c.tag) then
                req_c.request <= '0';
            end if;
        end if;
    end process;

    req <= req_c when g_registered else req_i;

end architecture;
