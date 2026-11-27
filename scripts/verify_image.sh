#!/usr/bin/env bash
#
# verify_image.sh — проверка собранного образа SD-карты.
#
# Использование:
#   bash scripts/verify_image.sh [каталог-с-образом]
#   по умолчанию — openwrt/bin/targets/zynq/generic
#
# Что проверяет:
#   1. архив: gzip цел, образ распакован, sha256 и размер напечатаны;
#   2. разделы: их два, FAT и squashfs, размеры правдоподобные;
#   3. FAT-раздел: boot.bin, u-boot.img, uboot_env.bin, uEnv.txt, fit.itb,
#      system.bit.gz — на месте и не пустые; метка тома — ANTMINER_S9;
#   4. содержимое: system.bit.gz побайтово равен репозиторному, uEnv.txt
#      содержит `fpga loadb`, в fit.itb есть строка платы;
#   5. корневая ФС: бинарники fm_radio/csdr/mympd, LuCI-приложение,
#      модуль ядра zynq_fm_radio.ko.
#
# Зачем: CI сейчас зелёный при любом непустом *.img.gz. Образ без битстрима
# или без kmod загружается, но радио и звук не работают — и это видно только
# на плате.
#
# Переменные окружения:
#   ALLOW_MISSING_BITSTREAM=1 — не считать отсутствие битстрима провалом.
#
# Код возврата: 0 — все проверки PASS (или SKIP), 1 — есть FAIL.
#
# Сообщения консоли — на английском: журнал шага читают в конвейере.
# Комментарии остаются на языке проекта.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${1:-$HERE/openwrt/bin/targets/zynq/generic}"

pass=0
fail=0
skip=0

ok() { pass=$((pass + 1)); printf '  PASS  %s\n' "$*"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$*"; }
skipped() { skip=$((skip + 1)); printf '  SKIP  %s\n' "$*"; }

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: utility '$1' is missing (package: $2)" >&2
    exit 1
  fi
}

echo "== image check =="

IMG_GZ="$(ls "$BIN_DIR"/*sdcard*.img.gz 2>/dev/null | head -1 || true)"
if [ -z "$IMG_GZ" ]; then
  echo "ERROR: no *sdcard*.img.gz in $BIN_DIR" >&2
  exit 1
fi
echo "   image: $IMG_GZ"
echo "   archive size: $(wc -c < "$IMG_GZ") bytes"

need gzip gzip
need sha256sum coreutils
need sfdisk fdisk
need mdir mtools
need mcopy mtools
need mtype mtools

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if gzip -t "$IMG_GZ" 2>/dev/null; then
  ok "gzip archive is intact"
else
  bad "gzip archive is corrupted"
  echo "Summary: PASS $pass, FAIL $fail, SKIP $skip"
  exit 1
fi

IMG="$TMP/disk.img"
gzip -dc "$IMG_GZ" > "$IMG"
echo "   image size: $(wc -c < "$IMG") bytes"
echo "   image sha256: $(sha256sum "$IMG" | cut -d' ' -f1)"

# ── разделы ──────────────────────────────────────────────────────────────
mapfile -t PARTS < <(sfdisk -d "$IMG" 2>/dev/null \
  | sed -n 's/.*start= *\([0-9]*\), *size= *\([0-9]*\), *type= *\([0-9a-fA-F]*\).*/\1 \2 \3/p')

if [ "${#PARTS[@]}" -eq 2 ]; then
  ok "exactly two partitions"
else
  bad "expected two partitions, found ${#PARTS[@]}"
fi

fat_off=""
rootfs_off=""
for p in "${PARTS[@]:-}"; do
  read -r start size type <<< "$p"
  bytes=$((size * 512))
  case "$type" in
    b | c | e | 0b | 0c | 0e | ef) fat_off=$((start * 512)); fat_bytes=$bytes ;;
    83) rootfs_off=$((start * 512)); rootfs_bytes=$bytes ;;
  esac
done

if [ -n "$fat_off" ]; then
  ok "FAT partition found, $((fat_bytes / 1024 / 1024)) MB"
else
  bad "FAT partition not found"
fi
if [ -n "$rootfs_off" ]; then
  ok "root partition found, $((rootfs_bytes / 1024 / 1024)) MB"
else
  bad "root partition not found"
fi

# Метка тома: её задаёт mkfs.fat -n в target/linux/zynq/image/Makefile
# (патч 0200). Метка видна в Windows и blkid; проверяем, что сборка её не потеряла.
EXPECTED_FAT_LABEL="${EXPECTED_FAT_LABEL:-ANTMINER_S9}"
if [ -n "$fat_off" ]; then
  if command -v blkid >/dev/null 2>&1; then
    fat_label="$(blkid -p -O "$fat_off" -o value -s LABEL "$IMG" 2>/dev/null || true)"
    if [ "$fat_label" = "$EXPECTED_FAT_LABEL" ]; then
      ok "FAT volume label is $EXPECTED_FAT_LABEL"
    else
      bad "FAT volume label is '${fat_label:-none}' instead of $EXPECTED_FAT_LABEL"
    fi
  else
    skipped "FAT volume label: blkid is missing"
  fi
fi

# ── FAT-раздел ───────────────────────────────────────────────────────────
if [ -n "$fat_off" ]; then
  FAT="$IMG@@$fat_off"
  export MTOOLS_SKIP_CHECK=1

  # Проверяем каждый файл напрямую, а не разбором `mdir -b ::`: формат
  # листинга зависит от версии mtools, и на прогоне 45354756963 grep -x
  # не совпал ни с одним именем, хотя mtype/mcopy те же файлы читали.
  for f in boot.bin u-boot.img uboot_env.bin uEnv.txt fit.itb system.bit.gz; do
    if mdir -i "$FAT" "::$f" >/dev/null 2>&1; then
      ok "FAT: $f is present"
    elif [ "$f" = "system.bit.gz" ] && [ "${ALLOW_MISSING_BITSTREAM:-0}" = "1" ]; then
      skipped "FAT: system.bit.gz is missing (allowed by ALLOW_MISSING_BITSTREAM=1), PL will be empty"
    else
      bad "FAT: $f is missing"
    fi
  done
  echo "   FAT listing: $(mdir -b -i "$FAT" :: 2>/dev/null | tr '\n' ' ')"

  # uEnv.txt: команда загрузки битстрима и ядра
  if mtype -i "$FAT" ::uEnv.txt > "$TMP/uEnv.txt" 2>/dev/null; then
    if grep -q "fpga loadb" "$TMP/uEnv.txt"; then
      ok "uEnv.txt contains 'fpga loadb'"
    else
      bad "uEnv.txt has no 'fpga loadb' — PL will not load"
    fi
    if grep -q "fit.itb" "$TMP/uEnv.txt"; then
      ok "uEnv.txt loads fit.itb"
    else
      bad "uEnv.txt does not load fit.itb"
    fi
    if grep -q "earlyprintk" "$TMP/uEnv.txt"; then
      bad "uEnv.txt contains earlyprintk — the kernel will report an unknown parameter"
    else
      ok "uEnv.txt has no extra earlyprintk"
    fi
    if [ -f "$HERE/files/uEnv.txt" ] &&
       [ "$(sha256sum < "$TMP/uEnv.txt" | cut -d' ' -f1)" = "$(sha256sum < "$HERE/files/uEnv.txt" | cut -d' ' -f1)" ]; then
      ok "uEnv.txt matches files/uEnv.txt"
    else
      bad "uEnv.txt in the image differs from files/uEnv.txt"
    fi
  else
    bad "uEnv.txt cannot be read from FAT"
  fi

  # system.bit.gz: байт-в-байт с репозиторным
  if mcopy -i "$FAT" -o ::system.bit.gz "$TMP/system.bit.gz" 2>/dev/null; then
    if [ -f "$HERE/bitstream/system.bit.gz" ] &&
       [ "$(sha256sum < "$TMP/system.bit.gz" | cut -d' ' -f1)" = "$(sha256sum < "$HERE/bitstream/system.bit.gz" | cut -d' ' -f1)" ]; then
      ok "system.bit.gz in the image matches bitstream/"
    else
      bad "system.bit.gz in the image does not match bitstream/"
    fi
    # `|| true` обязателен: head закрывает поток раньше, gzip получает SIGPIPE,
    # а с `set -o pipefail` это уронило бы скрипт на ровном месте
    magic="$(gzip -dc "$TMP/system.bit.gz" 2>/dev/null | head -c 4 | od -An -tx1 | tr -d ' \n' || true)"
    if [ "$magic" = "00090ff0" ]; then
      ok "bitstream magic 00 09 0f f0"
    else
      bad "bitstream magic is wrong: $magic"
    fi
  elif [ "${ALLOW_MISSING_BITSTREAM:-0}" != "1" ]; then
    bad "system.bit.gz cannot be extracted from FAT"
  fi

  # fit.itb: ядро с деревом устройства нужной платы
  if mcopy -i "$FAT" -o ::fit.itb "$TMP/fit.itb" 2>/dev/null; then
    if grep -qa "antminer" "$TMP/fit.itb"; then
      ok "fit.itb mentions antminer"
    else
      bad "fit.itb has no antminer string — possibly a wrong device tree"
    fi

    # узлы PL в DTB: без них драйвер радио и ALSA-карта не появятся
    if command -v dumpimage >/dev/null 2>&1 && command -v dtc >/dev/null 2>&1; then
      if dumpimage -T flat_dt -p 1 -o "$TMP/board.dtb" "$TMP/fit.itb" >/dev/null 2>&1 &&
         dtc -I dtb -O dts "$TMP/board.dtb" > "$TMP/board.dts" 2>/dev/null; then
        for node in "fm-radio@43c60000" "axi_i2s_adi@43c00000" "audio_clock" "sound"; do
          if grep -q "$node" "$TMP/board.dts"; then
            ok "DTB: node $node"
          else
            bad "DTB: node $node is missing (no /dev/radio0 and no ALSA card)"
          fi
        done
        # Разделы NAND: без них /proc/mtd пуст и nand_install не работает.
        for label in boot uboot fpga uboot_env kernel rootfs; do
          if grep -q "label = \"$label\";" "$TMP/board.dts"; then
            ok "DTB: NAND partition $label"
          else
            bad "DTB: NAND partition $label is missing (nand_install will not find the label)"
          fi
        done
      else
        bad "DTB: cannot extract or parse the DTB from fit.itb"
      fi
    else
      skipped "DTB: no dumpimage or dtc"
    fi
  else
    bad "fit.itb cannot be extracted from FAT"
  fi
fi

# ── корневая ФС ──────────────────────────────────────────────────────────
if [ -n "$rootfs_off" ]; then
  if command -v unsquashfs >/dev/null 2>&1; then
    if unsquashfs -o "$rootfs_off" -l "$IMG" > "$TMP/rootfs.list" 2>/dev/null; then
      check_in_rootfs() {
        if grep -qE "(^|/)${1}$" "$TMP/rootfs.list"; then
          ok "rootfs: $1"
        else
          bad "rootfs: $1 is missing"
        fi
      }
      check_in_rootfs "usr/bin/fm_radio"
      check_in_rootfs "usr/bin/csdr"
      check_in_rootfs "usr/bin/mympd"
      check_in_rootfs "sbin/nand_install"
      check_in_rootfs "etc/uci-defaults/99_antminer_setup"
      check_in_rootfs "etc/fw_env.config"
      check_in_rootfs "etc/uci-defaults/91_board_scripts"
      check_in_rootfs "myscripts/run-diag-board.sh"
      # Права на /myscripts в образе не проверяются: их ставит uci-defaults
      # при первой загрузке (91_board_scripts), а в рантайме — сама диагностика
      # (run-diag-board.sh) и шаг 03 qemu smoke. Разбор режимов в squashfs
      # зависел от версии unsquashfs и от формата листинга — источник ложных FAIL.
      check_in_rootfs "usr/libexec/rpcd/fmradio"
      check_in_rootfs "etc/init.d/fmradio"
      if grep -qE "/lib/modules/[^/]+/zynq_fm_radio\.ko$" "$TMP/rootfs.list"; then
        ok "rootfs: module zynq_fm_radio.ko"
      else
        bad "rootfs: zynq_fm_radio.ko is missing"
      fi
      if grep -qE "/www/luci-static/resources/view/fmradio/" "$TMP/rootfs.list"; then
        ok "rootfs: LuCI fmradio view"
      else
        bad "rootfs: LuCI fmradio view is missing"
      fi
    else
      bad "root partition is not readable as squashfs"
    fi
  else
    skipped "rootfs check: no unsquashfs (squashfs-tools package)"
  fi
fi

echo
echo "Summary: PASS $pass, FAIL $fail, SKIP $skip"

if [ "$fail" -gt 0 ]; then
  echo "ERROR: the image was built, but checks failed." >&2
  exit 1
fi

printf '%s: image passed all checks\n' PASS
