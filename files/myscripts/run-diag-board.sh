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
# Запуск: UART (консоль), ssh, LuCI («DIAG: проверка платы»), конвейер CI.
# Описание проверок и ожидаемых ответов — docs/board-check.ru.md.

PROFILE=board
LOG=/tmp/run-diag-board.log
SOUND=0
FULL=0

while [ $# -gt 0 ]; do
	case "$1" in
		--profile)
			PROFILE="${2:-}"
			[ -n "$PROFILE" ] || { printf 'нужно значение: board|qemu\n' >&2; exit 2; }
			shift 2
			;;
		--log)
			LOG="${2:-}"
			[ -n "$LOG" ] || { printf 'нужен путь к файлу\n' >&2; exit 2; }
			shift 2
			;;
		--sound) SOUND=1; shift ;;
		--full)  FULL=1; shift ;;
		-h|--help)
			sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
			exit 0
			;;
		*)
			printf 'Неизвестный аргумент: %s\n' "$1" >&2
			exit 2
			;;
	esac
done

case "$PROFILE" in
	board|qemu) ;;
	*) printf 'Профиль должен быть board или qemu, получено: %s\n' "$PROFILE" >&2; exit 2 ;;
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
		emit "(код возврата $rc)"
	fi
}

DT=/sys/firmware/devicetree/base

# ── Отметка запуска ──────────────────────────────────────────────────────
emit "run-diag-board.sh: проверка платы Antminer S9"
emit "профиль   : $PROFILE"
emit "дата      : $(date)"
emit "hostname  : $(cat /proc/sys/kernel/hostname 2>/dev/null)"
emit "ядро      : $(uname -r)"
emit "команда   : $(cat /proc/cmdline)"
emit "журнал    : ${LOG:-только консоль}"

# ── 1. Система ───────────────────────────────────────────────────────────
sec "1. система"
show "openwrt_release" cat /etc/openwrt_release
if [ -f /etc/openwrt_release ] && grep -q '^DISTRIB_ID=' /etc/openwrt_release; then
	rel=$(sed -n 's/^DISTRIB_RELEASE=//p' /etc/openwrt_release)
	pass "система: OpenWrt $rel"
else
	fail "система: /etc/openwrt_release отсутствует или без DISTRIB_ID"
fi
if [ "$(awk '$2 == "/rom" { print $3 }' /proc/mounts)" = "squashfs" ]; then
	pass "корневая система: squashfs смонтирована в /rom"
else
	fail "корневая система: /rom не смонтирован как squashfs"
fi

total=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)
if [ "${total:-0}" -ge 400000 ]; then
	pass "память: $((total / 1024)) Мб"
else
	fail "память: ${total:-0} Кб — меньше ожидаемых 400 000 Кб"
fi

# ── 2. Каталог пользовательских скриптов ─────────────────────────────────
sec "2. каталог /myscripts"
# В образе нет утилит stat и hostname: права берём из ls, имя — из /proc.
perm_of() { ls -ld "$1" 2>/dev/null | awk '{print $1}'; }
if [ -d /myscripts ]; then
	perm=$(perm_of /myscripts)
	if [ "$perm" = "drwxrwxrwx" ]; then
		pass "каталог /myscripts с правами 777"
	else
		fail "каталог /myscripts с правами ${perm:-неизвестно} вместо drwxrwxrwx"
	fi
else
	fail "каталога /myscripts нет"
fi
if [ -x /myscripts/run-diag-board.sh ]; then
	pass "скрипт /myscripts/run-diag-board.sh на месте"
	perm=$(perm_of /myscripts/run-diag-board.sh)
	if [ "$perm" = "-rwxrwxrwx" ]; then
		pass "скрипт /myscripts/run-diag-board.sh с правами 777"
	else
		fail "скрипт /myscripts/run-diag-board.sh с правами ${perm:-неизвестно} вместо -rwxrwxrwx"
	fi
else
	fail "скрипта /myscripts/run-diag-board.sh нет"
fi

# ── 3. Дерево устройства ─────────────────────────────────────────────────
sec "3. дерево устройства"
missing=""
for n in axi_i2s_adi@43c00000 fm-radio@43c60000 sound audio_clock; do
	if [ ! -e "$DT/$n" ]; then
		missing="$missing $n"
	fi
done
if [ -z "$missing" ]; then
	pass "узлы FPGA в DT: axi_i2s_adi, fm-radio, sound, audio_clock"
else
	fail "в DT нет узлов:$missing"
fi

labels=$(find "$DT" -type f -name label -path '*partition*' -exec cat {} \; 2>/dev/null | tr '\000' '\n')
missing=""
for l in boot uboot fpga uboot_env kernel rootfs; do
	printf '%s\n' "$labels" | grep -qx "$l" || missing="$missing $l"
done
if [ -z "$missing" ]; then
	pass "разделы NAND в DT: шесть меток"
else
	fail "в DT нет разделов:$missing"
fi

if grep -q 'earlyprintk' /proc/cmdline; then
	fail "командная строка: лишний параметр earlyprintk"
else
	pass "командная строка: без earlyprintk"
fi

# ── 4. Радиотракт ────────────────────────────────────────────────────────
sec "4. радиотракт"
if [ "$PROFILE" = "qemu" ]; then
	skip "драйвер радио: FPGA в QEMU не эмулируется"
else
	if [ -e /dev/radio0 ]; then
		pass "драйвер радио: /dev/radio0"
	else
		fail "драйвер радио: нет /dev/radio0"
	fi
	show "v4l2-ctl --list-devices" v4l2-ctl --list-devices
fi

# ── 5. Звук ──────────────────────────────────────────────────────────────
sec "5. звук"
if [ "$PROFILE" = "qemu" ]; then
	skip "карта ALSA: FPGA в QEMU не эмулируется"
else
	if [ -r /proc/asound/cards ] && grep -q 'audio' /proc/asound/cards; then
		pass "карта ALSA: sound-card «audio»"
	else
		fail "карта ALSA: нет карты «audio» в /proc/asound/cards"
	fi
	show "aplay -l" aplay -l
	if [ "$SOUND" = "1" ]; then
		emit "проверка воспроизведения: тон 1 кГц, 5 секунд; выход — J2 (PDM)"
		show "speaker-test" speaker-test -D hw:0,0 -c 2 -t sine -l 1
		if [ -r /proc/asound/cards ] && grep -q 'audio' /proc/asound/cards; then
			pass "воспроизведение: поток открылся"
		else
			fail "воспроизведение: карта недоступна"
		fi
	fi
fi

# ── 6. NAND ──────────────────────────────────────────────────────────────
sec "6. NAND"
if [ "$PROFILE" = "qemu" ]; then
	skip "разделы NAND: в QEMU NAND не эмулируется"
	skip "окружение U-Boot: в QEMU раздел uboot_env недоступен"
	skip "nand_install --dry-run: в QEMU нет NAND и SD-карты как /dev/mmcblk0p1"
else
	if [ -s /proc/mtd ]; then
		missing=""
		for l in boot uboot fpga uboot_env kernel rootfs; do
			grep -q "\"$l\"" /proc/mtd || missing="$missing $l"
		done
		if [ -z "$missing" ]; then
			pass "разделы NAND: /proc/mtd с шестью метками"
		else
			fail "в /proc/mtd нет:$missing"
		fi
	else
		fail "разделы NAND: /proc/mtd пуст — драйвер не загрузился"
	fi
	show "cat /proc/mtd" cat /proc/mtd

	if [ -f /etc/fw_env.config ]; then
		pass "окружение U-Boot: /etc/fw_env.config на месте"
	else
		fail "окружение U-Boot: нет /etc/fw_env.config"
	fi
	if command -v fw_printenv >/dev/null 2>&1; then
		if fw_printenv >/dev/null 2>&1; then
			pass "окружение U-Boot: fw_printenv читается"
		else
			fail "окружение U-Boot: fw_printenv завершился ошибкой"
		fi
	else
		skip "окружение U-Boot: утилиты fw_printenv нет"
	fi

	if command -v nand_install >/dev/null 2>&1; then
		if nand_install --dry-run >/dev/null 2>&1; then
			pass "nand_install --dry-run: план проверен"
		else
			fail "nand_install --dry-run: завершился ошибкой"
		fi
	else
		fail "nand_install: утилиты нет в системе"
	fi
fi

# ── 7. Сеть, MAC, hostname ───────────────────────────────────────────────
sec "7. сеть"
if [ "$PROFILE" = "qemu" ]; then
	skip "сеть: интерфейс платы в QEMU не эмулируется"
else
	if ip link show eth0 >/dev/null 2>&1; then
		pass "сеть: интерфейс eth0 есть"
		if ip -4 addr show eth0 2>/dev/null | grep -q 'inet '; then
			pass "сеть: IPv4 получен по DHCP"
		else
			skip "сеть: адреса нет — проверьте кабель и DHCP-сервер"
		fi
	else
		fail "сеть: интерфейса eth0 нет"
	fi
fi

host_name=$(cat /proc/sys/kernel/hostname 2>/dev/null)
case "$host_name" in
	owrt-zynq7010-*) pass "hostname: $host_name" ;;
	*) fail "hostname: ${host_name:-пусто} — ожидался owrt-zynq7010-XXXX" ;;
esac

if [ -s /etc/antminer-mac ]; then
	pass "MAC: постоянный адрес $(cat /etc/antminer-mac)"
else
	fail "MAC: нет /etc/antminer-mac"
fi

if [ "$(uci -q get network.lan.proto)" = "dhcp" ]; then
	pass "настройка сети: lan по DHCP"
else
	fail "настройка сети: network.lan.proto = «$(uci -q get network.lan.proto)» вместо dhcp"
fi

# ── 8. Службы и LuCI ─────────────────────────────────────────────────────
sec "8. службы"
if [ -f /www/cgi-bin/luci ]; then
	pass "LuCI: /www/cgi-bin/luci на месте"
else
	fail "LuCI: нет /www/cgi-bin/luci"
fi
if [ "$PROFILE" = "qemu" ]; then
	skip "служба uhttpd: в QEMU без сети не проверяется"
else
	if /etc/init.d/uhttpd status >/dev/null 2>&1; then
		pass "служба uhttpd: запущена"
	else
		fail "служба uhttpd: не запущена"
	fi
fi
tail_log=$(logread 2>/dev/null | tail -n 15)
if [ -n "$tail_log" ]; then
	emit "--- logread (хвост) ---"
	emit "$tail_log"
fi

# ── 9. Полные журналы ────────────────────────────────────────────────────
if [ "$FULL" = "1" ]; then
	sec "9. полный dmesg"
	emit "$(dmesg 2>&1)"
	sec "9.1 полный logread"
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
