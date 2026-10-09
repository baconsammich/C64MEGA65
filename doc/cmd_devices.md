CMD device support: design notes
================================

Design notes for emulating four Creative Micro Designs peripherals on the
C64 for MEGA65 core:

| Device | What it is | Assessment |
|:-------|:-----------|:-----------|
| CMD FD-2000/4000 | 3.5" IEC floppy drive, 32K DOS ROM | Cheapest to attempt |
| RAMLink | Expansion-port RAM disk, 64K DOS ROM | Self-contained |
| CMD HD | SCSI hard drive on IEC, 32K boot ROM | Viable, needs a new drive model |
| SuperCPU | 65816 accelerator, 128K ROM | Hardest by a wide margin |

**Status:** step 1 is done - the dormant C1581 is enabled and `*.d81` images
are recognised, which is the prerequisite for CMD FD. Everything else below is
still a plan, written after surveying what the core already provides. Statements are marked *(verified)* where they were
checked against the source, and *(unverified)* where they rest on general
knowledge of the hardware and still need confirmation against the CMD
documentation and VICE's implementation.

Ground rules
------------

### ROMs must never enter the repository

All four devices need copyrighted CMD ROM images. The core already has the
right mechanism for this and it must be used: ROMs live on the SD card and are
loaded at runtime, exactly as JiffyDOS already is. No ROM, and no disk or
drive image, may be committed.

`CORE/vhdl/globals.vhd` *(verified)*:

```vhdl
constant JIFFY_DOS_C64    : string := "/c64/jd-c64.bin" & ENDSTR;
constant JIFFY_DOS_C1541  : string := "/c64/jd-c1541.bin" & ENDSTR;

constant C_CRTROMS_AUTO_NUM   : natural := 2;   -- maximum is 16
constant C_CRTROMS_AUTO_NAMES : string  := JIFFY_DOS_C64 & JIFFY_DOS_C1541;
constant C_CRTROMS_AUTO       : crtrom_buf_array := (
   C_CRTROMTYPE_DEVICE, C_DEV_C64_KERNAL_C64,   C_CRTROMTYPE_OPTIONAL, JIFFY_DOS_C64_START,
   C_CRTROMTYPE_DEVICE, C_DEV_C64_KERNAL_C1541, C_CRTROMTYPE_OPTIONAL, JIFFY_DOS_C1541_START,
   x"EEEE");
```

Adding a ROM means: a new `C_DEV_*` device ID, a filename constant plus its
start offset into the concatenated `C_CRTROMS_AUTO_NAMES` string, a bump of
`C_CRTROMS_AUTO_NUM`, and wiring the device in the `qnice_ramrom_devices`
process in `mega65.vhd`. Mark CMD ROMs `C_CRTROMTYPE_OPTIONAL` so the core
still boots for users who do not own them - `C_CRTROMTYPE_MANDATORY` makes the
core go fatal when the file is missing. Note the framework does no consistency
checking on `C_CRTROMS_AUTO_NAMES`, so the offsets must be exactly right.

### Two repositories are involved

The drive models live in `CORE/C64_MiSTerMEGA65`, which is a **submodule**
pointing at `MJoergen/C64_MiSTerMEGA65`. Anything touching `iec_drive.sv`,
`c1581_*.sv` or `fdc1772.v` has to be committed there, with the parent repo
then updated to the new submodule commit. Work on CMD FD and CMD HD therefore
needs a fork of the submodule as well as of this repository; RAMLink and
SuperCPU can largely be done in this repository alone.

What the core already provides
------------------------------

All *(verified)*.

### Runtime ROM loading

Two paths: `C_CRTROMS_AUTO` (loaded before the core starts, used by JiffyDOS)
and `C_CRTROMS_MAN` (loaded on demand from the on-screen menu, used by the PRG
and CRT loaders). Both can target a QNICE device, HyperRAM, or SDRAM
(reserved). Up to 16 entries each.

### A free expansion-port mode

`CORE/vhdl/mega65.vhd`:

```vhdl
signal c64_exp_port_mode    : natural range 0 to 2;
signal hr_c64_exp_port_mode : std_logic_vector(1 downto 0);

constant C_MENU_EXP_PORT_HW  : natural := 7;
constant C_MENU_EXP_PORT_REU : natural := 8;
constant C_MENU_EXP_PORT_CRT : natural := 9;
```

Modes 0 (hardware slot), 1 (1750 REU) and 2 (simulated cartridge) are in use.
The clock-domain-crossing register `hr_c64_exp_port_mode` is **already two bits
wide**, so a fourth mode costs nothing structurally - only the `natural range`
and the menu need widening.

### Banked ROM in cartridge space

`crt_loader` -> `crt_parser` -> `crt_cacher` -> `sw_cartridge_wrapper` stores a
whole CRT file in HyperRAM and keeps the last eight 8K banks in BRAM, pausing
the CPU with DMA while a bank is filled. This exists because HyperRAM latency
(worst case ~1500 ns) far exceeds the C64's 500 ns bus half-cycle, so the CPU
cannot execute from HyperRAM directly. Any CMD ROM that lives in cartridge
space should reuse this pattern rather than invent another.

### Large RAM behind HyperRAM

`CORE/vhdl/reu_mapper.vhd` bridges a 25-bit (32 MB) address space onto
HyperRAM for the simulated 1750 REU, handshaking with `reu_ext_cycle`. This
works because REU transfers are block moves during which the CPU is halted -
latency is amortised. The HyperRAM map is in `globals.vhd`:

```vhdl
constant C_HMAP_M2M : std_logic_vector(15 downto 0) := x"0000";  -- framework
constant C_HMAP_CRT : std_logic_vector(15 downto 0) := x"0200";  -- CRT files
```

A new device needs its own non-overlapping window here.

### A complete IEC drive framework

`CORE/C64_MiSTerMEGA65/rtl/iec_drive/` contains drive models that run the
**real drive DOS on a T65 soft 6502** behind the IEC bus, with a block-device
interface served by QNICE from the SD card:

```systemverilog
module iec_drive #(parameter PARPORT=1, DUALROM=1, DRIVES=2)
   input  [1:0] img_type,   // 00=1541 D64, 01=1541 real GCR, 10=1581 D81
   output [31:0] sd_lba[NDR];  output [5:0] sd_blk_cnt[NDR];
   output sd_rd, sd_wr;  input sd_ack;
   input  [13:0] sd_buff_addr;  // 16K block window
   input  [15:0] rom_addr_i;  input [7:0] rom_data_i;  input rom_wr_i, rom_std_i;
```

Relevant details:

* `sd_lba` is **32 bits**, so the block interface can already address far more
  than any CMD device needs.
* `rom_addr_i` is 16 bits and the commented-out 1581 instantiation uses
  `rom_addr[15]` as the selector between the 1541 and 1581 ROM spaces - so
  there is already a defined way to load a second drive ROM.
* `DUALROM=1` gives each drive two switchable ROM sets; this is how JiffyDOS
  is selected at runtime, and the same path suits a CMD DOS.
* `DRIVES` is clamped to a **maximum of 4** (`NDR` in `iec_drive.sv`).
* `main.vhd` instantiates it with `PARPORT => 0` (DolphinDOS parallel port
  disabled), `DUALROM => 1`, `DRIVES => G_VDNUM`.
* `globals.vhd` sets `C_VDNUM := 1` (maximum 15) with a single mount buffer
  `C_DEV_C64_MOUNT`. More drives need more `C_VD_BUFFER` entries and menu
  mount points.

### A dormant C1581

This is the most useful find. The submodule already contains a full 1581:
`c1581_drv.sv` (T65 CPU), `c1581_multi.sv`, `c1581_rom.mif` (32K DOS),
`fdc1772.v` (WD177x floppy controller), `floppy.v`, `iecdrv_mos8520.v` (CIA).

It is **disabled, not missing**. In `iec_drive.sv` the instantiation is
commented out with an explicit note:

```systemverilog
/* //When commenting-in this here, don't forget to comment-in above
   //c1581_iec_data, c1581_iec_clk, c1581_led
c1581_multi #(.PARPORT(PARPORT), .DUALROM(DUALROM), .DRIVES(DRIVES)) c1581
```

The signals themselves are still *declared* (lines 134-136); what is commented
out is the instantiation plus five **uses** of them, which all have to be
restored together:

```systemverilog
66: assign led        = /*c1581_led      |*/ c1541_led;
67: assign iec_data_o = /*c1581_iec_data &*/ c1541_iec_data;
68: assign iec_clk_o  = /*c1581_iec_clk  &*/ c1541_iec_clk;
97:   .iec_data_i(iec_data_i /*& c1581_iec_data */),   // inside c1541_multi
98:   .iec_clk_i (iec_clk_i  /*& c1581_iec_clk */),
```

Worth noting while in here: line 69 is *not* commented out -

```systemverilog
69: assign par_stb_o = c1581_stb_o & c1541_stb_o;
```

`c1581_stb_o` is declared but, with the 1581 instantiation commented out,
never driven - so it floats into `par_stb_o`. It is harmless today only
because `main.vhd` instantiates `iec_drive` with `PARPORT => 0`, but it is a
trap for anyone enabling the parallel port (the DolphinDOS ROADMAP item)
without also enabling the 1581.

Note also that the 1581 is wired with `.sd_buff_addr(sd_buff_addr[8:0])` - a
512-byte window, narrower than the 14-bit port the module exposes.

`dtype[1]` is already the 1541/1581 selector (`reset | dtype[1]` versus
`reset | ~dtype[1]`), and `main.vhd` already carries `img_type` with `10` meaning
1581/`.d81`. The five 1581 files are simply **not in the Vivado projects** -
`CORE-R3/R4/R5/R6.xpr` list only the 1541 sources. Also absent from the
projects: `c1541_direct_gcr.sv` (raw GCR mode) and `c1541_dolphin.mif`
(DolphinDOS), both of which are open ROADMAP items.

1. CMD FD-2000/4000
-------------------

**Why first.** The FD series is architecturally a close cousin of the 1581 -
a 65C02, a CIA, and a WD177x-class controller driving 3.5" disks
*(unverified: needs confirmation against CMD's documentation)*. The 1581 model
is already written and merely switched off, and the ROM sizes match exactly
*(verified)*:

| Socket | Size | Candidate ROM | Size |
|:-------|-----:|:--------------|-----:|
| `c1541_rom` | 16384 | JiffyDOS 1541-II | 16384 |
| `c1581_rom` | 32768 | CMD FD DOS (`CMD FD DOS COPYRIGHT 1992`) | 32768 |

So the plausible shape is: switch the 1581 on, then load CMD FD DOS into its
ROM socket instead of the Commodore 1581 DOS.

**Steps.**

1. In the submodule, uncomment the `c1581_multi` instantiation in
   `iec_drive.sv` and restore the five commented-out uses of
   `c1581_iec_data` / `c1581_iec_clk` / `c1581_led` listed above.
2. Add `c1581_drv.sv`, `c1581_multi.sv`, `fdc1772.v`, `floppy.v` and
   `iecdrv_mos8520.v` to all four `CORE-R*.xpr` projects.
3. Drive `img_type = "10"` when a `.d81` is mounted; extend the virtual-drive
   mount logic and the on-screen menu to offer `.d81`.
4. Confirm the plain Commodore 1581 works first. **This alone closes two
   ROADMAP items** and is a worthwhile deliverable by itself.
5. Only then add CMD FD DOS as a selectable ROM through `C_CRTROMS_AUTO`,
   reusing the `rom_addr[15]` / `DUALROM` path.
6. Decide what FD-4000 native 1.6 MB media means. The 1581 model and `.d81`
   assume 800K; higher-density FD formats may need work in `fdc1772.v` and a
   container format decision.

**Risks.** How close the FD DOS is to running on a 1581's hardware model is
the central unknown - if the FD's register map or FDC differs materially, this
becomes a new drive model rather than a ROM swap. The FD-2000 at 800K is the
best first target because it is `.d81`-compatible. Resolve this by comparing
the FD DOS's I/O accesses against the 1581 model before writing code.

2. RAMLink
----------

**Why attractive.** It needs no submodule changes, and both halves of it map
onto machinery the core already has.

**Design.**

* Add expansion-port mode 3. `hr_c64_exp_port_mode` is already 2 bits, so only
  `c64_exp_port_mode`'s `natural range 0 to 2` and the menu change.
* Its 64K DOS ROM maps into cartridge space in 8K banks - the `crt_cacher`
  pattern, unchanged.
* Its RAM is used as a RAM **disk**: block-oriented, latency-tolerant, so it
  belongs behind HyperRAM via a `reu_mapper`-style bridge with its own
  `C_HMAP_*` window. `ramlink.rl` (8 MB) suggests the RAM size to support.
* RAMLink also provides a pass-through expansion port and a RAM-Port for an
  REU *(unverified)*. Decide early whether to emulate those at all; the
  simplest useful version is RAMLink alone, with no pass-through.

**Steps.** Study VICE's RAMLink implementation for the register map and
behaviour; define the register interface; map the ROM; map the RAM; add the
menu entry; test with `RAMLink.[81].d81` and the RAMDRIVE utilities on the
CMD HD image.

**Risks.** RAMLink patches the KERNAL and is reportedly timing-sensitive
*(unverified)*. Its interaction with the existing REU and simulated-cartridge
modes needs care - they contend for the same expansion-port path and HyperRAM
bandwidth. GEOS support is a distinct body of work: the ROM contains GEOS
hooks *(verified: a `GEOS format` string appears in `ramlink201.bin`)*.

3. CMD HD
---------

**Now viable.** A drive image exists. Its structure *(verified by inspection
of `HD0.img`)*:

```
4294967295 bytes (exactly 4 GiB - 1), raw 512-byte sectors
LBA     0 - 385   zeros
LBA   386         "CMD HD  " signature
LBA   391         "CMD HD DOS COPYRIGHT 1990 CREATIVE MICRO DESIGNS, INC."
LBA   444         second DOS copy (backup)
~16 MB            populated partitions: CMDUTILS 1/2, FDUTILS, RAMLINK,
                  RAMDRIVE 2.0/1.4, SMARTTRACK, GAMES, 1750XL UTILS, HDUTILS
DOS versions 1.92 and 2.00, both dated 03/22/96
```

The 32K boot ROM only bootstraps; the real DOS lives in the image's system
area, which is why the image was the missing piece.

**Note the file size.** 4 GiB - 1 is exactly the FAT32 maximum file size, so
`HD0.img` will *just* fit on an SD card - with no margin. `img_size` in
`iec_drive` is 32 bits, which also accommodates it exactly. Smaller images
would be more comfortable, and it is worth checking whether QNICE's FAT32
stack handles a file at the limit.

**Design.** Follow the 1541/1581 pattern: the real CMD HD DOS running on a T65
behind IEC. The SCSI layer is replaced by plain 512-byte block reads against
the image - the `sd_lba`/`sd_rd`/`sd_wr`/`sd_buff_*` interface already does
exactly this, and it is arguably *simpler* than the GCR floppy emulation the
core already performs.

**Steps.** Establish the CMD HD's controller hardware (CPU type, RAM, register
map, how the boot ROM reaches the disk) from the documentation; build a drive
model alongside `c1541_drv.sv`/`c1581_drv.sv`; map its disk access onto the
existing block interface; extend `img_type` (currently a 2-bit field with
three values used, so a fourth fits) and the mount logic for a new image type;
raise `C_VDNUM` and add a mount buffer if the HD is to coexist with a floppy.

**Risks.** This is a new drive model, not a ROM swap - the largest unknown is
the controller's register map. Partition handling and the native/1541-emulation
partition modes are substantial DOS surface. A 4 GiB image is awkward to
handle; consider supporting a truncated image for development.

4. SuperCPU
-----------

**Hardest by a wide margin.** Attempt last.

**The CPU.** `CORE/C64_MiSTerMEGA65/rtl/t65/` is already in the tree, and T65's
ALU and microcode declare a mode encoding `"00" => 6502, "01" => 65C02,
"10" => 65816` *(verified)*. **How complete that 65816 datapath is has not been
established** - T65 is primarily a 6502/65C02 core and its 65816 support may
not cover native mode, 16-bit registers or bank addressing. Evaluating this is
the first task, and its outcome decides whether SuperCPU is weeks or months of
work: either T65 can be driven in 65816 mode, or a 65816 core must be sourced
or written.

**Memory.** This is what makes SuperCPU conceivable at all. It does not execute
from the C64's bus at speed; it runs from its own fast memory, synchronising to
the 1 MHz bus only for I/O *(unverified - confirm against the documentation and
VICE's `xscpu64`)*. That means:

* ~64K shadow RAM plus the 128K ROM is roughly 192K, which fits comfortably in
  the Artix-7 **200T**'s ~1.6 MB of BRAM *(verified: `xc7a200tfbg484-2` on both
  R3 and R6)* - though BRAM is already committed to the OSM, disk buffers, the
  cartridge bank cache and ascal's line buffers, so **measuring current BRAM
  utilisation is a prerequisite**.
* SuperRAM (up to 16 MB) is bulk memory accessed in a block-like fashion, so it
  can go to HyperRAM via the `reu_mapper` pattern.

Crucially, this is the one device where the HyperRAM latency constraint that
shaped the cartridge cache **cannot** be worked around by caching: a 20 MHz
CPU needs memory every ~50 ns against HyperRAM's ~1500 ns worst case. If the
shadow-RAM architecture turns out not to hold, the design does not close.

**Risks.** Three, any of which can sink it: T65's 65816 completeness; exact
bus and I/O synchronisation semantics, including SuperCPU's speed and
optimisation modes; and timing closure at 20 MHz in a design that already
fills a large part of the device. Note also that the available documentation is
the SuperCPU **128** V2 guide while `scpu.rom` is the SuperCPU **64** ROM -
overlapping but not identical.

Suggested order, and what to prototype first
--------------------------------------------

1. **Enable the plain C1581 and `.d81` support.** Smallest change, immediate
   user-visible value, closes two ROADMAP items, and establishes whether the
   dormant 1581 actually works - which everything in the CMD FD plan depends
   on. Do this before writing any CMD-specific code.
2. **RAMLink.** Self-contained, no submodule fork, reuses two proven patterns.
3. **CMD FD DOS on the working 1581.** Only meaningful once step 1 is done.
4. **CMD HD.** A new drive model; worth it once the IEC drive path is familiar.
5. **SuperCPU.** Begin with a written evaluation of T65's 65816 mode and a BRAM
   utilisation measurement. Do not start RTL until both come back favourably.

Before any of it, two cheap pieces of groundwork pay for themselves:

* **Measure BRAM and LUT utilisation** of the current build. Several of these
  devices need block RAM, and SuperCPU's feasibility turns on it. The answer is
  a Vivado report away and nobody has to guess.
* **Extend the CI testbenches** as each device lands. `tb_crt_parser` shows the
  pattern: a self-contained, self-checking testbench with no external input.
  For RAMLink in particular, a register-level testbench is far cheaper than
  debugging on hardware.

Open questions
--------------

* Does QNICE's FAT32 stack handle a file of exactly 4 GiB - 1?
* How complete is T65's 65816 mode?
* What is the current BRAM/LUT utilisation headroom?
* Is the CMD FD's register map close enough to the 1581's for a ROM swap?
* What is the CMD HD controller's register map, and how does the boot ROM
  reach the disk?
* Should RAMLink's expansion pass-through and RAM-Port be emulated at all?
* How should devices coexist - can RAMLink and a CMD HD be active together,
  and what does the menu look like when they can?

References
----------

* VICE emulates RAMLink and ships `xscpu64` for the SuperCPU; both are
  open-source behavioural references. The ROM images in circulation
  (`scpu.rom` at 128K, `ramlink201.bin` at 64K) are in VICE's layout.
* CMD RAMLink User's Manual; CMD SuperCPU 128 V2 User's Guide.
* Utility disks: `RAMLink.d81`, `SUPERCPU.d81`, `HDUTILS.d81`,
  `FD-2000-FDUTILS.d81`.
* `doc/developer.md` - testbench setup, and the HyperRAM latency discussion
  that explains the cartridge bank cache.
