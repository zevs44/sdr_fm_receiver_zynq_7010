#!/usr/bin/env bash
#
# apply.sh — подготовка дерева OpenWrt к сборке образа Antminer S9.
#
# Использование:
#   bash scripts/apply.sh [путь-к-openwrt]
#   по умолчанию — ./openwrt рядом с репозиторием
#
# Что делает:
#   1. накладывает все патчи из target-patches/ по порядку (с проверкой, что ложатся);
#   2. копирует битстрим в дерево сборки (если он есть);
#   3. подключает фид автора как локальный src-link и ставит все фиды;
#   4. ставит наш .config и запускает make defconfig.
#
# Код возврата 0 — дерево готово к `make world`.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OWRT="${1:-$HERE/openwrt}"
CFG="$HERE/configs/zynq_antminer_s9.config"
VERSION="$(tr -d '[:space:]' < "$HERE/.openwrt-version" 2>/dev/null || echo '')"

# цель и подцель берутся из конфига, чтобы не дублировать их в скрипте
TARGET="$(sed -n 's/^CONFIG_TARGET_\([a-z0-9]*\)=y$/\1/p' "$CFG" | head -1)"
SUBTARGET="$(sed -n 's/^CONFIG_TARGET_[a-z0-9]*_\([a-z0-9]*\)=y$/\1/p' "$CFG" | head -1)"

if [ ! -d "$OWRT" ]; then
  echo "ОШИБКА: каталог OpenWrt не найден: $OWRT" >&2
  echo "Склонируйте его: git clone --depth 1 -b ${VERSION:-<тег>} https://github.com/openwrt/openwrt.git $OWRT" >&2
  exit 1
fi

echo "== 1. патчи =="
shopt -s nullglob
patches=("$HERE"/target-patches/*.patch)
if [ ${#patches[@]} -eq 0 ]; then
  echo "   ПРЕДУПРЕЖДЕНИЕ: в target-patches/ нет ни одного патча."
  echo "   Сборка получится без поддержки платы и без узлов PL."
else
  for p in "${patches[@]}"; do
    name="$(basename "$p")"
    if ! (cd "$OWRT" && git apply --check -p1 "$p" 2>/dev/null); then
      echo "   ОШИБКА: патч не ложится на это дерево: $name" >&2
      echo "   Скорее всего изменилась версия OpenWrt (тег в .openwrt-version)." >&2
      echo "   Проверьте вручную: cd $OWRT && git apply --check -p1 $p" >&2
      exit 1
    fi
    (cd "$OWRT" && git apply -p1 "$p")
    echo "   ok  $name"
  done
fi

echo "== 2. файлы для FAT-раздела =="
mkdir -p "$OWRT/antminer"
for f in boot.bin u-boot.img uboot_env.bin; do
  if [ -f "$HERE/bootloader/$f" ]; then
    cp "$HERE/bootloader/$f" "$OWRT/antminer/$f"
    echo "   загрузчик: $f ($(wc -c < "$OWRT/antminer/$f") байт)"
  else
    echo "   ОШИБКА: нет bootloader/$f — образ будет незагружаемым" >&2
    exit 1
  fi
done
if [ -f "$HERE/bitstream/system.bit.gz" ]; then
  cp "$HERE/bitstream/system.bit.gz" "$OWRT/antminer/system.bit.gz"
  echo "   битстрим: $(wc -c < "$OWRT/antminer/system.bit.gz") байт"
else
  echo "   битстрима нет — образ соберётся без PL (fpga loadb не сработает)"
fi
cp "$HERE/files/uEnv.txt" "$OWRT/antminer/uEnv.txt"
echo "   uEnv.txt: скопирован"

echo "== 3. feeds автора =="
cd "$OWRT"
if ! grep -q '^src-link antminer ' feeds.conf.default 2>/dev/null; then
  echo "src-link antminer $HERE/packages" >> feeds.conf.default
  echo "   подключён src-link antminer -> $HERE/packages"
else
  echo "   src-link antminer уже подключён"
fi
./scripts/feeds update -a
# Ставим ВСЕ фиды, а не только antminer: `feeds install -p antminer` подтягивает
# лишь зависимости пакетов автора, и тогда LuCI-тема, luci-ssl, i2c-tools и другие
# «необязательные» пакеты из официальных фидов остаются невидимыми для defconfig
# и молча выпадают из конфига.
./scripts/feeds install -a

echo "== 4. конфигурация =="
cp "$CFG" .config
make defconfig

echo
echo "Готово. Дальше:"
echo "  cd $OWRT && make -j\$(nproc) download && make -j\$(nproc) world"
echo "Результат: $OWRT/bin/targets/${TARGET:-<цель>}/${SUBTARGET:-<подцель>}/"
