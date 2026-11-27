#!/usr/bin/env bash
#
# check_config.sh — сверка запрошенного конфига с итоговым .config.
#
# Использование:
#   bash scripts/check_config.sh <каталог-openwrt> [запрошенный-конфиг]
#   по умолчанию запрошенный конфиг — configs/zynq_antminer_s9.config
#
# Зачем: `make defconfig` молча выбрасывает символы, которые не разрешились
# (неизвестное имя, невыполнимая зависимость, отсутствующий пакет). В итоге
# образ собирается, CI зелёный, а нужного пакета в системе нет. Скрипт ловит
# такое до сборки.
#
# Классификация расхождений:
#   FAIL — символ CONFIG_PACKAGE_* (пакет или kmod выпал/сменил значение);
#   WARN — остальные символы (цель, размеры разделов, опции ядра).
#
# Код возврата: 0 — провалов нет (WARN допустимы), 1 — есть FAIL.
#
# Сообщения консоли — на английском: журнал шага читают в конвейере.
# Комментарии остаются на языке проекта.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OWRT="${1:-$HERE/openwrt}"
REQ="${2:-$HERE/configs/zynq_antminer_s9.config}"
CONF="$OWRT/.config"

if [ ! -f "$CONF" ]; then
  echo "ERROR: $CONF is missing — run scripts/apply.sh first" >&2
  exit 1
fi
if [ ! -f "$REQ" ]; then
  echo "ERROR: requested config $REQ is missing" >&2
  exit 1
fi

checked=0
fail=0
warn=0

report() {
  # $1 — уровень (FAIL/WARN), $2 — символ, $3 — пояснение
  if [ "$1" = "FAIL" ]; then
    fail=$((fail + 1))
  else
    warn=$((warn + 1))
  fi
  printf '  %-4s %-52s %s\n' "$1" "$2" "$3"
}

echo "== config check =="
echo "   requested: $REQ"
echo "   resulting: $CONF"
echo

while IFS= read -r line; do
  if [[ "$line" == "# CONFIG_"*" is not set" ]]; then
    # так OpenWrt записывает выключенные символы
    key="${line#\# }"
    key="${key% is not set}"
    want="n"
  else
    case "$line" in
      '' | \#*) continue ;;
      CONFIG_*=*)
        key="${line%%=*}"
        want="${line#*=}"
        ;;
      *) continue ;;
    esac
  fi

  checked=$((checked + 1))

  case "$key" in
    CONFIG_PACKAGE_*) level=FAIL ;;
    *) level=WARN ;;
  esac

  if [ "$want" = "n" ]; then
    if grep -qx "$key=n" "$CONF" || grep -qx "# $key is not set" "$CONF"; then
      continue
    fi
    got="$(grep -m1 -E "^${key}=" "$CONF" | cut -d= -f2 || true)"
    report "$level" "$key" "expected n, in .config: ${got:-no line}"
    continue
  fi

  if grep -qx "$key=$want" "$CONF"; then
    continue
  fi

  if grep -q -E "^${key}=" "$CONF"; then
    got="$(grep -m1 -E "^${key}=" "$CONF" | cut -d= -f2)"
    report "$level" "$key" "expected $want, in .config: $got"
  else
    report "$level" "$key" "expected $want, the symbol is absent from .config (dropped by defconfig)"
  fi
done < "$REQ"

# ── опции ядра из target_patches ────────────────────────────────────────────
# Символы Kconfig в target/linux/*/config-6.* не входят в запрошенный конфиг
# OpenWrt, поэтому сверх defconfig их никто не проверяет. При невыполненной
# зависимости kconfig отбрасывает символ без сообщения об ошибке: звук и NAND
# исчезают из ядра, а сборка остаётся успешной (образ v25.12.6, журнал
# 17_boot_log_v25_12_6.md).
# Имя файла берём шаблоном: при смене ядра оно станет config-6.18 и т. п.
KCONF="$(find "$OWRT/target/linux/zynq" -maxdepth 1 -name 'config-6.*' 2>/dev/null | sort | tail -1 || true)"
if [ -z "$KCONF" ]; then
  echo
  echo "ERROR: no config-6.* in target/linux/zynq — target not found or patches did not apply." >&2
  fail=$((fail + 1))
else
  echo
  echo "== kernel options in $(basename "$KCONF") =="
  for sym in CONFIG_SOUND CONFIG_SND CONFIG_SND_SOC_ADI_AXI_I2S \
             CONFIG_SND_SIMPLE_CARD CONFIG_MTD_RAW_NAND \
             CONFIG_MTD_NAND_PL35X CONFIG_MTD_UBI CONFIG_UBIFS_FS; do
    checked=$((checked + 1))
    if grep -qx "$sym=y" "$KCONF"; then
      printf '  PASS %-32s\n' "$sym"
    else
      fail=$((fail + 1))
      printf '  FAIL %-32s missing from %s: the kernel will be built without this feature\n' "$sym" "$(basename "$KCONF")"
    fi
  done
fi

echo
echo "Summary: checked $checked, failures $fail, warnings $warn"

if [ "$fail" -gt 0 ]; then
  echo "ERROR: defconfig dropped or changed selected packages — the image will be built without them." >&2
  exit 1
fi

printf '%s: all CONFIG_PACKAGE_* symbols applied as requested.\n' PASS
