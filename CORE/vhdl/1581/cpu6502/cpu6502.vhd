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
use ieee.std_logic_unsigned.all;

entity cpu6502 is
port (
    cpu_clk     : in  std_logic;
    cpu_clk_en  : in  std_logic;
    cpu_reset   : in  std_logic;    

    cpu_write   : out std_logic;
    
    cpu_wdata   : out std_logic_vector(7 downto 0);
    cpu_rdata   : in  std_logic_vector(7 downto 0);
    cpu_addr    : out std_logic_vector(16 downto 0);
    cpu_pc      : out std_logic_vector(15 downto 0);

    carry       : out std_logic;
    
    IRQn        : in  std_logic; -- IRQ interrupt (level sensitive)
    NMIn        : in  std_logic; -- NMI interrupt (edge sensitive)

    SOn         : in  std_logic -- set Overflow flag
);
end cpu6502;


architecture cycle_exact of cpu6502 is

    signal read_write_n : std_logic;
begin
    
    core: entity work.proc_core
    generic map (
        support_bcd  => true )
    port map(
        clock        => cpu_clk,
        clock_en     => cpu_clk_en,
        reset        => cpu_reset,

        irq_n        => IRQn,
        nmi_n        => NMIn,
        so_n         => SOn,

        carry        => carry,
        pc_out       => cpu_pc,
        addr_out     => cpu_addr,
        data_in      => cpu_rdata,
        data_out     => cpu_wdata,
        read_write_n => read_write_n );

    cpu_write <= not read_write_n;

end cycle_exact;
