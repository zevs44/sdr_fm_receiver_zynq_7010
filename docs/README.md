# Documentation

Reference material for this board and this design. Everything here describes the
**stock** design from the original repository; nothing is a recommendation.

| Document | Language | Contents |
|---|---|---|
| [audio-path.md](audio-path.md) | English | audio signal paths, external pins, connector pinout, mux control, verification, pitfalls |
| [audio-path.ru.md](audio-path.ru.md) | Русский | то же на русском |
| [rebuild-bitstream.md](rebuild-bitstream.md) | English | Vivado installation, license, project edits, build, flashing without JTAG, common errors |
| [rebuild-bitstream.ru.md](rebuild-bitstream.ru.md) | Русский | то же на русском |
| [nand-install.md](nand-install.md) | English | writing OpenWrt from the SD card into NAND: safety model, usage, limits |
| [nand-install.ru.md](nand-install.ru.md) | Русский | то же на русском |

Diagrams live in `docs/img/`. They are self-contained SVG files: no external fonts,
no raster images, a dark background baked in, so they render the same on light and
dark themes and in any Markdown viewer.

Related documents in the repository root:

- [`BUILD.md`](../BUILD.md) — building the OpenWrt image (locally and in CI).
- [`FORK_CHANGES.md`](../FORK_CHANGES.md) — what this fork changes relative to upstream.
- [`bitstream/README.md`](../bitstream/README.md) — where the bitstream comes from.

## Scope and accuracy

The pin tables and signal paths are derived from `design_1.bd`, `sdr_recv.xdc`
and the RTL, and cross-checked against the board datasheet and the Xilinx package
file. They describe one specific design. If you change the design, they stop
being true for your bitstream.

The board is not a general-purpose development board: it was designed as a mining
controller. Treat every pin as unknown until you have verified it on your own
hardware.

## Fork changes

This fork is **the author's repository plus a build layer**. No file of the
original is deleted: `vivado_2023.2/`, all 19 packages and the READMEs stay in
place. Everything that needed no change is taken from the author as is — his
build has been verified on the board.

**Three files are changed** (necessary adaptations only):

| File | Change | Why |
|---|---|---|
| `packages/csdr/Makefile` | version `2019-02-27` -> `2019.02.27` | apk in OpenWrt 25.12 rejects versions with several dashes |
| `packages/kmod-zynq-fm-radio/src/zynq_fm_radio.c` | `no_llseek` -> `ZYNQ_FM_NO_LLSEEK` macro | the function was removed in kernel 6.0 |
| `packages/luci-app-mympd/Makefile` | comment about the `/etc/init.d/mpd` conflict | apk treats the conflict as an error, not a warning |

**Added** (a build layer unrelated to the author's design): OpenWrt patches,
configuration, CI, documentation, the prebuilt bootloader and bitstream from
the author's release, and the `nand-install` package.

`nand_install` is the **author's idea**: a script from his second project
`Antminer_S9_OpenWRT`. We kept the write order and extended it with signature
and size checks, a dry-run stamp, word confirmation, `flock`, a log and
read-back verification.

The bitstream in `bitstream/` is the stock one from the author's release. Our
own build (I2S output on J6, antenna and FM transmitter on J8) is not part of
this repository: it is built locally in Vivado, see `docs/rebuild-bitstream*.md`.
