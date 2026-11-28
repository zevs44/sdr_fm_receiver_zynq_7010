#!/bin/sh
#
# run-diag-board.sh — диагностика платы Antminer S9 (Zynq-7010) и её образа OpenWrt.
#
# Один и тот же скрипт работает на плате и в QEMU во время сборки:
#   run-diag-board.sh                     профиль board, параметры по умолчанию
#   run-diag-board.sh --profile qemu      проверки, применимые без FPGA и NAND
#   run-diag-board.sh --log /путь/файл    дублировать вывод в файл
#   run-diag-board.sh --sound             добавить проверку воспроизведения
#   run-diag-board.sh --full              добавить полные dmesg и logread
#
# Формат строки результата: «PASS|FAIL|SKIP  проверка: подробность».
# Итог: «TOTAL pass=N fail=N skip=N» и «RESULT: PASS|FAIL».
# Код возврата: 0 — ни одного FAIL, 1 — есть FAIL, 2 — неверные аргументы.
#
# Запуск: UART (консоль), ssh, LuCI («DIAG: board check»), конвейер CI.
# Описание проверок и ожидаемых ответов — docs/04_board_check_ru.md.
#
# Сообщения консоли — на английском: тот же вывод читают конвейер и разбор
# журнала. Комментарии остаются на языке проекта.

PROFILE=board
LOG=/tmp/run-diag-board.log
SOUND=0
FULL=0

usage() {
	cat <<EOF
Usage: run-diag-board.sh [options]

  --profile board|qemu   board (default) runs every check; qemu skips FPGA and NAND
  --log <file>           duplicate the output into a file (default /tmp/run-diag-board.log)
  --sound                add a 1 kHz playback check (about 5 seconds)
  --full                 add the full dmesg and logread
  -h, --help             this help

Result lines: PASS|FAIL|SKIP  check: detail
Summary: TOTAL pass=N fail=N skip=N and RESULT: PASS|FAIL
Exit code: 0 — no FAIL, 1 — at least one FAIL, 2 — bad arguments
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--profile)
			PROFILE="${2:-}"
			[ -n "$PROFILE" ] || { printf 'value required: board|qemu\n' >&2; exit 2; }
			shift 2
			;;
		--log)
			LOG="${2:-}"
			[ -n "$LOG" ] || { printf 'a file path is required\n' >&2; exit 2; }
			shift 2
			;;
		--sound) SOUND=1; shift ;;
		--full)  FULL=1; shift ;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			printf 'Unknown argument: %s\n' "$1" >&2
			exit 2
			;;
	esac
done

case "$PROFILE" in
	board|qemu) ;;
	*) printf 'Profile must be board or qemu, got: %s\n' "$PROFILE" >&2; exit 2 ;;
esac

# Журнал — копия вывода для передачи на анализ. Если файл недоступен,
# скрипт продолжает работу в консоль: проверка важнее журнала.
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
: > "$LOG" 2>/dev/null || LOG=""

PASS=0
FAIL=0
SKIP=0

emit() {
	if [ -n "$LOG" ]; then
		printf '%s\n' "$*" >> "$LOG"
	fi
	printf '%s\n' "$*"
}

pass() { PASS=$((PASS + 1)); emit "PASS  $*"; }
fail() { FAIL=$((FAIL + 1)); emit "FAIL  $*"; }
skip() { SKIP=$((SKIP + 1)); emit "SKIP  $*"; }

sec() {
	emit ""
	emit "===== $* ====="
}

# Вывод команды с заголовком. Ненулевой код печатается рядом: отказ команды
# и пустой вывод — разные факты.
show() {
	label="$1"
	shift
	out=$("$@" 2>&1)
	rc=$?
	emit "--- $label ---"
	if [ -n "$out" ]; then
		emit "$out"
	fi
	if [ "$rc" -ne 0 ]; then
		emit "(exit code $rc)"
	fi
}

DT=/sys/firmware/devicetree/base

# ── Отметка запуска ──────────────────────────────────────────────────────
emit "run-diag-board.sh: Antminer S9 board diagnostics"
emit "profile   : $PROFILE"
emit "date      : $(date)"
emit "hostname  : $(cat /proc/sys/kernel/hostname 2>/dev/null)"
emit "kernel    : $(uname -r)"
emit "cmdline   : $(cat /proc/cmdline)"
emit "log       : ${LOG:-console only}"

# ── 1. Система ───────────────────────────────────────────────────────────
sec "1. system"
show "openwrt_release" cat /etc/openwrt_release
if [ -f /etc/openwrt_release ] && grep -q '^DISTRIB_ID=' /etc/openwrt_release; then
	rel=$(sed -n 's/^DISTRIB_RELEASE=//p' /etc/openwrt_release)
	pass "system: OpenWrt $rel"
else
	fail "system: /etc/openwrt_release is missing or has no DISTRIB_ID"
fi
if [ "$(awk '$2 == "/rom" { print $3 }' /proc/mounts)" = "squashfs" ]; then
	pass "root filesystem: squashfs mounted at /rom"
else
	fail "root filesystem: /rom is not mounted as squashfs"
fi

total=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)
if [ "${total:-0}" -ge 400000 ]; then
	pass "memory: $((total / 1024)) MB"
else
	fail "memory: ${total:-0} kB is less than the expected 400000 kB"
fi

# ── 2. Каталог пользовательских скриптов ─────────────────────────────────
sec "2. /myscripts directory"
# В образе нет утилит stat и hostname: права берём из ls, имя — из /proc.
perm_of() { ls -ld "$1" 2>/dev/null | awk '{print $1}'; }
if [ -d /myscripts ]; then
	perm=$(perm_of /myscripts)
	if [ "$perm" = "drwxrwxrwx" ]; then
		pass "directory /myscripts has mode 777"
	else
		fail "directory /myscripts has mode ${perm:-unknown} instead of drwxrwxrwx"
	fi
else
	fail "directory /myscripts is missing"
fi
if [ -x /myscripts/run-diag-board.sh ]; then
	pass "script /myscripts/run-diag-board.sh is present"
	perm=$(perm_of /myscripts/run-diag-board.sh)
	if [ "$perm" = "-rwxrwxrwx" ]; then
		pass "script /myscripts/run-diag-board.sh has mode 777"
	else
		fail "script /myscripts/run-diag-board.sh has mode ${perm:-unknown} instead of -rwxrwxrwx"
	fi
else
	fail "script /myscripts/run-diag-board.sh is missing"
fi

# ── 3. Дерево устройства ─────────────────────────────────────────────────
sec "3. device tree"
missing=""
for n in axi_i2s_adi@43c00000 fm-radio@43c60000 sound audio_clock; do
	if [ ! -e "$DT/$n" ]; then
		missing="$missing $n"
	fi
done
if [ -z "$missing" ]; then
	pass "FPGA nodes in DT: axi_i2s_adi, fm-radio, sound, audio_clock"
else
	fail "DT is missing nodes:$missing"
fi

labels=$(find "$DT" -type f -name label -path '*partition*' -exec cat {} \; 2>/dev/null | tr '\000' '\n')
missing=""
for l in boot uboot fpga uboot_env kernel rootfs; do
	printf '%s\n' "$labels" | grep -qx "$l" || missing="$missing $l"
done
if [ -z "$missing" ]; then
	pass "NAND partitions in DT: six labels"
else
	fail "DT is missing partitions:$missing"
fi

if grep -q 'earlyprintk' /proc/cmdline; then
	fail "kernel command line: extra earlyprintk parameter"
else
	pass "kernel command line: no earlyprintk"
fi

# Индикаторы PS: узлы gpio-leds в DT работают только с kmod-leds-gpio,
# поэтому проверяется результат — записи в /sys/class/leds.
if [ "$PROFILE" = "qemu" ]; then
	skip "PS LEDs: the QEMU device tree has no gpio-leds"
else
	missing=""
	for l in "s9:red:usr" "s9:green:usr" "s9:red:inner"; do
		if [ ! -e "/sys/class/leds/$l" ]; then
			missing="$missing $l"
		fi
	done
	if [ -z "$missing" ]; then
		pass "PS LEDs registered: s9:red:usr, s9:green:usr, s9:red:inner"
	else
		fail "PS LEDs are missing:$missing (kmod-leds-gpio is not loaded)"
	fi
fi

# Зуммер и температура кристалла: узлы в DTB платы, в дереве QEMU их нет.
if [ "$PROFILE" = "qemu" ]; then
	skip "buzzer: the QEMU device tree has no buzzer"
	skip "XADC: the QEMU device tree has no xadc node"
else
	if [ -e /sys/class/leds/s9:buzzer ]; then
		pass "buzzer: /sys/class/leds/s9:buzzer"
	else
		fail "buzzer: s9:buzzer is missing (DTB node or leds-gpio driver)"
	fi
	if [ -r /sys/bus/iio/devices/iio:device0/name ] &&
	   [ "$(cat /sys/bus/iio/devices/iio:device0/name 2>/dev/null)" = "xadc" ]; then
		pass "XADC: iio device present"
	else
		fail "XADC: iio device is missing (adc node is not enabled)"
	fi
fi
# Кнопки: события раздаёт gpio-button-hotplug; список устройств — для сверки.
show "input devices" cat /proc/bus/input/devices

# ── 4. Радиотракт ────────────────────────────────────────────────────────
sec "4. radio path"
if [ "$PROFILE" = "qemu" ]; then
	skip "radio driver: FPGA is not emulated in QEMU"
else
	if [ -e /dev/radio0 ]; then
		pass "radio driver: /dev/radio0"
	else
		fail "radio driver: /dev/radio0 is missing"
	fi
	show "v4l2-ctl --list-devices" v4l2-ctl --list-devices
fi

# ── 5. Звук ──────────────────────────────────────────────────────────────
sec "5. sound"
if [ "$PROFILE" = "qemu" ]; then
	skip "ALSA card: FPGA is not emulated in QEMU"
else
	if [ -r /proc/asound/cards ] && grep -q 'audio' /proc/asound/cards; then
		pass "ALSA card: sound card \"audio\""
	else
		fail "ALSA card: no \"audio\" card in /proc/asound/cards"
	fi
	show "aplay -l" aplay -l
	if [ "$SOUND" = "1" ]; then
		emit "playback check: 1 kHz tone, 5 seconds; output J2 (PDM)"
		show "speaker-test" speaker-test -D hw:0,0 -c 2 -t sine -l 1
		if [ -r /proc/asound/cards ] && grep -q 'audio' /proc/asound/cards; then
			pass "playback: stream opened"
		else
			fail "playback: card unavailable"
		fi
	fi
fi

# ── 6. NAND ──────────────────────────────────────────────────────────────
sec "6. NAND"
if [ "$PROFILE" = "qemu" ]; then
	skip "NAND partitions: NAND is not emulated in QEMU"
	skip "U-Boot environment: the uboot_env partition is unavailable in QEMU"
	skip "nand_install --dry-run: QEMU has no NAND and no SD card as /dev/mmcblk0p1"
else
	# /proc/mtd — файл procfs: его stat-размер всегда 0, поэтому `-s` даёт
	# ложный FAIL. Проверяем читаемость и наличие строк с разделами (П16).
	if [ -r /proc/mtd ] && grep -q '^mtd[0-9]' /proc/mtd; then
		missing=""
		for l in boot uboot fpga uboot_env kernel rootfs; do
			grep -q "\"$l\"" /proc/mtd || missing="$missing $l"
		done
		if [ -z "$missing" ]; then
			pass "NAND partitions: /proc/mtd has six labels"
		else
			fail "/proc/mtd is missing:$missing"
		fi
	else
		fail "NAND partitions: /proc/mtd is empty — the driver did not load"
	fi
	show "cat /proc/mtd" cat /proc/mtd

	if [ -f /etc/fw_env.config ]; then
		pass "U-Boot environment: /etc/fw_env.config is present"
	else
		fail "U-Boot environment: /etc/fw_env.config is missing"
	fi
	if command -v fw_printenv >/dev/null 2>&1; then
		if fw_printenv >/dev/null 2>&1; then
			pass "U-Boot environment: fw_printenv reads it"
		else
			fail "U-Boot environment: fw_printenv exited with an error"
		fi
	else
		skip "U-Boot environment: fw_printenv utility is missing"
	fi

	if command -v nand_install >/dev/null 2>&1; then
		if nand_install --dry-run >/dev/null 2>&1; then
			pass "nand_install --dry-run: plan verified"
		else
			fail "nand_install --dry-run: exited with an error"
		fi
	else
		fail "nand_install: utility is missing from the system"
	fi
fi

# ── 7. Сеть, MAC, hostname ───────────────────────────────────────────────
sec "7. network"
if [ "$PROFILE" = "qemu" ]; then
	skip "network: the board interface is not emulated in QEMU"
else
	if ip link show eth0 >/dev/null 2>&1; then
		pass "network: interface eth0 is present"
		if ip -4 addr show eth0 2>/dev/null | grep -q 'inet '; then
			pass "network: IPv4 address obtained via DHCP"
		else
			skip "network: no address — check the cable and the DHCP server"
		fi
	else
		fail "network: interface eth0 is missing"
	fi
fi

host_name=$(cat /proc/sys/kernel/hostname 2>/dev/null)
case "$host_name" in
	owrt-zynq7010-*) pass "hostname: $host_name" ;;
	*) fail "hostname: ${host_name:-empty} — expected owrt-zynq7010-XXXX" ;;
esac

if [ -s /etc/antminer-mac ]; then
	pass "MAC: persistent address $(cat /etc/antminer-mac)"
else
	fail "MAC: /etc/antminer-mac is missing"
fi

if [ "$(uci -q get network.lan.proto)" = "dhcp" ]; then
	pass "network configuration: lan uses DHCP"
else
	fail "network configuration: network.lan.proto = \"$(uci -q get network.lan.proto)\" instead of dhcp"
fi

# ── 8. Службы и LuCI ─────────────────────────────────────────────────────
sec "8. services"
if [ -f /www/cgi-bin/luci ]; then
	pass "LuCI: /www/cgi-bin/luci is present"
else
	fail "LuCI: /www/cgi-bin/luci is missing"
fi
if [ "$PROFILE" = "qemu" ]; then
	skip "uhttpd service: not checked in QEMU without network"
else
	if /etc/init.d/uhttpd status >/dev/null 2>&1; then
		pass "uhttpd service: running"
	else
		fail "uhttpd service: not running"
	fi
fi
tail_log=$(logread 2>/dev/null | tail -n 15)
if [ -n "$tail_log" ]; then
	emit "--- logread (tail) ---"
	emit "$tail_log"
fi

# ── 9. Полные журналы ────────────────────────────────────────────────────
if [ "$FULL" = "1" ]; then
	sec "9. full dmesg"
	emit "$(dmesg 2>&1)"
	sec "9.1 full logread"
	emit "$(logread 2>&1)"
fi

# ── Итог ─────────────────────────────────────────────────────────────────
emit ""
emit "TOTAL pass=$PASS fail=$FAIL skip=$SKIP"
if [ "$FAIL" -eq 0 ]; then
	emit "RESULT: PASS"
	exit 0
fi
emit "RESULT: FAIL"
exit 1
