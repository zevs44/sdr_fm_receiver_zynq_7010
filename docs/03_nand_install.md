# NAND install: writing OpenWrt from the SD card

The package `nand-install` adds `/sbin/nand_install`. It writes the running
system, the bootloader, the FPGA bitstream and the kernel from the SD card into
the board NAND.

The **idea is the author's**: a script from his second project
[`Antminer_S9_OpenWRT`](https://github.com/alexsys87/Antminer_S9_OpenWRT). This
package keeps his write order and adds safety checks.

## What it does

| Mode | Writes |
|---|---|
| `--full` (default) | root filesystem into UBI, then `boot`, `uboot`, `uboot_env`, `fpga`, `kernel` |
| `--system` | root filesystem only; the bootloader is not touched |

The root filesystem is copied from `/rom` — the read-only squashfs of the
running system — not from the live overlay. Temporary files and the SD card
itself are therefore never copied.

## Safety model

1. **Preconditions.** Root, booted from SD (not from NAND), all NAND partitions
   present in `/proc/mtd`.
2. **Input checks.** Required files exist; signatures and sizes match
   (FSBL header, uImage magic, gzip, FIT); every file fits its partition; the
   system fits the rootfs partition.
3. **Dry run.** `--dry-run` performs all checks, prints the plan and creates a
   stamp valid for 10 minutes. A write without a fresh stamp is refused.
4. **Confirmation.** Without `--yes` the script asks for the word `INSTALL`.
5. **Lock.** `flock` prevents two installs at once.
6. **Two stages.** The system is written first; the bootloader only after that.
7. **Read-back.** `mtd verify` compares each written partition with the source
   file.
8. **Log.** Every step goes to `/tmp/nand_install.log` and to the console.

## Usage

From the console (booted from the SD card):

```sh
nand_install --dry-run          # check the plan, nothing is written
nand_install                    # asks for the word INSTALL
```

From LuCI (if `luci-app-commands` is installed): *System → Commands* has two
entries, `NAND: dry-run` and `NAND: install`. Run the dry-run first; the
install entry works only within 10 minutes after it.

## Requirements

- NAND partitions in the device tree: `boot`, `uboot`, `fpga`, `uboot_env`,
  `kernel`, `rootfs` (see the board DTS).
- Packages `mtd`, `ubi-utils`, `nand-utils` (installed as dependencies).

## Limits

- **The system does not boot without the SD card.** This U-Boot reads its
  environment from `uboot_env.bin` on the FAT partition of the SD card. With the
  card removed the board falls back to the built-in Xilinx environment, which
  does not know this NAND layout. A test on 2026-11-27 confirmed it: after the
  install the board was powered up without the card, the SPL still selected MMC
  and stopped. The `uboot_env` partition in NAND is read only by `fw_printenv`
  on the Linux side. Booting from NAND needs a bootloader whose environment
  lives in NAND, and the NAND boot mode (`0 1 0 0`). Until then the install
  writes a verified copy of the system, not a boot medium.
- **The shipped bootloader cannot boot from NAND.** `bootloader/boot.bin` has no
  NAND driver: the binary contains no `NAND device` strings and its boot-mode
  switch has no NAND branch. In NAND boot mode the board shows a lit red LED and
  no console output. The script now refuses `--full` unless `boot.bin` contains a
  NAND driver; `--force` bypasses the check for recovery only. A NAND-capable SPL
  must be built separately: mainline U-Boot with `SPL_NAND_SUPPORT`, a
  fixed-geometry SPL reader, and `CONFIG_SYS_NAND_U_BOOT_OFFS=0x80000` matching
  the `uboot` partition.
- The script does not create the partition table and does not change the device
  tree.
- It does not verify the filesystem after writing; that is done by the build
  checks and by booting the board.
- A failed bootloader write cannot be repaired from NAND; boot from the SD card
  again and repeat the install.
