# Board peripherals

What the Antminer S9 control board (Zynq-7010) carries, what OpenWrt uses, and how
to reach the rest. Sources: the control board schematic (sheet numbers are given
below), the board device tree in this repository, and the FPGA constraints file.

## What is populated

| Part | Present | Consequence |
|---|---|---|
| Headers J6, J7, J8 | yes | the external I2S output and the antenna are wired here |
| Headers J1-J5, J9 | no | the J2 (delta-sigma DAC), J4 (FM analog) and J9 (external I2S input) nets have no connector |
| Fan headers FAN5, FAN6 | yes | two fans can be connected |
| Fan headers FAN1-FAN4 | no | marked `FAN HEADER_NC` in the schematic |
| Buttons S1, S2 | yes | reset and IP reporting |
| PS LEDs | three: MIO15, MIO37, MIO38 | controlled by `gpio-leds` |
| PL LEDs | four: M17, M19, L19, F16 | driven by the bitstream |
| Buzzer BZ1 | no | footprint and driver transistor only |

## PS LEDs

Three indicators belong to the PS and appear in `/sys/class/leds`:

| Sysfs name | Pin | Default |
|---|---|---|
| `s9:red:usr` | MIO37 | off |
| `s9:green:usr` | MIO38 | on at boot (`default-on`) |
| `s9:red:inner` | MIO15 | off |

They need `kmod-leds-gpio`, which is part of the image, and the nodes declared in
the device tree. Control from the shell:

```sh
ls /sys/class/leds
echo 1 > /sys/class/leds/s9:green:usr/brightness
```

The same LEDs are available in LuCI under **System → LED Configuration**; the
defaults are written once by `/etc/uci-defaults/98_antminer_leds`.

## Buttons

| Button | Pin | Behavior |
|---|---|---|
| `reset` (S1) | MIO47 | short press reboots; holding 5 s or more performs a factory reset and enters failsafe |
| `ip_get` (S2) | MIO51 | short press renews the DHCP lease on `lan` and logs the address |

Events are delivered by `gpio-button-hotplug`; the name comes from the `label`
property of the device tree node, and `/etc/rc.button/<label>` handles it. Check:

```sh
logread -f | grep -i ip-get
```

## Buzzer

`BZ1` is a footprint on schematic sheet 4, next to the indicator transistors Q2/Q3
and button S2. Two pads:

| Pad | Net | Meaning |
|---|---|---|
| 1 | through diode D4 (`1N4148`) from the 3.3 V rail | positive terminal |
| 2 | collector of Q1 (`MMBT3904`) | negative terminal, switched to ground |

The base of Q1 is driven through R39 (1 kOhm) from MIO39; C20 (0.1 uF) sits across
the buzzer. Solder an **active** 3.3 V buzzer with two leads. Check the polarity
with a multimeter: the positive pad is the one connected to the cathode of D4.

No rebuild is needed: the node is already in the device tree as an LED-class pin.

```sh
echo 1 > /sys/class/leds/s9:buzzer/brightness
sleep 1
echo 0 > /sys/class/leds/s9:buzzer/brightness
```

A passive transducer needs a square wave, so it requires a PWM core in the
bitstream and the `pwm-beeper` driver instead.

## XADC

The internal ADC gives the die temperature. The node is enabled in the board device
tree; the driver is built into the image.

```sh
cat /sys/bus/iio/devices/iio:device0/name        # xadc
cat /sys/bus/iio/devices/iio:device0/in_temp0_raw
cat /sys/bus/iio/devices/iio:device0/in_temp0_offset
cat /sys/bus/iio/devices/iio:device0/in_temp0_scale
```

The temperature in millidegrees is `(raw + offset) * scale`.

## Fans

Fan control lives in the FPGA: `FAN_PWM` on BANK35_L14P, `FAN_SPEED1..6` on
BANK35_L15P, L15N, L16P, L16N, L17P and L17N (schematic, sheet 6). One PWM output
is shared by all channels, each channel has its own tachometer input. The current
bitstream does not drive them, and there is no Linux interface yet: adding fans
means adding a PWM module and counters to the design.

## SD card detect and write protection

The microSD socket has both switches wired to the PS: card detect on MIO46
(`CD_SW`) and write protect on MIO50 (`CD_WP`). They are not used by default.

`target_patches_optional/0350_zynq_sd_card_detect.patch` adds `cd-gpios` and
`wp-gpios` to the `sdhci0` node. Measure the polarity before enabling the patch:
with the wrong polarity the kernel sees no card, and the board does not boot from
the card it just started from. The measurement recipe is in the patch directory
README.

## Notes and limits

- The board has no USB connector, although the device tree keeps `usb0` enabled
  from the upstream board support.
- The bitstream still generates the J2 and J4 signals, but those headers are not
  soldered: the signals have nowhere to go.
- The four PL LEDs show reception status from the bitstream (stereo lock, station
  found, RDS sync, audio heartbeat); Linux does not control them.
- Everything above was checked against the schematic and the device tree; the
  buzzer and the SD card switches were not measured on hardware yet.
