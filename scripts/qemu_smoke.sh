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
fat_off=""
while read -r start type; do
  case "$type" in
    c|e|0c|0e) fat_off=$((start * 512)) ;;
  esac
done < <(sfdisk -d "$WORK/disk.img" 2>/dev/null \
         | sed -n 's/.*start= *\([0-9]*\), *size= *[0-9]*, *type= *\([0-9a-fA-F]*\).*/\1 \2/p')
if [ -z "$fat_off" ]; then
  echo "ОШИБКА: FAT-раздел не найден" >&2
  exit 1
fi
echo "   FAT по смещению $fat_off"

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
dumpimage -T flat_dt -p "$kidx" -o "$WORK/kernel.gz" "$WORK/fit.itb" >/dev/null
dumpimage -T flat_dt -p "$didx" -o "$WORK/board.dtb" "$WORK/fit.itb" >/dev/null
if [ "$(head -c2 "$WORK/kernel.gz" | od -An -tx1 | tr -d ' \n')" = "1f8b" ]; then
  gunzip -c "$WORK/kernel.gz" > "$WORK/Image"
else
  cp "$WORK/kernel.gz" "$WORK/Image"
fi
echo "   ядро: $(wc -c < "$WORK/Image") байт, DTB: $(wc -c < "$WORK/board.dtb") байт"

# QEMU для arm32 грузит голый Image по 0x10000, а ядро слинковано на 0x8000
# (так и записано в FIT). Заворачиваем Image в uImage с явными адресами —
# QEMU читает их из заголовка и ставит PC правильно.
mkimage -A arm -O linux -T kernel -C none -a 0x8000 -e 0x8000 \
        -n "openwrt-qemu-smoke" -d "$WORK/Image" "$WORK/kernel.uImage" >/dev/null
echo "   uImage: $(wc -c < "$WORK/kernel.uImage") байт (load/entry 0x8000)"

echo "== загрузка в QEMU (таймаут ${TIMEOUT}s) =="
# Консоль платы — ttyPS0 = serial@e0001000 = второй UART QEMU (serial_hd(1)),
# поэтому первый отдаём в null, второй — в stdio. Дисплей не нужен.
set +e
timeout "$TIMEOUT" qemu-system-arm \
  -M xilinx-zynq-a9 -m 512 -display none \
  -serial null -serial stdio \
  -kernel "$WORK/kernel.uImage" -dtb "$WORK/board.dtb" \
  -append "console=ttyPS0,115200 root=/dev/mmcblk0p2 rw rootwait" \
  -drive "file=$WORK/disk.img,format=raw,if=sd" \
  > "$WORK/serial.log" 2>&1
rc=$?
set -e

# если задан QEMU_LOG — сохраняем лог вне временного каталога (для артефакта CI)
if [ -n "${QEMU_LOG:-}" ]; then
  cp "$WORK/serial.log" "$QEMU_LOG"
fi

echo "== последовательная консоль (хвост) =="
tail -n 80 "$WORK/serial.log" || true

if grep -q "Kernel panic" "$WORK/serial.log"; then
  echo "FAIL: kernel panic" >&2
  exit 1
fi
if grep -qE "procd: - init complete -|Please press Enter to activate this console|BusyBox v[0-9]" "$WORK/serial.log"; then
  echo "PASS: система дошла до init"
  exit 0
fi
echo "FAIL: признаков загрузки нет (код QEMU $rc)" >&2
exit 1
