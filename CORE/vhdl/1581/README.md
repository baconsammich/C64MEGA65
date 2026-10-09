C1581 from the 1541 Ultimate
============================

VHDL sources for a Commodore 1581 disk drive, vendored from the
[1541 Ultimate](https://github.com/GideonZ/1541ultimate) project by Gideon
Zweijtzer. That project is licensed under the GNU General Public License v3,
the same licence as C64MEGA65, so the code can be reused here with attribution.
Every file carries a provenance header; nothing has been modified except for
adding that header.

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
| `sim/` | two simulation-only packages, plus Gideon's own 1581 testbench (`c1581_startup_tc.vhd`, `harness_c1581.vhd`) |

Checking them
-------------

```bash
cd CORE/vhdl/test
./analyze_1581.sh
```

Analyses all 32 files and elaborates `c1581_drive`. These sources need
different GHDL settings from the rest of the tree - `--std=93` (one sim-only
package uses `default` as an identifier, which VHDL-2008 reserved),
`-fsynopsys` (`cpu6502.vhd` uses `std_logic_unsigned`) and `-frelaxed` - which
is why they get their own script rather than joining `analyze_all.sh`.

For synthesis only the 30 files outside `sim/` are needed: the two sim-only
packages are referenced from inside `-- synthesis translate_off` regions.

Still to do
-----------

The drive compiles and elaborates, but is **not yet wired into the core**. It
needs an adapter between its two buses and what M2M provides:

* `io_req`/`io_resp` (read/write, 24-bit address, 8-bit data) to QNICE's device
  bus (`qnice_dev_*`, 28-bit address, 16-bit data), so the Shell can mount
  images and poll drive status.
* `mem_req`/`mem_resp` (32-bit data, 26-bit address, tagged) to HyperRAM. The
  existing `reu_mapper.vhd` is the precedent for a device mastering HyperRAM
  from the core clock domain, and `avm_increase`/`avm_decrease` in
  `M2M/vhdl/memory` handle the 32-to-16-bit width change. The disk image would
  live in its own `C_HMAP_*` window, as CRT files already do.
* IEC lines to the C64, alongside the existing C1541.

See `doc/cmd_devices.md` for the wider plan, including CMD FD-2000/4000, which
is the reason for wanting a working 1581 in the first place.
