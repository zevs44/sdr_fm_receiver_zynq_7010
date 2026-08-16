# fm_monitor

Real-time console monitor for the **axi_sdr_fm** FM SDR receiver core (Zynq-7010, AXI4-Lite).
It memory-maps the core's register window through `/dev/mem` and continuously decodes the
complete register map (`0x00`–`0x80`): tuning, status/RSSI, volume, controls, the full RDS
set (PI, PS, PTY, TP/TA/M-S, 64-character RadioText, block error statistics) and the RDS /
MPX / audio export FIFO status. It can optionally write the four RW registers at startup.

```
======================================================================
        axi_sdr_fm - Real-Time Register Monitor (0x00-0x80)
======================================================================
 Tuning word:   0x6858793E  ->    101.9000 MHz   (NCO clk 250.000 MHz)
 Station:       FOUND
 Audio mode:    STEREO (pilot locked)
 Signal level:  [###############-----] RSSI   1500 / 2000 (RSSI_THRESH_HI)
----------------------------------------------------------------------
 RDS sync:      SYNC   RDS_EN: ON
 PI code:       0x7722
 PS name:       [ RADIO 1  ]
 PTY:           10 (Pop Music)    TP:ON  TA:OFF  M/S: Music
 RadioText:     Now playing: Something Nice - Th
                e Artist
 RDS blocks:    ok   364 (100.0/s)   bad    34 (10.0/s)   BLER   9.1%
----------------------------------------------------------------------
 RDS FIFO:        7/32 entries   empty:0   overflow:YES (events: 1)
 MPX FIFO:        512 samples   empty:0   overflow:no  (events: 0)   MPX_SHIFT=1
 AUDIO FIFO:       64 samples   empty:0   overflow:no  (events: 0)
----------------------------------------------------------------------
 Volume:        [#########------]  9/15
 Controls:      0x0000000C  MUTE:OFF BASS:OFF RDS:ON  DEEMPH:ON  MONO:OFF
======================================================================
```

## Build

```sh
gcc -O2 -Wall -Wextra -std=c11 -o fm_monitor fm_monitor.c
```

Cross-compiling for the target (OpenWrt SDK):

```sh
$STAGING_DIR/../toolchain-*/bin/arm-openwrt-linux-gcc \
    -O2 -Wall -Wextra -std=c11 -o fm_monitor fm_monitor.c
```

No external libraries; libm is not required (the frequency conversion uses plain
double arithmetic).

## Usage

```
fm_monitor [options]
```

| Option | Description |
| --- | --- |
| `-b, --base ADDR` | Physical base address (default `0x43C60000`) |
| `-d, --dev PATH` | Device to map (default `/dev/mem`; see *Offline testing*) |
| `-c, --clk MHZ` | NCO reference clock in MHz (default `250.0`, must match `CLK_RF_HZ`) |
| `-i, --interval MS` | Refresh interval (default `200`) |
| `-1, --once` | Print one frame and exit (plain output, pipe friendly) |
| `-R, --raw` | Append a raw dump of every register |
| `-r, --rds-blocks` | Also pop the raw RDS block FIFO — **destructive**, see below |
| `-S, --rssi-full N` | RSSI value that fills the bar (default `2000` = `RSSI_THRESH_HI`) |
| `-n, --no-color` | Plain output, no ANSI escapes |
| `-f, --freq MHZ` | Tune: write `TUNING_WORD = round(MHz × 2³² / clk)` |
| `-V, --volume N` | Write `VOLUME` (0–15) |
| `-s, --shift N` | Write `MPX_SHIFT` (0–15) |
| `-C, --controls HEX` | Write `CONTROLS` (bit0 MUTE, 1 BASS, 2 RDS, 3 DEEMPH, 4 MONO) |
| `-h, --help` | Help text |

Examples:

```sh
./fm_monitor                                  # monitor at the default base
./fm_monitor -f 101.9 -V 8 -C 0x04            # tune 101.9 MHz, vol 8, RDS on, then monitor
./fm_monitor --once --raw --no-color          # one frame for a log file
./fm_monitor -c 200                           # build with CLK_RF_HZ = 200 MHz
```

Root privileges are required for `/dev/mem`. Without any write option the device is
opened read-only and mapped `PROT_READ`, so the monitor cannot disturb the core.

## Register map

| Offset | Name | Access | Notes |
| --- | --- | --- | --- |
| `0x00` | `TUNING_WORD` | RW | NCO tuning word |
| `0x04`/`0x08` | `RDS_PS_0/1` | RO | Program Service name, 8 chars, MSB first |
| `0x0C` | reserved | — | reads 0 |
| `0x10` | `STATUS` | RO | `[0]` pilot lock, `[1]` station found, `[19:2]` 18-bit RSSI, `[20]` RDS sync |
| `0x14` | `VOLUME` | RW | 0–15 |
| `0x18` | `CONTROLS` | RW | MUTE / BASS / RDS_EN / DEEMPH / MONO |
| `0x1C` | `RDS_PI` | RO | last PI that passed the checkword |
| `0x20` | `RDS_FIFO_STAT` | RO | count, overflow (**clear-on-read**), empty |
| `0x24` | `RDS_FIFO_DATA` | RO | **read = pop**: info word, block id, corrected/uncorrectable |
| `0x28` | `RDS_ERR_STATS` | RO | free-running 16-bit corrected / uncorrectable counters |
| `0x2C` | `MPX_FIFO_STAT` | RO | count, overflow (**clear-on-read**), empty |
| `0x30` | `MPX_FIFO_DATA` | RO | **read = pop**: signed 16-bit MPX composite sample |
| `0x34` | `MPX_SHIFT` | RW | right shift before saturation (reset value 1) |
| `0x38` | `AUDIO_FIFO_STAT` | RO | count of individual L/R samples, not pairs |
| `0x3C` | `AUDIO_FIFO_DATA` | RO | **read = pop**: one sample, sign-extended from `AUDIO_DATA_WIDTH` |
| `0x40` | `RDS_FLAGS` | RO | `[4:0]` PTY, `[5]` TP, `[6]` TA, `[7]` M/S |
| `0x44`–`0x80` | `RDS_RT_0..15` | RO | 64-character RadioText, 4 chars per register |

## Things worth knowing

* **Address segment.** The core's AXI address bus is `[7:0]`. In Vivado's Address Editor the
  peripheral needs at least 256 bytes (4K recommended). With the old 64-byte segment every
  read above `0x3C` returns an interconnect decode error. The monitor prints a warning when
  the reads look like that (or like a missing peripheral).
* **Destructive reads.** `0x24`, `0x30` and `0x3C` pop one FIFO entry per read. The monitor
  never touches them (they show as `(pop on read)` in the raw dump) unless `--rds-blocks` is
  given — and that option competes with any other consumer of the same FIFO, for example the
  V4L2 driver.
* **Overflow flags are clear-on-read.** Each `*_FIFO_STAT` register is read exactly once per
  frame and the flags are latched in software, so the `events:` counter shows how many frames
  reported an overflow since startup instead of losing the flag the moment it is displayed.
* **RadioText coherency.** Reading `0x44` latches all 64 characters into the core's shadow
  register; `0x48`–`0x80` then read from that snapshot. The monitor always reads `0x44` first
  through a `volatile` pointer, so the 64 characters always come from one instant. Text is
  terminated with `0x0D` per IEC 62106 and displayed up to that point.
* **Block counters wrap.** `RDS_ERR_STATS` is a pair of free-running 16-bit counters; the
  per-second rates and the BLER figure are computed wrap-safe from the difference.
* **PTY names** use the European IEC 62106 table, not the North-American RBDS one.
* **NCO clock.** `--clk` must match the synthesized `CLK_RF_HZ`, otherwise the displayed
  frequency (and `--freq`) is off by that ratio.
* **VOLUME/MUTE affect the audio export.** `AUDIO_FIFO_DATA` taps the post-resampler,
  post-volume path, so `0x14` and `CONTROLS[0]` change what a reader of that FIFO gets.

## Offline testing

`--dev` accepts a plain file, which makes it possible to exercise the decoding without
hardware:

```sh
python3 - <<'EOF'
import struct
regs = [0]*33
regs[0x00//4] = round(101.9/250.0 * 2**32)
regs[0x10//4] = 1 | (1<<1) | (1500<<2) | (1<<20)
open('regs.bin','wb').write(b''.join(struct.pack('<I', v) for v in regs).ljust(4096, b'\0'))
EOF
./fm_monitor -d regs.bin -b 0 --once --raw
```
