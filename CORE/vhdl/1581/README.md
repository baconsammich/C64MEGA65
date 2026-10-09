C1581 from the 1541 Ultimate
============================

VHDL sources for a Commodore 1581 disk drive, vendored from the
[1541 Ultimate](https://github.com/GideonZ/1541ultimate) project by Gideon
Zweijtzer. That project is licensed under the GNU General Public License v3,
the same licence as C64MEGA65, so the code can be reused here with attribution.
Every file carries a provenance header saying where it came from.

Only one file was changed beyond adding that header: `sim/tl_string_util_pkg.vhd`
used `default` as a formal parameter name, which VHDL-2008 made a reserved word,
so it is renamed to `dflt`. The header on that file says so. The three files in
`glue/` are ours, not Gideon's.

Why these and not the MiSTer C1581
----------------------------------

The `C64_MiSTerMEGA65` submodule also contains a C1581, but it is unfinished
for this platform and does not meet timing. The reason is architectural rather
than incidental:

* MiSTer's drives take their disk image over a **block interface** - `sd_lba`,
  `sd_rd`, `sd_wr`, `sd_buff_*` - which the host answers. On MiSTer the drive
  and the host share one clock. On the MEGA65 they do not: the core runs at
  31.528 MHz and QNICE at 50 MHz. The C1541 was adapted for that split
  (`c1541_drv` runs `c1541_track` on `clk_sys` and uses dual-clock buffers);
  the C1581 never was. `c1581_drv.sv` declares a `clk_sys` port and never uses
  it, and `fdc1772.v` has no such port at all, clocking its transfer FIFO from
  the core clock while addressing it with QNICE-domain signals.
* Gideon's C1581 instead takes its image over a **memory bus** and is entirely
  **single-clock**:

  ```vhdl
  clock    : in  std_logic;        -- one clock, no clk_sys
  mem_req  : out t_mem_req_32;     -- the drive is a DMA master
  mem_resp : in  t_mem_resp_32;    -- the image lives in memory
  io_req   : in  t_io_req;         -- register bus
  io_resp  : out t_io_resp;
  ```

  There is no cross-domain handshake to get wrong, so the problem disappears by
  construction rather than being constrained away.

It is also all VHDL, so GHDL can analyse, elaborate and simulate it. MiSTer's
FDC is Verilog, which GHDL cannot read at all - so that version could not be
verified here even in principle.

What is here
------------

| Directory | Contents |
|:----------|:---------|
| `drive/` | the 1581 itself: `c1581_drive`, `cpu_part_1581`, `wd177x` (the floppy controller), the CIA, stepper, drive registers, timing |
| `cpu6502/` | Gideon's 6502 in VHDL, used by the drive. Self-contained, so no dependency on T65 |
| `busses/` | the `t_io_req`/`t_mem_req_32` bus packages and helpers the drive expects |
| `sim/` | two simulation-only packages, plus Gideon's own 1581 testbench (`c1581_startup_tc.vhd`, `harness_c1581.vhd`). Referenced only from inside `-- synthesis translate_off` regions, so synthesis does not need them |
| `glue/` | our own adapters - see below |

Checking them
-------------

```bash
cd CORE/vhdl/test
./analyze_1581.sh
```

Analyses 35 files into `c1581_lib` and elaborates `c1581_wrapper`, which
type-checks the whole hierarchy below the drive including our glue.

These sources need two GHDL settings the rest of the tree does not -
`-fsynopsys` (`cpu6502.vhd` uses the non-standard `std_logic_unsigned`) and
`-frelaxed` - which is why they get their own script rather than joining
`analyze_all.sh`. They build as **VHDL-2008**, the same standard as the rest of
the core, which matters because `main.vhd` instantiates the drive out of
`c1581_lib` and a GHDL library is tied to the standard it was built with.

They also need their own *library*: Gideon's 6502 and QNICE both define an
entity called `alu`, and in a single library Vivado silently black-boxes
`data_oper`.

How it is wired in
------------------

`glue/` holds the three files that are ours rather than Gideon's:

| File | Job |
|:-----|:----|
| `c1581_wrapper.vhd` | instantiates the drive, derives its `tick_4MHz` and `tick_1KHz` from the 31.528 MHz core clock, and holds it in reset until it is usable |
| `c1581_disk_server.vhd` | plays the part the Ultimate's host software plays: brings the drive up over `io_req`, then services its WD177x command FIFO by turning each read/write into a HyperRAM transfer |
| `c1581_mem_bridge.vhd` | `t_mem_req_32`/`t_mem_resp_32` to the Avalon-style `avm_*` bus that M2M uses for HyperRAM |

The drive keeps its ROM, its RAM and the whole disk image in HyperRAM rather
than in block RAM, which is why adding it cost no BRAM at all:

| HyperRAM window | Contents |
|:----------------|:---------|
| `C_HMAP_1581_MEM` | drive RAM, 32 KB |
| `C_HMAP_1581_ROM` | drive DOS ROM, 32 KB, loaded from `/c64/1581.rom` |
| `C_HMAP_1581_IMG` | the `*.d81`, 819200 bytes |

See `CORE/vhdl/globals.vhd` for the addresses.

Sector addressing is the plain `.d81` layout - 80 tracks, 2 sides, 10 sectors
of 512 bytes:

```
offset = (((track * 2) + side) * 10 + (sector - 1)) * 512
```

Using it
--------

The drive is **device 9**. The core's own C1541 is device 8 and answers on the
IEC bus whether or not a disk is mounted, so both drives on 8 would reply to
the same ATN. Load from the 1581 with `,9`:

```
LOAD"$",9
LOAD"SOMETHING",9,1
```

Two things have to be on the SD card, both read at runtime and both optional as
far as booting goes:

* `/c64/1581.rom` - a 1581 DOS dump. Without it the drive stays in reset: it is
  an optional auto-load ROM, so the core still boots, but the drive's 6502
  would otherwise fetch its reset vector out of uninitialised HyperRAM.
* at least one `*.d81`, anywhere the file browser can reach it.

`CORE/mksdcard.sh` reports on both.

Writes go to the copy of the image in HyperRAM and are **not** written back to
the SD card. They last until the image is replaced or the core is reset.

Still to do
-----------

* Write the image back to the SD card so changes survive.
* A menu item for the device number, instead of hard-coding 9 in `main.vhd`.
* CMD FD-2000/4000, which is the reason for wanting a working 1581 in the first
  place. See `doc/cmd_devices.md`.
