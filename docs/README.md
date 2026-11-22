# Documentation

Reference material for this board and this design. Everything here describes the
**stock** design from the original repository; nothing is a recommendation.

| Document | Language | Contents |
|---|---|---|
| [audio-path.md](audio-path.md) | English | audio signal paths, external pins, connector pinout, mux control, verification, pitfalls |
| [audio-path.ru.md](audio-path.ru.md) | Русский | то же на русском |
| [rebuild-bitstream.md](rebuild-bitstream.md) | English | Vivado installation, license, project edits, build, flashing without JTAG, common errors |
| [rebuild-bitstream.ru.md](rebuild-bitstream.ru.md) | Русский | то же на русском |

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
