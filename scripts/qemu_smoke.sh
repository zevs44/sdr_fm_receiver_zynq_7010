#!/usr/bin/env bash
#
# qemu_smoke.sh — загрузка собранного образа OpenWrt в QEMU (xilinx-zynq-a9).
#
# Использование:
#   bash scripts/qemu_smoke.sh <sdcard.img.gz> [таймаут-секунд]
#
# Что делает:
#   1. распаковывает образ и находит FAT-раздел (первый раздел типа c/e);
#   2. достаёт fit.itb, вынимает из него ядро (dumpimage) и DTB платы;
#   3. грузит ядро в QEMU с DTB и SD-картой, снимает последовательную консоль;
#   4. PASS, если в логе появился признак загрузки OpenWrt и нет kernel panic.
#
# Что проверяется: ядро стартует на этом DTB, монтирует squashfs-корень
# с /dev/mmcblk0p2 и доходит до init (procd). PL (радио, I2S) в QEMU не
# эмулируется — это проверка базовой системы, а не звука.
#
# Зависимости: qemu-system-arm, u-boot-tools (dumpimage), mtools, fdisk,
# gzip. Код возврата: 0 — PASS, 1 — FAIL.

set -euo pipefail

IMG_GZ="${1:?использование: qemu_smoke.sh <sdcard.img.gz> [таймаут-секунд]}"
TIMEOUT="${2:-180}"

for t in qemu-system-arm dumpimage mcopy sfdisk gzip; do
  command -v "$t" >/dev/null 2>&1 || { echo "ОШИБКА: нет утилиты '$t'" >&2; exit 1; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "== распаковка образа =="
gzip -dc "$IMG_GZ" > "$WORK/disk.img"
echo "   размер: $(wc -c < "$WORK/disk.img") байт"

# Модель SD-карты в QEMU принимает только размер-степень-двойки, а образ
# усечён (31 МБ при разделах 16 + 200 МБ). Дополняем нулями до ближайшей
# степени двойки не меньше 256 МБ: если образ вырастет, truncate не урежет его.
need="$(wc -c < "$WORK/disk.img")"
size=$((256 * 1024 * 1024))
while [ "$size" -lt "$need" ]; do
  size=$((size * 2))
done
truncate -s "$size" "$WORK/disk.img"
echo "   размер для QEMU: $size байт"

echo "== поиск FAT-раздела =="
# Номер корневого раздела не зашит: он берётся из разметки образа, чтобы
# проверка пережила смену раскладки (root= в командной строке ядра).
fat_off=""
root_part=""
part_no=0
while read -r start type; do
  part_no=$((part_no + 1))
  case "$type" in
    b|c|e|0b|0c|0e|ef) fat_off=$((start * 512)) ;;
    83) root_part="$part_no" ;;
  esac
done < <(sfdisk -d "$WORK/disk.img" 2>/dev/null \
         | sed -n 's/.*start= *\([0-9]*\), *size= *[0-9]*, *type= *\([0-9a-fA-F]*\).*/\1 \2/p')
if [ -z "$fat_off" ]; then
  echo "ОШИБКА: FAT-раздел не найден" >&2
  exit 1
fi
[ -n "$root_part" ] || root_part=2
echo "   FAT по смещению $fat_off, корневой раздел — №$root_part"

echo "== извлечение fit.itb =="
export MTOOLS_SKIP_CHECK=1
mcopy -i "$WORK/disk.img@@$fat_off" ::fit.itb "$WORK/fit.itb"
dumpimage -l "$WORK/fit.itb"

echo "== извлечение ядра и DTB =="
dumpimage -l "$WORK/fit.itb" > "$WORK/fit.list"
# Порядок образов в FIT может измениться: ищем по типу, индексы 0/1 — запасной путь.
fit_index() {
  awk -v want="$1" '
    /^ *Image [0-9]+/ { idx=$2; sub(/[^0-9].*/, "", idx); type=""; next }
    /Type:/ { t=$0; sub(/.*Type: */, "", t); if (t == want) { print idx; exit } }
  ' "$WORK/fit.list"
}
kidx="$(fit_index "Kernel Image")"
didx="$(fit_index "Flat Device Tree")"
[ -n "$kidx" ] || kidx=0
[ -n "$didx" ] || didx=1
echo "   образы FIT: ядро #$kidx, DTB #$didx"

# Адрес загрузки ядра берём из FIT: QEMU для arm32 ставит PC по заголовку
# uImage. Прежняя сборка линкует ядро на 0x8000, но при смене конфигурации
# адрес может измениться — тогда зашитое значение сломает загрузку.
fit_field() {
  awk -v idx="$1" -v key="$2" '
    /^ *Image [0-9]+/ { cur=$2; sub(/[^0-9].*/, "", cur); next }
    cur == idx && index($0, key ":") { sub(".*" key ": *", ""); print; exit }
  ' "$WORK/fit.list"
}
load_addr="$(fit_field "$kidx" "Load Address")"
[ -n "$load_addr" ] || load_addr="0x8000"
echo "   адрес загрузки ядра: $load_addr"
dumpimage -T flat_dt -p "$kidx" -o "$WORK/kernel.gz" "$WORK/fit.itb" >/dev/null
dumpimage -T flat_dt -p "$didx" -o "$WORK/board.dtb" "$WORK/fit.itb" >/dev/null
if [ "$(head -c2 "$WORK/kernel.gz" | od -An -tx1 | tr -d ' \n')" = "1f8b" ]; then
  gunzip -c "$WORK/kernel.gz" > "$WORK/Image"
else
  cp "$WORK/kernel.gz" "$WORK/Image"
fi
echo "   ядро: $(wc -c < "$WORK/Image") байт, DTB: $(wc -c < "$WORK/board.dtb") байт"

# QEMU для arm32 грузит голый Image по 0x10000, а ядро слинковано по адресу
# из FIT (обычно 0x8000). Заворачиваем Image в uImage с явными адресами —
# QEMU читает их из заголовка и ставит PC правильно.
mkimage -A arm -O linux -T kernel -C none -a "$load_addr" -e "$load_addr" \
        -n "openwrt-qemu-smoke" -d "$WORK/Image" "$WORK/kernel.uImage" >/dev/null
echo "   uImage: $(wc -c < "$WORK/kernel.uImage") байт (load/entry $load_addr)"

echo "== загрузка в QEMU (таймаут ${TIMEOUT}s) =="
# Консоль платы — ttyPS0 = serial@e0001000 = второй UART QEMU (serial_hd(1)),
# поэтому первый отдаём в null, второй — в stdio. Дисплей не нужен.
#
# stdin QEMU — файл-очередь (FIFO): через него в консоль уходят команды
# диагностики. Оба конца держим открытыми (<>), иначе QEMU получит EOF
# на пустом вводе и завершится раньше времени.
FIFO="$WORK/serial.in"
mkfifo "$FIFO"
exec 3<>"$FIFO"

set +e
timeout "$TIMEOUT" qemu-system-arm \
  -M xilinx-zynq-a9 -m 512 -display none -monitor none \
  -serial null -serial stdio \
  -kernel "$WORK/kernel.uImage" -dtb "$WORK/board.dtb" \
  -append "console=ttyPS0,115200 root=/dev/mmcblk0p${root_part} rw rootwait" \
  -drive "file=$WORK/disk.img,format=raw,if=sd" \
  < "$FIFO" > "$WORK/serial.log" 2>&1 &
QPID=$!
set -e

# Ожидание строки в журнале: 0 — строка появилась, 1 — таймаут или QEMU
# завершился (ждать больше нечего).
wait_log() {
  pattern="$1"
  limit="$2"
  i=0
  while [ "$i" -lt "$limit" ]; do
    if grep -qaE "$pattern" "$WORK/serial.log" 2>/dev/null; then
      return 0
    fi
    kill -0 "$QPID" 2>/dev/null || return 1
    sleep 1
    i=$((i + 1))
  done
  return 1
}

booted=0
# Ждём появления консоли: в QEMU строка «procd: - init complete -» не печатается —
# инициализация не доходит до конца (сеть и часы отсутствуют). Готовность
# диагностики обеспечивает цикл ожидания исполняемого файла ниже: uci-defaults
# выставляет права во время init, и цикл дождётся их появления.
if wait_log "procd: - init complete -|Please press Enter to activate" "$TIMEOUT"; then
  booted=1
fi

# Диагностика тем же скриптом, что запускает пользователь на плате:
# профиль qemu пропускает проверки, для которых нужны FPGA и NAND.
if [ "$booted" -eq 1 ]; then
  echo "== запуск /myscripts/run-diag-board.sh (профиль qemu) =="
  printf '\n' >&3
  sleep 1
  printf 'i=0; while [ ! -x /myscripts/run-diag-board.sh ] && [ $i -lt 120 ]; do i=$((i+1)); sleep 1; done; /myscripts/run-diag-board.sh --profile qemu\n' >&3
  wait_log 'RESULT: (PASS|FAIL)' 180 || true
fi

# Завершение: команда poweroff, затем сигнал по таймауту-обёртке.
printf 'poweroff -f\n' >&3 2>/dev/null || true
sleep 2
set +e
kill "$QPID" 2>/dev/null
wait "$QPID" 2>/dev/null
exec 3>&-
set -e

# если задан QEMU_LOG — сохраняем лог вне временного каталога (для артефакта CI)
if [ -n "${QEMU_LOG:-}" ]; then
  cp "$WORK/serial.log" "$QEMU_LOG"
fi

echo "== последовательная консоль (хвост) =="
tail -n 120 "$WORK/serial.log" || true

echo "== итог диагностики =="
grep -aE '^(FAIL|SKIP|TOTAL|RESULT)' "$WORK/serial.log" | tail -n 40 || true
if grep -qa "Kernel panic" "$WORK/serial.log"; then
  echo "FAIL: kernel panic" >&2
  exit 1
fi
if [ "$booted" -ne 1 ]; then
  echo "FAIL: признаков загрузки нет" >&2
  exit 1
fi
if grep -qa "RESULT: PASS" "$WORK/serial.log"; then
  echo "PASS: система загрузилась, диагностика без FAIL"
  exit 0
fi
echo "FAIL: диагностика сообщила RESULT: FAIL или не завершилась" >&2
exit 1
