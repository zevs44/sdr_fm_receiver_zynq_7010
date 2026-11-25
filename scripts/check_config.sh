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

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OWRT="${1:-$HERE/openwrt}"
REQ="${2:-$HERE/configs/zynq_antminer_s9.config}"
CONF="$OWRT/.config"

if [ ! -f "$CONF" ]; then
  echo "ОШИБКА: нет $CONF — сначала запустите scripts/apply.sh" >&2
  exit 1
fi
if [ ! -f "$REQ" ]; then
  echo "ОШИБКА: нет запрошенного конфига $REQ" >&2
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

echo "== сверка конфига =="
echo "   запрошен : $REQ"
echo "   итоговый : $CONF"
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
    report "$level" "$key" "ожидалось n, в .config: ${got:-нет строки}"
    continue
  fi

  if grep -qx "$key=$want" "$CONF"; then
    continue
  fi

  if grep -q -E "^${key}=" "$CONF"; then
    got="$(grep -m1 -E "^${key}=" "$CONF" | cut -d= -f2)"
    report "$level" "$key" "ожидалось $want, в .config: $got"
  else
    report "$level" "$key" "ожидалось $want, символа в .config нет (выброшен defconfig)"
  fi
done < "$REQ"

# ── опции ядра из target-patches ────────────────────────────────────────────
# Символы Kconfig в target/linux/*/config-6.* не входят в запрошенный конфиг
# OpenWrt, поэтому сверх defconfig их никто не проверяет. При невыполненной
# зависимости kconfig отбрасывает символ без сообщения об ошибке: звук и NAND
# исчезают из ядра, а сборка остаётся успешной (образ v25.12.6, журнал
# 17_boot_log_v25.12.6.log).
# Имя файла берём шаблоном: при смене ядра оно станет config-6.18 и т. п.
KCONF="$(ls "$OWRT/target/linux/zynq"/config-6.* 2>/dev/null | tail -1 || true)"
if [ -z "$KCONF" ]; then
  echo
  echo "ОШИБКА: в target/linux/zynq нет config-6.* — цель не найдена или патчи не легли." >&2
  fail=$((fail + 1))
else
  echo
  echo "== опции ядра в $(basename "$KCONF") =="
  for sym in CONFIG_SOUND CONFIG_SND CONFIG_SND_SOC_ADI_AXI_I2S \
             CONFIG_SND_SIMPLE_CARD CONFIG_MTD_RAW_NAND \
             CONFIG_MTD_NAND_PL35X CONFIG_MTD_UBI CONFIG_UBIFS_FS; do
    checked=$((checked + 1))
    if grep -qx "$sym=y" "$KCONF"; then
      printf '  PASS %-32s\n' "$sym"
    else
      fail=$((fail + 1))
      printf '  FAIL %-32s нет в %s: ядро соберётся без этой возможности\n' "$sym" "$(basename "$KCONF")"
    fi
  done
fi

echo
echo "Итог: проверено $checked, провалов $fail, предупреждений $warn"

if [ "$fail" -gt 0 ]; then
  echo "ОШИБКА: defconfig выбросил или изменил выбранные пакеты — образ соберётся без них." >&2
  exit 1
fi

echo "PASS: все CONFIG_PACKAGE_* применены как запрошено."
