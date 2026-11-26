# Board check: the `run-diag-board.sh` diagnostics script

The script collects the state of the Antminer S9 board (Zynq-7010) into a single
log: the system, memory, the user script directory, the device tree, the radio
path, sound, NAND, network and services. Every check prints `PASS`, `FAIL` or
`SKIP`; the summary is the `TOTAL` and `RESULT` lines.

The same script runs on the board and inside QEMU during the build. A user runs
it with the default parameters; the pipeline runs it with `--profile qemu`,
which skips the checks that need the FPGA and NAND.

## Requirements

- An image built after 2026-11-26: the build layer ships `/myscripts` with mode
  `777` and the `/myscripts/run-diag-board.sh` script through the `files/` overlay.
- For the LuCI launch — `luci-app-commands` (included in the image).
- Root rights: the script reads `/proc/mtd`, runs `fw_printenv` and
  `nand_install --dry-run`.

The `/myscripts` directory and the `run-diag-board.sh` script have mode `777`.
If the directory already existed with your own files, the installation leaves them
alone: the image ships only its own `run-diag-board.sh` and never clears the
directory.

## Checks at a glance

| Group | Check | Expected result | In QEMU |
|---|---|---|---|
| System | `/etc/openwrt_release` with `DISTRIB_ID` | the OpenWrt version is printed | yes |
| System | `/rom` mounted as `squashfs` | read-only root with an overlay | yes |
| System | `MemTotal` at least 400 000 kB | 512 MB or 1 GB | yes |
| `/myscripts` | directory exists, mode `777` | a user may write there | yes |
| `/myscripts` | `run-diag-board.sh` present, mode `777` | the script ships in the image | yes |
| Device tree | nodes `axi_i2s_adi@43c00000`, `fm-radio@43c60000`, `sound`, `audio_clock` | addresses match `design_1.bd` | yes |
| Device tree | six NAND partition labels | `boot`, `uboot`, `fpga`, `uboot_env`, `kernel`, `rootfs` | yes |
| Device tree | no `earlyprintk` in `/proc/cmdline` | the spare parameter is gone | yes |
| Radio | `/dev/radio0` | the driver found the FPGA device | `SKIP` |
| Sound | the `audio` card in `/proc/asound/cards` | the ALSA path and `simple-audio-card` are up | `SKIP` |
| Sound, `--sound` | playback of a tone on J2 (PDM) | the stream opens, audio reaches the delta-sigma DAC | `SKIP` |
| NAND | `/proc/mtd` with six labels | the NAND driver and layout are loaded | `SKIP` |
| NAND | `/etc/fw_env.config` and `fw_printenv` | the U-Boot environment is read from `uboot_env` | `SKIP` |
| NAND | `nand_install --dry-run` | sizes match, writing is possible | `SKIP` |
| Network | `eth0` with a DHCP address | the network works | `SKIP` |
| Network | hostname `owrt-zynq7010-XXXX` | the first-boot setup ran | yes |
| Network | `/etc/antminer-mac` | a persistent MAC was created | yes |
| Network | `network.lan.proto = dhcp` | the network configuration was applied | yes |
| Services | `/www/cgi-bin/luci` and `uhttpd` | the web interface is reachable | `SKIP` for the service |

## Running it

### Over UART

```sh
/myscripts/run-diag-board.sh
```

The output goes to the console and to `/tmp/run-diag-board.log` at the same time.
A UART log (PuTTY, `All session output`) keeps the same text in full.

### Before boot: U-Boot

The bootloader stage is not covered by the script. Interrupt autoboot with any key
and run:

```
bdinfo
printenv
mmc info
fatls mmc 0:1
nand info
mtd list
```

Expected: `DRAM: … 1 GiB` or `512 MiB`; in `fatls` — six files including
`system.bit.gz`.

### Over SSH

```sh
ssh root@<board-address> '/myscripts/run-diag-board.sh --log /tmp/run-diag-board.log'
scp root@<board-address>:/tmp/run-diag-board.log ./run-diag-board.log
```

### Over LuCI

`System` → `Commands` → `DIAG: проверка платы` (or `DIAG: проверка платы со
звуком`). The buttons are created by `/etc/uci-defaults/91-board-scripts` on the
first boot.

### Parameters

| Parameter | Meaning |
|---|---|
| `--profile board` | the default profile: every check |
| `--profile qemu` | without FPGA and NAND: those groups report `SKIP` |
| `--log <file>` | duplicate the output into a file; default `/tmp/run-diag-board.log` |
| `--sound` | add a 1 kHz tone playback (about 5 seconds) |
| `--full` | add the full `dmesg` and `logread` |
| `-h`, `--help` | short help |

## Reading the output

```
PASS  система: OpenWrt 25.12.6
FAIL  карта ALSA: нет карты «audio» в /proc/asound/cards
SKIP  разделы NAND: в QEMU NAND не эмулируется
TOTAL pass=17 fail=1 skip=4
RESULT: FAIL
```

- `FAIL` — the check did not pass: the image or the board differs from the
  expected state.
- `SKIP` — the check does not apply in this profile or under these conditions;
  it is not an error.
- Exit code: `0` — no `FAIL`, `1` — at least one `FAIL`, `2` — bad arguments.

The `TOTAL` and `RESULT` lines are the machine-readable summary; the pipeline
makes its decision on them.

## Transferring the log

- Over the network: `scp` from `/tmp` or from `/myscripts` when `--log` points
  there.
- Through the SD card: `mkdir -p /mnt/sd && mount -t vfat /dev/mmcblk0p1 /mnt/sd`,
  then `cp /tmp/run-diag-board.log /mnt/sd/` and `umount /mnt/sd`.
- The UART log is the file the terminal writes; it holds the same output.

## Role in the build

Step `03 qemu smoke` boots the built image in QEMU and runs the same script with
`--profile qemu`. The step fails when the log has no `RESULT: PASS`. A release
therefore takes only an image whose diagnostics passed in full; there is no
separate check set for the pipeline.

## Limits

- QEMU does not emulate the FPGA or NAND: radio, sound and NAND writing are
  verified on the board only.
- The sound check confirms the path up to J2 (PDM). The external I2S on
  connector J6 appears only after a custom bitstream is built.
- Nothing is written to NAND: `nand_install` runs with `--dry-run`.
- Signal levels and edges are not measured by commands — a scope is required.

## Updating

A new check is added to `files/myscripts/run-diag-board.sh` together
with a row in the table above. Scripts in the directory use the `.sh` suffix and
mode `777`. Checks that apply to the board only must report `SKIP` in the `qemu`
profile; otherwise every build starts failing.
