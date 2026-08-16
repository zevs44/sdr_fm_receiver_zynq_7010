# fm_radio

Userspace control utility for the **`axi_sdr_fm`** FM receiver IP on the Zynq-7010
platform. It maps the AXI4-Lite slave through `/dev/mem` — no kernel driver is
required — and exposes tuning, seek/scan, audio controls, full RDS readout and
raw MPX / audio capture from the command line.

## Contents

- [Build](#build)
- [Configuration](#configuration)
- [Commands](#commands)
- [Register map](#register-map)
- [Notes and limitations](#notes-and-limitations)
- [Testing without hardware](#testing-without-hardware)

## Build

No external dependencies, no `libm`:

```sh
gcc -O2 -Wall -Wextra -o fm_radio fm_radio.c
```

OpenWrt package snippet:

```make
define Package/fm-radio
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Zynq FM SDR receiver control utility
endef

define Build/Compile
	$(TARGET_CC) $(TARGET_CFLAGS) -o $(PKG_BUILD_DIR)/fm_radio $(PKG_BUILD_DIR)/fm_radio.c
endef

define Package/fm-radio/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/fm_radio $(1)/usr/bin/
endef
```

Root privileges are required for everything except `-h`.

## Configuration

Global options come **before** the command; each also has an environment
variable equivalent where noted.

| Option | Default | Env | Meaning |
| --- | --- | --- | --- |
| `-b <addr>` | `0x43C60000` | `FM_RADIO_BASE` | AXI4-Lite base address of the IP |
| `-k <hz>` | `250000000` | `FM_RADIO_CLK` | `clk_rf` frequency (NCO reference) |
| `-s <khz>` | `100` | — | Channel step for seek/scan |
| `-d <ms>` | `100` | — | Settle time per channel for seek/scan |
| `-w <bits>` | `24` | — | `AUDIO_DATA_WIDTH` the bitstream was built with |
| — | `/dev/mem` | `FM_RADIO_MEM_DEV` | Device to map (testing only) |

```sh
fm_radio -b 0x43C60000 -k 250000000 -c
```

## Commands

### Information

| Command | Description |
| --- | --- |
| `-c`, `--current` | Frequency, status, audio settings and full RDS |
| `-j`, `--json` | The same data as one JSON object (for LuCI / scripts) |
| `-rds` | RDS only: PI, PS, PTY, TP/TA, M/S, RadioText, block error counters |
| `-m [ms]` | Live one-line-per-update monitor until `Ctrl-C` (default 1000 ms) |
| `-regs [all]` | Dump the register map; `all` also reads the pop-on-read FIFO registers |

### Tuning

| Command | Description |
| --- | --- |
| `-f <MHz>` | Tune to a frequency (76.0 – 108.0 MHz) |
| `-up [MHz]` | Seek up from `<MHz>`, or from the current frequency |
| `-down [MHz]` | Seek down from `<MHz>`, or from the current frequency |
| `-scan [ms]` | Sweep the whole band and list every station found; the optional dwell lets the RDS decoder acquire the PS name |

Seek stops on the hardware `station_found` flag (RSSI hysteresis, thresholds
`RSSI_THRESH_HI`/`LO` in the RTL). If a full sweep finds nothing, the previous
tuning word is restored and the exit code is non-zero.

### Audio controls

| Command | Register effect |
| --- | --- |
| `-vol <0-15>` | `VOLUME[3:0]` |
| `-mute <0/1>` | `CONTROLS[0]` |
| `-bass <0/1>` | `CONTROLS[1]` |
| `-rds-en <0/1>` | `CONTROLS[2]` — the RDS decoder |
| `-eu` / `-us` | `CONTROLS[3]` — de-emphasis 50 µs / 75 µs |
| `-mono <0/1>` | `CONTROLS[4]` — force mono |

All of these are read-modify-write on `CONTROLS`, so they do not disturb the
other bits.

### Capture and debug

| Command | Description |
| --- | --- |
| `-mpxshift [0-15]` | Show or set `MPX_SHIFT` (reset value 1) |
| `-mpx <file> <n>` | Capture `n` raw MPX samples — `s16le`, 250 kHz, `-` = stdout |
| `-rec <file> <s>` | Record `s` seconds of audio to a 16-bit 48 kHz stereo WAV; `-` writes headerless `s16le` to stdout |
| `-rdsraw [n]` | Dump `n` raw RDS blocks (block id, info word, checkword result) |

```sh
# 5 seconds of composite MPX for offline analysis / redsea
fm_radio -mpx mpx.raw 1250000

# pipe live audio to a host
fm_radio -rec - 30 | aplay -f S16_LE -r 48000 -c 2
```

## Register map

Byte offsets from the AXI base; see `axi_sdr_fm.v` for the authoritative
description.

| Offset | Name | Access |
| --- | --- | --- |
| `0x00` | `TUNING_WORD` | RW |
| `0x04` / `0x08` | `RDS_PS_0/1` — PS chars 1‑4 / 5‑8 | RO |
| `0x10` | `STATUS` — `[0]` stereo lock, `[1]` station found, `[19:2]` RSSI, `[20]` RDS sync | RO |
| `0x14` | `VOLUME[3:0]` | RW |
| `0x18` | `CONTROLS` — mute / bass / RDS / de-emphasis / mono | RW |
| `0x1C` | `RDS_PI` | RO |
| `0x20` / `0x24` | RDS block FIFO status / data (read = pop) | RO |
| `0x28` | `RDS_ERR_STATS` — good / bad block counters | RO |
| `0x2C` / `0x30` | MPX FIFO status / data (read = pop) | RO |
| `0x34` | `MPX_SHIFT[3:0]` | RW |
| `0x38` / `0x3C` | Audio FIFO status / data (read = pop) | RO |
| `0x40` | `RDS_FLAGS` — PTY, TP, TA, M/S | RO |
| `0x44`–`0x80` | `RDS_RT_0..15` — 64-character RadioText | RO |

## Notes and limitations

- **Address segment.** The IP uses an 8-bit address bus, so the segment in
  Vivado's Address Editor must be at least 256 bytes (4 K recommended).
  Anything above `0x3C` otherwise returns a decode error; the utility prints a
  warning if every register reads back `0xFFFFFFFF`.
- **RadioText coherency.** `0x44` must be read before `0x48`–`0x80`: that read
  latches all 64 characters into the PL shadow register. The utility always
  reads in that order, and the text is cut at the IEC 62106 `0x0D` terminator.
- **Read = pop.** Reading `RDS_FIFO_DATA`, `MPX_FIFO_DATA` or `AUDIO_FIFO_DATA`
  removes an entry, and reading a `*_FIFO_STAT` register clears its overflow
  flag. `-c`, `-j` and `-rds` deliberately touch none of them, so they are safe
  to poll while another process is capturing. `-regs` skips the popping
  registers unless `all` is given.
- **Nyquist folding.** The 1-bit front end samples RF directly, so a station
  above `clk_rf/2` is tuned via its alias; the utility folds automatically. At
  the default 250 MHz the whole 76–108 MHz band lies in the first Nyquist zone
  and read-back is exact. At `clk_rf = 200 MHz` the alias of 108 MHz is 92 MHz —
  also in band — so read-back of frequencies above 100 MHz is ambiguous and the
  first-zone candidate is reported.
- **PTY names** follow the IEC 62106 (European) table, or the RBDS table when
  de-emphasis is set to 75 µs.
- **Capture is not real-time.** MPX and audio capture poll AXI4-Lite from
  userspace; if the FIFO overflows the reported sample count is still correct
  but samples were dropped. The I2S/ALSA output is the real audio path — use
  `-rec` for debugging only.
- **Audio format.** `AUDIO_FIFO_DATA` is sign-extended from `AUDIO_DATA_WIDTH`
  (24 by default), and `-rec` converts to 16-bit. Rebuild-time changes to that
  parameter must be mirrored with `-w`.
- Exit code is `0` on success, `1` on an invalid argument, a hardware access
  failure, or a seek that found no station.

## Testing without hardware

Setting `FM_RADIO_MEM_DEV` makes the utility map a regular file instead of
`/dev/mem`, which allows the whole command surface to be exercised on a host:

```sh
head -c 4096 /dev/zero > fake.bin
FM_RADIO_MEM_DEV=fake.bin ./fm_radio -b 0 -f 101.9
FM_RADIO_MEM_DEV=fake.bin ./fm_radio -b 0 -c
```
