# axi_sdr_fm — FPGA FM Stereo + RDS Receiver IP Core

**English** | [Русский](README_ru.md)

A complete, from-scratch FM broadcast receiver implemented in synthesizable
Verilog for a Xilinx Zynq-7010, exposed to the PS (ARM) side as a single
AXI4-Lite peripheral. Everything from the raw 1-bit RF sample stream down to
stereo audio (I2S and an on-chip delta-sigma DAC) and decoded RDS data runs
in the PL — the ARM core only talks to a handful of memory-mapped registers.

No DMA, no external RDS chip, no software demodulation: tuning, FM
demodulation, stereo decode, de-emphasis, bass boost, volume/mute and the
full RDS protocol stack are all dedicated hardware.

## Contents

- [Features](#features)
- [Architecture](#architecture)
- [RF front end: direct sampling with a comparator](#rf-front-end-direct-sampling-with-a-comparator)
- [Delta-sigma DAC output filter](#delta-sigma-dac-output-filter)
- [Raw MPX & post-resampler audio export](#raw-mpx--post-resampler-audio-export)
- [Repository layout](#repository-layout)
- [Register map](#register-map-axi4-lite)
- [Build-time parameters](#build-time-parameters)
- [Clock domains](#clock-domains)
- [Known limitations](#known-limitations)
- [Verification](#verification)
- [Software / Linux integration](#software--linux-integration)
- [Software pipeline (mpx_stream, csdr/csdr2, redsea)](#software-pipeline-mpx_stream-csdrcsdr2-redsea)
- [Getting started](#getting-started)

## Features

### Tuning & reception
- Digital down-conversion straight from a 1-bit LVDS RF sample stream
  (`fm_ddc_mixer`), tuned by a 32-bit NCO tuning word written over AXI —
  no analog VCO or external tuner chip.
- RSSI estimation and station-found detection, debounced against
  configurable high/low thresholds.
- CORDIC-based FM discriminator (14-stage vectoring CORDIC) for the
  demodulated MPX composite signal.

### Stereo decode
- 19 kHz pilot-tone PLL (leaky-integrator + proportional loop, saturating
  with anti-windup) driving debounced `stereo_lock` status and the 38 kHz
  subcarrier used to recover L−R.
- Pilot notch filters on both the L+R and L−R paths, CIC-decimated stereo
  matrixing (`L = (L+R)+(L−R)`, `R = (L+R)−(L−R)`).
- Runtime mono/stereo switch, with a dedicated forced-mono low-pass path so
  mono playback isn't just "L−R muted."

### Audio processing
- Selectable de-emphasis, 50 µs or 75 µs, switchable at runtime
  (build-time optional).
- Optional bass boost (leaky-integrator low-shelf, build-time optional).
- Digital volume control (0–15, non-linear table) and hardware mute.
- Sample-rate conversion from the internal 50 kHz demodulator rate to
  48 kHz audio (`audio_resampler`), with headroom for an on-chip
  parametric EQ if the downstream feature set is enabled.

### RDS (IEC 62106)
- Full RDS decoder as a **standalone module with zero dependency on the
  stereo demodulator**: it takes only the shared MPX composite and runs its
  own 57 kHz Costas loop, so RDS decodes on mono-only broadcasts and works
  even with `fm_stereo_demod` removed from the build entirely.
- Two-stage bit synchronization (parallel coarse phase search + tracking
  loop) and Annex-C block/group synchronization with a hysteretic
  lock/quality window.
- Decodes and exposes over AXI: PI (Programme Identification), PS (station
  name, group 0A/0B), PTY/TP/TA/M-S (Programme Type and traffic/speech
  flags), and full 64-character RadioText (group 2A).
- Raw decoded-block stream and free-running corrected/uncorrectable block
  counters are also exposed over AXI, for a Linux-side driver to build on
  top of.
- Automatic resynchronization if block lock is lost for an extended period,
  without needing a software-driven reset.

### Output
- On-chip 1st-order 1-bit delta-sigma stereo DAC — no external audio codec
  required for basic playback.
- Parallel I2S transmitter (24-bit, standard Philips format) for driving an
  external DAC (PCM5102A, MAX98357, WM8731, etc.) at higher quality.
- Status LEDs: stereo lock, station found, RDS sync, and an audio
  "heartbeat" that only blinks while real 48 kHz audio samples are flowing
  (distinguishing "stuck" from "silent").

### Raw MPX & audio export
- Raw MPX (multiplex) composite samples — the undecoded L+R + 19 kHz pilot
  + 38 kHz L−R + 57 kHz RDS composite, at the same point `fm_stereo_demod`
  itself demodulates from — pulled off in parallel via an independent
  discriminator and exported through a register-mapped FIFO
  (`MPX_FIFO_STAT`/`MPX_FIFO_DATA`, `MPX_SHIFT`).
- Post-resampler stereo audio (the same 48 kHz, post-volume/mute content
  driving the on-chip DAC and I2S) exported the same way, as an
  interleaved L/R sample FIFO (`AUDIO_FIFO_STAT`/`AUDIO_FIFO_DATA`) — no
  extra ADC or capture hardware needed to record or re-stream what the
  receiver is playing.
- Both add no new clock-domain crossings — they tap signals that are
  already native to `s_axi_aclk`. See
  [Raw MPX & post-resampler audio export](#raw-mpx--post-resampler-audio-export)
  for the full picture, including throughput caveats.

### Build-time configurability
De-emphasis, the stereo path, RDS decoding, and bass boost can each be
compiled out entirely via top-level parameters, trading capability for
DSP/LUT/FF budget on smaller parts. See
[Build-time parameters](#build-time-parameters).

## Architecture

```
 lvds_p/n ──▶ fm_rf_input ──▶ fm_ddc_mixer ──▶ CIC×2 (I/Q) ───┐
  (clk_rf, up to 250 MHz)      (NCO tuner)     (decimate)     │  toggle-handshake
                                                              │  CDC (clk_rf → s_axi_aclk)
                                                              ▼
                                                     fm_cordic_discrim
                                              (ONE shared FM discriminator)
                                                              │
                                          MPX composite @ 250 kHz (+ magnitude)
        ┌─────────────────────────────────────┼─────────────────────────────┐
        ▼                                     ▼                             ▼
 fm_stereo_demod                        rds_decode                  fm_mpx_scale
 (RSSI, pilot PLL,              (57 kHz Costas loop, bit/          (shift + saturate)
  stereo matrix, bass            block sync, PI/PS, raw                    │
  boost, de-emphasis)            block stream)                             ▼
        │                                     │                    mpx_sample_fifo
        ▼                                     ▼                   (raw MPX export,
  audio_resampler                     rds_block_fifo                0x2C/0x30/0x34)
  (50 kHz → 48 kHz)
        │
  ┌─────┼──────────────┐
  ▼     ▼              ▼
fm_ds_dac  mpx_sample_fifo  i2s_tx
(Δ-Σ DAC)  (audio export,   (external
            0x38/0x3C)        DAC)

         AXI4-Lite (s_axi_aclk, ~50 MHz) ◀──── register file: RDS/MPX/audio
                                                FIFO reads, PI, status
```

The design demodulates **once**: a single `fm_cordic_discrim` instance
turns the decimated I/Q into the MPX composite, which then fans out to
three consumers — the stereo demodulator, the RDS decoder, and the raw-MPX
export path. Those three are **mutually independent**: none of them reads
anything produced by another, and any one can be removed or compiled out
without affecting the rest. In particular `rds_decode` is a top-level
module, not a submodule of `fm_stereo_demod`, and works with the stereo
path absent entirely — which matters because RDS is broadcast on mono
stations too.

Sharing one discriminator also means the raw-MPX export carries exactly
the composite the receiver's own audio and RDS paths see, rather than a
separately-derived approximation of it.

## RF front end: direct sampling with a comparator

`fm_rf_input.v` has no ADC, no mixer, and no LNA. It samples the antenna
signal directly, using the FPGA's LVDS differential input buffer
(`IBUFDS`) as a 1-bit comparator rather than as a logic input:

```
  FPGA (lvds_p) ---+---------------------+
                     |                   |
                    ---                 _|_
                    --- C1             (   )  Coil L1 (hand-wound from
                     |  22n            (   )  twisted-pair wire, ~6-7 turns)
                     |                   |
                     |                   |  <---- tap at 1.5 turns from the bottom
                     |                   +---------+-----> Antenna (~75 cm wire)
                     |                 (   )
                     |                 (   )
  FPGA (lvds_n) ---+---------------------+
```

1. **Passive antenna coupling.** A hand-wound coil (`L1`, ~6-7 turns of
   twisted-pair wire) and a 22 nF capacitor (`C1`) form a parallel
   resonant LC tank across the FPGA's two differential pins (`lvds_p`/
   `lvds_n`). A ~75 cm antenna wire feeds into a tap about 1.5 turns from
   the bottom of the coil. That tap acts as an autotransformer: it steps
   the antenna's (comparatively low) impedance up to match the resonant
   tank, boosting the RF signal amplitude purely passively, with no
   amplifying devices, before it ever reaches the FPGA pins. `L1` is tuned
   so the tank resonates within the FM broadcast band.
2. **Comparator, not ADC.** `lvds_p`/`lvds_n` are the two ends of that
   analog tank, not a real differential logic pair, and `DIFF_TERM` is
   disabled accordingly. `IBUFDS` is (ab)used purely for its fast
   differential comparator stage: its output flips each time the RF
   waveform crosses zero, producing a 1-bit ("hard-limited") stream that
   preserves the RF signal's phase/frequency information — but not its
   amplitude.
3. **I/O-block capture.** The comparator output is registered right in the
   I/O block (`(* IOB = "TRUE" *)`) at the 250 MHz `clk_rf` sample clock to
   minimize jitter, then re-registered once more for a clean pipeline
   stage into fabric.
4. **All tuning happens digitally, downstream.** This module does not
   select a station — it hands `fm_ddc_mixer` and the CIC decimators a
   1-bit oversampled representation of whatever the passive LC tank let
   through. Station selection is entirely digital: `fm_ddc_mixer`'s NCO
   (driven by the `TUNING_WORD` register) mixes the desired frequency down
   to baseband, and the CIC decimators reject everything else.

This is a deliberately minimal, passive front end (no LNA, no AGC, no
image-reject filter beyond the single LC tank) — see
[Known limitations](#known-limitations).

## Delta-sigma DAC output filter

`fm_ds_dac.v` only produces a 1-bit PDM (pulse-density-modulated) bitstream
per channel, toggling at the DAC's own clock rate — 50 MHz. That pin is
**not** analog audio by itself; an external analog low-pass filter is
required between the FPGA pin and the amplifier/line input to reconstruct
the audio waveform and reject the out-of-band PDM carrier energy.

Recommended values for 50 MHz:

For good sound quality (cutoff around 22 kHz):
- Resistor (R): 1.5 kΩ (standard value)
- Capacitor (C): 4.7 nF

```
  FPGA (ds_dac_l/r) ---[ R 1.5k ]---+-----> Analog audio out
                                     |       (to amp / line-in)
                                    ---
                                    --- C 4.7n
                                     |
                                    GND
```

This is a **1st-order** (single-pole) RC low-pass filter — one reactive
element, 6 dB/octave (20 dB/decade) roll-off past the cutoff — not a
multi-pole filter. Cutoff frequency:

```
fc = 1 / (2·π·R·C) = 1 / (2·π · 1500 Ω · 4.7 nF) ≈ 22.6 kHz
```

Other technical notes:
- **Oversampling ratio.** At a 50 MHz bit clock feeding 48 kHz audio, the
  effective OSR is ≈50,000,000 / 48,000 ≈ 1042×, so the delta-sigma
  modulator's quantization noise is still pushed well above the audible
  band, just with noticeably less headroom than a higher-rate modulator
  would give — the noise-shaped quantization noise starts climbing closer
  to the audio band, and the PDM carrier content itself sits an order of
  magnitude lower in frequency too. A simple 1st-order RC is still enough
  for casual listening/monitoring straight off the pin, but with less
  margin against audible residual noise than at a higher clock rate.
- **When 1st order isn't enough.** With only ~1042× OSR, residual
  PDM carrier/switching noise is more likely to be audible or leak into
  nearby RF/analog circuitry than at a higher modulator clock — if that
  happens, use a higher-order filter instead (2nd/3rd-order RC or LC, or
  an active filter) — or skip the on-chip DAC altogether and use `i2s_tx`
  into an external audio DAC (PCM5102A, MAX98357, WM8731, etc.), which is
  what the higher-quality output path is for (see [Output](#output)).
- **Component choice.** Both values are standard E12/E24-series parts.
  Raising R reduces the filter's ability to drive low-impedance loads
  (buffer with an op-amp before driving headphones directly); lowering R
  (with C scaled to hold the same cutoff) improves drive strength at the
  cost of a lower filter impedance loading the FPGA pin.

## Raw MPX & post-resampler audio export

Two parallel export paths tap into the existing pipeline, add no new
clock-domain crossings, and don't touch any pre-existing signal or
register:

**Raw MPX composite** (registers `0x2C`/`0x30`/`0x34`) taps the shared
`fm_cordic_discrim` output — the same 250 kHz MPX composite the stereo and
RDS paths demodulate from, so what software reads out is exactly what the
receiver itself is working with, not a separately-derived approximation.
`fm_mpx_scale` does only the export-side conditioning: an arithmetic
right shift by the runtime `MPX_SHIFT` value, then a saturating narrow to
a signed 16-bit sample. Useful shift values are small — the composite is a
signed 18-bit phase difference reaching roughly ±39000 at full ±75 kHz
deviation, so `MPX_SHIFT=1` (the reset value) fits worst-case peaks
without clipping, and `0` gives 6 dB more resolution at the cost of
flat-topping the loudest peaks. Values past the 16-bit range are clamped
rather than wrapped, since a wrap would turn a loud peak into a
full-amplitude sign inversion.

This export is intended for capturing or streaming the composite for
offline analysis, feeding a software RDS/MPX decoder for cross-checking,
or general debugging.

**Post-resampler stereo audio** (registers `0x38`/`0x3C`) taps
`audio_48k_l`/`audio_48k_r`/`audio_48k_valid` — the exact same signal
already feeding `fm_ds_dac` and `i2s_tx`, i.e. after volume/mute and
resampling to 48 kHz. A small serializing FSM turns each L/R sample pair
into two back-to-back FIFO writes (L then R), so software sees a plain
interleaved-stereo PCM stream on readout.

Both paths reuse the same `mpx_sample_fifo` module (a generic,
BRAM-backed sample FIFO despite the name — nothing about it is
MPX-specific) with different data widths. It's a two-stage buffered
design (a BRAM output register feeding a fabric "head" register) so a
single output register's one-cycle read latency can never return a
stale/duplicate sample even under back-to-back pops; the only cost is a
few extra cycles of latency between a write into an empty FIFO and that
sample's visibility, which is irrelevant on a continuously polled queue.
The write side is never backpressured — a write while full drops the
incoming sample (older queued samples stay in order) and raises a sticky
overflow flag, cleared by reading the corresponding `*_STAT` register.

Both FIFOs share the read-side convention already used by the RDS FIFO:
check the `*_STAT` register (entry count, empty, overflow-since-last-read)
before popping a sample from `*_DATA`; reading `*_DATA` pops one entry
regardless of whether new data has arrived.

**Throughput note:** the MPX path runs at the full 250 kHz decimated
sample rate — sustaining that continuously means polling the AXI4-Lite
interface at up to 250,000 register reads/second from software, which
needs a tight polling loop (or a small dedicated core) rather than a
best-effort userspace thread; the default 1024-deep FIFO buffers roughly
4 ms of margin. The audio path is far gentler (48 kHz × 2 channels =
96,000 reads/second at most). Both FIFO depths are build-time
configurable (`MPX_FIFO_DEPTH`, `AUDIO_FIFO_DEPTH`) if more buffering
margin is needed.

## Repository layout

| File | Description |
|---|---|
| `axi_sdr_fm.v` | Top-level AXI4-Lite IP core: register file, clock-domain crossings, LEDs, instantiates everything below. |
| `fm_rf_input.v` | RF front end — direct-samples the antenna signal into the 1-bit `rf_bit` stream via a comparator (see [RF front end](#rf-front-end-direct-sampling-with-a-comparator)). Runs in the `clk_rf` domain. |
| `fm_ddc_mixer.v` | Digital down-converter / NCO — mixes the raw RF bitstream down to baseband I/Q. |
| `cic_decimator.v` | Parametric CIC decimator, reused for the RF front end, the RDS I/Q path, and the stereo L±R paths. |
| `fm_cordic_discrim.v` | CORDIC FM discriminator (I/Q → 250 kHz MPX composite + magnitude for RSSI). A single shared instance feeds all three MPX consumers. |
| `fm_stereo_demod.v` | RSSI/station detection, pilot PLL, stereo decode, bass boost, de-emphasis, volume/mute. Takes the MPX composite as input; does not demodulate. |
| `rds_decode.v` | Full IEC 62106 RDS decoder (57 kHz Costas loop, bit sync, block/group sync, PI/PS parsing). A standalone top-level module fed the shared MPX composite — not a submodule of `fm_stereo_demod`, and works with it absent entirely. |
| `rds_block_fifo.v` | Small synchronous FIFO buffering raw decoded RDS blocks for the AXI read side. |
| `audio_resampler.v` | Single-DSP time-multiplexed resampler (50 kHz → 48 kHz) with optional de-emphasis/EQ/volume stages. |
| `fm_ds_dac.v` | 2-channel 1st-order delta-sigma (PDM) DAC. |
| `i2s_tx.v` | I2S transmitter for an external audio DAC. |
| `fm_mpx_scale.v` | Export-side conditioning for the raw-MPX path: runtime shift (`MPX_SHIFT`) plus saturating narrow to 16 bits. Takes the shared MPX composite, like the other two consumers. |
| `mpx_sample_fifo.v` | Generic, BRAM-backed, two-stage-buffered sample FIFO (despite the name, used for both the raw-MPX and post-resampler audio export paths). |

## Register map (AXI4-Lite)

Base offsets are relative to the IP's AXI4-Lite base address (8-bit
address bus, word-aligned, 0x00–0x80).

| Offset | Name | Access | Description |
|---|---|---|---|
| `0x00` | `TUNING_WORD` | RW | 32-bit NCO tuning word. |
| `0x04` | `RDS_PS_0` | RO | RDS Program Service name, characters 1–4. |
| `0x08` | `RDS_PS_1` | RO | RDS Program Service name, characters 5–8. |
| `0x0C` | — | — | Reserved. |
| `0x10` | `STATUS` | RO | `[0]` stereo lock, `[1]` station found, `[19:2]` 18-bit raw RSSI, `[20]` RDS sync. |
| `0x14` | `VOLUME` | RW | `[3:0]` volume, 0–15. |
| `0x18` | `CONTROLS` | RW | `[0]` mute, `[1]` bass boost enable, `[2]` RDS enable, `[3]` de-emphasis select, `[4]` mono. Cleared to 0 on reset. |
| `0x1C` | `RDS_PI` | RO | `[15:0]` last-known Programme Identification. |
| `0x20` | `RDS_FIFO_STAT` | RO | `[7:0]` queued entries, `[8]` overflow (clear-on-read), `[9]` FIFO empty. |
| `0x24` | `RDS_FIFO_DATA` | RO | `[15:0]` raw 16-bit RDS info word, `[18:16]` block ID (0=A,1=B,2=C,3=D), `[19]` corrected, `[20]` uncorrectable. **Reading this register pops one FIFO entry.** |
| `0x28` | `RDS_ERR_STATS` | RO | `[15:0]` free-running corrected-block counter, `[31:16]` free-running uncorrectable-block counter. |
| `0x2C` | `MPX_FIFO_STAT` | RO | Entries queued (width tracks `MPX_FIFO_DEPTH`), `[16]` overflow (clear-on-read), `[17]` FIFO empty. |
| `0x30` | `MPX_FIFO_DATA` | RO | `[15:0]` signed raw MPX composite sample (same tap point `fm_stereo_demod`'s input uses — L+R + 19 kHz pilot + 38 kHz L−R DSB-SC + 57 kHz RDS subcarrier, still undecoded). **Reading pops one FIFO entry** — check `MPX_FIFO_STAT` first, reading while empty returns stale data rather than underflowing. |
| `0x34` | `MPX_SHIFT` | RW | `[3:0]` arithmetic right-shift applied to the shared MPX composite before it's saturated into the 16-bit FIFO sample. The reset value (`1`) fits full ±75 kHz deviation peaks without clipping; `0` gives 6 dB more resolution at the cost of flat-topping the loudest peaks. |
| `0x38` | `AUDIO_FIFO_STAT` | RO | Entries queued (width tracks `AUDIO_FIFO_DEPTH`) — counts individual L/R samples, not stereo pairs, `[16]` overflow (clear-on-read), `[17]` FIFO empty. |
| `0x3C` | `AUDIO_FIFO_DATA` | RO | One post-resampler audio sample, sign-extended from `AUDIO_DATA_WIDTH` (24 by default) to 32 bits — i.e. ALSA `S24_LE` for the default width, **not** `S32_LE` (48 dB too quiet) and not packed `S24_3LE`. Entries alternate L, R, L, R... **Reading pops one entry.** Same signal already feeding `fm_ds_dac`/`i2s_tx` — `VOLUME` (0x14) and mute (0x18[0]) affect it too. |
| `0x40` | `RDS_FLAGS` | RO | Programme-wide RDS fields, latched together whenever a group completes so one 32-bit read is an internally consistent snapshot: `[4:0]` PTY (Programme Type, 0–31), `[5]` TP (Traffic Programme), `[6]` TA (Traffic Announcement), `[7]` M/S (1 = Music, 0 = Speech). TP is carried by every group type; TA/M-S only appear in group 0 and hold their last value between group-0 transmissions. |
| `0x44` | `RDS_RT_0` | RO | RadioText (group 2A), characters 1–4. **Reading this register also takes a snapshot of all 64 RadioText characters** — always read this register first. |
| `0x48`–`0x80` | `RDS_RT_1`…`RDS_RT_15` | RO | RadioText, 4 characters per register (MSB = earliest character), read from the snapshot taken by the `RDS_RT_0` read — the 64 characters are guaranteed to come from one instant even if the station updates the text mid-read. RadioText is space-padded and, if shorter than 64 characters, terminated with `0x0D` per IEC 62106; stop at the terminator rather than printing the padding. |

> Compatibility note: 0x2C, 0x30, 0x34, 0x38 and 0x3C previously read back
> as zero (reserved/undecoded), and 0x40–0x80 were outside the address bus
> entirely (it was 6 bits, 0x00–0x3C). Software that relied on either
> should be updated before targeting this register map. **Block-design
> note:** the widened address bus means the AXI4-Lite address segment for
> this peripheral must now be at least 256 bytes — if your Vivado Address
> Editor still has it set to 64 bytes from before, reads above 0x3C will
> return the interconnect's decode error instead of the new registers; 4K
> is the usual safe choice for a PS-attached slave.

## Build-time parameters

Set on the `axi_sdr_fm` instance; all default to the values below.

| Parameter | Default | Effect |
|---|---|---|
| `CLK_RF_HZ` | `250_000_000` | Frequency of `clk_rf`; used to derive the RF-side CIC decimation ratio. |
| `S_AXI_ACLK_HZ` | `50_000_000` | Frequency of `s_axi_aclk`; used to derive the I2S bit-clock divider. |
| `AUDIO_DATA_WIDTH` | `24` | Audio sample width through the resampler/DAC/I2S path. |
| `RSSI_THRESH_HI` / `RSSI_THRESH_LO` | `2000` / `1200` | Station-found detection thresholds (hysteresis). |
| `DEEMPH_SHIFT` | `8` | De-emphasis IIR pole shift. |
| `DEEMPH_ENABLE` | `1` | Include the de-emphasis filter hardware. |
| `STEREO_ENABLE` | `1` | Include the pilot PLL and L−R stereo path. |
| `RDS_ENABLE` | `1` | Include the RDS decoder. |
| `BASS_BOOST_ENABLE` | `1` | Include the bass-boost filter. |
| `MPX_FIFO_DEPTH` | `1024` | Depth (must be a power of 2) of the raw-MPX export FIFO (`0x2C`/`0x30`). Tune against measured AXI4-Lite polling throughput on the PS side. |
| `AUDIO_FIFO_DEPTH` | `1024` | Depth (must be a power of 2) of the post-resampler audio export FIFO (`0x38`/`0x3C`). Counts individual L/R entries, not stereo pairs. |

Disabling a feature removes its hardware from the build entirely rather
than just idling it at runtime — useful for fitting the design onto
smaller parts, or for a mono-only / no-RDS deployment.

## Clock domains

Two clock domains, one crossing:

- **`clk_rf`** (up to 250 MHz) — `fm_rf_input`, `fm_ddc_mixer`, and the I/Q
  CIC decimators. These are the only blocks that need the full RF sample
  rate.
- **`s_axi_aclk`** (~50 MHz) — everything else: `fm_cordic_discrim`,
  `fm_stereo_demod`, `rds_decode`, `fm_mpx_scale`, `audio_resampler`,
  `fm_ds_dac`, `i2s_tx`, the sample FIFOs, and the AXI4-Lite register file.
  The actual demodulator sample rate is fixed at 250 kHz regardless of
  `clk_rf`, so these blocks are throughput-, not latency-bound, and
  comfortably meet timing at 50 MHz.

The only clock-domain crossing between them is the decimated I/Q sample
pair (`clk_rf` → `s_axi_aclk`), via a toggle-handshake synchronizer. The
tuning word crosses in the opposite direction (`s_axi_aclk` → `clk_rf`)
the same way. Every other control/status signal into or out of
`fm_stereo_demod` is native to `s_axi_aclk` and needs no synchronizer of
its own.

## Known limitations

- RDS groups **0B** and **2B** are not decoded (only 0A and 2A) — a
  deliberate scope limit; most FM broadcasts use 0A/2A.
- No AF (alternate frequency list), CT (clock time), TMC, EON, or ODA
  support.
- The RF front end (`fm_rf_input.v`) is a passive comparator-based direct
  sampler with no LNA, AGC, or dedicated image-reject filtering beyond a
  single hand-tuned LC tank — sensitivity and out-of-band rejection depend
  on that tank and antenna, not on anything digital. See
  [RF front end](#rf-front-end-direct-sampling-with-a-comparator).

## Verification

The DSP-heavy modules (`cic_decimator`, `fm_ddc_mixer`, `rds_decode`,
`fm_stereo_demod`) were developed against Icarus Verilog testbenches,
including differential comparisons against floating-point reference models
for the fixed-point arithmetic. The full hierarchy elaborates cleanly and
has been exercised with a smoke-test bench that resets the design, performs
AXI4-Lite register read/write transactions, and confirms the RF-front-end
→ demodulator → AXI clock-domain crossings settle to defined values.

No functional/DSP-algorithm changes have been made since that
verification — later passes over this code (comment cleanup, parameter
exposure, dead-code removal) were re-checked for compile/elaborate
correctness but did not touch the arithmetic.

## Software / Linux integration

This core is designed to sit behind a Linux driver on the Zynq PS side
rather than be operated by writing raw registers by hand. The broader
project this IP core is part of also includes:

- A V4L2 tuner driver exposing standard controls (frequency, volume, mute,
  stereo/mono, de-emphasis, RDS) over `/dev/radio*`.
- An ALSA driver for the audio path.
- An OpenWrt LuCI web UI (station presets, RDS display, auto-play on boot).

Those components live outside this repository; this repo covers the FPGA
IP core itself.

## Software pipeline (mpx_stream, csdr/csdr2, redsea)

This covers the four command-line tools that make up the receive-side
software pipeline that pairs with this core: **`mpx_stream`** (bridges the
FPGA to userspace), **`csdr`** and **`csdr2`** (DSP pipelines: filtering,
demod, resampling), and **`redsea`** (RDS decoding). It documents how to
*use* them and how they fit together — not how to build or install them;
these are external tools, not part of this repository.

### Pipeline architecture

```
                 ┌───────────────┐
  FPGA           │  mpx_stream   │   raw MPX (s16 mono, ~250 kHz)
  (axi_sdr_fm) ─▶│  --source mpx │──────────┬─────────────────────▶ redsea (RDS)
                 └───────────────┘          │
                                            ▼
                                  csdr / csdr2 (filter, stereo
                                  decode, de-emphasis, resample)
                                            │
                                            ▼
                                          aplay
```

`mpx_stream` is the only thing that talks to the FPGA over `/dev/mem`. Both
`csdr`/`csdr2` and `redsea` are ordinary stdin/stdout filters that never touch
hardware directly — they just consume whatever `mpx_stream` produces.

### `mpx_stream`

Reads AXI4-Lite registers from the SDR core (`axi_sdr_fm`) and streams raw
samples out. Two independent sources:

| Source | Flag | Format | Rate | Notes |
|---|---|---|---|---|
| Raw MPX composite | `--source mpx` (default) | mono, signed 16-bit, little-endian | ~250 kHz nominal | Contains pilot (19 kHz), stereo subcarrier (38 kHz DSB-SC), RDS (57 kHz) — everything, unprocessed. |
| Post-resampler audio | `--source audio` | interleaved stereo, S24_LE | 48 kHz | Already stereo-decoded and de-emphasized **on the FPGA fabric**. |

Common flags:

- `-b <hex>` — AXI4-Lite base address of your `axi_sdr_fm` instance (your
  Vivado Address Editor assignment — there's no universal default, it
  depends on your bitstream). Example used throughout this document:
  `0x43C60000`.
- `-f <freq>` — tune frequency, accepts suffixes (`101.9M`, `98700k`). Writes
  the tuning word register before streaming starts.
- `-o <sink>` — output sink. `stdout` (default, for piping into
  `csdr`/`csdr2`/`redsea`), `file:<path>`, `tcp:<host>:<port>`,
  `udp:<host>:<port>`, `alsa:<device>` (only meaningful with `--source audio`,
  since raw MPX isn't directly playable).

```bash
# raw MPX to stdout, piped downstream (the pipeline this doc is built around)
mpx_stream -b 0x43C60000 -f 101.9M | ...

# hardware-decoded stereo audio straight to a sound card, no csdr/csdr2 at all
mpx_stream --source audio -b 0x43C60000 -f 101.9M -o alsa:plughw:0,0
```

If your card only takes a fixed 48000 Hz and the `--source audio` path fits
your needs, it's the simplest option — everything below is for when you want
the raw MPX in your own hands (custom filtering, RDS alongside playback from
one source, etc.).

### `csdr` vs `csdr2`

Two unrelated codebases, **not** interchangeable command-for-command:

| | `csdr` (ha7ilm) | `csdr2` (jketterl) |
|---|---|---|
| Language | C | C++ |
| Maintenance | Unmaintained since 2019 | Active — OpenWebRX's own DSP backend |
| CLI style | `csdr convert_s16_f`, `csdr fractional_decimator_ff 8 12 --prefilter` | `csdr convert -i s16 -o float`, `csdr fractionaldecimator 8 --prefilter` |
| 24-bit convert | Yes (`convert_f_s24`/`convert_s24_f`) | No — s16/float/char only |
| Stereo decode | Not upstream — added here as a bundled tool | Not upstream — added here as a bundled tool |
| Rational resampler | `rational_resampler_ff` — **broken**, don't use it (see below) | Works correctly, including upsampling |

Both now also ship **`fm_stereo_decode`** and **`resample_upsample_f`** —
small standalone tools bundled alongside them (not separate packages),
described below.

#### `csdr` commands used in these pipelines

- `convert_s16_f` / `convert_f_s16` / `convert_f_s24` / `convert_s24_f` —
  format conversion. Channel-agnostic (works fine on interleaved stereo, it's
  just a flat stream of numbers to these). `convert_f_s24`/`convert_s24_f`
  default to little-endian (`S24_3LE`); pass `--bigendian` for `S24_3BE`.
- `fractional_decimator_ff <rate> <numpoly> [--prefilter]` — decimate by a
  fractional ratio. **Always pass `--prefilter`** — without it, there's no
  anti-aliasing filter at all and everything above the new Nyquist folds
  straight into the audio band. Note the built-in prefilter's cutoff sits
  near the *decimation's own* Nyquist, not at 15 kHz — decimating straight
  from 250000 to 48000 does **not** adequately reject the 19 kHz pilot
  (measured: 0 dB, i.e. it passes straight through). Decimate to something
  around 31250 first (factor 8), *then* bring the rate back up.
- `deemphasis_wfm_ff <rate> <tau>` — de-emphasis (`50e-6` for EU, `75e-6` for
  US). Not stereo-interleave-aware — for stereo, this is handled internally
  by `fm_stereo_decode` instead (see below).
- `rational_resampler_ff` / `suboptimal_rational_resampler_ff` — **do not
  use**. Reproducibly reads uninitialized memory (confirmed on a clean
  build; the symptom is sensitive to heap layout, e.g. it disappears under
  AddressSanitizer, which is consistent with an uninitialized-read bug).
  Use `resample_upsample_f` instead for going back up to a fixed output rate.
- `pll_cc`, `dsb_fc` — general-purpose PLL and real→complex conversion
  primitives; what `fm_stereo_decode` is built on internally.

#### `csdr2` equivalents

- `convert -i <fmt> -o <fmt>` (fmt: `char`, `s16`, `float`) — same role as
  `csdr`'s `convert_*` family, just unified into one command.
- `fractionaldecimator <rate> [-f float|complex] [-n numpoly] [-t transition]
  [-p/--prefilter]` — same idea as `csdr`'s version, but `--prefilter` and a
  custom `--transition` **can be combined** (in `csdr` they're mutually
  exclusive on the command line). The underlying cutoff math is the same
  though — going straight 250000→48000 still doesn't reject the pilot, for
  the same reason as above. Also, unlike `csdr`'s decimator, this one
  **correctly handles rate < 1** (upsampling) — so `csdr2` alone can do the
  full 31250↔48000 round trip without needing `resample_upsample_f` at all,
  if you'd rather keep the pipeline in native `csdr2` commands.
- `deemphasis --wfm <rate> <tau>` (or `--nfm` for narrowband).
- No 24-bit convert format — see the table above.

#### Bundled extras: `fm_stereo_decode` and `resample_upsample_f`

Neither `csdr` nor `csdr2` implements FM stereo (pilot-tone / 38 kHz DSB-SC)
decoding — it's an open, unimplemented feature request against the original
project. `fm_stereo_decode` fills that gap:

```
fm_stereo_decode <mpx_rate_hz> <decimation_factor> [pilot_hz] [tau]
```

Reads real float32 MPX, PLL-locks the 19 kHz pilot, coherently demodulates
the 38 kHz subcarrier for (L−R), lowpass-decimates both (L+R) and (L−R),
de-emphasizes each channel independently, and outputs **interleaved float32
L,R** at `mpx_rate/decimation_factor`. Uses a real phase-locked loop (not a
fixed-frequency mixer) specifically because a real station's pilot is never
exactly 19000.000 Hz relative to your ADC clock — without tracking, the
coherent demod slowly rotates out of phase and stereo separation
periodically collapses to nothing.

`resample_upsample_f <in_rate> <out_rate> [channels]` — linear-interpolation
upsampler, the `rational_resampler_ff` workaround mentioned above. `channels`
defaults to 1 (mono); pass 2 for `fm_stereo_decode`'s interleaved output.
Only correct for **upsampling** an already band-limited signal — that's
exactly the role it plays here (bringing the decimated/filtered rate back up
to whatever your sound hardware needs), not general-purpose resampling.

### `redsea`

Decodes RDS from a raw MPX stream into newline-delimited JSON (one line per
group).

```bash
redsea --input mpx -r 250000
```

`--input mpx` is redsea's default and matches `mpx_stream --source mpx`'s
output format exactly (mono S16LE PCM) — **but the sample rate does not**:
redsea defaults to 171000 Hz (rtl_fm's usual rate), not our 250000. Always
pass `-r` explicitly; recent redsea versions warn on stderr if you don't.
171 kHz decodes fastest since it's a clean multiple of the RDS bit rate, but
any rate ≥128 kHz works — redsea just resamples internally, at some extra
CPU cost.

Useful flags: `-p`/`--show-partial` (print PS/RadioText/AF before fully
received, prefixed `partial_`), `-E`/`--bler` (show block error rate),
`-e`/`--feed-through` (echo input to stdout, groups to stderr — lets you
chain redsea itself into an audio pipeline instead of using `tee`), `-f
<file>` (decode a WAV/FLAC file instead of stdin).

Only one process can read `mpx_stream`'s hardware FIFO at a time, so to get
**audio and RDS from the same reception**, fork the stream with `tee` and
bash process substitution (needs `bash`, not just `ash`/`dash`):

```bash
mpx_stream -b 0x43C60000 -f 101.9M | \
  tee >(redsea --input mpx -r 250000 >> /tmp/rds.jsonl) | \
  csdr convert_s16_f | csdr fractional_decimator_ff 8 12 --prefilter | \
  csdr deemphasis_wfm_ff 31250 50e-6 | resample_upsample_f 31250 48000 | \
  csdr convert_f_s16 | aplay -t raw -r 48000 -f S16_LE -c 1
```

### Pipeline recipes

#### Mono playback — `csdr`

```bash
mpx_stream -b 0x43C60000 -f 101.9M | csdr convert_s16_f | \
  csdr fractional_decimator_ff 8 12 --prefilter | \
  csdr deemphasis_wfm_ff 31250 50e-6 | resample_upsample_f 31250 48000 | \
  csdr convert_f_s24 | aplay -t raw -r 48000 -f S24_3LE -c 1
```

#### Mono playback — `csdr2`

```bash
mpx_stream -b 0x43C60000 -f 101.9M | csdr convert -i s16 -o float | \
  csdr fractionaldecimator 8 --format=float --prefilter | \
  csdr deemphasis --wfm 31250 50e-6 | \
  csdr fractionaldecimator 0.651042 --format=float | \
  csdr convert -i float -o s16 | \
  aplay -D plughw:CARD=0,DEV=0 -t raw -r 48000 -f S16_LE -c 1
```

(`csdr2` has no 24-bit convert — `plughw` handles the final 16→24-bit step in
software instead.)

#### Stereo playback — `csdr` or `csdr2`

Identical either way, since `fm_stereo_decode`/`resample_upsample_f` are
shared, self-contained tools — only the `convert_s16_f`/`convert -i s16 -o
float` front end differs:

```bash
# csdr
mpx_stream -b 0x43C60000 -f 101.9M | csdr convert_s16_f | \
  fm_stereo_decode 250000 8 | resample_upsample_f 31250 48000 2 | \
  csdr convert_f_s24 | aplay -t raw -r 48000 -f S24_3LE -c 2

# csdr2
mpx_stream -b 0x43C60000 -f 101.9M | csdr convert -i s16 -o float | \
  fm_stereo_decode 250000 8 | resample_upsample_f 31250 48000 2 | \
  csdr convert -i float -o s16 | \
  aplay -D plughw:CARD=0,DEV=0 -t raw -r 48000 -f S16_LE -c 2
```

#### RDS only

```bash
mpx_stream -b 0x43C60000 -f 101.9M | redsea --input mpx -r 250000
```

#### Hardware-decoded stereo, no DSP tools at all

```bash
mpx_stream --source audio -b 0x43C60000 -f 101.9M -o alsa:plughw:0,0
```

### Known limitations (software tools)

- **`csdr`'s `fractional_decimator_ff` without `--prefilter` has zero
  anti-aliasing.** Always pass it, every time, for every decimation step.
- **`csdr`'s `rational_resampler_ff`/`suboptimal_rational_resampler_ff` are
  broken** (uninitialized-memory read) — use `resample_upsample_f`.
- **Decimating straight from 250000 Hz to 48000 Hz does not reject the pilot
  tone**, in either `csdr` or `csdr2` — the built-in prefilter's cutoff
  tracks the decimation ratio's own Nyquist, not a fixed 15 kHz. Go through
  an intermediate ~31250 Hz stage.
- **`csdr`'s `convert_f_s24`/`convert_s24_f` default to little-endian
  (`S24_3LE`)** — packed 3 bytes/sample, not the 4-byte-padded `S24_LE`.
  Pass `--bigendian` for `S24_3BE` instead.
- **`tee >(...)` needs `bash`** — won't work under a plain `ash`/`dash`
  shell.

### Troubleshooting

This pipeline sits directly on top of the `axi_sdr_fm` FPGA core's
AXI4-Lite register map — most reception problems that survive past
`mpx_stream` starting up cleanly trace back to that register state, not to
`csdr`/`csdr2`/`redsea`. See the [Register map](#register-map-axi4-lite) and
[Build-time parameters](#build-time-parameters) above for the full picture;
the common cases:

- **`mpx_stream` exits with a permission error opening `/dev/mem`.** Needs
  root (or `CAP_SYS_RAWIO`) — memory-mapped register access isn't something
  a normal user can do. Double-check `-b` too: the wrong base address
  usually doesn't fail outright, it just reads/writes the wrong peripheral's
  registers.
- **Stream starts, but there's silence or a flat/dead signal.** Check
  `CONTROLS` (`0x18`) on the core: bit 0 is mute (must be 0), and if you're
  using `--source audio`, `VOLUME` (`0x14`) being 0 will also produce
  silence even though everything else is working.
- **No RDS groups from `redsea`, ever, on a station you know carries RDS.**
  Confirm `CONTROLS` bit 2 (RDS enable) is set — if the core was built with
  `RDS_ENABLE=0`, the RDS FIFO stays permanently empty regardless of what
  `mpx_stream`/`redsea` do. Also confirm `-r 250000` is actually being
  passed — a silently-wrong sample rate produces plausible-looking JSON with
  garbage content rather than an obvious error.
- **Raw MPX (`--source mpx`) sounds/looks clipped, or unexpectedly quiet.**
  That's the core's `MPX_SHIFT` register (`0x34`), not anything in this
  software pipeline — its reset value is tuned to fit full ±75 kHz
  deviation without clipping, but if it's been changed, `0` trades that
  headroom for more resolution and will flat-top loud peaks.
- **`--source audio` and a raw-MPX-based pipeline disagree about whether
  stereo is present.** They're independent signal paths (one decoded on the
  FPGA, one decoded here in software) — if only one sounds right, the
  problem is specific to that path, not to reception itself. Worth ruling
  out `STEREO_ENABLE=0` on the core (forces `--source audio` to mono) before
  suspecting `fm_stereo_decode`.


## Getting started

1. Add all files in this repository to your Vivado project (2023.2 or
   later recommended).
2. Instantiate `axi_sdr_fm` and connect it to an AXI4-Lite master (e.g. the
   Zynq PS via an AXI interconnect), `clk_rf`/`rst_n` from your RF
   front-end clocking, and the LVDS RF input pins. In Vivado's Address
   Editor, give this peripheral an address range of at least 256 bytes
   (4K is the usual safe default for a PS-attached slave) — the register
   map now reaches up to `0x80`.
3. Drive `TUNING_WORD` (`0x00`) with `round(f_offset / CLK_RF_HZ * 2^32)`,
   where `f_offset` is the desired IF/baseband offset produced by your RF
   front end.
4. Set `CONTROLS` (`0x18`) to unmute and enable the features you want, and
   read `STATUS` (`0x10`) / the RDS registers to monitor reception.


## License

The repository is marked UNLICENSED: see `LICENSE`. Third-party binaries keep
their original licenses; sources and license names are listed in `NOTICE`.
