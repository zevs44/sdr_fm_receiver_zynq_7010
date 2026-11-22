# Audio paths and connector pinout

This document describes the **stock bitstream** shipped with this repository
(Vivado 2023.2 project in `vivado_2023.2/`). Everything below is derived from
`design_1.bd`, `sdr_recv.xdc` and the RTL sources, and cross-checked against the
board datasheet and the Xilinx package file `xc7z010clg400pkg.txt`.

It answers three questions:

1. where the audio actually goes in the stock design;
2. which FPGA pins are used and what they are connected to;
3. how to verify all of this on a running board.

> **Scope.** This is a description, not a recommendation. Changing the design
> (for example, routing I2S to external pins) requires rebuilding the bitstream —
> see [rebuild-bitstream.md](rebuild-bitstream.md).

---

## 1. What the design contains

The programmable logic implements an FM receiver with three audio sources and
several outputs:

| Block | Role |
|---|---|
| `axi_sdr_fm` | RF front end, FM demodulator, stereo decoder, resampler to 48 kHz |
| `axi_i2s_adi` | I2S controller used by Linux (ALSA playback and capture) |
| `i2s_axi_mux` | 3-to-1 multiplexer selecting which I2S stream reaches the DAC |
| `i2s_to_delta_sigma_d` | 1-bit delta-sigma modulator |
| `fm_transmitter` | FM transmitter fed from the ALSA playback stream |

There are **two I2S transmitters** (`axi_sdr_fm/i2s_tx` and `axi_i2s_adi` TX) and
**one I2S receiver** (`axi_i2s_adi` RX). None of the transmitters is routed to an
external pin: both feed the internal multiplexer.

## 2. Signal paths

| # | Source | Path | Output | Selected by |
|---|---|---|---|---|
| 1 | RF input (J5) | `axi_sdr_fm` → resampler → `i2s_tx` → mux ch0 → ΔΣ | J2, 1-bit PDM | mux = 0 |
| 1b | RF input (J5) | resampler → `fm_ds_dac` | J4, 1-bit PDM | always |
| 1c | RF input (J5) | mux ch0 → slave bridge → `axi_i2s_adi.sdata_i` | ALSA capture | always |
| 2 | Linux playback (ALSA) | PS DMA → `axi_i2s_adi` TX → mux ch1 → ΔΣ | J2, 1-bit PDM | mux = 1 |
| 2b | Linux playback (ALSA) | `axi_i2s_adi` TX → `fm_transmitter` | T16, FM carrier | always |
| 3 | External I2S input (J9) | mux ch2 → ΔΣ | J2, 1-bit PDM | mux = 2 |
| 4 | any I2S | — | **no external I2S output** | — |

Two consequences worth stating plainly:

- The only wired audio output of the multiplexer is **1-bit PDM on J2**, not I2S.
  It needs an external RC low-pass filter and a buffer to become an analog signal.
- The external I2S port on **J9 is an input**. Connecting an I2S DAC there does
  not work: both ends would be inputs.

## 3. External pins used by the stock bitstream

The list below is exhaustive for `sdr_recv.xdc`.

| Signal | FPGA pin | Connector | Direction | Notes |
|---|---|---|---|---|
| `lvds_p_0` | V15 | J5 pin 15 | in | antenna +, LVDS_25 |
| `lvds_n_0` | W15 | J5 pin 11 | in | antenna −, LVDS_25 |
| `ch2_i2s_bclk_0` | T17 | J9 pin 15 | in | external I2S bit clock |
| `ch2_i2s_lrclk_0` | R18 | J9 pin 11 | in | external I2S word clock |
| `ch2_i2s_sdata_0` | R17 | J9 pin 5 | in | external I2S data |
| `dac_out_0[0]` | W13 | J2 pin 11 | out | ΔΣ left |
| `dac_out_0[1]` | V12 | J2 pin 15 | out | ΔΣ right |
| `audio_out_l_0` | Y14 | J4 pin 11 | out | FM only, bypasses the mux |
| `audio_out_r_0` | W14 | J4 pin 15 | out | FM only, bypasses the mux |
| `antenna_out_0` | T16 | J4 pin 12 | out | FM transmitter |
| `led_stereo_lock_0` | M17 | — | out | status LED |
| `led_station_found_0` | M19 | — | out | status LED |
| `led_rds_sync_0` | L19 | — | out | status LED |
| `led_audio_heartbeat_0` | F16 | — | out | status LED |

## 4. Connector pinout

The board has three physical connectors, each carrying three 18-pin chains
(J1…J9). Every chain has the same pinout:

| Pin | Function | Pin | Function |
|---|---|---|---|
| 1 | GND | 10 | GND |
| 2 | GND | 11 | TXD |
| 3 | SDA | 12 | RXD |
| 4 | SCL | 13 | GND |
| 5 | PLUG | 14 | GND |
| 6 | A2 | 15 | RST |
| 7 | A1 | 16 | +3.3 V |
| 8 | A0 | 17 | NC |
| 9 | GND | 18 | EN (MIO) |

Physical layout: two rows of nine pins. Pin 1 is at the keyed end. The schematic
symbol is drawn by function, not in physical order — do not read it as a picture
of the connector.

## 5. Multiplexer control

The mux is an AXI4-Lite slave at `0x43C80000`. Writing the channel index selects
the source:

| Value | Source |
|---|---|
| 0 | FM receiver (`axi_sdr_fm`) |
| 1 | Linux playback (`axi_i2s_adi` TX) |
| 2 | external I2S input (J9) |

On a running system:

```sh
devmem 0x43C80000 32 1     # select Linux playback
devmem 0x43C80000 32 0     # select FM receiver
```

The slave bridge that feeds ALSA capture is wired to channel 0 in the shipped
design, so `arecord` captures the FM receiver, not the playback stream.

## 6. Verifying on a running board

```sh
cat /proc/asound/cards
aplay -l
dmesg | grep -i i2s
cat /proc/asound/card0/pcm0p/sub0/hw_params
cat /proc/asound/card0/pcm0p/sub0/status
cat /proc/interrupts | grep dmac
```

Expected on a working system: one card named `audio`, a playback device backed by
`axi_i2s_adi`, and an active DMA interrupt. These commands confirm that ALSA and
DMA work; they do **not** prove that an external I2S output exists — for that,
check the XDC file.

## 7. Pitfalls

- **J9 is an input.** An I2S DAC has inputs too; two inputs never talk.
- **The schematic symbol is not the connector.** Pin numbers in the symbol are
  grouped by function. Verify against the physical layout and the datasheet.
- **U13 is a configuration pin** (`PUDC_B`). It must not be used as a general
  purpose I/O.
- **The antenna input is differential** and must not be grounded. The LC tank sits
  between the two pins.
- **PDM is not I2S.** The J2 output is a 1-bit stream; feeding it to an I2S DAC
  will not work.

## 8. Choosing free pins for a new output

If you need to route a signal to a connector, the procedure is:

1. List every pin already used in `sdr_recv.xdc`.
2. Take the remaining pins of the connector from the board datasheet.
3. Check each candidate in the package file (`xc7z010clg400pkg.txt`) — bank,
   voltage, and whether it is a configuration or special-purpose pin.
4. Exclude configuration pins (`PUDC_B`, `PROGRAM_B`, `INIT_B`, `DONE`, `MIO`).
5. Confirm the bank voltage matches the peripheral (3.3 V for most modules).
6. Add the pins to the XDC and rebuild the bitstream.

A pin that is free in the XDC is not automatically free on the board: it may be
wired to something else. Verify with a multimeter before connecting anything.
