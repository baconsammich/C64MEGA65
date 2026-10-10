; ****************************************************************************
; Commodore 64 for MEGA65 (C64MEGA65) QNICE ROM
;
; Main program that is used to build m2m-rom.rom by make-rom.sh.
; The ROM is loaded by qnice.vhd
;
; The execution starts at the label START_FIRMWARE.
;
; done by sy2002 in 2023 and licensed under GPL v3
; ****************************************************************************

; If the define RELEASE is defined, then the ROM will be a self-contained and
; self-starting ROM that includes the Monitor (QNICE "operating system") and
; jumps to START_FIRMWARE. In this case it is assumed, that the firmware is
; located in ROM and the variables are located in RAM.
;
; If RELEASE is not defined, then it is assumed that we are in the develop and
; debug mode so that the firmware runs in RAM and can be changed/loaded using
; the standard QNICE Monitor mechanisms such as "M/L" or QTransfer.

#define RELEASE

; ----------------------------------------------------------------------------
; Firmware: M2M system
; ----------------------------------------------------------------------------

; main.asm is the mandatory, so always include it
; It jumps to START_FIRMWARE (see below) after the QNICE "operating system"
; called "Monitor" has been included and initialized
#include "../../M2M/rom/main.asm"

; The C64 core uses the Shell of MiSTer2MEGA65
#include "../../M2M/rom/shell.asm"

; ----------------------------------------------------------------------------
; Firmware: Main Code
; ----------------------------------------------------------------------------

START_FIRMWARE  RBRA    START_SHELL, 1

; ----------------------------------------------------------------------------
; Core specific callback functions: Submenus
; ----------------------------------------------------------------------------

; SUBMENU_SUMMARY callback function:
;
; Called when displaying the main menu for every %s that is found in the
; "headline" / starting point of any submenu in config.vhd: You are able to
; change the standard semantics when it comes to summarizing the status of the
; very submenu that is meant by the "headline" / starting point.
;
; Input:
;   R8: pointer to the string that includes the "%s"
;   R9: pointer to the menu item within the M2M$CFG_OPTM_GROUPS structure
;  R10: end-of-menu-marker: if R9 == R10: we reached end of the menu structure
; Output:
;   R8: 0, if no custom SUBMENU_SUMMARY, else:
;       string pointer to completely new headline (do not modify/re-use R8)
;   R9, R10: unchanged

SUBMENU_SUMMARY XOR     R8, R8                  ; R8 = 0 = no custom string
                RET

; ----------------------------------------------------------------------------
; Core specific callback functions: File browsing and disk image mounting
; ----------------------------------------------------------------------------

; FILTER_FILES callback function:
;
; Called by the file- and directory browser. Used to make sure that the 
; browser is only showing valid files and directories.
;
;
; Input:
;   R8: Name of the file in capital letters
;   R9: 0=file, 1=directory
;  R10: Context (CTX_* constants in sysdef.asm)
;  R11: Menu group id (see config.vhd) of the menu item that is responsible
;       for triggering FILTER_FILES
; Output:
;   R8: 0=do not filter file, i.e. show file
FILTER_FILES    INCRB
                MOVE    R9, R0
        
                CMP     1, R9                   ; do not filter directories
                RBRA    _FFILES_RET_0, Z

                ; Context: Mount virtual drive
                CMP     CTX_MOUNT_DISKIMG, R10
                RBRA    _FFILES_1, !Z

                ; does this file have the ".D64" file extension?
                MOVE    C64_IMGFILE_D64, R9
                RSUB    M2M$CHK_EXT, 1
                RBRA    _FFILES_RET_0, C        ; yes: do not filter it

                ; ... or the ".D81" extension (1581 disk image)?
                MOVE    C64_IMGFILE_D81, R9
                RSUB    M2M$CHK_EXT, 1
                RBRA    _FFILES_RET_0, C        ; yes: do not filter it

_FFILES_DOFLT   MOVE    1, R8                   ; no: filter it
                RBRA    _FFILES_RET, 1

                ; Context: Load cartridge ROM file
_FFILES_1       CMP     CTX_LOAD_ROM, R10
                RBRA    _FFILES_RET_0, !Z       ; do not filter in other CTXs

                ; menu item "PRG:<Load>"
                CMP     C64_OPTM_G_LOAD_PRG, R11
                RBRA    _FFILES_2, !Z
                MOVE    C64_PRGFILE, R9
                RBRA    _FFILES_3, 1

                ; menu item "D81:<Load>" (1581 disk image)
_FFILES_2       CMP     C64_OPTM_G_LOAD_D81, R11
                RBRA    _FFILES_2B, !Z
                MOVE    C64_IMGFILE_D81, R9
                RBRA    _FFILES_3, 1

                ; menu item "CRT:<Load>"
_FFILES_2B      CMP     C64_OPTM_G_MOUNT_CRT, R11
                RBRA    _FFILES_RET_0, !Z
                MOVE    C64_CRTFILE, R9

                ; does this file have the right file extension?
_FFILES_3       RSUB    M2M$CHK_EXT, 1
                RBRA    _FFILES_DOFLT, !C       ; no: filter it

_FFILES_RET_0   XOR     R8, R8                  ; do not filter

_FFILES_RET     MOVE    R0, R9
                DECRB
                RET

; PREP_LOAD_IMAGE callback function:
;
; Some images need to be parsed, for example to extract configuration data or
; to move the file read pointer to the start position of the actual data.
; Sanity checks ("is this a valid file") can also be implemented here.
; Last but not least: The mount system supports the concept of a 2-bit
; "image type". In case this is used at the core of your choice, make sure
; you return the correct image type.
;
; Input:
;   R8: File handle: You are allowed to modify the read pointer of the handle
;   R9: Context (CTX_* constants in sysdef.asm)
;  R10: Menu group id (see config.vhd) of the menu item that is responsible
;       for triggering PREP_LOAD_IMAGE
; Output:
;   R8: 0=OK, error code otherwise
;   R9: image type if R8=0, otherwise 0 or optional ptr to error msg string
PREP_LOAD_IMAGE INCRB

                ; Context CRT/ROM loading: Do not check the file-size
                CMP     CTX_LOAD_ROM, R9
                RBRA    _PREP_LI_START, !Z
                XOR     R8, R8
                XOR     R9, R9
                RBRA    _PREP_LI_RET, 1

                ; Context is disk image loading: We check for valid disk
                ; image sizes as defined in D64_STDSIZE_L and D64_STDSIZE_H
_PREP_LI_START  MOVE    R8, R0
                MOVE    R0, R1

                ADD     FAT32$FDH_SIZE_LO, R0
                MOVE    @R0, R0                 ; R0: low word of file size
                ADD     FAT32$FDH_SIZE_HI, R1
                MOVE    @R1, R1                 ; R1: high word of file size

                ; check if the D64 filesize equals one of the valid variants
                MOVE    D64_VARIANT_CNT, R2     ; R2: amount of valid variants
                MOVE    D64_STDSIZE_L, R3       ; R3: table of valid lo words
                MOVE    D64_STDSIZE_H, R4       ; R4: table of valid hi words

_PREP_LI_CMP    MOVE    @R3++, R5               ; R5: valid lo word
                MOVE    @R4++, R6               ; R6: valid hi word

                CMP     R5, R0                  ; lo word equals table entry?
                RBRA    _PREP_LI_NEXT, !Z       ; no: check next variant
                CMP     R6, R1                  ; hi word equals table entry?
                RBRA    _PREP_LI_OK, Z          ; yes: correct filesize

_PREP_LI_NEXT   SUB     1, R2                   ; next variant
                RBRA    _PREP_LI_CMP, !Z

                ; Not a valid D64, so try the D81 sizes (1581 disk image)
                MOVE    D81_VARIANT_CNT, R2     ; R2: amount of valid variants
                MOVE    D81_STDSIZE_L, R3       ; R3: table of valid lo words
                MOVE    D81_STDSIZE_H, R4       ; R4: table of valid hi words

_PREP_LI_C81    MOVE    @R3++, R5               ; R5: valid lo word
                MOVE    @R4++, R6               ; R6: valid hi word

                CMP     R5, R0                  ; lo word equals table entry?
                RBRA    _PREP_LI_N81, !Z        ; no: check next variant
                CMP     R6, R1                  ; hi word equals table entry?
                RBRA    _PREP_LI_OK81, Z        ; yes: correct filesize

_PREP_LI_N81    SUB     1, R2                   ; next variant
                RBRA    _PREP_LI_C81, !Z

                ; filesize matches neither a D64 nor a D81
                MOVE    1, R8                   ; R8: error code
                MOVE    WRN_WRONG_IMG, R9       ; R9: error message
                RBRA    _PREP_LI_RET, 1

                ; filesize correct: 1581 disk image
_PREP_LI_OK81   XOR     R8, R8                  ; no errors
                MOVE    C64_IMGTYPE_D81, R9     ; image type: D81 (1581)
                RBRA    _PREP_LI_RET, 1

                ; filesize correct: 1541 disk image
_PREP_LI_OK     XOR     R8, R8                  ; no errors
                MOVE    C64_IMGTYPE_D64, R9     ; image type: D64 (1541)

_PREP_LI_RET    DECRB
                RET

; ----------------------------------------------------------------------------
; Core specific callback functions: Custom tasks
; ----------------------------------------------------------------------------

; PREP_START callback function:
;
; Called right before the core is being started. At this point, the core
; is ready to run, settings are loaded (if the core uses settings) and the
; core is still held in reset (if RESET_KEEP is on). So at this point in time,
; you can execute tasks that change the run-state of the core.
;
; Input: None
; Output:
;   R8: 0=OK, else pointer to string with error message
;   R9: 0=OK, else error code
PREP_START      INCRB

                ; Check if JiffyDOS is configured as the default Kernal but
                ; the JiffyDOS ROMs cannot be found: In this case we switch
                ; back to the default Kernal.
                ;
                ; In globals.vhd we configured the JiffyDOS ROMs to be ROM #0
                ; and ROM #1, that means if both of them are loaded correctly,
                ; then the elements #0 and #1 of the CRTROM_AUT_LDF array
                ; should both be 1.
                MOVE    C64_OSM_KERNAL_JIFFY, R8
                RSUB    M2M$GET_SETTING, 1
                CMP     1, R9
                RBRA    PREP_START_R, !Z

                MOVE    CRTROM_AUT_LDF, R0
                MOVE    @R0++, R1
                ADD     @R0, R1
                CMP     2, R1
                RBRA    PREP_START_R, Z

                MOVE    WRN_JIFFY, R8           ; output warning on dbg cnsl
                SYSCALL(puts, 1)

                MOVE    C64_OSM_KERNAL_JIFFY, R8
                XOR     R9, R9
                RSUB    M2M$SET_SETTING, 1
                MOVE    C64_OSM_KERNAL_STD, R8
                MOVE    1, R9
                RSUB    M2M$SET_SETTING, 1

                ; Tell the core whether the C1581 DOS ROM made it into
                ; HyperRAM.
                ;
                ; /c64/1581.rom is an *optional* auto-load ROM (globals.vhd),
                ; because the core must boot on an SD card that does not carry
                ; it. But the drive cannot run without it: its 6502 would fetch
                ; a reset vector out of uninitialised HyperRAM. So publish the
                ; load flag and let main.vhd hold the drive in reset until both
                ; this and a mounted *.d81 are present.
                ;
                ; This runs here rather than in OSM_SEL_POST because auto-load
                ; ROMs are fetched during start-up, long before the user can
                ; open the menu.
PREP_START_R    MOVE    CRTROM_AUT_LDF, R0
                ADD     C64_CRTROM_AUT_1581, R0
                MOVE    @R0, R1                 ; R1: 1 = DOS ROM is loaded
                AND     0x0001, R1
                ADD     R1, R1                  ; -> gp_reg bit 1. Doubling
                                                ; rather than SHL, because
                                                ; the QNICE SHL shifts the X flag
                                                ; in from the right.
                MOVE    M2M$CFD_ADDR, R0
                MOVE    0, @R0                  ; window 0 = gp_reg bits 15..0
                MOVE    M2M$CFD_DATA, R0
                MOVE    @R0, R2
                AND     0xFFFD, R2              ; clear bit 1
                OR      R1, R2
                MOVE    R2, @R0

                XOR     R8, R8
                XOR     R9, R9

                DECRB
                RET

; OSM_SEL_POST callback function:
;
; Called each time the user selects something in the on-screen-menu (OSM),
; and while the OSM is still visible. This means, that this callback function
; is called on each press of one of the valid selection keys with the
; exception that pressing a selection key while hovering over a submenu entry
; or exit point does not call this function. All the functionality and
; semantics associated with a certain menu item is already handled by the
; framework when OSM_SELECTED is called, so you are not able to change the
; basic semantics but you are able to add core specific additional
; "intelligent" semantics and behaviors.
;
; Input:
;   R8: selected menu group (as defined in config.vhd)
;   R9: selected item within menu group
;       in case of single selected items: 0=not selected, 1=selected
;   R10: OPTM_KEY_SELECT (by default means "Return") or
;        OPTM_KEY_SELALT (by default means "Space")
; Output:
;   R8: 0=OK, else pointer to string with error message
;   R9: 0=OK, else error code
OSM_SEL_POST    INCRB

                ; Tell the core when a *.d81 has been loaded into HyperRAM.
                ;
                ; The C1581 (CORE/vhdl/1581) reads its disk image straight out
                ; of HyperRAM, so unlike the 1541 it is not driven by the
                ; virtual drive system and has no "mounted" signal of its own.
                ; The load itself is done by the framework because the menu item
                ; carries OPTM_G_LOAD_ROM; all that is left is to publish the
                ; result, which goes through the 256-bit general purpose
                ; register that the core sees as qnice_gp_reg.
                ;
                ; CRTROM_MAN_LDF is the array of "has been loaded" flags for
                ; manually loadable ROMs, in the order they appear in
                ; C_CRTROMS_MAN in globals.vhd: 0 = D81, 1 = PRG, 2 = CRT.
                CMP     C64_OPTM_G_LOAD_D81, R8
                RBRA    _OSM_SEL_POST_1, !Z
                MOVE    CRTROM_MAN_LDF, R0
                ADD     C64_CRTROM_MAN_D81, R0
                MOVE    @R0, R1                 ; R1: 1 = image is loaded
                MOVE    M2M$CFD_ADDR, R0
                MOVE    0, @R0                  ; window 0 = gp_reg bits 15..0
                MOVE    M2M$CFD_DATA, R0
                MOVE    @R0, R2
                AND     0xFFFE, R2              ; clear bit 0
                OR      R1, R2                  ; bit 0 = a disk is in the drive
                MOVE    R2, @R0

                ; auto-reset if the user changes the kernal mode
_OSM_SEL_POST_1 CMP     C64_OPTM_G_KERNAL_MODES, R8
                RBRA    _OSM_SEL_POST_R, !Z
                MOVE    M2M$CSR, R0             ; control and status register
                OR      M2M$CSR_RESET, @R0      ; reset the core
                AND     M2M$CSR_UN_RESET, @R0   ; un-reset the core

_OSM_SEL_POST_R XOR     R8, R8
                XOR     R9, R9

                DECRB
                RET

; OSM_SEL_PRE callback function:
;
; Identical to the OSM_SEL_POST callback function (see above) but it is being
; called before the functionality and semantics associated with a certain
; menu item has been handled by the framework.
OSM_SEL_PRE     INCRB

                ; Tell the C1581 its disk has been taken out, before a new
                ; *.d81 is loaded over the old one.
                ;
                ; This runs before the framework does the loading, which
                ; matters for the second and every later mount: by then the
                ; drive is running, and the Shell is about to overwrite the
                ; disk image in HyperRAM underneath its 6502 and its WD177x
                ; DMA. Dropping "disk present" first takes the drive's ready
                ; line away, so it abandons any transfer instead of reading an
                ; image that is changing under it.
                ;
                ; Note this clears bit 0 only. Bit 1 - "the DOS ROM is loaded,
                ; the drive may run" - stays set, so the drive is NOT reset and
                ; does not repeat its 1.5 s power-on self test. OSM_SEL_POST
                ; puts bit 0 back once the new image is complete, which the
                ; drive sees as a disk change.
                CMP     C64_OPTM_G_LOAD_D81, R8
                RBRA    _OSM_SEL_PRE_1, !Z
                MOVE    M2M$CFD_ADDR, R0
                MOVE    0, @R0                  ; window 0 = gp_reg bits 15..0
                MOVE    M2M$CFD_DATA, R0
                MOVE    @R0, R1
                AND     0xFFFE, R1              ; clear bit 0: no disk
                MOVE    R1, @R0

                ; automatically switch to "Simulate cartridge" if the user
                ; chooses to load a software cartridge
_OSM_SEL_PRE_1  CMP     C64_OPTM_G_MOUNT_CRT, R8
                RBRA    _OSM_SEL_PRE_R, !Z
                MOVE    C64_OSM_EXP_PORT_CRT, R8
                RSUB    M2M$GET_SETTING, 1
                CMP     1, R9                   ; already in sim crt mode?
                RBRA    _OSM_SEL_PRE_R, Z       ; yes, then nothing to do
                MOVE    1, R9                   ; no, then set sim crt mode
                RSUB    M2M$FORCE_MENU, 1

_OSM_SEL_PRE_R  XOR     R8, R8
                XOR     R9, R9

                DECRB
                RET

; ----------------------------------------------------------------------------
; Core specific callback functions: Custom messages
; ----------------------------------------------------------------------------

; CUSTOM_MSG callback function:
;
; Called in various situations where the Shell needs to output a message
; to the end user. The situations and contexts are described in sysdef.asm
;
; Input:
;   R8: Situation (CMSG_* constants in sysdef.asm)
;   R9: Context   (CTX_* constants in sysdef.asm)
; Output:
;   R8: 0=no custom message available, otherwise pointer to string

CUSTOM_MSG      INCRB
                MOVE    R8, R0
                XOR     R8, R8                  ; no custom message

                CMP     CMSG_BROWSENOTHING, R0  ; "no D64" situation?
                RBRA    _CUSTOM_MSG_RET, !Z     ; no: default custom message
                CMP     CTX_MOUNT_DISKIMG, R9   ; trying to mount a disk?
                RBRA    _CUSTOM_MSG_RET, !Z     ; no: default custom message
                MOVE    WRN_NO_D64, R8          ; yes: custom message

_CUSTOM_MSG_RET DECRB
                RET

; ----------------------------------------------------------------------------
; Core specific constants and strings
; ----------------------------------------------------------------------------

; auto-generated file that constains the menu indexes from mega65.vhd
#include "osm_const.asm"

; Warning: At this point we are only supporting standard D64 files
WRN_WRONG_IMG   .ASCII_P "\n\nD64 file size must be exactly 174848 bytes\n"
                .ASCII_P "(35 tracks) or 196608 bytes (40 tracks).\n"
                .ASCII_P "D81 file size must be 819200 or 829440 bytes\n"
                .ASCII_P "(80 or 81 tracks), or 822400/832680 with an\n"
                .ASCII_P "appended error map."
                .ASCII_W "\n\nPress SPACE to continue.\n"

; Warning: Nothing to browse
WRN_NO_D64      .ASCII_P "This core uses D64 disk images.\n\n"
                .ASCII_P "Please copy at least one D64 file\n"
                .ASCII_P "to any sub-directory or to the root\n"
                .ASCII_P "directory of this SD card.\n\n"
                .ASCII_P "If you use a folder called /c64, then\n"
                .ASCII_P "the file browser will always start there.\n\n"
                .ASCII_P "You can use long file names and you can\n"
                .ASCII_P "also use nested sub-directories to nicely\n"
                .ASCII_P "order your collection of D64 files.\n\n"
                .ASCII_P "Nothing to browse.\n\n"
                .ASCII_W "Press Space to continue."

; Warning: JiffyDOS is the currently active but no Jiffy Kernal is available
; This warning is only shown in the debug console
WRN_JIFFY       .ASCII_P "JiffyDOS is the currently active Kernal but the "
                .ASCII_P "JiffyDOS ROMs were not loaded. Switching back to "
                .ASCII_W "the standard Kernal.\n"

; C64 specific file extensions (need to be upper case)
C64_IMGFILE_D64 .ASCII_W ".D64"
C64_IMGFILE_G64 .ASCII_W ".G64"
C64_IMGFILE_D81 .ASCII_W ".D81"
C64_CRTFILE     .ASCII_W ".CRT"
C64_PRGFILE     .ASCII_W ".PRG"

; C64 disk image types
C64_IMGTYPE_D64 .EQU    0x0000  ; 1541 emulated GCR: D64
C64_IMGTYPE_G64 .EQU    0x0001  ; 1541 real GCR mode: G64, D64
C64_IMGTYPE_D81 .EQU    0x0002  ; 1581: D81

; Index of the C1581 DOS ROM within C_CRTROMS_AUTO in globals.vhd
C64_CRTROM_AUT_1581 .EQU 0x0002

; Index of the *.d81 entry within C_CRTROMS_MAN in globals.vhd
; (0 = PRG, 1 = CRT, 2 = D81)
C64_CRTROM_MAN_D81 .EQU 0x0000

; We currently only support D64 images with 35 tracks (filesize 174,848 bytes)
; or 40 tracks (filesize 196,608 bytes).
; 174848 decimal = 0x0002AB00 hex
; 196608 decimal = 0x00030000 hex
D64_VARIANT_CNT .EQU    2
D64_STDSIZE_L   .DW     0xAB00, 0x0000
D64_STDSIZE_H   .DW     0x0002, 0x0003

; Valid file sizes for *.d81 images (1581). A standard disk is 80 tracks of
; 40 sectors of 256 bytes, but 81-track images are common in the wild - both
; HDUTILS.d81 and SUPERCPU.d81 from CMD are 81 tracks - and either variant may
; carry an appended error map of one byte per sector:
;   80 tracks               3200 sectors   819200 bytes
;   80 tracks + error map                  822400 bytes
;   81 tracks               3240 sectors   829440 bytes
;   81 tracks + error map                  832680 bytes
D81_VARIANT_CNT .EQU    4
D81_STDSIZE_L   .DW     0x8000, 0x8C80, 0xA800, 0xB4A8
D81_STDSIZE_H   .DW     0x000C, 0x000C, 0x000C, 0x000C

; This needs to be the last thing before the "Variables" sections starts
END_OF_ROM      .DW 0

; ----------------------------------------------------------------------------
; Variables: Need to be located in RAM
; ----------------------------------------------------------------------------

#ifdef RELEASE
                .ORG    0x8000                  ; RAM starts at 0x8000
#endif

; M2M shell variables
#include "../../M2M/rom/shell_vars.asm"

; ----------------------------------------------------------------------------
; Heap and Stack: Need to be located in RAM after the variables
; ----------------------------------------------------------------------------

; The On-Screen-Menu uses the heap for several data structures. This heap
; is located before the main system heap in memory.
; You need to deduct MENU_HEAP_SIZE from the actual heap size below.
; Example: If your HEAP_SIZE would be 30208, then you write 30208-1728=28480
; instead, but when doing the sanity check calculations, you use 30208
;
; This has to grow when menu items or C_CRTROMS_MAN entries are added. The
; options menu carves OPTM_HEAP out of what is left of MENU_HEAP_SIZE after
; the menu structure, and needs OPTM_DX words per "%s" filename slot - one per
; virtual drive, per submenu and per manually loadable ROM, plus one scratch
; slot. Adding the *.d81 entry (C_CRTROMS_MAN_NUM 2 -> 3) and its menu line
; overran the old 1664 by 22 words, which showed up as
; "Heap corruption: Hint: OPTM_HEAP_SIZE" on opening the menu.
MENU_HEAP_SIZE  .EQU 1728

#ifndef RELEASE

; heap for storing the sorted structure of the current directory entries
; this needs to be the last variable before the monitor variables as it is
; only defined as "BLOCK 1" to avoid a large amount of null-values in
; the ROM file
HEAP_SIZE       .EQU 5440                       ; 7168 - 1728 = 5440
HEAP            .BLOCK 1

; in RELEASE mode: 28k of heap which leads to a better user experience when
; it comes to folders with a lot of files
#else

HEAP_SIZE       .EQU 28480                      ; 30208 - 1728 = 28480
HEAP            .BLOCK 1
 
; The monitor variables use 22 words, round to 32 for being safe and subtract
; it from FF00 because this is at the moment the highest address that we
; can use as RAM: 0xFEE0
; The stack starts at 0xFEE0 (search var VAR$STACK_START in m2m-rom.lis to
; calculate the address). To see, if there is enough room for the stack
; given the HEAP_SIZE do this calculation: Add 30208 words to HEAP which
; is currently 0x81E6 and subtract the result from 0xFEE0. This yields
; currently a stack size of 1786, which is more than 1.5k words, and therefore
; sufficient for this program.

                .ORG    0xFEE0                  ; @TODO: automate calculation
#endif

; STACK_SIZE: Size of the global stack and should be a minimum of 768 words
; after you subtract B_STACK_SIZE.
; B_STACK_SIZE: Size of local stack of the the file- and directory browser. It
; should also have a minimum size of 768 words. If you are not using the
; Shell, then B_STACK_SIZE is not used.
STACK_SIZE      .EQU    1536
B_STACK_SIZE    .EQU    768

#include "../../M2M/rom/main_vars.asm"
